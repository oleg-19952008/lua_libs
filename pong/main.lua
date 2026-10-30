-- main.lua
-- Точка входа игры Pong.
-- Собирает вместе библиотеки репозитория:
--   color.lua  — ANSI-коды (через term.lua)
--   paths.lua  — работа с путями (загрузка библиотек, проверка файлов)
--   random.lua — инициализация ГСЧ (seed + случайное направление мяча)
--   base64.lua — сохранение рекордов в файл (кодирование строки результата)
-- Запуск:  lua main.lua

local scriptDir = (debug.getinfo(1, "S").source:gsub("^@", "")):match("(.*[/\\])") or "./"
local sep = package.config:sub(1, 1)
local root = scriptDir .. ".." .. sep

local function load_lib(name)
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then return mod end
    local path = root .. name .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then error("Не удалось загрузить " .. name .. ": " .. tostring(err)) end
    return chunk()
end

local color  = load_lib("color")
local paths  = load_lib("paths")
local random = load_lib("random")
local base64 = load_lib("base64")

local term  = dofile(scriptDir .. "term.lua")
local game  = dofile(scriptDir .. "game.lua")
local input = dofile(scriptDir .. "input.lua")

--------------------------------------------------------------------------------
-- Рекорды (сохраняются в score.dat рядом со скриптом, код base64.lua)
--------------------------------------------------------------------------------

local SCORE_FILE = paths.joinPath(scriptDir, "score.dat")

local function rand01()
    -- Случайное число [0,1) на основе random.getRandomBytes
    local b = random.getRandomBytes(3)
    if #b < 3 then return math.random() end
    local n = string.byte(b, 1) * 65536 + string.byte(b, 2) * 256 + string.byte(b, 3)
    return n / 16777216
end

local function saveScore(scoreL, scoreR, won)
    local line = string.format("%s|%d-%d|%s",
        os.date("%Y-%m-%d %H:%M"), scoreL, scoreR, won and "W" or "L")
    local encoded = base64.encode(line)
    local f = io.open(SCORE_FILE, "a")
    if f then
        f:write(encoded, "\n")
        f:close()
    end
end

--------------------------------------------------------------------------------
-- Отрисовка кадра
--------------------------------------------------------------------------------

local function render(s)
    local c = s.cfg
    term.clear(term.COL.field[1], term.COL.field[2], term.COL.field[3])

    -- Рамка поля
    term.fillRect(1, 1, c.width, 1, term.COL.border)
    term.fillRect(1, c.height, c.width, c.height, term.COL.border)
    term.fillRect(1, 1, 1, c.height, term.COL.border)
    term.fillRect(c.width, 1, c.width, c.height, term.COL.border)

    -- Сетка
    term.drawNet(term.COL.net)

    -- Ракетки (ширина 2 символа)
    term.drawPaddle(c.paddleX_L, math.floor(s.leftY), c.paddleH, term.COL.padL)
    term.drawPaddle(c.width - c.paddleX_L - 1, math.floor(s.rightY), c.paddleH, term.COL.padR)

    -- Мяч
    term.drawBall(math.floor(s.ballX), math.floor(s.ballY), term.COL.ball)

    -- Счёт крупно
    local scoreStr = string.format("%d                    %d", s.scoreL, s.scoreR)
    term.drawText(math.floor(c.width / 2) - 10, 2, scoreStr, term.COL.score)

    -- Подсказки / сообщения
    if s.state == "menu" then
        term.drawText(math.floor(c.width / 2) - 14, math.floor(c.height / 2) - 3,
            "T E R M I N A L   P O N G", term.COL.ball)
        term.drawText(math.floor(c.width / 2) - 18, math.floor(c.height / 2),
            "press SPACE to start  |  q - quit", term.COL.hud)
        term.drawText(math.floor(c.width / 2) - 18, math.floor(c.height / 2) + 2,
            "W/S or Up/Down - move paddle", term.COL.hud)
    elseif s.state == "pause" then
        term.drawText(math.floor(c.width / 2) - 3, math.floor(c.height / 2),
            "PAUSE", term.COL.msg)
    elseif s.msg ~= "" then
        term.drawText(math.floor(c.width / 2) - math.floor(#s.msg / 2), c.height - 1,
            s.msg, term.COL.msg)
    end

    term.present()
end

--------------------------------------------------------------------------------
-- Главный цикл
--------------------------------------------------------------------------------

local function sleep(sec)
    -- Переносимый сон: LuaJIT+ffi, иначе busy-wait по os.clock
    local okLJ, ffi = pcall(require, "ffi")
    if okLJ then
        local done = false
        pcall(function()
            ffi.cdef[[ void usleep(unsigned int usec); ]]
            ffi.C.usleep(math.floor(sec * 1000000))
            done = true
        end)
        if done then return end
    end
    local t0 = os.clock()
    while os.clock() - t0 < sec do end
end

local FPS = 30

local function run()
    random.initRandom()  -- сидируем ГСЧ через random.lua

    local s = game.newState()
    local keysHeld = {}  -- состояние "удерживаемых" клавиш

    local rawModeOK = input.enableRawMode()
    term.init()

    local running = true
    local last = os.clock()

    while running do
        -- Ввод
        local pressed = input.poll()
        for _, k in ipairs(pressed) do
            if k == "q" then
                running = false
            elseif k == "space" then
                if s.state == "menu" then
                    s.state = "play"
                    game.resetBall(s, rand01() < 0.5 and 1 or -1, rand01)
                elseif s.state == "over" then
                    s = game.newState()
                    s.state = "play"
                    game.resetBall(s, rand01() < 0.5 and 1 or -1, rand01)
                elseif s.state == "pause" then
                    s.state = "play"
                end
            elseif k == "p" then
                if s.state == "play" then s.state = "pause"
                elseif s.state == "pause" then s.state = "play"
                end
            else
                keysHeld[k] = true
            end
        end
        -- Отпускаем клавиши при каждой новой пачке событий ввода;
        -- для сырых потоков это грубая, но рабочая эвристика.
        if #pressed > 0 then
            for _, k in ipairs(pressed) do
                -- если клавиша не пришла повторно в следующем poll, она "отпущена"
            end
        end
        -- Для режима строки (фолбэк) каждая poll-строка заменяет набор удерживаемых клавиш
        if #pressed > 0 then
            local fresh = {}
            for _, k in ipairs(pressed) do fresh[k] = true end
            keysHeld = fresh
        end

        -- Логика
        if s.state == "play" then
            game.update(s, keysHeld)
        elseif s.state == "round" then
            game.handleRound(s, os.clock())
        end

        -- В режиме строкового фолбэка (нет raw-режима) сбрасываем "удерживаемые"
        -- клавиши после кадра, чтобы движение не стало бесконечным.
        if not rawModeOK then keysHeld = {} end

        if s.state == "over" and not s.saved then
            s.saved = true
            saveScore(s.scoreL, s.scoreR, s.scoreL > s.scoreR)
        end

        -- Рендер с ограничением FPS
        render(s)
        local dt = os.clock() - last
        if dt < 1 / FPS then
            sleep(1 / FPS - dt)
        end
        last = os.clock()
    end

    term.shutdown()
    input.disableRawMode()

    print(color.writeln_color("Thanks for playing! Final score: "
        .. s.scoreL .. ":" .. s.scoreR, color.fg.green, color.style.bold))
end

-- Защита терминала от аварийного выхода
local okOld = pcall(function()
    if type(unpack) == "function" then end -- noop для 5.1
end)

local rawRun = run
run = function()
    local ok, err = pcall(rawRun)
    term.shutdown()
    input.disableRawMode()
    if not ok then
        io.stderr:write("Ошибка: " .. tostring(err) .. "\n")
        os.exit(1)
    end
end

run()
