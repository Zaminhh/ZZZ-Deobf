local Ast = require('prometheus.ast')
local visitast = require('prometheus.visitast')

local FoldNumbers = {}
FoldNumbers.__index = FoldNumbers
FoldNumbers.Name = 'FoldNumbers'

function FoldNumbers:new()
  return setmetatable({}, self)
end

local K

local function try_num(node)
  if node.isConstant and type(node.value) == 'number' then return true, node.value end
  return false
end

local function fold_bin(op, a, b)
  if op == K.AddExpression then return a + b end
  if op == K.SubExpression then return a - b end
  if op == K.MulExpression then return a * b end
  if op == K.DivExpression and b ~= 0 then return a / b end
  if op == K.ModExpression and b ~= 0 then return a % b end
  if op == K.PowExpression then return a ^ b end
end

function FoldNumbers:apply(ast)
  K = Ast.AstKind
  local changed = 0
  visitast(ast, nil, function(node)
    if node.kind == K.AddExpression or node.kind == K.SubExpression or node.kind == K.MulExpression
      or node.kind == K.DivExpression or node.kind == K.ModExpression or node.kind == K.PowExpression then
      local lhs, rhs = node.lhs, node.rhs
      if lhs.isConstant and rhs.isConstant and type(lhs.value) == 'number' and type(rhs.value) == 'number' then
        local ok, res = pcall(fold_bin, node.kind, lhs.value, rhs.value)
        if ok and type(res) == 'number' then
          changed = changed + 1
          return Ast.NumberExpression(res)
        end
      end
    end
  end)
  if changed > 0 then print('[FoldNumbers] folded ' .. changed .. ' expressions') end
  return ast
end

return FoldNumbers 