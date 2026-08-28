local Ast = require('prometheus.ast')
local visitast = require('prometheus.visitast')

local UndoEncryptStrings = {}
UndoEncryptStrings.__index = UndoEncryptStrings
UndoEncryptStrings.Name = 'UndoEncryptStrings'

function UndoEncryptStrings:new()
  return setmetatable({}, self)
end

local K

local function extract_numbers_from_source(src)
  local params = {}
  params.param_mul_45 = tonumber(src:match('state_45%s*%*%s*(%d+)%s*%+%s*(%d+)')) and tonumber(src:match('state_45%s*%*%s*(%d+)%s*%+%s*(%d+)')) or nil
  params.param_add_45 = tonumber(src:match('state_45%s*%*%s*%d+%s*%+%s*(%d+)'))
  params.param_mul_8 = tonumber(src:match('state_8%s*%*%s*(%d+)%s*%%%s*257'))
  params.secret_key_8 = tonumber(src:match('prevVal%s*=%s*(%d+)%s*;'))
  return params
end

local function build_decryptor_from_ast(ast, unparse)
  local code = unparse(ast)
  local p = extract_numbers_from_source(code)
  if not (p and p.param_mul_45 and p.param_add_45 and p.param_mul_8 and p.secret_key_8) then
    return nil
  end
  local function make_decrypt(param_mul_45, param_add_45, param_mul_8, secret_key_8)
    local floor = math.floor
    local function make_state(seed)
      local state_45 = seed % 35184372088832
      local state_8 = seed % 255 + 2
      local prev_values = {}
      local function get_next_pseudo_random_byte()
        if #prev_values == 0 then
          state_45 = (state_45 * param_mul_45 + param_add_45) % 35184372088832
          repeat
            state_8 = state_8 * param_mul_8 % 257
          until state_8 ~= 1
          local r = state_8 % 32
          local n = floor(state_45 / 2 ^ (13 - (state_8 - r) / 32)) % 2 ^ 32 / 2 ^ r
          local rnd = floor(n % 1 * 2 ^ 32) + floor(n)
          local low_16 = rnd % 65536
          local high_16 = (rnd - low_16) / 65536
          local b1 = low_16 % 256
          local b2 = (low_16 - b1) / 256
          local b3 = high_16 % 256
          local b4 = (high_16 - b3) / 256
          prev_values = { b1, b2, b3, b4 }
        end
        return table.remove(prev_values)
      end
      return function(enc)
        local prevVal = secret_key_8
        local out = {}
        for i = 1, #enc do
          local byte = string.byte(enc, i)
          prevVal = (byte + get_next_pseudo_random_byte() + prevVal) % 256
          out[i] = string.char(prevVal)
        end
        return table.concat(out)
      end
    end
    return function(enc, seed)
      return make_state(seed)(enc)
    end
  end
  return make_decrypt(p.param_mul_45, p.param_add_45, p.param_mul_8, p.secret_key_8)
end

local function collect_symbols(ast)
  local decryptVar, stringsVar
  visitast(ast, nil, function(n, data)
    if n.kind == K.LocalVariableDeclaration then
      for _, id in ipairs(n.ids) do
        local name = n.scope:getVariableName(id)
        if name == 'DECRYPT' then decryptVar = { scope=n.scope, id=id }
        elseif name == 'STRINGS' then stringsVar = { scope=n.scope, id=id } end
      end
    end
    if n.kind == K.FunctionDeclaration and n.scope:getVariableName(n.id) == 'DECRYPT' then
      decryptVar = { scope=n.scope, id=n.id }
    end
  end)
  return decryptVar, stringsVar
end

function UndoEncryptStrings:apply(ast, pipeline)
  K = Ast.AstKind
  local unparse = function(tree) return pipeline:getUnparser():unparse(tree) end
  local decryptVar, stringsVar = collect_symbols(ast)
  if not decryptVar or not stringsVar then return ast end

  local decrypt_fn = build_decryptor_from_ast(ast, unparse)
  if not decrypt_fn then return ast end

  local count = 0
  visitast(ast, nil, function(node)
    if node.kind == K.IndexExpression then
      local base, idx = node.base, node.index
      if base.kind == K.VariableExpression and base.scope == stringsVar.scope and base.id == stringsVar.id then
        if idx.kind == K.FunctionCallExpression and idx.base.kind == K.VariableExpression and idx.base.scope == decryptVar.scope and idx.base.id == decryptVar.id then
          local args = idx.args
          if #args == 2 and args[1].kind == K.StringExpression and args[2].kind == K.NumberExpression then
            local plaintext = decrypt_fn(args[1].value, args[2].value)
            count = count + 1
            return Ast.StringExpression(plaintext)
          end
        end
      end
    end
  end)
  if count > 0 then print('[UndoEncryptStrings] decrypted ' .. count .. ' strings') end

  return ast
end

return UndoEncryptStrings 