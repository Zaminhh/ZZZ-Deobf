local Ast = require('prometheus.ast')
local Unparser = require('prometheus.unparser')

local DispatchFlatten = {}
DispatchFlatten.__index = DispatchFlatten
DispatchFlatten.Name = 'DispatchFlatten'

function DispatchFlatten:new()
  return setmetatable({}, self)
end

local function find_dispatch_with_parent(ast)
  local K = Ast.AstKind
  local found_node, found_parent, found_index, pos_scope, pos_id
  local function walk_block(block)
    local list = block and block.statements or {}
    for i=1,#list do
      local st = list[i]
      if st.kind == K.WhileStatement and st.condition and st.condition.kind == K.VariableExpression then
        found_node, found_parent, found_index = st, block, i
        pos_scope, pos_id = st.condition.scope, st.condition.id
        return true
      end
      if st.body and walk_block(st.body) then return true end
      if st.elsebody and walk_block(st.elsebody) then return true end
      if st.elseifs then
        for _, eif in ipairs(st.elseifs) do if walk_block(eif.body) then return true end end
      end
    end
    return false
  end
  walk_block(ast.body)
  return found_node, pos_scope, pos_id, found_parent, found_index
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

local function instrument(ast, while_node, pos_scope, pos_id, parent_block, while_index)
  local leaves = collect_leaves(while_node.body)
  local scope, id = ast.globalScope:resolveGlobal('__log_leaf')
  local hook_var = Ast.VariableExpression(scope, id)
  local pos_var = Ast.VariableExpression(pos_scope, pos_id)
  for _, leaf in ipairs(leaves) do
    local call = Ast.FunctionCallStatement(hook_var, { pos_var })
    table.insert(leaf.statements, 1, call)
  end
  local prelude = {}
  for i=1, while_index-1 do prelude[#prelude+1] = parent_block.statements[i] end
  local new_stmts = {}
  for i=1,#prelude do new_stmts[#new_stmts+1] = prelude[i] end
  new_stmts[#new_stmts+1] = while_node
  ast.body.statements = new_stmts
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

function DispatchFlatten:apply(ast, pipeline)
  local luaVersion = pipeline and pipeline.luaVersion or require('prometheus.enums').LuaVersion.Lua51
  local while_node, pos_scope, pos_id, parent_block, while_index = find_dispatch_with_parent(ast)
  if not while_node then return ast end
  local leaves = instrument(ast, while_node, pos_scope, pos_id, parent_block, while_index)
  local pos_order = run_instrumented(ast, luaVersion)
  if #pos_order == 0 then
    -- try seeding from first leaf's first assignment to pos if any; else fallback to 1
    local seed = Ast.AssignmentStatement({ Ast.AssignmentVariable(pos_scope, pos_id) }, { Ast.NumberExpression(1) })
    table.insert(ast.body.statements, 1, seed)
    pos_order = run_instrumented(ast, luaVersion)
  end
  local map = {}
  for i, pos in ipairs(pos_order) do if pos ~= nil and map[pos] == nil then map[pos] = i end end
  local new = {}
  for pos, idx in pairs(map) do
    local leaf = leaves[idx]
    for _, st in ipairs(leaf.statements) do table.insert(new, st) end
  end
  if #leaves > 0 then print(string.format('[DispatchFlatten] leaves=%d order=%d emitted=%d', #leaves, #pos_order, #new)) end
  ast.body.statements = new
  return ast
end

return DispatchFlatten 