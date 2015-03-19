local lpeg = require "lpeg"
local table = require "table"

local P = lpeg.P
local S = lpeg.S
local R = lpeg.R
local C = lpeg.C
local Ct = lpeg.Ct
local Cg = lpeg.Cg
local Cc = lpeg.Cc
local V = lpeg.V
local Cmt = lpeg.Cmt
local Carg = lpeg.Carg

local function count_lines(_,pos, parser_state)
	if parser_state.pos < pos then
		local line = parser_state.line + 1
		parser_state.line = line
		parser_state.pos = pos
	end
	return pos
end


local color = {
	red = 31,
	green = 32,
	blue = 36,
	yellow = 33,
	other = 37
}
local function highlight(s, c)
	c = c or "red"
	return string.format("\x1b[1;%dm%s\x1b[0m", color[c], tostring(s))
end

local function highlight_type(s)
	return highlight(s, "green")
end

local function highlight_tag(s)
	return highlight(s, "yellow")
end


local exception = Cmt( Carg(1) , function ( _ , pos, parser_state)
	error(highlight(string.format("syntax error at [%s] line (%d)", parser_state.file or "", parser_state.line)))
	return pos
end)

local eof = P(-1)
local newline = Cmt((P"\n" + "\r\n") * Carg(1) ,count_lines)
local line_comment = "#" * (1 - newline) ^0 * (newline + eof)
local blank = S" \t" + newline + line_comment
local blank0 = blank ^ 0
local blanks = blank ^ 1
local alpha = R"az" + R"AZ" + "_"
local alnum = alpha + R"09"
local word = alpha * alnum ^ 0
local name = C(word)
local typename = C(word * ("." * word) ^ 0)
local tag = R"09" ^ 1 / tonumber
local mainkey = "(" * blank0 * name * blank0 * ")"

local function multipat(pat)
	return Ct(blank0 * (pat * blank0) ^ 0)
end

local function metapatt(name, idx)
	local patt = Cmt(Carg(1), function (_,pos, parser_state)
			local info = {line=parser_state.line, file=parser_state.file}
			setmetatable(info, {__tostring = function (v)
					return highlight(string.format(" at %s:%d line", v.file, v.line))
				end})
			return pos, info
		end)
	return patt
end

local function namedpat(name, pat)
	local type = Cg(Cc(name), "type")
	local meta = Cg(metapatt(name, idx), "meta")
	return Ct(type * meta * Cg(pat))
end


local typedef = P {
	"ALL",
	FIELD = namedpat("field", (name * blanks * tag * blank0 * ":" * blank0 * (C"*")^0 * typename * mainkey^0)),
	STRUCT = P"{" * multipat(V"FIELD" + V"TYPE") * P"}",
	TYPE = namedpat("type", P"." * name * blank0 * V"STRUCT" ),
	SUBPROTO = Ct((C"request" + C"response") * blanks * (typename + V"STRUCT")),
	PROTOCOL = namedpat("protocol", name * blanks * tag * blank0 * P"{" * multipat(V"SUBPROTO") * P"}"),
	ALL = multipat(V"TYPE" + V"PROTOCOL"),
}

local proto = blank0 * typedef * blank0


local convert = {}

function convert.protocol(all, obj, build)
	local result = { tag = obj[2], meta=obj.meta, name = obj[1]}
	for _, p in ipairs(obj[3]) do
		assert(result[p[1]] == nil)
		local typename = p[2]
		if type(typename) == "table" then
			local struct = typename
			typename = obj[1] .. "." .. p[1]
			all.type[typename] = convert.type(all, { typename, struct }, build)
		end
		result[p[1]] = typename
	end
	return result
end

function convert.type(all, obj)
	local result = {}
	local typename = obj[1]
	local tags = {}
	local names = {}
	for _, f in ipairs(obj[2]) do
		local meta = f.meta
		local meta_info = tostring(meta)
		if f.type == "field" then
			local name = f[1]
			if names[name] then
				error(string.format("redefine %s in type %s"..meta_info, 
					highlight_type(name), 
					highlight_type(typename)))
			end
			names[name] = true
			local tag = f[2]
			if tags[tag] then
				error(string.format("redefine tag %s in type %s"..meta_info, 
					highlight_tag(tag),
					highlight_type(typename)))
			end
			tags[tag] = true
			local field = { name = name, tag = tag }
			table.insert(result, field)
			local fieldtype = f[3]
			if fieldtype == "*" then
				field.array = true
				fieldtype = f[4]
			end
			local mainkey = f[5]
			if mainkey then
				assert(field.array)
				field.key = mainkey
			end
			field.typename = fieldtype
			field.meta = meta
		else
			assert(f.type == "type")	-- nest type
			local nesttypename = typename .. "." .. f[1]
			f[1] = nesttypename
			assert(all.type[nesttypename] == nil, "redefined " ..highlight_type(nesttypename)..meta_info)
			local v = convert.type(all, f)
			v.meta = meta
			all.type[nesttypename] = v
		end
	end
	table.sort(result, function(a,b) return a.tag < b.tag end)
	return result
end

local function adjust(r, build)
	local result = { type = {} , protocol = {} }

	for _, obj in ipairs(r) do
		local set = result[obj.type]
		local build_set = build[obj.type]
		local name = obj[1]
		local meta_info = tostring(obj.meta)
		assert(set[name] == nil and build_set[name] == nil, "redefined "..highlight_type(name)..meta_info)
		set[name] = convert[obj.type](result,obj, build)
	end

	return result
end

local buildin_types = {
	integer = 0,
	boolean = 1,
	string = 2,
}

local function checktype(types, ptype, t)
	if buildin_types[t] then
		return t
	end
	local fullname = ptype .. "." .. t
	if types[fullname] then
		return fullname
	else
		ptype = ptype:match "(.+)%..+$"
		if ptype then
			return checktype(types, ptype, t)
		elseif types[t] then
			return t
		end
	end
end


local function checkprotocol(r)
	local map = {}
	local type = r.type
	for protocol_name, v in pairs(r.protocol) do
		local tag = v.tag
		local request = v.request
		local response = v.response
		local p = map[tag]
		if p then
			error(string.format("redefined protocol tag %s of %s and %s %s", 
				highlight_tag(tag), 
				highlight_type(p.name),
				highlight_type(protocol_name), 
				tostring(v.meta)))
		end

		if request and not type[request] then
			error(string.format("Undefined request type %s in protocol %s %s",
				highlight_type(request),
				highlight_type(protocol_name),
				tostring(v.meta)))
		end

		if response and not type[response] then
			error(string.format("Undefined response type %s in protocol %s",
				highlight_type(response),
				highlight_type(protocol_name),
				tostring(v.meta)))
		end
		map[tag] = v
	end
end


local function flattypename(r)
	for typename, t in pairs(r.type) do
		for _, f in ipairs(t) do
			local ftype = f.typename
			local fullname = checktype(r.type, typename, ftype)
			if fullname == nil then
				error(string.format("Undefined type %s in type %s"..tostring(f.meta), 
					highlight_type(ftype), 
					highlight_type(typename)))
			end
			f.typename = fullname

			if f.array and f.key then
				local key = f.key
				local reason = "Invalid map index: "..highlight_tag(key)..tostring(f.meta)
				local vtype=r.type[fullname]
				for _,v in ipairs(vtype) do
					if v.name == key and buildin_types[v.typename] then
						f.key=v
						reason = false
						break
					end
				end
				if reason then error(reason) end
			end
		end
	end

	return r
end


local function parser(text,filename, build)
	local state = { file = filename, pos = 0, line = 1}
	local r = lpeg.match(proto * -1 + exception , text , 1, state )
	local v = adjust(r, build)
	return v
end


--[[ 
	trunk_list parameter format:
	{
		{text, name},
		{text, name},
		...
	}
]]
local function gen_trunk(trunk_list)
	local ret = {}
	local build = {protocol={}, type={}}
	for i,v in ipairs(trunk_list) do
		local text = v[1]
		local name = v[2] or "=text"
		local ast = parser(text, name, build)
		local protocol = ast.protocol
		local type = ast.type

		-- merge type
		for k,v in pairs(type) do
			assert(build.type[k] == nil, k)
			build.type[k] = v
		end
		-- merge protocol
		for k,v in pairs(protocol) do
			assert(build.protocol[k] == nil, k)
			build.protocol[k] = v
		end

		table.insert(ret, ast)
	end

	flattypename(build)
	checkprotocol(build)
	return ret, build
end


return {
	buildin_types = buildin_types,
	gen_trunk = gen_trunk,
}

