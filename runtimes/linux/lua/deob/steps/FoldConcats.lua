local Ast = require('prometheus.ast')
local visitast = require('prometheus.visitast')

local FoldConcats = {}
FoldConcats.__index = FoldConcats
FoldConcats.Name = 'FoldConcats'

function FoldConcats:new()
  return setmetatable({}, self)
end

local function flatten_strcat(node, out)
  local K = Ast.AstKind
  if node.kind == K.StrCatExpression then
    flatten_strcat(node.lhs, out)
    flatten_strcat(node.rhs, out)
  else
    table.insert(out, node)
  end
end

function FoldConcats:apply(ast)
  local changed = 0
  visitast(ast, nil, function(node)
    local K = Ast.AstKind
    if node.kind == K.StrCatExpression then
      local parts = {}
      flatten_strcat(node, parts)
      local all = true
      local buf = {}
      for _, p in ipairs(parts) do
        if p.kind ~= K.StringExpression then all = false; break end
        buf[#buf+1] = p.value
      end
      if all then
        changed = changed + 1
        return Ast.StringExpression(table.concat(buf))
      end
    elseif node.kind == K.FunctionCallExpression then
      local base = node.base
      if base.kind == K.IndexExpression and base.base.kind == K.VariableExpression and base.index.kind == K.StringExpression then
        local name = base.index.value
        local gscope, gid = base.base.scope, base.base.id
        local gname
        if gscope and gscope.getVariableName then gname = gscope:getVariableName(gid) end
        if name == 'concat' and gname == 'table' and #node.args == 1 and node.args[1].kind == K.TableConstructorExpression then
          local tb = node.args[1]
          local all = true
          local buf = {}
          for _, entry in ipairs(tb.entries) do
            if entry.kind ~= K.TableEntry or entry.value.kind ~= K.StringExpression then all=false; break end
            buf[#buf+1] = entry.value.value
          end
          if all then
            changed = changed + 1
            return Ast.StringExpression(table.concat(buf))
          end
        end
      end
    end
  end)
  if changed > 0 then print('[FoldConcats] folded ' .. changed .. ' items') end
  return ast
end

return FoldConcats 