-- main.lua
-- Точка входа игры Pong.
-- Библиотеки репозитория:
--   color.lua  — ANSI-коды TrueColor (через term.lua) + финальный текст
--   paths.lua  — joinPath для файла рекордов
--   random.lua — initRandom() (seed) + getRandomBytes() (случайная подача)
--   base64.lua — кодирование строки результата в score.dat
-- Запуск:  lua main.lua   (рекомендуется luajit — полноценный неблокирующий ввод)

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
-- Рекорды (score.dat рядом со скриптом, строки закодированы base64.lua)
--------------------------------------------------------------------------------

local SCORE_FILE = paths.joinPath(scriptDir, "score.dat")

local function rand01()
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
-- Отрисовка кадра (весь текст — битмап-шрифтом 5x7 из font.lua)
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
    local scoreStr = string.format("%d : %d", s.scoreL, s.scoreR)
    term.drawText(term.centerX(scoreStr), 3, scoreStr, term.COL.score)

    -- Сообщения
    local midY = math.floor(c.height / 2)
    if s.state == "menu" then
        term.drawText(term.centerX("TERMINAL PONG"), midY - 5, "TERMINAL PONG", term.COL.ball)
        term.drawText(term.centerX("press SPACE to start"), midY + 1, "press SPACE to start", term.COL.hud)
        term.drawText(term.centerX("W/S or Up/Down - paddle"), midY + 3, "W/S or Up/Down - paddle", term.COL.hud)
        term.drawText(term.centerX("q - quit"), midY + 5, "q - quit", term.COL.hud)
    elseif s.state == "pause" then
        term.drawText(term.centerX("PAUSE"), midY, "PAUSE", term.COL.msg)
    elseif s.state == "over" then
        local res = s.scoreL > s.scoreR and "YOU WIN!" or "YOU LOSE"
        term.drawText(term.centerX(res), midY - 2, res,
            s.scoreL > s.scoreR and term.COL.score or term.COL.msg)
        term.drawText(term.centerX("SPACE - again | q - quit"), midY + 2, "SPACE - again | q - quit", term.COL.hud)
    elseif s.msg ~= "" then
        term.drawText(term.centerX(s.msg), c.height - 3, s.msg, term.COL.msg)
    end

    term.present()
end

--------------------------------------------------------------------------------
-- Главный цикл
--------------------------------------------------------------------------------

local FPS = 30

local function sleep(sec)
    local ms = math.floor(sec * 1000)
    if ms <= 0 then return end
    -- Windows+LuaJIT: kernel32 Sleep; иначе busy-wait по os.clock
    if input.winapi and input.winapi.sleep(ms) then return end
    local t0 = os.clock()
    while os.clock() - t0 < sec do end
end

local function run()
    random.initRandom()  -- сидируем ГСЧ через random.lua

    local s = game.newState()
    local keysHeld = {}

    local rawModeOK = input.enableRawMode()
    term.init()

    local running = true
    local frameMs = math.floor(1000 / FPS)

    while running do
        -- Ввод: на Windows через Console API poll ждёт до конца кадра (не крутит CPU);
        -- на POSIX фрейм ограничивается сном после рендера.
        local waitMs = 0
        if rawModeOK and sep == "\\" then waitMs = frameMs end
        local pressed = input.poll(waitMs)

        for _, k in ipairs(pressed) do
            if k == "q" then
                running = false
            elseif k == "space" then
                if s.state == "menu" or s.state == "over" then
                    if s.state == "over" then s = game.newState() end
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

        -- В Console-API режиме удержание = «клавиша приходила в этом кадре или прошлом»
        if rawModeOK and sep == "\\" then
            local fresh = {}
            for _, k in ipairs(pressed) do fresh[k] = true end
            for k in pairs(keysHeld) do
                if not fresh[k] then keysHeld[k] = nil end
            end
            for k in pairs(fresh) do keysHeld[k] = true end
        end

        -- Логика. s.lastNow — «часы» текущего кадра: game.handleRound при
        -- now=nil обязан видеть актуальное время, иначе roundUntil считается
        -- от застывшего lastNow=0 и раунд никогда не завершается.
        s.lastNow = os.clock()
        if s.state == "play" then
            game.update(s, keysHeld)
        elseif s.state == "round" then
            game.handleRound(s, s.lastNow)
        end

        -- Протокол голов: ровно одна запись на вход в раунд (dedup по
        -- флагу goalCounted внутри handleRound/popGoal).
        local g = game.popGoal(s)
        if g then
            if not s.goalLog then s.goalLog = {} end
            table.insert(s.goalLog, g)
        end

        -- В строковом фолбэке (нет raw-режима) сбрасываем удержание после кадра
        if not rawModeOK then keysHeld = {} end

        if s.state == "over" and not s.saved then
            s.saved = true
            saveScore(s.scoreL, s.scoreR, s.scoreL > s.scoreR)
        end

        render(s)

        -- Ограничение FPS на POSIX (на Windows сон уже учтён в poll)
        if sep ~= "\\" then
            sleep(1 / FPS)
        end
    end

    term.shutdown()
    input.disableRawMode()

    print(color.writeln_color("Thanks for playing! Final score: "
        .. s.scoreL .. ":" .. s.scoreR, color.fg.green, color.style.bold))
end

-- Защита терминала от аварийного выхода
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
