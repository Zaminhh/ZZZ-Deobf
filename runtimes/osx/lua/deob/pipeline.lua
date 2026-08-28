local function add_path()
  local here = debug.getinfo(1, 'S').source:sub(2)
  local dir = here:match('(.*[/%\\])') or ''
  package.path = dir .. '../../Prometheus/src/?.lua;' .. dir .. '?.lua;' .. package.path
end
add_path()

local Parser = require('prometheus.parser')
local Unparser = require('prometheus.unparser')
local Enums = require('prometheus.enums')
local Ast = require('prometheus.ast')
local visitast = require('prometheus.visitast')

local DeobPipeline = {}
DeobPipeline.__index = DeobPipeline

local function count_nodes(ast)
  local k = Ast.AstKind
  local c = { func=0, strings=0, numbers=0, assigns=0 }
  visitast(ast, nil, function(n)
    if n.kind == k.FunctionDeclaration or n.kind == k.LocalFunctionDeclaration or n.kind == k.FunctionLiteralExpression then c.func=c.func+1 end
    if n.kind == k.StringExpression then c.strings=c.strings+1 end
    if n.kind == k.NumberExpression then c.numbers=c.numbers+1 end
    if n.kind == k.AssignmentStatement then c.assigns=c.assigns+1 end
  end)
  return c
end

local function line_count(s)
  local _, n = s:gsub('\n', '')
  return n + 1
end

function DeobPipeline:new(opts)
  local o = {
    luaVersion = (opts and (opts.LuaVersion or opts.luaVersion)) or Enums.LuaVersion.Lua51,
    prettyPrint = opts and opts.PrettyPrint or false,
    steps = {},
    metrics = {},
    last_ast = nil,
    snapshots = {},
  }
  setmetatable(o, self)
  o.parser = Parser:new({ LuaVersion = o.luaVersion })
  o.unparser = Unparser:new({ LuaVersion = o.luaVersion, PrettyPrint = o.prettyPrint })
  return o
end

function DeobPipeline:add(step)
  table.insert(self.steps, step)
  return self
end

function DeobPipeline:getParser()
  return self.parser
end

function DeobPipeline:getUnparser()
  return self.unparser
end

function DeobPipeline:apply(code)
  local ast = self.parser:parse(code)
  for _, step in ipairs(self.steps) do
    local before_code = self.unparser:unparse(ast)
    local before_lines = line_count(before_code)
    local before_counts = count_nodes(ast)
    local res = step:apply(ast, self)
    if type(res) == 'table' then
      ast = res
    end
    local after_code = self.unparser:unparse(ast)
    local after_lines = line_count(after_code)
    local after_counts = count_nodes(ast)
    local name = tostring(step.__name or step.Name or step.__index or step)
    local info = {
      lines_before = before_lines,
      lines_after = after_lines,
      lines_delta = after_lines - before_lines,
      funcs_before = before_counts.func,
      funcs_after = after_counts.func,
      funcs_delta = after_counts.func - before_counts.func,
      strings_before = before_counts.strings,
      strings_after = after_counts.strings,
      strings_delta = after_counts.strings - before_counts.strings,
      numbers_before = before_counts.numbers,
      numbers_after = after_counts.numbers,
      numbers_delta = after_counts.numbers - before_counts.numbers,
      assigns_before = before_counts.assigns,
      assigns_after = after_counts.assigns,
      assigns_delta = after_counts.assigns - before_counts.assigns,
    }
    self.metrics[name] = info
    table.insert(self.snapshots, { name = name, code = after_code })
    print(string.format('[%s] lines %d -> %d (%+d) funcs %+d strings %+d numbers %+d assigns %+d', name, info.lines_before, info.lines_after, info.lines_delta, info.funcs_delta, info.strings_delta, info.numbers_delta, info.assigns_delta))
  end
  self.last_ast = ast
  return self.unparser:unparse(ast)
end

return DeobPipeline 