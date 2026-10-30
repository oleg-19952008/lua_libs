--- base64.lua
---
--- Компактный Base64-кодек для Lua 5.1+ без внешних зависимостей.
--- Поддерживает стандартный (RFC 4648) и URL-safe (RFC 4648 §5) алфавиты.
---
--- Пример использования:
---   local b64 = require('base64')
---   local s   = b64.encode('hello')       --> 'aGVsbG8='
---   local u   = b64.encode_url('hello')   --> 'aGVsbG8'
---   local d   = b64.decode(u)             --> 'hello'
---
--- @module base64
local base64 = {}

-- Алфавит стандартного Base64. Индекс i в строке соответствует значению i-1.
local chars  = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

-- Обратная таблица: символ -> значение (0..63).
local lookup = {}
for i = 1, #chars do
    lookup[chars:sub(i, i)] = i - 1
end

--- Кодирует строку в Base64.
---
--- При `url_safe = true` применяются замены:
---   '+' -> '-', '/' -> '_', и удаляется padding '='.
---
--- @param  data      string   Исходные байты.
--- @param  url_safe  boolean? Если true — URL-safe вариант без padding.
--- @return string             Base64-строка.
--- @raise                            Если data не строка.
function base64.encode(data, url_safe)
    assert(type(data) == 'string', 'string expected')
    local out, n, len = {}, 0, #data
    for i = 1, len, 3 do
        local b1 = data:byte(i)
        local b2 = data:byte(i + 1)
        local b3 = data:byte(i + 2)

        local c1 = math.floor(b1 / 4)
        local c2 = (b1 % 4) * 16 + (b2 and math.floor(b2 / 16) or 0)
        local c3 = b2 and ((b2 % 16) * 4 + (b3 and math.floor(b3 / 64) or 0))
        local c4 = b3 and (b3 % 64)

        n = n + 1; out[n] = chars:sub(c1 + 1, c1 + 1)
        n = n + 1; out[n] = chars:sub(c2 + 1, c2 + 1)
        n = n + 1; out[n] = c3 and chars:sub(c3 + 1, c3 + 1) or '='
        n = n + 1; out[n] = c4 and chars:sub(c4 + 1, c4 + 1) or '='
    end

    local result = table.concat(out)
    if url_safe then
        result = result:gsub('%+', '-'):gsub('/', '_'):gsub('=', '')
    end
    return result
end

--- Кодирует строку в URL-safe Base64 (без padding).
--- Эквивалент `base64.encode(data, true)`.
---
--- @param  data string
--- @return string
function base64.encode_url(data)
    return base64.encode(data, true)
end

--- Декодирует Base64-строку.
---
--- Принимает как стандартный, так и URL-safe алфавит одновременно:
--- символы '-' и '_' трактуются как '+' и '/' соответственно.
--- Пробельные символы игнорируются, padding '=' опционален.
---
--- В случае ошибки не бросает исключение, а возвращает nil и текст ошибки:
---   * 'invalid base64 length'    — длина после удаления padding даёт #data % 4 == 1
---   * 'invalid base64 character' — встречен символ вне алфавита
---
--- @param  data string
--- @return string? decoded   Расшифрованные байты, либо nil.
--- @return string? err       Описание ошибки, либо nil.
--- @raise                    Если data не строка.
function base64.decode(data)
    assert(type(data) == 'string', 'string expected')

    -- убираем пробелы и переводы строк
    data = data:gsub('%s', '')

    -- поддерживаем URL-safe алфавит
    data = data:gsub('%-', '+'):gsub('_', '/')

    -- срезаем padding, если он есть
    if data:sub(-2) == '==' then
        data = data:sub(1, -3)
    elseif data:sub(-1) == '=' then
        data = data:sub(1, -2)
    end

    if #data % 4 == 1 then
        return nil, 'invalid base64 length'
    end

    local out, n = {}, 0
    for i = 1, #data, 4 do
        local rem = #data - i + 1
        local c1 = lookup[data:sub(i,     i)]
        local c2 = lookup[data:sub(i + 1, i + 1)]
        local c3 = lookup[data:sub(i + 2, i + 2)]
        local c4 = lookup[data:sub(i + 3, i + 3)]

        if not c1 or not c2
            or (rem >= 3 and not c3)
            or (rem >= 4 and not c4)
        then
            return nil, 'invalid base64 character'
        end

        local b1 = c1 * 4 + math.floor(c2 / 16)
        n = n + 1; out[n] = string.char(b1)

        if c3 then
            local b2 = (c2 % 16) * 16 + math.floor(c3 / 4)
            n = n + 1; out[n] = string.char(b2)
        end
        if c4 then
            local b3 = (c3 % 4) * 64 + c4
            n = n + 1; out[n] = string.char(b3)
        end
    end
    return table.concat(out)
end

--- Алиас `base64.decode` для симметрии с `encode_url`.
--- URL-safe алфавит уже поддерживается в `decode`, так что это просто обёртка.
---
--- @param  data string
--- @return string?
--- @return string?
function base64.decode_url(data)
    return base64.decode(data)
end

return base64



-- # base64.lua

-- Чистый Lua Base64-кодек (RFC 4648), включая URL-safe вариант.

-- ## Установка

-- Скопируйте `base64.lua` в `package.path` и подключите:

-- ```lua
-- local b64 = require('base64')
-- ```

-- ## API

-- ### `b64.encode(data, url_safe?) -> string`

-- Кодирует `data`. При `url_safe = true`:
-- `+` → `-`, `/` → `_`, padding `=` удаляется.

-- ### `b64.encode_url(data) -> string`

-- Шорткат для `encode(data, true)`.

-- ### `b64.decode(data) -> string?, string?`

-- Декодирует как стандартный, так и URL-safe Base64.
-- Возвращает `nil, err` при ошибке (не бросает исключение).

-- Возможные `err`:
-- - `'invalid base64 length'`
-- - `'invalid base64 character'`

-- ### `b64.decode_url(data) -> string?, string?`

-- Алиас `decode`.

-- ## Примеры

-- ```lua
-- local b64 = require('base64')

-- b64.encode('hello')       --> 'aGVsbG8='
-- b64.encode_url('hello')   --> 'aGVsbG8'

-- b64.decode('aGVsbG8=')    --> 'hello'
-- b64.decode('aGVsbG8')     --> 'hello'   (padding опционален)

-- b64.decode('aGVsbG8_')    --> 'hello\xff' (URL-safe алфавит)
-- b64.decode('!!!')         --> nil, 'invalid base64 character'
-- ```

-- ## Отличия от C#

-- C#-вариант:
-- ```csharp
-- Convert.ToBase64String(bytes).Replace("+", "-").Replace("/", "_").TrimEnd('=');
-- ```

-- Lua-вариант ведёт себя так же, за исключением того, что `encode(data, true)`
-- удаляет все `=`, а не только хвостовые. Для корректного Base64 это эквивалентно.
 
