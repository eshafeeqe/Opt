
local S = require("std")
local util = require("util")
local C = util.C
local Timer = util.Timer

solversGPU = {}

local function noHeader(pd)
	return quote end
end

local function noFooter(pd)
	return quote end
end

solversGPU.gradientDescentGPU = function(problemSpec, vars)

	local struct PlanData(S.Object) {
		plan : opt.Plan
		images : vars.PlanImages
		scratchF : &float
		
		gradStore : vars.unknownType

		timer : Timer
	}
	
	local specializedKernels = {}
	specializedKernels.updatePosition = function(data)
		local terra updatePositionGPU(pd : &data.PlanData, w : int, h : int, learningRate : float)
			var delta = -learningRate * pd.gradStore(w, h)
			pd.images.unknown(w, h) = pd.images.unknown(w, h) + delta
		end
		return { kernel = updatePositionGPU, header = noHeader, footer = noFooter, params = {symbol(float)}, mapMemberName = "unknown" }
	end
	
	local gpu = util.makeGPUFunctions(problemSpec, vars, PlanData, specializedKernels)
	
	local terra impl(data_ : &opaque, images : &&opaque, params_ : &opaque)
		var pd = [&PlanData](data_)
		pd.timer:init()

		var params = [&double](params_)

		unpackstruct(pd.images) = [util.getImages(PlanData, images)]

		-- TODO: parameterize these
		var initialLearningRate = 0.01
		var maxIters = 5000
		var tolerance = 1e-10

		-- Fixed constants (these do not need to be parameterized)
		var learningLoss = 0.8
		var learningGain = 1.1
		var minLearningRate = 1e-25

		var learningRate = initialLearningRate
		
		for iter = 0, maxIters do

			var startCost = gpu.computeCost(pd, pd.images.unknown)
			logSolver("iteration %d, cost=%f, learningRate=%f\n", iter, startCost, learningRate)
			
			gpu.computeGradient(pd, pd.gradStore)
			
			--
			-- move along the gradient by learningRate
			--
			gpu.updatePosition(pd, learningRate)
			
			--
			-- update the learningRate
			--
			var endCost = gpu.computeCost(pd, pd.images.unknown)
			if endCost < startCost then
				learningRate = learningRate * learningGain
			else
				learningRate = learningRate * learningLoss

				if learningRate < minLearningRate then
					break
				end
			end
			pd.timer:nextIteration()
		end
		pd.timer:evaluate()
		pd.timer:cleanup()
	end

	local terra makePlan() : &opt.Plan
		var pd = PlanData.alloc()
		pd.plan.data = pd
		pd.plan.impl = impl

		pd.gradStore:initGPU()
		C.cudaMallocManaged([&&opaque](&(pd.scratchF)), sizeof(float), C.cudaMemAttachGlobal)

		return &pd.plan
	end
	return makePlan
end

-- vector-free L-BFGS using two-loop recursion: http://papers.nips.cc/paper/5333-large-scale-l-bfgs-using-mapreduce.pdf
solversGPU.vlbfgsGPU = function(problemSpec, vars)

	local maxIters = 1000
	local m = 5
	local b = 2 * m + 1

	local struct GPUStore {
		-- These all live on the CPU!
		dotProductMatrix : vars.unknownType
		dotProductMatrixStorage : vars.unknownType
		alphaList : vars.unknownType
		coefficients : float[b]
	}

	-- TODO: alphaList must be a custom image!
	local struct PlanData(S.Object) {
		plan : opt.Plan
		images : vars.PlanImages
		scratchF : &float
		
		gradient : vars.unknownType
		prevGradient : vars.unknownType

		p : vars.unknownType
		
		timer : Timer

		sList : vars.unknownType[m]
		yList : vars.unknownType[m]
		
		-- variables used for line search
		currentValues : vars.unknownType
		currentResiduals : vars.unknownType
		
		gpuStore : GPUStore
	}
		
	local terra imageFromIndex(pd : &PlanData, index : int)
		if index < m then
			return pd.sList[index]
		elseif index < 2 * m then
			return pd.yList[index - m]
		else
			return pd.gradient
		end
	end
	
	local terra nextCoefficientIndex(index : int)
		if index == m - 1 or index == 2 * m - 1 or index == 2 * m then
			return -1
		end
		return index + 1
	end
	
	local specializedKernels = {}
	
	local gpu = util.makeGPUFunctions(problemSpec, vars, PlanData, {})
	local cpu = util.makeCPUFunctions(problemSpec, vars, PlanData)
	
	local terra impl(data_ : &opaque, images : &&opaque, params_ : &opaque)
		
		var pd = [&PlanData](data_)
		var params = [&double](params_)
		pd.timer:init()
		unpackstruct(pd.images) = [util.getImages(PlanData, images)]

		var k = 0
		
		-- using an initial guess of alpha means that it will invoke quadratic optimization on the first iteration,
		-- which is only sometimes a good idea.
		var prevBestAlpha = 0.0
		
		gpu.computeGradient(pd, pd.gradient)

		for iter = 0, maxIters - 1 do
		
			var iterStartCost = gpu.computeCost(pd, pd.images.unknown)
			
			logSolver("iteration %d, cost=%f\n", iter, iterStartCost)
			
			--
			-- compute the search direction p
			--
			if k == 0 then
				gpu.copyImageScale(pd, pd.p, pd.gradient, -1.0f)
			else
				-- note that much of this happens on the CPU!
				
				-- compute the top half of the dot product matrix
				cpu.copyImage(pd.gpuStore.dotProductMatrixStorage, pd.gpuStore.dotProductMatrix)
				for i = 0, b do
					for j = i, b do
						var prevI = nextCoefficientIndex(i)
						var prevJ = nextCoefficientIndex(j)
						if prevI == -1 or prevJ == -1 then
							pd.gpuStore.dotProductMatrix(i, j) = gpu.innerProduct(pd, imageFromIndex(pd, i), imageFromIndex(pd, j))
							C.printf("%d dot %d\n", i, j)
						else
							pd.gpuStore.dotProductMatrix(i, j) = pd.gpuStore.dotProductMatrixStorage(prevI, prevJ)
						end
					end
				end
				
				-- compute the bottom half of the dot product matrix
				for i = 1, b do
					for j = 0, i - 1 do
						pd.gpuStore.dotProductMatrix(i, j) = pd.gpuStore.dotProductMatrix(j, i)
					end
				end
			
				for i = 0, 2 * m do pd.gpuStore.coefficients[i] = 0.0 end
				pd.gpuStore.coefficients[2 * m] = -1.0
				
				for i = k - 1, k - m - 1, -1 do
					if i < 0 then break end
					var j = i - (k - m)
					
					var num = 0.0
					for q = 0, b do
						num = num + pd.gpuStore.coefficients[q] * pd.gpuStore.dotProductMatrix(q, j)
					end
					var den = pd.gpuStore.dotProductMatrix(j, j + m)
					pd.gpuStore.alphaList(i, 0) = num / den
					pd.gpuStore.coefficients[j + m] = pd.gpuStore.coefficients[j + m] - pd.gpuStore.alphaList(i, 0)
				end
				
				var scale = pd.gpuStore.dotProductMatrix(m - 1, 2 * m - 1) / pd.gpuStore.dotProductMatrix(2 * m - 1, 2 * m - 1)
				for i = 0, b do
					pd.gpuStore.coefficients[i] = pd.gpuStore.coefficients[i] * scale
				end
				
				for i = k - m, k do
					if i >= 0 then
						var j = i - (k - m)
						var num = 0.0
						for q = 0, b do
							num = num + pd.gpuStore.coefficients[q] * pd.gpuStore.dotProductMatrix(q, m + j)
						end
						var den = pd.gpuStore.dotProductMatrix(j, j + m)
						var beta = num / den
						pd.gpuStore.coefficients[j] = pd.gpuStore.coefficients[j] + (pd.gpuStore.alphaList(i, 0) - beta)
					end
				end
				
				-- reconstruct p from basis vectors
				gpu.copyImageScale(pd, pd.p, pd.p, 0.0f)
				for i = 0, b do
					var image = imageFromIndex(pd, i)
					var coefficient = pd.gpuStore.coefficients[i]
					gpu.addImage(pd, pd.p, image, coefficient)
				end
			end
			
			--
			-- line search
			--
			gpu.copyImage(pd, pd.currentValues, pd.images.unknown)
			--gpu.computeResiduals(pd, pd.currentResiduals, pd.currentValues)
			
			var bestAlpha = gpu.lineSearchQuadraticFallback(pd, pd.currentValues, pd.currentResiduals, iterStartCost, pd.p, pd.images.unknown, prevBestAlpha)
			
			-- cycle the oldest s and y
			var yListStore = pd.yList[0]
			var sListStore = pd.sList[0]
			for i = 0, m - 1 do
				pd.yList[i] = pd.yList[i + 1]
				pd.sList[i] = pd.sList[i + 1]
			end
			pd.yList[m - 1] = yListStore
			pd.sList[m - 1] = sListStore
			
			-- compute new x and s
			gpu.copyImageScale(pd, pd.sList[m - 1], pd.p, bestAlpha)
			gpu.combineImage(pd, pd.images.unknown, pd.currentValues, pd.sList[m - 1], 1.0f)
			
			gpu.copyImage(pd, pd.prevGradient, pd.gradient)
			
			gpu.computeGradient(pd, pd.gradient)
			
			-- compute new y
			gpu.combineImage(pd, pd.yList[m - 1], pd.gradient, pd.prevGradient, -1.0f)
			
			prevBestAlpha = bestAlpha
		
			
			k = k + 1
			
			logSolver("alpha=%12.12f\n\n", bestAlpha)
			if bestAlpha == 0.0 then
				break
			end
		end
		pd.timer:evaluate()
		pd.timer:cleanup()
	end
	
	local terra makePlan() : &opt.Plan
		var pd = PlanData.alloc()
		pd.plan.data = pd
		pd.plan.impl = impl

		pd.gradient:initGPU()
		pd.prevGradient:initGPU()
		
		pd.currentValues:initGPU()
		pd.currentResiduals:initGPU()
		
		pd.p:initGPU()
		
		for i = 0, m do
			pd.sList[i]:initGPU()
			pd.yList[i]:initGPU()
		end
		
		C.cudaMallocManaged([&&opaque](&(pd.scratchF)), sizeof(float), C.cudaMemAttachGlobal)
		
		-- CPU!
		pd.gpuStore.dotProductMatrix:initCPU()
		pd.gpuStore.dotProductMatrixStorage:initCPU()
		pd.gpuStore.alphaList:initCPU()
		--pd.alphaList:initCPU(maxIters, 1)
		

		return &pd.plan
	end
	return makePlan
end

return solversGPU