local Ast = require('prometheus.ast')

local UnwrapFunction = {}
UnwrapFunction.__index = UnwrapFunction
UnwrapFunction.Name = 'UnwrapFunction'

function UnwrapFunction:new()
  return setmetatable({}, self)
end

local function unwrap_once(ast)
  local ret = ast.body.statements[1]
  if not ret or ret.kind ~= Ast.AstKind.ReturnStatement then return false end
  local call = ret.args and ret.args[1]
  if not call or call.kind ~= Ast.AstKind.FunctionCallExpression then return false end
  local base = call.base
  if base and base.kind == Ast.AstKind.FunctionLiteralExpression then
    ast.body.statements = base.body.statements
    return true
  end
  if base and base.kind == Ast.AstKind.FunctionCallExpression and base.base and base.base.kind == Ast.AstKind.FunctionLiteralExpression then
    ast.body.statements = base.base.body.statements
    return true
  end
  return false
end

function UnwrapFunction:apply(ast)
  local changed = unwrap_once(ast)
  if changed then unwrap_once(ast) end
  return ast
end

return UnwrapFunction 