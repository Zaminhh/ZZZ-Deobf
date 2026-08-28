local Ast = require('prometheus.ast')
local visitast = require('prometheus.visitast')

local UndoProxifyLocals = {}
UndoProxifyLocals.__index = UndoProxifyLocals
UndoProxifyLocals.Name = 'UndoProxifyLocals'

function UndoProxifyLocals:new()
  return setmetatable({}, self)
end

local K

local function find_value_name_keys(ast)
  local valueNames = {} -- map scope->id->valueName
  visitast(ast, nil, function(n)
    if n.kind == K.AssignmentStatement then
      local lhs = n.variables and n.variables[1]
      local rhs = n.expressions and n.expressions[1]
      if lhs and lhs.kind == K.AssignmentIndexing and rhs and (rhs.kind == K.VariableExpression or rhs.kind == K.FunctionLiteralExpression) then
        if lhs.index.kind == K.StringExpression then
          local base = lhs.base
          if base.kind == K.VariableExpression then
            valueNames[base.scope] = valueNames[base.scope] or {}
            valueNames[base.scope][base.id] = lhs.index.value
          end
        end
      end
    end
  end)
  return valueNames
end

function UndoProxifyLocals:apply(ast)
  K = Ast.AstKind
  local valueNames = find_value_name_keys(ast)
  if not next(valueNames) then return ast end

  visitast(ast, nil, function(node)
    if node.kind == K.VariableExpression then
      local scope, id = node.scope, node.id
      local vn = valueNames[scope] and valueNames[scope][id]
      if vn then
        return Ast.VariableExpression(scope, id)
      end
    end
    if node.kind == K.AssignmentVariable then
      local scope, id = node.scope, node.id
      local vn = valueNames[scope] and valueNames[scope][id]
      if vn then
        return Ast.AssignmentVariable(scope, id)
      end
    end
  end)

  return ast
end

return UndoProxifyLocals 