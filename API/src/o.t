
--terralib.settypeerrordebugcallback( function(fn) fn:printpretty() end )

opt = {} --anchor it in global namespace, otherwise it can be collected
local S = require("std")

local util = require("util")
local solversCPU = require("solversCPU")
local solversGPU = require("solversGPU")

local C = util.C

-- constants
local verboseSolver = true
local verboseAD = false

local function newclass(name)
    local mt = { __name = name }
    mt.__index = mt
    function mt:is(obj)
        return getmetatable(obj) == self
    end
    function mt:__tostring()
        return "<"..name.." instance>"
    end
    function mt:new(obj)
        obj = obj or {}
        setmetatable(obj,self)
        return obj
    end
    return mt
end

local vprintf = terralib.externfunction("cudart:vprintf", {&int8,&int8} -> int)

local function createbuffer(args)
    local Buf = terralib.types.newstruct()
    return quote
        var buf : Buf
        escape
            for i,e in ipairs(args) do
                local typ = e:gettype()
                local field = "_"..tonumber(i)
                typ = typ == float and double or typ
                table.insert(Buf.entries,{field,typ})
                emit quote
                   buf.[field] = e
                end
            end
        end
    in
        [&int8](&buf)
    end
end

printf = macro(function(fmt,...)
    local buf = createbuffer({...})
    return `vprintf(fmt,buf) 
end)
local dprint

if verboseSolver then
	logSolver = macro(function(fmt,...)
		local args = {...}
		return `C.printf(fmt, args)
	end)
else
	logSolver = macro(function(fmt,...)
		return 0
	end)
end

if verboseAD then
	logAD = macro(function(fmt,...)
		local args = {...}
		return `C.printf(fmt, args)
	end)
	dprint = print
else
	logAD = macro(function(fmt,...)
		return 0
	end)
	dprint = function() end
end


local GPUBlockDims = {{"blockIdx","ctaid"},
              {"gridDim","nctaid"},
              {"threadIdx","tid"},
              {"blockDim","ntid"}}
for i,d in ipairs(GPUBlockDims) do
    local a,b = unpack(d)
    local tbl = {}
    for i,v in ipairs {"x","y","z" } do
        local fn = cudalib["nvvm_read_ptx_sreg_"..b.."_"..v] 
        tbl[v] = `fn()
    end
    _G[a] = tbl
end

__syncthreads = cudalib.nvvm_barrier0

local Dim = newclass("dimension")


local ffi = require('ffi')

local problems = {}

-- this function should do anything it needs to compile an optimizer defined
-- using the functions in tbl, using the optimizer 'kind' (e.g. kind = gradientdecesnt)
-- it should generate the field makePlan which is the terra function that 
-- allocates the plan

local function compilePlan(problemSpec, kind, params)
	print("Compile Plan Start")
	local vars = {
		costFunctionType = problemSpec.cost.boundary:gettype()
	}
	
	vars.unknownType = vars.costFunctionType.parameters[3] -- 3rd argument is the image that is the unknown we are mapping over

	local PlanImages = terralib.types.newstruct ("PlanImages")
	PlanImages.entries:insert( { "unknown", vars.unknownType } )
	
	for i = 4, #vars.costFunctionType.parameters do
		PlanImages.entries:insert( { "image"..tostring(i - 4), vars.costFunctionType.parameters[i] } )
	end
	
	vars.PlanImages = PlanImages

	if kind == "gradientDescentCPU" then
        return solversCPU.gradientDescentCPU(problemSpec, vars)
	elseif kind == "gradientDescentGPU" then
		return solversGPU.gradientDescentGPU(problemSpec, vars)
	elseif kind == "conjugateGradientCPU" then
		return solversCPU.conjugateGradientCPU(problemSpec, vars)
	elseif kind == "linearizedConjugateGradientCPU" then
		return solversCPU.linearizedConjugateGradientCPU(problemSpec, vars)
	elseif kind == "linearizedConjugateGradientGPU" then
		return solversGPU.linearizedConjugateGradientGPU(problemSpec, vars)
	elseif kind == "lbfgsCPU" then
		return solversCPU.lbfgsCPU(problemSpec, vars)
	elseif kind == "vlbfgsCPU" then
		return solversCPU.vlbfgsCPU(problemSpec, vars)
	elseif kind == "vlbfgsGPU" then
		return solversGPU.vlbfgsGPU(problemSpec, vars)
	elseif kind == "bidirectionalVLBFGSCPU" then
		return solversCPU.bidirectionalVLBFGSCPU(problemSpec, vars)
	end
	
	error("unknown kind: "..kind)
    
end

struct opt.GradientDescentPlanParams {
    nIterations : uint64
}

struct opt.Plan(S.Object) {
    impl : {&opaque,&&opaque,&opaque} -> {}
    data : &opaque
} 

struct opt.Problem {} -- just used as an opaque type, pointers are actually just the ID
local function problemDefine(filename, kind, params, pid)
    local problemmetadata = { filename = ffi.string(filename), kind = ffi.string(kind), params = params, id = #problems + 1 }
    problems[problemmetadata.id] = problemmetadata
    pid[0] = problemmetadata.id
end
-- define just stores meta-data right now. ProblemPlan does all compilation for now
terra opt.ProblemDefine(filename : rawstring, kind : rawstring, params : &opaque)
    var id : int
    problemDefine(filename, kind, params,&id)
    return [&opt.Problem](id)
end 
terra opt.ProblemDelete(p : &opt.Problem)
    var id = int64(p)
    --TODO: remove from problem table
end

function opt.Dim(name,idx)
    idx = assert(tonumber(idx),"expected an index for this dimension")
    return Dim:new { name = name, size = tonumber(opt.dimensions[idx]) }
end

terra opt.InBoundsCalc(x : int64, y : int64, W : int64, H : int64, sx : int64, sy : int64) : int
    var minx,maxx,miny,maxy = x - sx,x + sx,y - sy,y + sy
    return int(minx >= 0) and int(maxx < W) and int(miny >= 0) and int(maxy < H)
end 

local newImage = terralib.memoize(function(typ, W, H, elemsize, stride)
	local struct Image {
		data : &uint8
	}
	function Image.metamethods.__tostring()
	  return string.format("Image(%s,%s,%s)",tostring(typ),W.name, H.name)
	end
	Image.metamethods.__apply = macro(function(self, x, y)
	 return `@[&typ](self.data + y*stride + x*elemsize)
	end)
	terra Image:inbounds(x : int64, y : int64)
	    return x >= 0 and y >= 0 and x < W.size and y < H.size
	end
	terra Image:get(x : int64, y : int64)
	    var v : typ = 0.f --TODO:only works for single precision things
	    if opt.InBoundsCalc(x,y,W.size,H.size,0,0) ~= 0 then
	        v = self(x,y)
	    end
	    return v
	end
	terra Image:H() return H.size end
	terra Image:W() return W.size end
	terra Image:elemsize() return elemsize end
	terra Image:stride() return stride end
	terra Image:initCPU()
		self.data = [&uint8](C.malloc(stride*H.size))
		for h = 0, H.size do
			for w = 0, W.size do
				self(w, h) = 0.0f
			end
		end
	end
	terra Image:initGPU()
		var cudaError = C.cudaMalloc([&&opaque](&(self.data)), stride*H.size)
		cudaError = C.cudaMemset([&opaque](self.data), 0, stride*H.size)
	end
	local mm = Image.metamethods
	mm.typ,mm.W,mm.H,mm.elemsize,mm.stride = typ,W,H,elemsize,stride
	return Image
end)


local unity = Dim:new { name = "1", size = 1 }
local function todim(d)
    return Dim:is(d) and d or d == 1 and unity
end

function opt.InternalImage(typ,W,H)
    W,H = assert(todim(W)),assert(todim(H))
    assert(terralib.type.istype(typ))
    local elemsize = terralib.sizeof(typ)
    return newImage(typ,W,H,elemsize,elemsize*W.size)
end
function opt.Image(typ, W, H, idx)
    assert(terralib.types.istype(typ))
    local elemsize = assert(tonumber(opt.elemsizes[idx]))
    local stride = assert(tonumber(opt.strides[idx]))
    return newImage(typ, assert(todim(W)), assert(todim(H)), elemsize, stride)
end

local allPlans = terralib.newlist()

local function problemPlan(id, dimensions, elemsizes, strides, pplan)
    local success,p = xpcall(function() 
		local problemmetadata = assert(problems[id])
        opt.dimensions,opt.elemsizes,opt.strides = dimensions,elemsizes,strides
        local tbl = assert(terralib.loadfile(problemmetadata.filename))()
        assert(type(tbl) == "table")
		local result = compilePlan(tbl,problemmetadata.kind,problemmetadata.params)
		allPlans:insert(result)
		pplan[0] = result()
    end,function(err) print(debug.traceback(err,2)) end)
	
	print("Compile Plan End")
end
terra opt.ProblemPlan(problem : &opt.Problem, dimensions : &uint64, elemsizes : &uint64, strides : &uint64) : &opt.Plan
	var p : &opt.Plan = nil 
	problemPlan(int(int64(problem)),dimensions,elemsizes,strides,&p)
	return p
end 

terra opt.PlanFree(plan : &opt.Plan)
    -- TODO: plan should also have a free implementation
    plan:delete()
end

terra opt.ProblemSolve(plan : &opt.Plan, images : &&opaque, params : &opaque)
	return plan.impl(plan.data, images, params)
end

ad = require("ad")


local ImageTable = newclass("ImageTable") -- a context that keeps a mapping from image accesses im(0,-1) to the ad variable object that represents the access

local ImageAccess = newclass("ImageAccess")
local BoundsAccess = newclass("BoundsAccess")
local SumOfSquares = newclass("SumOfSquares")
function SumOfSquares:__toadexp()
    local sum = 0
    for i,t in ipairs(self.terms) do
        sum = sum + t*t
    end
    return sum
end
function ad.sumsquared(...)
    local exp = terralib.newlist {...}
    exp = exp:map(function(x) return assert(ad.toexp(x), "expected an ad expression") end)
    return SumOfSquares:new { terms = exp }
end
ImageAccess.get = terralib.memoize(function(self,im,field,x,y)
    return ImageAccess:new { image = im, field = field, x = x, y = y}
end)

function ImageAccess:__tostring()
    local xn,yn = tostring(self.x):gsub("-","m"),tostring(self.y):gsub("-","m")
    return ("%s_%s_%s_%s"):format(self.image.name,self.field,xn,yn)
end
function BoundsAccess:__tostring() return ("bounds_%d_%d_%d_%d"):format(self.x,self.y,self.sx,self.sy) end
BoundsAccess.get = terralib.memoize(function(self,x,y,sx,sy)
    return BoundsAccess:new { x = x, y = y, sx = sx, sy = sy }
end)

local Image = newclass("Image")
-- Z: this will eventually be opt.Image, but that is currently used by our direct methods
-- so this is going in the ad table for now
function ad.Image(name,W,H,idx)
    assert(W == 1 or Dim:is(W))
    assert(H == 1 or Dim:is(H))
    return Image:new { name = tostring(name), W = W, H = H, idx = assert(tonumber(idx)) }
end

function Image:__call(x,y)
    x,y = assert(tonumber(x)),assert(tonumber(y))
    return ad.v[ImageAccess:get(self,"v",x,y)]
end
function opt.InBounds(sx,sy)
    return ad.v[BoundsAccess:get(0,0,sx,sy)]
end
function BoundsAccess:shift(x,y)
    return BoundsAccess:get(self.x+x,self.y+y,self.sx,self.sy)
end
function ImageAccess:shift(x,y)
    return ImageAccess:get(self.image,self.field,self.x + x, self.y + y)
end
local function shiftexp(exp,x,y)
    local function rename(a)
        return ad.v[a:shift(x,y)]
    end
    return exp:rename(rename)
end 

local function removeboundaries(exp)
    local function nobounds(a)
        if BoundsAccess:is(a) then return ad.toexp(1)
        else return ad.v[a] end
    end
    return exp:rename(nobounds)
end
local function createfunction(images,exp,usebounds)
    if not usebounds then
        exp = removeboundaries(exp)
    end
    local imageindex = {}
    local imagesyms = terralib.newlist()
    for i,im in ipairs(images) do
        local s = symbol(opt.Image(float,im.W,im.H,i-1),im.name)
        imageindex[im] = s
        imagesyms:insert(s)
    end
    local stencil = {0,0}
    
    local unknownimage = imagesyms[1]
    local i,j = symbol(int64,"i"), symbol(int64,"j")
    local stmts = terralib.newlist()
    local accesssyms = {}
    local vartosym = {}
    local function emitvar(a)
        if not accesssyms[a] then
            local r 
            if ImageAccess:is(a) then
                local im = assert(imageindex[a.image],("cost function uses image %s not listed in parameters."):format(a.image))
                r = symbol(float,tostring(a))
                stmts:insert quote
                    var [r] = [ usebounds and (`im:get(i+[a.x],j+[a.y])) or (`im(i+[a.x],j+[a.y])) ]
                    --if i < 4 and j < 4 then
                    --    C.printf("%s(%d + %d,%d + %d) = %f,%f\n",[a.image.name],i,[a.x],j,[a.y],[r.v],[r.bounds])
                    --end
                end
                stencil[1] = math.max(stencil[1],math.abs(a.x))
                stencil[2] = math.max(stencil[2],math.abs(a.y))
            else --bounds calculation
                assert(usebounds) -- if we removed them, we shouldn't see any boundary accesses
                r = symbol(int,tostring(a))
                local W,H = unknownimage.type.metamethods.W.size,unknownimage.type.metamethods.H.size
                print(W,H)
                stmts:insert quote
                    var [r] = opt.InBoundsCalc(i+a.x,j+a.y,W,H,a.sx,a.sy)
                end
                stencil[1] = math.max(stencil[1],math.abs(a.x)+a.sx)
                stencil[2] = math.max(stencil[2],math.abs(a.y)+a.sy)
            end
            accesssyms[a] = r
        end
        return accesssyms[a]
    end
    local result = ad.toterra({exp},emitvar)
    local terra generatedfn([i] : int64, [j] : int64, [imagesyms])
        [stmts]
        return result
    end
    generatedfn:compile()
    if verboseAD then
        --generatedfn:disas()
    end
    return generatedfn,stencil
end
local function createfunctionset(images,exp)
    dprint("bound")
    local boundary,stencil = createfunction(images,exp,true)
    dprint("interior")
    local interior = createfunction(images,exp,false)
    return { boundary = boundary, stencil = stencil, interior = interior, dimensions = {images[1].W,images[1].H} }
end
local function unknowns(exp)
    local seenunknown = {}
    local unknownvars = terralib.newlist()
    exp:rename(function(a)
        local v = ad.v[a]
        if ImageAccess:is(a) and a.image.idx == 0 and a.field == "v" and not seenunknown[a] then -- assume image 0 is unknown
            unknownvars:insert(v)
            seenunknown[a] = true
        end
        return v
    end)
    return unknownvars
end
local function imagesusedinexpression(exp)
    local N = 0
    local idxtoimage = terralib.newlist{}
    exp:rename(function(a)
        if ImageAccess:is(a) then
            N = math.max(N,a.image.idx+1)
            assert(idxtoimage[a.image.idx+1] == nil or idxtoimage[a.image.idx+1] == a.image, "image for index " ..tostring(a.image.idx).. " defined twice?")
            idxtoimage[a.image.idx+1] = a.image
        end
        return ad.v[a]
    end)
    for i = 1,N do
        assert(idxtoimage[i],"undefined image at index "..tostring(i-1))
    end
    return idxtoimage
end

local getshift = terralib.memoize(function(x,y) return {x = x, y = y} end)

local function shiftswithoverlappingstencil(unknownvars)
    local shifttooverlap = {}
    local shifts = terralib.newlist()
    for i,a_ in ipairs(unknownvars) do
        local a = a_:key()
        for j,b_ in ipairs(unknownvars) do
            local b = b_:key()
            local s = getshift(a.x - b.x, a.y - b.y) -- at what shift from a to b does a's (a.x,a.y) overlap with b's (b.x,b.y)
            if not shifttooverlap[s] then
                shifttooverlap[s] = terralib.newlist()
                shifts:insert(s)
            end
            shifttooverlap[s]:insert({left = i, right = j})
        end
    end
    return shifts,shifttooverlap
end

local function createjtj(Fs,unknown,P)
    local P_hat = 0
    for _,F in ipairs(Fs) do
        local P_F = 0
        local unknownvars = unknowns(F)
        local dfdx = F:gradient(unknownvars)
        local shifts,shifttooverlap = shiftswithoverlappingstencil(unknownvars)
        for _,shift in pairs(shifts) do
            local overlaps = shifttooverlap[shift]
            --print("shift",shift.x,shift.y)
            local sum = 0
            for i,o in ipairs(overlaps) do
                --print("considering  ", unknownvars[o.left],unknownvars[o.right])
                local alpha = dfdx[o.left]
                local beta = shiftexp(dfdx[o.right],shift.x,shift.y)
                sum = sum + alpha*beta
            end
            P_F = P_F + P(shift.x,shift.y) * sum  
        end
        P_hat = P_hat + P_F
    end
    return P_hat
end

function ad.Cost(costexp_)
    local costexp = assert(ad.toexp(costexp_))
    local images = imagesusedinexpression(costexp)
    local unknown = images[1]
    
    local unknownvars = unknowns(costexp)
    local gradient = costexp:gradient(unknownvars)
    
    dprint("cost expression")
    dprint(ad.tostrings({assert(costexp)}))
    dprint("grad expression")
    local names = table.concat(unknownvars:map(function(v) return tostring(v:key()) end),", ")
    dprint(names.." = "..ad.tostrings(gradient))
    
    local gradientgathered = 0
    for i,u in ipairs(unknownvars) do
        local a = u:key()
        gradientgathered = gradientgathered + shiftexp(gradient[i],-a.x,-a.y)
    end
    
    dprint("grad gather")
    dprint(ad.tostrings({gradientgathered}))
    
    dprint("cost")
    local cost = createfunctionset(images,costexp)
    dprint("grad")
    local gradient = createfunctionset(images,gradientgathered)
    local r = { cost = cost, gradient = gradient }
    if verboseAD then
        terralib.tree.printraw(r)
    end
    
    if SumOfSquares:is(costexp_) then
        local P = ad.Image("P",unknown.W,unknown.H,#images+1)
        local jtjexp = createjtj(costexp_.terms,unknown,P)
        dprint("jtj with bounds:")
        dprint(jtjexp)
        dprint("jtj without bounds:")
        dprint(removeboundaries(jtjexp))
    end
    return r
end
return opt