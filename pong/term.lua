-- term.lua
-- Терминальная графика для игры Pong: двойной буфер RGB + вывод через ANSI TrueColor.
-- Использует color.lua (генерация SGR-кодов) и paths.lua (поиск библиотек).
-- Совместимо с Lua 5.1–5.4 / LuaJIT, Windows и POSIX.

local M = {}

local ESC = string.char(27)

--------------------------------------------------------------------------------
-- Загрузка библиотек репозитория (../color.lua, ../paths.lua, ../random.lua)
--------------------------------------------------------------------------------

local function script_dir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("(.*[/\\])") or "./"
end

local sep = package.config:sub(1, 1)
local root = script_dir() .. ".." .. sep

local function load_lib(name)
    -- Сначала пробуем require (вдруг пути уже настроены)
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then return mod end
    -- Иначе грузим по абсолютному пути через paths.joinPath, если возможно
    local path = root .. name .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then error("Не удалось загрузить " .. name .. ": " .. tostring(err)) end
    return chunk()
end

local color  = load_lib("color")
local paths  = load_lib("paths")
local random = load_lib("random")

M.color  = color
M.paths  = paths
M.random = random

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
-- Двойной буфер
--------------------------------------------------------------------------------

local buf = nil
local textLayer = {}

function M.init()
    buf = {}
    for y = 1, M.HEIGHT do
        local row = {}
        for x = 1, M.WIDTH do
            row[x] = {0, 0, 0}
        end
        buf[y] = row
    end
    io.write(ESC .. "[?1049h")  -- alternate screen
    io.write(ESC .. "[?25l")    -- спрятать курсор
    io.flush()
end

function M.shutdown()
    io.write(ESC .. "[0m")
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
    for y = math.max(1, y1), math.min(M.HEIGHT, y2) do
        local row = buf[y]
        for x = math.max(1, x1), math.min(M.WIDTH, x2) do
            local px = row[x]
            px[1] = c[1]; px[2] = c[2]; px[3] = c[3]
        end
    end
end

--- Рисует ASCII-текст поверх буфера (каждый символ — пиксель цвета c).
-- Для простоты поддерживается только ASCII; кириллица выводится как блоки.
function M.drawText(x, y, text, c)
    for i = 1, #text do
        M.setPixel(x + i - 1, y, c)
        -- сам символ будет нарисован в present() из текстового слоя
        textLayer[y] = textLayer[y] or {}
        textLayer[y][x + i - 1] = text:sub(i, i)
    end
end

function M.resetTextLayer()
    for y = 1, M.HEIGHT do textLayer[y] = nil end
end

--------------------------------------------------------------------------------
-- Вывод кадра
--------------------------------------------------------------------------------

-- Кэш последней строки, чтобы не пересылать неизменённые строки
local lastLines = {}

function M.present()
    M.resetTextLayer()  -- подготавливаем на следующий кадр
    io.write(ESC .. "[H")
    local out = {}
    for y = 1, M.HEIGHT do
        local row = buf[y]
        local tl = textLayer[y] or {}
        local parts = {}
        local lineStr = ""
        for x = 1, M.WIDTH do
            local px = row[x]
            local ch = tl[x]
            if not ch then ch = " " end
            local code = color.bgRGB(px[1], px[2], px[3])
            -- fg оставляем чёрным, чтобы пробелы выглядели фоном
            parts[#parts + 1] = ESC .. "[" .. code .. ";30m" .. ch
            lineStr = lineStr .. code .. "|" .. ch
        end
        parts[#parts + 1] = ESC .. "[0m"
        -- Если строка не изменилась — всё равно печатаем (проще, чем позиционирование)
        table.insert(out, table.concat(parts))
        lastLines[y] = lineStr
    end
    io.write(table.concat(out, "\r\n"))
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
