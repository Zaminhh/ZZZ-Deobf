local Ast = require('prometheus.ast')
local Unparser = require('prometheus.unparser')

local DynamicTrace = {}
DynamicTrace.__index = DynamicTrace
DynamicTrace.Name = 'DynamicTrace'

function DynamicTrace:new(opts)
  return setmetatable({ opts = opts or {} }, self)
end

local is_lua51 = _VERSION == 'Lua 5.1'

local function run_with_trace(code, level)
  local calls = {}
  local function rec(name, args)
    calls[#calls+1] = { name = name, args = args }
  end
  local function recs(name, ...)
    local t = {}
    for i=1,select('#', ...) do t[i] = tostring(select(i, ...)) end
    rec(name, t)
  end

  local function mkStub(path)
    local stub = {}
    local mt = {}
    function mt.__index(t, k)
      local v = rawget(t, k)
      if v ~= nil then return v end
      local key = tostring(k)
      local child = mkStub(path .. "." .. key)
      rawset(t, k, child)
      return child
    end
    function mt.__newindex(t, k, v)
      if level ~= 'prints' then recs('set:' .. path, tostring(k), tostring(v)) end
      rawset(t, k, v)
    end
    function mt.__call(t, ...)
      if level ~= 'prints' then recs('call:' .. path, ...) end
      local argc = select('#', ...)
      for i=1,argc do
        local a = select(i, ...)
        if type(a) == 'function' then
          local ev = path:match('%.([%w_]+)%.Connect$') or ''
          if ev == 'InputBegan' then
            local input = mkStub('Input')
            input.KeyCode = _ENV.Enum and _ENV.Enum.KeyCode and _ENV.Enum.KeyCode.E or mkStub('Enum.KeyCode.E')
            pcall(a, input)
          elseif ev == 'RenderStepped' then
            pcall(a, 0)
          else
            pcall(a)
          end
          break
        end
      end
      return t
    end
    function mt.__tostring()
      return '<stub ' .. path .. '>'
    end
    function mt.__concat(a, b)
      return tostring(a) .. tostring(b)
    end
    function mt.__len()
      return 0
    end
    function mt.__unm()
      return 0
    end
    function mt.__add()
      return 0
    end
    function mt.__sub()
      return 0
    end
    function mt.__mul()
      return 0
    end
    function mt.__div()
      return 0
    end
    function mt.__mod()
      return 0
    end
    function mt.__pow()
      return 0
    end
    function mt.__lt()
      return false
    end
    function mt.__le()
      return false
    end
    setmetatable(stub, mt)
    return stub
  end

  local env = {}
  env._ENV = env
  env._G = env

  env.print = function(...)
    local args = {}
    for i=1,select('#', ...) do args[i] = select(i, ...) end
    rec('print', args)
  end

  env.io = setmetatable({
    write = function(...)
      local args = {}
      for i=1,select('#', ...) do args[i] = select(i, ...) end
      rec('io.write', args)
    end
  }, { __index = _G.io or {} })

  env.getfenv = function() return env end
  env.setfenv = function() end
  env.unpack = unpack or table.unpack
  env.table = table
  if not env.table.find then
    env.table.find = function(t, v)
      for i=1,#t do if t[i] == v then return i end end
      return nil
    end
  end
  env.string = string
  env.math = math
  env.pairs = pairs
  env.ipairs = ipairs
  env.type = type
  env.typeof = function(v) return type(v) end
  env.select = select
  env.newproxy = newproxy
  env.setmetatable = setmetatable
  env.getmetatable = getmetatable
  env.require = function() return {} end

  -- Minimal filesystem and executor helpers
  local fs = {}
  env.getgenv = function() return env end
  env.cloneref = function(v) return v end
  env.makefolder = function(path)
    if level ~= 'prints' then recs('call:makefolder', path) end
    fs['__dir__:' .. tostring(path)] = true
    return true
  end
  env.isfolder = function(path)
    if level ~= 'prints' then recs('call:isfolder', path) end
    return fs['__dir__:' .. tostring(path)] and true or false
  end
  env.writefile = function(path, data)
    if level ~= 'prints' then recs('call:writefile', path, tostring(data)) end
    fs[tostring(path)] = data
    return true
  end
  env.readfile = function(path)
    if level ~= 'prints' then recs('call:readfile', path) end
    return fs[tostring(path)]
  end
  env.isfile = function(path)
    if level ~= 'prints' then recs('call:isfile', path) end
    return fs[tostring(path)] ~= nil
  end
  env.setclipboard = function(data)
    if level ~= 'prints' then recs('call:setclipboard', tostring(data)) end
    return true
  end
  env.queue_on_teleport = function(src)
    if level ~= 'prints' then recs('call:queue_on_teleport', tostring(src)) end
    return true
  end
  env.http_request = function(opts)
    if level ~= 'prints' then recs('call:http_request', tostring(opts and opts.Url or '')) end
    return { StatusCode = 200, Body = '', Success = true }
  end
  env.request = env.http_request
  env.http = { request = env.http_request }
  env.syn = { request = env.http_request }
  env.fluxus = { request = env.http_request }

  env.loadstring = function(src)
    local fn, err = loadstring(src)
    if not fn then return nil, err end
    setfenv(fn, env)
    return fn
  end

  env.load = function(src, chunkname, mode, _env)
    local fn, err = load(src, chunkname or 'TRACE_CHUNK', mode, _env or env)
    return fn, err
  end

  local function wrap_global(name, fn)
    return function(...)
      if level ~= 'prints' then recs('call:' .. tostring(name), ...) end
      return fn(...)
    end
  end

  setmetatable(env, {
    __index = function(t, k)
      local v = rawget(t, k)
      if v ~= nil then return v end
      local g = _G[k]
      if (level ~= 'prints') and type(g) == 'function' then
        local w = wrap_global(k, g)
        rawset(t, k, w)
        return w
      end
      if g == nil then
        local s = mkStub(tostring(k))
        rawset(t, k, s)
        return s
      end
      return g
    end
  })

  env.game = mkStub('game')
  env.workspace = mkStub('workspace')
  env.script = mkStub('script')
  env.Enum = mkStub('Enum')

  env.Vector2 = { new = function(x, y) return mkStub('Vector2') end }
  env.Vector3 = { new = function(x, y, z) return mkStub('Vector3') end }
  env.UDim = { new = function(scale, offset) return mkStub('UDim') end }
  env.UDim2 = { new = function(xScale, xOffset, yScale, yOffset) return mkStub('UDim2') end }
  env.Color3 = { fromRGB = function(r, g, b) return mkStub('Color3') end }
  env.TweenInfo = { new = function(...) return mkStub('TweenInfo') end }

  -- Network helpers on game/HttpService
  env.game.HttpGet = function(self, url)
    if level ~= 'prints' then recs('call:game.HttpGet', tostring(url)) end
    return ''
  end
  env.HttpService = env.HttpService or mkStub('HttpService')
  env.HttpService.GetAsync = function(self, url)
    if level ~= 'prints' then recs('call:HttpService.GetAsync', tostring(url)) end
    return ''
  end
  env.HttpService.PostAsync = function(self, url, body)
    if level ~= 'prints' then recs('call:HttpService.PostAsync', tostring(url), tostring(body)) end
    return ''
  end

  env.task = {
    wait = function(t)
      if level ~= 'prints' then recs('call:task.wait', t) end
      return 0
    end,
    spawn = function(fn)
      if level ~= 'prints' then recs('call:task.spawn') end
      if type(fn) == 'function' then pcall(fn) end
    end,
    delay = function(t, fn)
      if level ~= 'prints' then recs('call:task.delay', t) end
      if type(fn) == 'function' then pcall(fn) end
    end,
  }
  env.Instance = {
    new = function(className, parent)
      if level ~= 'prints' then recs('call:Instance.new', className, parent) end
      local obj = mkStub('Instance<' .. tostring(className) .. '>')
      if parent then obj.Parent = parent end
      return obj
    end
  }

  local dbg = (level == 'debug' or level == 'calls') and debug or nil
  local function hook(ev, line)
    if not dbg then return end
    local info = dbg.getinfo(2, 'nS') or {}
    if ev == 'call' then
      recs('dbg:call', info.name or 'anonymous', info.namewhat or '', info.what or '', info.linedefined or -1)
      if level == 'debug' then
        local i = 1
        while true do
          local name, val = dbg.getlocal(2, i)
          if not name then break end
          recs('dbg:local', name, tostring(val))
          i = i + 1
        end
      end
    elseif ev == 'return' and level == 'debug' then
      recs('dbg:return', info.name or 'anonymous')
    elseif ev == 'line' and level == 'debug' then
      recs('dbg:line', line or -1)
    end
  end

  local function with_hook(fn)
    if dbg and dbg.sethook then dbg.sethook(hook, 'crl') end
    local ok, r1, r2, r3, r4, r5 = pcall(fn)
    if dbg and dbg.sethook then dbg.sethook() end
    if not ok then return {} end
    return { r1, r2, r3, r4, r5 }
  end

  local main
  if is_lua51 then
    main = loadstring(code)
    if not main then return calls end
    setfenv(main, env)
  else
    main = select(1, load(code, 'TRACE_CHUNK', 't', env))
    if not main then return calls end
  end

  local queue = {}
  for _, v in ipairs(with_hook(main)) do queue[#queue+1] = v end
  local depth = 0
  while #queue > 0 and depth < 128 do
    local v = table.remove(queue, 1)
    if type(v) == 'function' then
      for _, ret in ipairs(with_hook(v)) do queue[#queue+1] = ret end
    end
    depth = depth + 1
  end
  return calls
end

local function to_node(v)
  local t = type(v)
  if t == 'string' then return Ast.StringExpression(v) end
  if t == 'number' then return Ast.NumberExpression(v) end
  if t == 'boolean' then return Ast.BooleanExpression(v) end
  return Ast.StringExpression(tostring(v))
end

local function is_ident(s)
  return type(s) == 'string' and s:match('^[_%a][_%w]*$') ~= nil
end

local ignore_globals = {
  print = true,
  io = true,
  ipairs = true,
  pairs = true,
  pcall = true,
  xpcall = true,
  select = true,
  type = true,
  tostring = true,
  tonumber = true,
  rawget = true,
  rawset = true,
  getmetatable = true,
  setmetatable = true,
  getfenv = true,
  setfenv = true,
  load = true,
  loadstring = true,
  require = true,
  unpack = true,
  next = true,
  rawequal = true,
  assert = true,
  error = true,
}

function DynamicTrace:apply(ast, pipeline)
  local level = (self.opts and self.opts.level) or 'prints'
  local code = (pipeline and pipeline.source) or ''
  local calls = run_with_trace(code, level)
  if #calls == 0 then
    local unparser = pipeline and pipeline.getUnparser and pipeline:getUnparser() or nil
    if unparser then
      local alt = unparser:unparse(ast)
      calls = run_with_trace(alt, level)
      if #calls == 0 and level ~= 'prints' then
        local prints_calls = run_with_trace(code, 'prints')
        if #prints_calls == 0 and alt then
          prints_calls = run_with_trace(alt, 'prints')
        end
        if #prints_calls > 0 then
          calls = prints_calls
          level = 'prints'
        end
      end
    end
  end
  if #calls == 0 then return ast end
  local stmts = {}
  for _, c in ipairs(calls) do
    if c.name == 'print' then
      local args = {}
      for i=1,#c.args do args[i] = to_node(c.args[i]) end
      local pScope, pId = ast.globalScope:resolveGlobal('print')
      stmts[#stmts+1] = Ast.FunctionCallStatement(Ast.VariableExpression(pScope, pId), args)
    elseif c.name == 'io.write' then
      local args = {}
      for i=1,#c.args do args[i] = to_node(c.args[i]) end
      local ioVarScope, ioVarId = ast.globalScope:resolveGlobal('io')
      local base = Ast.IndexExpression(Ast.VariableExpression(ioVarScope, ioVarId), Ast.StringExpression('write'))
      stmts[#stmts+1] = Ast.FunctionCallStatement(base, args)
    elseif level == 'api' then
      if c.name:sub(1,5) == 'call:' or c.name:sub(1,4) == 'set:' then
        local args = { Ast.StringExpression('[' .. c.name .. ']') }
        for i=1,#c.args do args[#args+1] = to_node(c.args[i]) end
        local pScope, pId = ast.globalScope:resolveGlobal('print')
        stmts[#stmts+1] = Ast.FunctionCallStatement(Ast.VariableExpression(pScope, pId), args)
      end
    elseif level == 'calls' and c.name == 'dbg:call' then
      local fnName = c.args[1]
      local namewhat = c.args[2] or ''
      if namewhat == 'global' and is_ident(fnName) and not ignore_globals[fnName] then
        local fnScope, fnId = ast.globalScope:resolveGlobal(fnName)
        stmts[#stmts+1] = Ast.FunctionCallStatement(Ast.VariableExpression(fnScope, fnId), {})
      end
    elseif level == 'debug' then
      local args = { Ast.StringExpression('[' .. c.name .. ']') }
      for i=1,#c.args do args[#args+1] = to_node(c.args[i]) end
      local pScope, pId = ast.globalScope:resolveGlobal('print')
      stmts[#stmts+1] = Ast.FunctionCallStatement(Ast.VariableExpression(pScope, pId), args)
    end
  end
  if #stmts > 0 then
    ast.body.statements = stmts
    print(string.format('[DynamicTrace] replayed %d calls', #stmts))
  end
  return ast
end

return DynamicTrace 