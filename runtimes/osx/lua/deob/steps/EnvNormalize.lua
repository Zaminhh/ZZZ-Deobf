local Ast = require('prometheus.ast')
local visitast = require('prometheus.visitast')

local EnvNormalize = {}
EnvNormalize.__index = EnvNormalize
EnvNormalize.Name = 'EnvNormalize'

local whitelist = {
  print=true, table=true, string=true, math=true,
  setmetatable=true, getmetatable=true, select=true,
  unpack=true, pairs=true, ipairs=true, type=true,
}

local function key_of(var)
  return tostring(var.scope) .. ':' .. tostring(var.id)
end

function EnvNormalize:new()
  return setmetatable({}, self)
end

local function make_global(ast, name)
  local scope, id = ast.globalScope:resolveGlobal(name)
  return Ast.VariableExpression(scope, id)
end

local function collect_aliases(ast)
  local aliases = {}
  visitast(ast, nil, function(node)
    if node.kind == Ast.AstKind.LocalVariableDeclaration and node.expressions and #node.ids == 1 and #node.expressions == 1 then
      local expr = node.expressions[1]
      if expr and expr.kind == Ast.AstKind.IndexExpression then
        local base, idx = expr.base, expr.index
        if base and base.kind == Ast.AstKind.VariableExpression and idx and idx.kind == Ast.AstKind.StringExpression then
          local name = idx.value
          if whitelist[name] then
            local fake = { scope = node.scope, id = node.ids[1] }
            aliases[key_of(fake)] = name
          end
        end
      elseif expr and expr.kind == Ast.AstKind.VariableExpression then
        local vname = expr.scope:getVariableName(expr.id)
        if whitelist[vname] then
          local fake = { scope = node.scope, id = node.ids[1] }
          aliases[key_of(fake)] = vname
        end
      end
    end
  end)
  return aliases
end

local function transform(ast, aliases)
  visitast(ast, nil, function(node)
    if node.kind == Ast.AstKind.VariableExpression then
      local k = key_of(node)
      local name = aliases[k]
      if name then return make_global(ast, name) end
    elseif node.kind == Ast.AstKind.IndexExpression then
      local base, idx = node.base, node.index
      if base and base.kind == Ast.AstKind.VariableExpression and idx and idx.kind == Ast.AstKind.StringExpression then
        local name = idx.value
        if whitelist[name] then
          return make_global(ast, name)
        end
      end
    end
  end)
end

local function filter_block(block, aliases)
  local out = {}
  for _, st in ipairs(block.statements or {}) do
    if st.kind == Ast.AstKind.LocalVariableDeclaration then
      local drop = false
      for _, id in ipairs(st.ids) do
        local fake = { scope = st.scope, id = id }
        if aliases[key_of(fake)] then drop = true; break end
      end
      if not drop then table.insert(out, st) end
    else
      if st.body then st.body = Ast.Block(filter_block(st.body, aliases), st.body.scope) end
      if st.elsebody then st.elsebody = Ast.Block(filter_block(st.elsebody, aliases), st.elsebody.scope) end
      if st.elseifs then
        for _, eif in ipairs(st.elseifs) do
          if eif.body then eif.body = Ast.Block(filter_block(eif.body, aliases), eif.body.scope) end
        end
      end
      table.insert(out, st)
    end
  end
  return out
end

function EnvNormalize:apply(ast)
  local aliases = collect_aliases(ast)
  transform(ast, aliases)
  ast.body.statements = filter_block(ast.body, aliases)
  return ast
end

return EnvNormalize 