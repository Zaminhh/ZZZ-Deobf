local Ast = require('prometheus.ast')
local visitast = require('prometheus.visitast')

local UndoSplitStrings = {}
UndoSplitStrings.__index = UndoSplitStrings
UndoSplitStrings.Name = 'UndoSplitStrings'

function UndoSplitStrings:new()
  return setmetatable({}, self)
end

local K

local function is_lit_string_table(tb)
  if tb.kind ~= K.TableConstructorExpression then return false end
  for _, e in ipairs(tb.entries) do
    if e.kind ~= K.TableEntry or e.value.kind ~= K.StringExpression then return false end
  end
  return true
end

local function custom1_join(argtb)
  if argtb.kind ~= K.TableConstructorExpression then return nil end
  if #argtb.entries < 2 then return nil end
  local last = argtb.entries[#argtb.entries]
  if last.kind ~= K.TableEntry or last.value.kind ~= K.TableConstructorExpression then return nil end
  local strtb = last.value
  if not is_lit_string_table(strtb) then return nil end
  local n = #strtb.entries
  if n == 0 then return '' end
  if #argtb.entries - 1 ~= n then return nil end
  local parts = {}
  for i=1,n do
    local idxEntry = argtb.entries[i]
    if idxEntry.kind ~= K.TableEntry or idxEntry.value.kind ~= K.NumberExpression then return nil end
    local idx = idxEntry.value.value
    local strEntry = strtb.entries[i]
    local s = strtb.entries[idx] and strtb.entries[idx].value.value or nil
    if type(idx) ~= 'number' or not s then return nil end
    parts[#parts+1] = s
  end
  return table.concat(parts)
end

local function custom2_join(argtb)
  if argtb.kind ~= K.TableConstructorExpression then return nil end
  local m = #argtb.entries
  if m % 2 ~= 0 or m == 0 then return nil end
  local half = m / 2
  for i=1,half do
    local e = argtb.entries[i]
    if e.kind ~= K.TableEntry or e.value.kind ~= K.NumberExpression then return nil end
  end
  for i=half+1,m do
    local e = argtb.entries[i]
    if e.kind ~= K.TableEntry or e.value.kind ~= K.StringExpression then return nil end
  end
  local parts = {}
  for i=1,half do
    local idx = argtb.entries[i].value.value
    local s = argtb.entries[half + idx]
    if not s or s.value.kind ~= K.StringExpression then return nil end
    parts[#parts+1] = s.value.value
  end
  return table.concat(parts)
end

function UndoSplitStrings:apply(ast)
  K = Ast.AstKind
  visitast(ast, nil, function(node)
    if node.kind == K.FunctionCallExpression and #node.args == 1 then
      local tb = node.args[1]
      if tb.kind == K.TableConstructorExpression then
        local s = custom1_join(tb) or custom2_join(tb)
        if s ~= nil then
          return Ast.StringExpression(s)
        end
      end
    end
  end)
  return ast
end

return UndoSplitStrings 