local Ast = require('prometheus.ast')
local visitast = require('prometheus.visitast')

local ConstantArrayDecode = {}
ConstantArrayDecode.__index = ConstantArrayDecode
ConstantArrayDecode.Name = 'ConstantArrayDecode'

local is_lua51 = _VERSION == 'Lua 5.1'
local function compile(code)
  if is_lua51 then
    local fn, err = loadstring(code)
    if not fn then return nil, err end
    setfenv(fn, {})
    return fn
  else
    return load(code, nil, 't', {})
  end
end

local function find_block(src, start_pat, open_ch, close_ch)
  local s, e = src:find(start_pat)
  if not s then return nil end
  local i = e + 1
  local depth, start_i = 0
  while i <= #src do
    local ch = src:sub(i,i)
    if start_i then
      if ch == open_ch then depth = depth + 1 end
      if ch == close_ch then depth = depth - 1; if depth == 0 then return start_i, i - 1 end end
    else
      if ch == open_ch then start_i = i + 1; depth = 1 end
    end
    i = i + 1
  end
  return nil
end

local function parse_u_array_text(src)
  local si, ei = find_block(src, 'local%s+J%s*=%s*%{', '{', '}')
  if not si then si, ei = find_block(src, 'J%s*=%s*%{', '{', '}') end
  if not si then return {} end
  local fn = compile('return {' .. src:sub(si, ei) .. '}')
  if not fn then return {} end
  local ok, res = pcall(fn)
  if not ok then return {} end
  return res
end

local function eval_expr(expr)
  local fn = compile('return ' .. expr)
  if not fn then return nil end
  local ok, v = pcall(fn)
  if not ok then return nil end
  return v
end

local function parse_rotate_pairs(src)
  local p = src:find('ipairs%s*%(%s*%{%s*%{')
  if not p then return nil end
  local si, ei = find_block(src:sub(p), '^', '{', '}')
  if not si then return nil end
  local body = src:sub(p + si, p + ei - 1)
  local parts = {}
  for part in body:gmatch('%b{}') do table.insert(parts, part) end
  if #parts < 3 then return nil end
  local function pair_to_nums(s)
    local a,b = s:match('^%{%s*([^,}]+)%s*[,;]%s*([^}]+)%s*%}$')
    if not a then
      s = s:sub(2, -2)
      local p = {}
      for x in s:gmatch('[^,};]+') do table.insert(p, x) end
      a, b = p[1], p[2]
    end
    return eval_expr(a), eval_expr(b)
  end
  local a1,b1 = pair_to_nums(parts[1])
  local a2,b2 = pair_to_nums(parts[2])
  local a3,b3 = pair_to_nums(parts[3])
  return {a1,b1}, {a2,b2}, {a3,b3}
end

local function reverse_range(t, i, j)
  while i < j do
    t[i], t[j] = t[j], t[i]
    i = i + 1
    j = j - 1
  end
end

local function unrotate_in_place(t, p1, p2, p3)
  reverse_range(t, p1[1], p1[2])
  reverse_range(t, p2[1], p2[2])
  reverse_range(t, p3[1], p3[2])
end

local function parse_lookup_map(src)
  local pos = src:find('local%s+j%s*=%s*%{')
  if not pos then return {} end
  local si, ei = find_block(src:sub(pos), '^', '{', '}')
  if not si then return {} end
  local body = src:sub(pos + si, pos + ei - 1)
  local fn = compile('return {' .. body .. '}')
  if not fn then return {} end
  local ok, tbl = pcall(fn)
  if not ok then return {} end
  local map = {}
  for k,v in pairs(tbl) do
    if type(k) == 'string' and #k == 1 and type(v) == 'number' then
      map[k] = v
    end
  end
  return map
end

local function decode_base64_custom(s, map)
  local len = #s
  local out = {}
  local idx, value, count = 1, 0, 0
  local function push3(n)
    local c1 = math.floor(n / 65536)
    local c2 = math.floor(n % 65536 / 256)
    local c3 = n % 256
    out[#out+1] = string.char(c1, c2, c3)
  end
  while idx <= len do
    local ch = s:sub(idx, idx)
    local code = map[ch]
    if code then
      value = value + code * (64 ^ (3 - count))
      count = count + 1
      if count == 4 then
        count = 0; push3(value); value = 0
      end
    elseif ch == '=' then
      out[#out+1] = string.char(math.floor(value / 65536))
      if idx >= len or s:sub(idx + 1, idx + 1) ~= '=' then
        out[#out+1] = string.char(math.floor(value % 65536 / 256))
      end
      break
    end
    idx = idx + 1
  end
  return table.concat(out)
end

local function decode_constants(u, map)
  local r = {}
  for i=1,#u do
    local v = u[i]
    if type(v) == 'string' and v ~= '' then
      r[i] = decode_base64_custom(v, map)
    else
      r[i] = v
    end
  end
  return r
end

local function eval_num_expr(node)
  local K = Ast.AstKind
  if node.kind == K.NumberExpression then return node.value end
  if node.kind == K.UnaryMinusExpression then
    local v = eval_num_expr(node.operand)
    if v then return -v end
  end
  if node.kind == K.AddExpression or node.kind == K.SubExpression or node.kind == K.MulExpression or node.kind == K.DivExpression or node.kind == K.ModExpression or node.kind == K.PowExpression then
    local a = eval_num_expr(node.lhs)
    local b = eval_num_expr(node.rhs)
    if not a or not b then return nil end
    if node.kind == K.AddExpression then return a + b end
    if node.kind == K.SubExpression then return a - b end
    if node.kind == K.MulExpression then return a * b end
    if node.kind == K.DivExpression then if b ~= 0 then return a / b end return nil end
    if node.kind == K.ModExpression then if b ~= 0 then return a % b end return nil end
    if node.kind == K.PowExpression then return a ^ b end
  end
  return nil
end

function ConstantArrayDecode:new()
  return setmetatable({}, self)
end

local function replace_value_node(val)
  if type(val) == 'string' then
    return Ast.StringExpression(val)
  elseif type(val) == 'number' then
    return Ast.NumberExpression(val)
  elseif type(val) == 'boolean' then
    return Ast.BooleanExpression(val)
  else
    return Ast.NilExpression()
  end
end

function ConstantArrayDecode:apply(ast, pipeline)
  local code = pipeline:getUnparser() and pipeline:getUnparser():unparse(ast) or nil
  local source = code or pipeline.source or ''
  if not source or #source == 0 then return ast end

  local u = parse_u_array_text(source)
  if #u == 0 then u = {} end
  local p1,p2,p3 = parse_rotate_pairs(source)
  if p1 and p2 and p3 and #u > 0 then
    unrotate_in_place(u, p1, p2, p3)
  end
  local map = parse_lookup_map(source)
  local decoded = next(map) and decode_constants(u, map) or u

  local arrScope, arrId, wrapperScope, wrapperId, wrapperOffset
  local localWrappers = {}
  local replaced = 0
  local wrapperName

  visitast(ast, nil, function(node)
    if node.kind == Ast.AstKind.LocalVariableDeclaration and node.expressions and #node.expressions == 1 then
      local expr = node.expressions[1]
      if expr.kind == Ast.AstKind.TableConstructorExpression then
        if not arrScope then
          arrScope = node.scope; arrId = node.ids[1]
        end
      end
    end
    if node.kind == Ast.AstKind.LocalFunctionDeclaration then
      local body = node.body
      if body and #body.statements == 1 then
        local st = body.statements[1]
        if st.kind == Ast.AstKind.ReturnStatement and #st.args == 1 then
          local ret = st.args[1]
          if ret.kind == Ast.AstKind.IndexExpression then
            local base, index = ret.base, ret.index
            if (index.kind == Ast.AstKind.AddExpression or index.kind == Ast.AstKind.SubExpression)
              and base.kind == Ast.AstKind.VariableExpression then
              local lhs, rhs = index.lhs, index.rhs
              if lhs.kind == Ast.AstKind.VariableExpression and rhs.kind == Ast.AstKind.NumberExpression then
                wrapperScope, wrapperId = node.scope, node.id
                wrapperName = node.scope.getVariableName and node.scope:getVariableName(node.id) or nil
                arrScope, arrId = base.scope, base.id
                wrapperOffset = (index.kind == Ast.AstKind.AddExpression) and rhs.value or -rhs.value
              end
            end
          end
        end
      end
    end
    if node.kind == Ast.AstKind.LocalVariableDeclaration and #node.ids == 1 and node.expressions and node.expressions[1] and node.expressions[1].kind == Ast.AstKind.TableConstructorExpression then
      local tbl = node.expressions[1]
      for _, entry in ipairs(tbl.entries or {}) do
        if entry.kind == Ast.AstKind.KeyedTableEntry and entry.key.kind == Ast.AstKind.StringExpression then
          local key = entry.key.value
          if entry.value.kind == Ast.AstKind.FunctionLiteralExpression then
            local fn = entry.value
            local fbody = fn.body
            if fbody and #fbody.statements == 1 and fbody.statements[1].kind == Ast.AstKind.ReturnStatement then
              local call = fbody.statements[1].args[1]
              if call and call.kind == Ast.AstKind.FunctionCallExpression then
                local base = call.base
                local idxExpr
                if base.kind == Ast.AstKind.IndexExpression then
                  idxExpr = base.index
                end
                if idxExpr and (idxExpr.kind == Ast.AstKind.AddExpression or idxExpr.kind == Ast.AstKind.SubExpression) then
                  local lhs, rhs = idxExpr.lhs, idxExpr.rhs
                  if lhs.kind == Ast.AstKind.VariableExpression and rhs.kind == Ast.AstKind.NumberExpression then
                    local off = (idxExpr.kind == Ast.AstKind.AddExpression) and rhs.value or -rhs.value
                    localWrappers[key] = { scope = node.scope, id = node.ids[1], offset = off, fn = fn }
                  end
                end
              end
            end
          end
        end
      end
    end
  end)

  visitast(ast, nil, function(node)
    if node.kind == Ast.AstKind.IndexExpression and node.base.kind == Ast.AstKind.VariableExpression then
      if arrScope and arrId and node.base.scope == arrScope and node.base.id == arrId then
        if node.index.kind == Ast.AstKind.NumberExpression and decoded[node.index.value] ~= nil then
          local val = decoded[node.index.value]
          replaced = replaced + 1
          return replace_value_node(val)
        end
      end
    end
  end)

  if (arrScope and arrId) and (wrapperOffset ~= nil) then
    visitast(ast, nil, function(node)
      if node.kind == Ast.AstKind.FunctionCallExpression then
        if node.base.kind == Ast.AstKind.VariableExpression then
          local ok = false
          if wrapperScope and wrapperId and node.base.scope == wrapperScope and node.base.id == wrapperId then ok = true end
          if not ok and wrapperName and node.base.scope and node.base.scope.getVariableName and node.base.scope:getVariableName(node.base.id) == wrapperName then ok = true end
          if ok and #node.args == 1 then
            local num = eval_num_expr(node.args[1])
            if num and decoded[num + wrapperOffset] ~= nil then
              local idx = num + wrapperOffset
              local val = decoded[idx]
              replaced = replaced + 1
              return replace_value_node(val)
            end
          end
        end
      end
    end)
  end

  if arrScope and arrId and next(localWrappers) then
    visitast(ast, nil, function(node)
      if node.kind == Ast.AstKind.FunctionCallExpression and node.base.kind == Ast.AstKind.IndexExpression then
        local base = node.base
        if base.base.kind == Ast.AstKind.VariableExpression then
          local info
          if base.index.kind == Ast.AstKind.StringExpression then
            local key = base.index.value
            info = localWrappers[key]
          end
          if info and base.base.scope == info.scope and base.base.id == info.id then
            local num
            for _, a in ipairs(node.args or {}) do
              local v = eval_num_expr(a)
              if v then num = v end
            end
            if num and decoded[num + info.offset] ~= nil then
              local idx = num + info.offset
              local val = decoded[idx]
              replaced = replaced + 1
              return replace_value_node(val)
            end
          end
        end
      end
    end)
  end

  if replaced > 0 then print('[ConstantArrayDecode] inlined ' .. replaced .. ' constants') end
  return ast
end

return ConstantArrayDecode 