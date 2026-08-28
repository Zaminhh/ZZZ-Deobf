local Ast = require('prometheus.ast')
local Unparser = require('prometheus.unparser')
local visitast = require('prometheus.visitast')

local UndoVmify = {}
UndoVmify.__index = UndoVmify
UndoVmify.Name = 'UndoVmify'

function UndoVmify:new()
  return setmetatable({}, self)
end

local function count_ifs(block)
  local K = Ast.AstKind
  local c = 0
  local function dive(node)
    if not node then return end
    if node.kind == K.IfStatement then
      c = c + 1
      dive(node.body)
      for _, eif in ipairs(node.elseifs or {}) do dive(eif.body) end
      dive(node.elsebody)
    elseif node.kind == K.Block then
      for _, st in ipairs(node.statements or {}) do dive(st) end
    else
      for k,v in pairs(node) do
        if type(v) == 'table' and v.kind then dive(v) end
      end
    end
  end
  dive(block)
  return c
end

local function collect_leaves(block)
  local K = Ast.AstKind
  local leaves = {}
  local function dive(node)
    if not node then return end
    if node.kind == K.IfStatement then
      dive(node.body)
      for _, eif in ipairs(node.elseifs or {}) do dive(eif.body) end
      if node.elsebody then
        if node.elsebody.kind == K.IfStatement then dive(node.elsebody) else table.insert(leaves, node.elsebody) end
      end
    else
      if node.kind == K.Block then table.insert(leaves, node) end
    end
  end
  dive(block)
  return leaves
end

local function find_best_dispatch(ast)
  local K = Ast.AstKind
  local best, best_parent, best_index, best_pos_scope, best_pos_id, best_score = nil, nil, nil, nil, nil, -1
  local function walk_block(block, parent)
    local list = block and block.statements or {}
    for i=1,#list do
      local st = list[i]
      if st.kind == K.WhileStatement and st.condition and st.condition.kind == K.VariableExpression then
        local score = count_ifs(st.body)
        if score > best_score then
          best, best_parent, best_index = st, parent or block, i
          best_pos_scope, best_pos_id = st.condition.scope, st.condition.id
          best_score = score
        end
      end
      if st.body then walk_block(st.body, st) end
      if st.elsebody then walk_block(st.elsebody, st) end
      if st.elseifs then for _, eif in ipairs(st.elseifs) do walk_block(eif.body, st) end end
      for k,v in pairs(st) do
        if type(v) == 'table' and v.kind == K.FunctionLiteralExpression and v.body then
          walk_block(v.body, st)
        end
      end
    end
  end
  walk_block(ast.body, ast.body)
  return best, best_parent, best_index, best_pos_scope, best_pos_id, best_score
end

local function instrument_in_place(ast, while_node, pos_scope, pos_id)
  local leaves = collect_leaves(while_node.body)
  local scope, id = ast.globalScope:resolveGlobal('__log_leaf')
  local hook_var = Ast.VariableExpression(scope, id)
  local pos_var = Ast.VariableExpression(pos_scope, pos_id)
  for _, leaf in ipairs(leaves) do
    table.insert(leaf.statements, 1, Ast.FunctionCallStatement(hook_var, { pos_var }))
  end
  return leaves
end

local function run_instrumented(ast, luaVersion)
  local unparser = Unparser:new({ LuaVersion = luaVersion })
  local code = unparser:unparse(ast)
  local out = {}
  local env = {}
  env.__log_leaf = function(pos) out[#out+1] = pos end
  env.print = function() end
  setmetatable(env, { __index = _G })
  local fn, err = load(code, nil, 't', env)
  if not fn then return out end
  pcall(fn)
  return out
end

function UndoVmify:apply(ast, pipeline)
  local luaVersion = pipeline and pipeline.luaVersion or require('prometheus.enums').LuaVersion.Lua51
  local while_node, parent_block, while_index, pos_scope, pos_id, score = find_best_dispatch(ast)
  if not while_node or score <= 0 then return ast end
  local leaves = instrument_in_place(ast, while_node, pos_scope, pos_id)
  local pos_order = run_instrumented(ast, luaVersion)
  if #pos_order == 0 and parent_block and while_index then
    table.insert(parent_block.statements, while_index, Ast.AssignmentStatement({ Ast.AssignmentVariable(pos_scope, pos_id) }, { Ast.NumberExpression(1) }))
    pos_order = run_instrumented(ast, luaVersion)
  end
  local seen = {}
  local ordered = {}
  for _, pos in ipairs(pos_order) do
    if pos ~= nil and not seen[pos] then
      seen[pos] = true
      ordered[#ordered+1] = pos
    end
  end
  local new = {}
  for _, pos in ipairs(ordered) do
    local idx = seen[pos] and nil
    for i, p in ipairs(pos_order) do if p == pos then idx = i; break end end
    local leaf = idx and leaves[idx] or nil
    if leaf then
      for _, st in ipairs(leaf.statements) do
        if st.kind ~= Ast.AstKind.FunctionCallStatement then
          table.insert(new, st)
        end
      end
    end
  end
  if #new > 0 then
    print(string.format('[UndoVmify] leaves=%d order=%d emitted=%d', #leaves, #pos_order, #new))
    ast.body.statements = new
  end
  return ast
end

return UndoVmify 