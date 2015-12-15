local IO = terralib.includec("stdio.h")
local adP = ad.ProblemSpec()
local P = adP.P
local W,H = opt.Dim("W",0), opt.Dim("H",1)

local X = 			adP:Image("X", opt.float6,W,H,0)			--vertex.xyz, rotation.xyz <- unknown
local UrShape = 	adP:Image("UrShape", opt.float3,W,H,1)		--urshape: vertex.xyz
local Constraints = adP:Image("Constraints", opt.float3,W,H,2)	--constraints
local G = adP:Graph("G", 0, "v0", W, H, 0, "v1", W, H, 1)
P:Stencil(2)

local C = terralib.includecstring [[
#include <math.h>
]]


local w_fitSqrt = adP:Param("w_fitSqrt", float, 0)
local w_regSqrt = adP:Param("w_regSqrt", float, 1)

useAD = true
useHandwrittenMath = false

if useAD then
	function evalRot(CosAlpha, CosBeta, CosGamma, SinAlpha, SinBeta, SinGamma)
		return ad.Vector(
			CosGamma*CosBeta, 
			-SinGamma*CosAlpha + CosGamma*SinBeta*SinAlpha, 
			SinGamma*SinAlpha + CosGamma*SinBeta*CosAlpha,
			SinGamma*CosBeta,
			CosGamma*CosAlpha + SinGamma*SinBeta*SinAlpha,
			-CosGamma*SinAlpha + SinGamma*SinBeta*CosAlpha,
			-SinBeta,
			CosBeta*SinAlpha,
			CosBeta*CosAlpha)
	end
	
	function evalR(alpha, beta, gamma)
		return evalRot(ad.cos(angle), ad.cos(beta), ad.cos(gamma), ad.sin(angle), ad.sin(beta), ad.sin(gamma))
	end
	
	function mul(matrix, v)
		return ad.Vector(matrix(0)*v(0)+matrix(1)*v(1)*matrix(2)*v(2),matrix(3)*v(0)+matrix(4)*v(1)*matrix(5)*v(2),matrix(6)*v(0)+matrix(7)*v(1)*matrix(8)*v(2))
	end

	local terms = terralib.newlist()
	
	--fitting
	local x_fit = ad.Vector(X(0,0,0), X(0,0,1), X(0,0,1))	--vertex-unknown : float3
	local constraint = Constraints(0,0)						--target : float3
	local e_fit = x_fit - constraint
	--TODO check that this works; its set to minus infinity...
	e_fit = ad.select(ad.greatereq(constraint(0), 0.0), e_fit, ad.Vector(0.0, 0.0, 0.0))
	e_fit = ad.select(ad.greatereq(constraint(1), 0.0), e_fit, ad.Vector(0.0, 0.0, 0.0))
	e_fit = ad.select(ad.greatereq(constraint(2), 0.0), e_fit, ad.Vector(0.0, 0.0, 0.0))
	
	--TODO don't we have vectors?
	terms:insert(w_fitSqrt*e_fit(0))
	terms:insert(w_fitSqrt*e_fit(1))
	terms:insert(w_fitSqrt*e_fit(2))

	--regularization
	local x = ad.Vector(X(G.v0,0), X(G.v0,1), X(G.v0,1))	--vertex-unknown : float3
	local a = ad.Vector(X(G.v0,3), X(G.v0,4), X(G.v0,5))	--rotation(alpha,beta,gamma) : float3
	local R = evalR(a)			-- rotation : float3x3
	local xHat = UrShape(G.v0)	-- uv-urshape : float3
	
	local n = ad.Vector(X(G.v1,0), X(G.v1,1), X(G.v1,2))
	local ARAPCost = (x - n)	-	mul(R, (xHat - UrShape(G.v1)))

	--TODO don't we have vectors?
	for i = 0,2 do
		terms:insert(w_regSqrt*ARAPCost(i))
	end
	
	local cost = ad.sumsquared(unpack(terms))
	return adP:Cost(cost)
	
   -- -- realcost	
    --local w_fit_rt, w_reg_rt = ad.sqrt(w_fit),ad.sqrt(w_reg)
    --local cost = ad.sumsquared(w_fit_rt*(X(0,0,0) - UrShape(0,0,0))) 
     --                          --w_reg_rt*(X(G.v0) - X(G.v1)),
     --                          --w_reg_rt*(X(G.v1) - X(G.v0)))
   -- return adP:Cost(cost)
end

local C = terralib.includecstring [[
#include <math.h>
]]


-- same functions, but expressed in math language
local IP = adP:Image("P",opt.float4,W,H,-1)
local Ap_X = adP:Image("Ap_X",opt.float4,W,H,-2)
local r = Ap_X

local L = terralib.newlist
local function S(im,idx,exp) return { image = im, index = idx, expression = exp } end

-- cost
local x,a= X(0,0),A(0,0)
local math_cost = w_fit * (x - a) ^ 2 
local math_cost_graph = 2*w_reg*(X(G.v0) - X(G.v1))^2
math_cost,math_cost_graph = math_cost:sum(),math_cost_graph:sum()

-- jtj
local p0,p1 = IP(G.v0),IP(G.v1)
local c = 2.0*2.0*w_reg*(p0 - p1)
local math_jtj_graph = p0:dot(c) + p1:dot(-c)
local math_jtj_scatters = L { S(Ap_X,G.v0,c), S(Ap_X,G.v1,-c) }

local math_jtj = w_fit*2*IP(0,0)

-- jtf
local x0,x1 = X(G.v0),X(G.v1)
local gradient = w_fit*2.0*(x - a)
local math_jtf = L { gradient, ad.toexp(1) }
local lap = w_reg*2*2*(x0 - x1)
local math_jtf_scatters = L { S(IP,G.v0,-lap), S(IP,G.v1,lap), S(r,G.v0,-lap), S(r,G.v1,lap) }

local unknownElement = P:UnknownType().metamethods.typ

local terra laplacianCost(idx : int32, self : P:ParameterType()) : unknownElement	
    var x0 = self.X(self.G.v0_x[idx], self.G.v0_y[idx])
    var x1 = self.X(self.G.v1_x[idx], self.G.v1_y[idx])
    return x0 - x1
end

local terra cost(i : int32, j : int32, gi : int32, gj : int32, self : P:ParameterType()) : float
	var v2 = self.X(i, j) - self.A(i, j)
	var e_fit = w_fit * v2 * v2	
	
	var res : float = e_fit(0) + e_fit(1) + e_fit(2) + e_fit(3)
		
	return res
end

local terra cost_graph(idx : int32, self : P:ParameterType()) : float
	var l0 = laplacianCost(idx, self)		
	var e_reg = 2.f*w_reg*l0*l0
	
	var res : float = e_reg(0) + e_reg(1) + e_reg(2) + e_reg(3)
	
	return res
end

-- eval 2*JtF == \nabla(F); eval diag(2*(Jt)^2) == pre-conditioner
local terra evalJTF(i : int32, j : int32, gi : int32, gj : int32, self : P:ParameterType())
	var x = self.X(i, j)
	var a = self.A(i, j)
	var gradient = w_fit*2.0f * (x - a)	
	var pre : float = 1.0f
	return gradient, pre
end


local terra evalJTF_graph(idx : int32, self : P:ParameterType(), p : P:UnknownType(), r : P:UnknownType())
	
	var w0,h0 = self.G.v0_x[idx], self.G.v0_y[idx]
    var w1,h1 = self.G.v1_x[idx], self.G.v1_y[idx]
	
	-- is there a 2?
	var lap = 2.0*2.0*laplacianCost(idx, self)
	var c0 = ( 1.0f)*lap
	var c1 = (-1.0f)*lap
	
	var pre : float = 1.0f
	--return gradient, pre
	


	--write results
	var _residuum0 = -c0
	var _residuum1 = -c1
	r:atomicAdd(w0, h0, _residuum0)
	r:atomicAdd(w1, h1, _residuum1)
	
	var _pre0 = pre
	var _pre1 = pre
	--preconditioner:atomicAdd(w0, h0, _pre0)
	--preconditioner:atomicAdd(w1, h1, _pre1)
	
	var _p0 = _pre0*_residuum0
	var _p1 = _pre1*_residuum1
	p:atomicAdd(w0, h0, _p0)
	p:atomicAdd(w1, h1, _p1)
	
end

-- eval 2*JtJ (note that we keep the '2' to make it consistent with the gradient
local terra applyJTJ(i : int32, j : int32, gi : int32, gj : int32, self : P:ParameterType(), pImage : P:UnknownType()) : unknownElement 
    return w_fit*2.0f*pImage(i,j)
end

local terra applyJTJ_graph(idx : int32, self : P:ParameterType(), pImage : P:UnknownType(), Ap_X : P:UnknownType())
    var w0,h0 = self.G.v0_x[idx], self.G.v0_y[idx]
    var w1,h1 = self.G.v1_x[idx], self.G.v1_y[idx]
    
    var p0 = pImage(w0,h0)
    var p1 = pImage(w1,h1)

    -- (1*p0) + (-1*p1)
    var l_n = p0 - p1
    var e_reg = 2.0f*2.0f*w_reg*l_n

	var c0 = 1.0 *  e_reg
	var c1 = -1.0f * e_reg
	

	Ap_X:atomicAdd(w0, h0, c0)
    Ap_X:atomicAdd(w1, h1, c1)

    var d = 0.0f
	d = d + opt.Dot(pImage(w0,h0), c0)
	d = d + opt.Dot(pImage(w1,h1), c1)					
	return d 

end

if useHandwrittenMath then

    adP:createfunctionset("cost",{math_cost},L{ { graph = G, results = L{math_cost_graph}, scatters = L{} } })
    adP:createfunctionset("evalJTF", math_jtf, L{ { graph = G, results = L {}, scatters = math_jtf_scatters } })
    adP:createfunctionset("applyJTJ",{math_jtj},L{ { graph = G, results = L{math_jtj_graph}, scatters = math_jtj_scatters } })
    
else 

    P:Function("cost", cost, "G", cost_graph)
    P:Function("evalJTF", evalJTF, "G", evalJTF_graph)
    P:Function("applyJTJ", applyJTJ, "G", applyJTJ_graph)
end

return P
