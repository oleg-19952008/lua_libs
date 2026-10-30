-- term.lua
-- Терминальная графика для игры Pong: RGB-буфер + вывод ANSI TrueColor.
-- Использует color.lua (генерация SGR-кодов) и font.lua (битмап-шрифт 5x7).
-- Рендер оптимизирован: пиксели одной строки с одинаковым цветом сливаются
-- в один escape-запуск, неизменённые строки перемещаются курсором без вывода.
-- Совместимо с Lua 5.1+ / LuaJIT, Windows и POSIX.

local M = {}

local ESC = string.char(27)

--------------------------------------------------------------------------------
-- Загрузка библиотек репозитория (../color.lua) и соседних модулей
--------------------------------------------------------------------------------

local function script_dir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("(.*[/\\])") or "./"
end

local sep = package.config:sub(1, 1)
local root = script_dir() .. ".." .. sep

local function load_lib(name)
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then return mod end
    local chunk, err = loadfile(root .. name .. ".lua")
    if not chunk then error("Не удалось загрузить " .. name .. ": " .. tostring(err)) end
    return chunk()
end

local function load_local(name)
    local chunk, err = loadfile(script_dir() .. name .. ".lua")
    if not chunk then error("Не удалось загрузить " .. name .. ": " .. tostring(err)) end
    return chunk()
end

local color = load_lib("color")
local font  = load_local("font")

M.color = color
M.font  = font

--------------------------------------------------------------------------------
-- Размер поля
--------------------------------------------------------------------------------

M.WIDTH  = 64
M.HEIGHT = 22

--------------------------------------------------------------------------------
-- Палитра (RGB)
--------------------------------------------------------------------------------

M.COL = {
    field   = {12, 12, 24},
    border  = {40, 40, 70},
    net     = {70, 70, 110},
    padL    = {0, 200, 255},
    padR    = {255, 120, 0},
    ball    = {255, 255, 255},
    hud     = {220, 220, 220},
    score   = {255, 230, 0},
    msg     = {255, 80, 80},
}

--------------------------------------------------------------------------------
-- Буфер кадров
--------------------------------------------------------------------------------

local buf = nil          -- buf[y][x] = "idx" в палитре строк (см. ниже)
local lastBuf = nil      -- предыдущий отправленный кадр для diff-рендера

-- Кэш SGR-строк вида "\27[48;2;r;g;b;38;2;255;255;255m" по ключу r*65536+g*256+b
local sgrCache = {}

local function sgrFor(r, g, b)
    local key = r * 65536 + g * 256 + b
    local s = sgrCache[key]
    if not s then
        s = ESC .. "[" .. color.bgRGB(r, g, b) .. ";" .. color.fgRGB(255, 255, 255) .. "m"
        sgrCache[key] = s
    end
    return s
end

function M.init()
    buf = {}
    lastBuf = {}
    for y = 1, M.HEIGHT do
        local row, lrow = {}, {}
        for x = 1, M.WIDTH do
            row[x] = {0, 0, 0}
            lrow[x] = nil
        end
        buf[y] = row
        lastBuf[y] = lrow
    end
    io.write(ESC .. "[?1049h")  -- alternate screen
    io.write(ESC .. "[?25l")    -- спрятать курсор
    io.flush()
end

function M.shutdown()
    io.write(ESC .. "[0m\r\n")
    io.write(ESC .. "[?25h")
    io.write(ESC .. "[?1049l")
    io.flush()
end

function M.clear(r, g, b)
    for y = 1, M.HEIGHT do
        local row = buf[y]
        for x = 1, M.WIDTH do
            local px = row[x]
            px[1] = r; px[2] = g; px[3] = b
        end
    end
end

function M.setPixel(x, y, c)
    x = math.floor(x); y = math.floor(y)
    if x < 1 or x > M.WIDTH or y < 1 or y > M.HEIGHT then return end
    local px = buf[y][x]
    px[1] = c[1]; px[2] = c[2]; px[3] = c[3]
end

function M.fillRect(x1, y1, x2, y2, c)
    x1 = math.max(1, math.floor(x1)); x2 = math.min(M.WIDTH, math.floor(x2))
    y1 = math.max(1, math.floor(y1)); y2 = math.min(M.HEIGHT, math.floor(y2))
    for y = y1, y2 do
        local row = buf[y]
        for x = x1, x2 do
            local px = row[x]
            px[1] = c[1]; px[2] = c[2]; px[3] = c[3]
        end
    end
end

--- Рисует текст битмап-шрифтом 5x7 поверх буфера (белые «пиксели» букв).
-- text — ASCII; кириллица отображается как пропуск (шрифт латиницы).
function M.drawText(x, y, text, c)
    local function put(px_x, px_y, r, g, b)
        if px_x < 1 or px_x > M.WIDTH or px_y < 1 or px_y > M.HEIGHT then return end
        local px = buf[px_y][px_x]
        px[1] = r; px[2] = g; px[3] = b
    end
    font.draw(put, math.floor(x), math.floor(y), text, c)
end

--- Отцентрировать текст по горизонтали; вернуть стартовую X.
function M.centerX(text)
    return math.floor((M.WIDTH - font.width(text)) / 2)
end

--------------------------------------------------------------------------------
-- Вывод кадра (diff + run-length)
--------------------------------------------------------------------------------

local RESET = ESC .. "[0m"

function M.present()
    if not buf then return end   -- защита от вызова до init(): раньше падало с
                                 -- «attempt to index a nil value (upvalue 'buf')»
    local out = {}
    local n = 0
    local curY = 1 -- логическая позиция курсора (1-based)
    for y = 1, M.HEIGHT do
        local row = buf[y]
        local lrow = lastBuf[y]

        -- Проверка: строка целиком совпадает с прошлым кадром?
        local same = true
        for x = 1, M.WIDTH do
            local px = row[x]
            local lp = lrow[x]
            if not lp or lp[1] ~= px[1] or lp[2] ~= px[2] or lp[3] ~= px[3] then
                same = false; break
            end
        end
        if same then
            if y ~= curY then
                n = n + 1; out[n] = ESC .. "[" .. y .. ";1H"
                curY = y
            end
            n = n + 1; out[n] = "\r\n"
            curY = curY + 1
        else
            if y ~= curY then
                n = n + 1; out[n] = ESC .. "[" .. y .. ";1H"
                curY = y
            end
            local line = {}
            local ln = 0
            local prevKey = nil
            local runLen = 0
            local flushRun
            local function appendRun(key, cnt)
                ln = ln + 1
                line[ln] = sgrFor(math.floor(key / 65536),
                                  math.floor(key / 256) % 256,
                                  key % 256) .. string.rep(" ", cnt)
            end
            for x = 1, M.WIDTH do
                local px = row[x]
                local key = px[1] * 65536 + px[2] * 256 + px[3]
                if key == prevKey then
                    runLen = runLen + 1
                else
                    if prevKey then appendRun(prevKey, runLen) end
                    prevKey = key
                    runLen = 1
                end
                -- обновляем снимок последней строки
                local lp = lrow[x]
                if lp then lp[1] = px[1]; lp[2] = px[2]; lp[3] = px[3]
                else lrow[x] = {px[1], px[2], px[3]} end
            end
            if prevKey then appendRun(prevKey, runLen) end
            ln = ln + 1; line[ln] = RESET
            n = n + 1; out[n] = table.concat(line) .. "\r\n"
            curY = curY + 1
        end
    end
    io.write(table.concat(out))
    io.flush()
end

--------------------------------------------------------------------------------
-- Спейсбар-хелперы для игровых объектов
--------------------------------------------------------------------------------

function M.drawPaddle(x, y, h, c)
    M.fillRect(x, y, x + 1, y + h - 1, c)
end

function M.drawBall(cx, cy, c)
    M.fillRect(cx, cy, cx + 1, cy, c)
end

function M.drawNet(c)
    local cx = math.floor(M.WIDTH / 2)
    for y = 3, M.HEIGHT - 2, 2 do
        M.setPixel(cx, y, c)
    end
end

return M
