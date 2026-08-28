local function add_path()
  local here = debug.getinfo(1, 'S').source:sub(2)
  local dir = here:match('(.*[/%\\])') or ''
  package.path = dir .. '../?.lua;' .. dir .. '../../Prometheus/src/?.lua;' .. package.path
end
add_path()

local Pipeline = require('deob.pipeline')
local ConstantArrayDecode = require('deob.steps.ConstantArrayDecode')
local UnwrapFunction = require('deob.steps.UnwrapFunction')
local EnvNormalize = require('prometheus.util') and require('deob.steps.EnvNormalize') or require('deob.steps.EnvNormalize')
local FoldConcats = require('deob.steps.FoldConcats')
local FoldNumbers = require('deob.steps.FoldNumbers')
local Cleanup = require('deob.steps.CleanupObfuscatorScaffold')
local DispatchFlatten = require('deob.steps.DispatchFlatten')
local UndoSplitStrings = require('deob.steps.UndoSplitStrings')
local UndoEncryptStrings = require('deob.steps.UndoEncryptStrings')
local UndoProxifyLocals = require('deob.steps.UndoProxifyLocals')
local UndoVmify = require('deob.steps.UndoVmify')
local DynamicTrace = require('deob.steps.DynamicTrace')

local function read(path)
  local f = assert(io.open(path, 'rb'))
  local s = f:read('*a'); f:close(); return s
end

local function write(path, s)
  local f = assert(io.open(path, 'wb'))
  f:write(s)
  f:close()
end

local function ensure_dir(dir)
  -- best-effort: create directory if not exists (Windows 'mkdir' will succeed if exists)
  os.execute(string.format('mkdir "%s" > NUL 2>&1', dir))
end

local function decode_numeric_escapes_in_code(code)
  return code:gsub("\\(%d%d%d)", function(d)
    return string.char(tonumber(d))
  end)
end

local function usage()
  io.write([[Usage: lua src/deob/cli.lua <input.lua> [--out <path>] [--trace prints|calls|api|debug|off] [--trace-only] [--pretty|--no-pretty] [--emit-ast <path>] [--emit-snapshots <dir>]
Defaults: --trace prints, --pretty
]])
end

local in_path = arg[1]
if not in_path or in_path == '--help' or in_path == '-h' then
  usage()
  os.exit(in_path and 0 or 1)
end

local out_path = (arg[2] and not arg[2]:match('^%-%-')) and arg[2] or (in_path:gsub('%.lua$', '') .. '.deob.lua')
local trace_level = 'prints'
local trace_only = false
local pretty = true
local emit_ast_path = nil
local emit_snapshots_dir = nil

local i = 2
while i <= #arg do
  local a = arg[i]
  if a == '--out' then
    out_path = arg[i+1]; i = i + 2
  elseif a and a:match('^%-%-out=') then
    out_path = a:match('^%-%-out=(.+)$'); i = i + 1
  elseif a == '--trace' then
    trace_level = (arg[i+1] or trace_level); i = i + 2
  elseif a and a:match('^%-%-trace=') then
    trace_level = a:match('^%-%-trace=(.+)$'); i = i + 1
  elseif a == '--trace-only' then
    trace_only = true; i = i + 1
  elseif a == '--static-only' then
    trace_level = 'off'; i = i + 1
  elseif a == '--emit-ast' then
    emit_ast_path = arg[i+1]; i = i + 2
  elseif a and a:match('^%-%-emit%-ast=') then
    emit_ast_path = a:match('^%-%-emit%-ast=(.+)$'); i = i + 1
  elseif a == '--emit-snapshots' then
    emit_snapshots_dir = arg[i+1]; i = i + 2
  elseif a and a:match('^%-%-emit%-snapshots=') then
    emit_snapshots_dir = a:match('^%-%-emit%-snapshots=(.+)$'); i = i + 1
  elseif a == '--pretty' then
    pretty = true; i = i + 1
  elseif a == '--no-pretty' then
    pretty = false; i = i + 1
  else
    i = i + 1
  end
end

local source = read(in_path)

local pipeline
if trace_only then
  pipeline = Pipeline:new({ LuaVersion = require('prometheus.enums').LuaVersion.Lua51, PrettyPrint = pretty })
  if trace_level and trace_level ~= 'off' then
    pipeline:add(DynamicTrace:new({ level = trace_level }))
  end
else
  pipeline = Pipeline:new({ LuaVersion = require('prometheus.enums').LuaVersion.Lua51, PrettyPrint = pretty })
    :add(UnwrapFunction:new())
    :add(ConstantArrayDecode:new())
    :add(FoldNumbers:new())
    :add(EnvNormalize:new())
    :add(FoldConcats:new())
    :add(UndoSplitStrings:new())
    :add(UndoEncryptStrings:new())
    :add(UndoProxifyLocals:new())
    :add(Cleanup:new())
    :add(UndoVmify:new())
  if trace_level and trace_level ~= 'off' then
    pipeline:add(DynamicTrace:new({ level = trace_level }))
  end
end

pipeline.source = source
local result = pipeline:apply(source)
result = decode_numeric_escapes_in_code(result)
write(out_path, result)
print('wrote ' .. out_path)

if emit_ast_path then
  local unparser = pipeline:getUnparser()
  local ast_code = unparser:unparse(pipeline.last_ast)
  write(emit_ast_path, ast_code)
  print('emitted AST-like code to ' .. emit_ast_path)
end

if emit_snapshots_dir and pipeline.snapshots then
  ensure_dir(emit_snapshots_dir)
  for idx, snap in ipairs(pipeline.snapshots) do
    local name = tostring(snap.name or ('step' .. idx))
    local safe = name:gsub('[^%w%-_]+', '_')
    local path = string.format('%s/%02d_%s.lua', emit_snapshots_dir, idx, safe)
    write(path, snap.code)
  end
  print('emitted snapshots to ' .. emit_snapshots_dir)
end 