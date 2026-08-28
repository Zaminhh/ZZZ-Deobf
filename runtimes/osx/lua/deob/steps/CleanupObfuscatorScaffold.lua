local Ast = require('prometheus.ast')
local visitast = require('prometheus.visitast')

local Cleanup = {}
Cleanup.__index = Cleanup
Cleanup.Name = 'CleanupObfuscatorScaffold'

function Cleanup:new()
  return setmetatable({}, self)
end

local function is_empty_local(st)
  if st.kind ~= Ast.AstKind.LocalVariableDeclaration then return false end
  return not st.expressions or #st.expressions == 0
end

local function should_drop_localdecl(st)
  if st.kind ~= Ast.AstKind.LocalVariableDeclaration then return false end
  for _, expr in ipairs(st.expressions or {}) do
    if expr and expr.kind == Ast.AstKind.FunctionLiteralExpression then
      return true
    end
  end
  return false
end

local function is_rotate_for(st)
  if st.kind ~= Ast.AstKind.ForGenericStatement then return false end
  return true
end

local function is_base64_lookup_local(st)
  if st.kind ~= Ast.AstKind.LocalVariableDeclaration then return false end
  if #st.ids ~= 1 or not st.expressions or not st.expressions[1] then return false end
  local expr = st.expressions[1]
  if expr.kind ~= Ast.AstKind.TableConstructorExpression then return false end
  local charKeys = 0
  for _, e in ipairs(expr.entries or {}) do
    if e.kind == Ast.AstKind.KeyedTableEntry and e.key.kind == Ast.AstKind.StringExpression and #e.key.value == 1 then
      charKeys = charKeys + 1
    end
  end
  return charKeys >= 30
end

function Cleanup:apply(ast)
  local out = {}
  for _, st in ipairs(ast.body.statements) do
    if should_drop_localdecl(st) or is_empty_local(st) then
    elseif is_rotate_for(st) then
    elseif is_base64_lookup_local(st) then
    else
      table.insert(out, st)
    end
  end
  ast.body.statements = out
  return ast
end

return Cleanup 