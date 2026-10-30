-- game.lua
-- Игровая логика Pong: состояние, физика, ИИ, столкновения.
-- Чистая логика без ввода-вывода (легко тестировать).
-- Случайность начального направления мяча — через random.lua (seed-инициализация в main.lua).

local M = {}

--------------------------------------------------------------------------------
-- Конфигурация
--------------------------------------------------------------------------------

M.CONFIG = {
    width       = 64,     -- поле по X (в символах)
    height      = 22,     -- поле по Y
    paddleH     = 5,      -- высота ракетки
    paddleX_L   = 3,      -- X левой ракетки
    ballW       = 2,      -- ширина мяча (в символах)
    ballH       = 1,      -- высота мяча (1 строка; визуально ~квадрат из-за пропорций шрифта)
    playerSpeed = 0.9,    -- скорость игрока (строк за кадр)
    aiSpeed     = 0.55,   -- скорость ИИ
    ballSpeed0  = 0.45,   -- начальная скорость мяча
    ballAccel   = 1.06,   -- ускорение после каждого удара о ракетку
    maxBounceAngle = 0.75,-- максимальный вертикальный угол после удара (доля от скорости)
    winScore    = 7,      -- счёт до победы
}

--------------------------------------------------------------------------------
-- Создание состояния
--------------------------------------------------------------------------------

function M.newState(cfg)
    local c = cfg or M.CONFIG
    local s = {
        cfg = c,
        leftY  = math.floor(c.height / 2 - c.paddleH / 2),
        rightY = math.floor(c.height / 2 - c.paddleH / 2),
        ballX  = math.floor(c.width / 2),
        ballY  = math.floor(c.height / 2),
        vx = 0, vy = 0,
        scoreL = 0,
        scoreR = 0,
        state = "menu",   -- menu | play | pause | round | over
        msg = "",
        frame = 0,
    }
    return s
end

--- Сброс мяча в центр; dir = +1 (направо) или -1 (налево); speedMul для вариативности.
function M.resetBall(s, dir, randFn)
    local c = s.cfg
    s.ballX = math.floor(c.width / 2)
    s.ballY = math.floor(c.height / 2)
    local angle = ((randFn and randFn() or math.random()) * 2 - 1) * 0.35
    s.vx = dir * c.ballSpeed0
    s.vy = angle * c.ballSpeed0
end

--------------------------------------------------------------------------------
-- Обновление
--------------------------------------------------------------------------------

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- dirL/dirR: -1 вверх, 0 покой, +1 вниз (для игрока слева, W/S или стрелки).
-- ИИ ходит автоматически к мячу.
function M.update(s, keys)
    local c = s.cfg
    s.frame = s.frame + 1

    if s.state ~= "play" then
        return
    end

    -- Игрок: W/S или стрелки вверх/вниз
    local dy = 0
    if keys.w or keys.up   then dy = dy - c.playerSpeed end
    if keys.s or keys.down then dy = dy + c.playerSpeed end
    s.leftY = clamp(s.leftY + dy, 1, c.height - c.paddleH)

    -- ИИ: следует за мячом с ограничением скорости и мёртвой зоной
    local padCenter = s.rightY + c.paddleH / 2
    local target = s.ballY + c.ballH / 2
    local diff = target - padCenter
    if math.abs(diff) > 0.8 then
        local step = clamp(diff, -c.aiSpeed, c.aiSpeed)
        s.rightY = clamp(s.rightY + step, 1, c.height - c.paddleH)
    end

    -- Мяч: шаг разбивается на подобластные подшаги (substepping), чтобы быстрый
    -- мяч не «туннелировал» сквозь ракетку/стенку за один кадр.
    local lx = c.paddleX_L
    local rx = c.width - lx - 1  -- правая ракетка симметрично, ширина 2

    local distY = math.abs(s.vy) + c.ballH
    local maxStep = 1.0
    local nsub = math.floor(math.max(math.abs(s.vx) + c.ballW, distY) / maxStep) + 1
    if nsub < 1 then nsub = 1 end
    local sx = s.vx / nsub
    local sy = s.vy / nsub

    for _ = 1, nsub do
        s.ballX = s.ballX + sx
        s.ballY = s.ballY + sy

        -- Отскок от верх/низ (симметричная обработка туннеля: если за подшаг
        -- мяч пролетел поле по высоте больше чем на 2*maxStep — считаем двойное
        -- отражение и продолжаем движение вниз; иначе — одинарное).
        if s.ballY < 1 then
            s.ballY = 1
            s.vy = -s.vy; sy = -sy
        elseif s.ballY + c.ballH - 1 > c.height then
            s.ballY = c.height - c.ballH + 1
            s.vy = -s.vy; sy = -sy
        end

        -- Столкновение с левой ракеткой (проверка только при движении влево)
        if sx < 0 and s.ballX <= lx + 2 and s.ballX >= lx - 1 then
            if s.ballY + c.ballH - 1 >= s.leftY and s.ballY <= s.leftY + c.paddleH - 1 then
                s.ballX = lx + 2
                local rel = ((s.ballY + c.ballH / 2) - (s.leftY + c.paddleH / 2)) / (c.paddleH / 2)
                rel = clamp(rel, -1, 1)
                local speed = math.sqrt(s.vx * s.vx + s.vy * s.vy) * c.ballAccel
                s.vx = math.abs(math.cos(rel * c.maxBounceAngle)) * speed
                s.vy = math.sin(rel * c.maxBounceAngle) * speed
                break -- отбито: остаток кадра не продвигаем прямым линейным шагом
            end
        end

        -- Столкновение с правой ракеткой
        if sx > 0 and s.ballX + c.ballW >= rx and s.ballX <= rx + 1 then
            if s.ballY + c.ballH - 1 >= s.rightY and s.ballY <= s.rightY + c.paddleH - 1 then
                s.ballX = rx - c.ballW
                local rel = ((s.ballY + c.ballH / 2) - (s.rightY + c.paddleH / 2)) / (c.paddleH / 2)
                rel = clamp(rel, -1, 1)
                local speed = math.sqrt(s.vx * s.vx + s.vy * s.vy) * c.ballAccel
                s.vx = -math.abs(math.cos(rel * c.maxBounceAngle)) * speed
                s.vy = math.sin(rel * c.maxBounceAngle) * speed
                break
            end
        end
    end

    -- Гол
    if s.ballX + c.ballW < 1 then
        s.scoreR = s.scoreR + 1
        s.state = "round"
        s.msg = "Right scores!"
    elseif s.ballX > c.width then
        s.scoreL = s.scoreL + 1
        s.state = "round"
        s.msg = "Left scores!"
    end

    if s.scoreL >= c.winScore or s.scoreR >= c.winScore then
        s.state = "over"
        -- Управление на экране конца матча — SPACE (реванш) / q (выход), см. main.lua
        if s.scoreL >= c.winScore then
            s.msg = "YOU WIN!  [SPACE] again  [q] quit"
        else
            s.msg = "CPU WINS! [SPACE] again  [q] quit"
        end
    end
end

--- Обработка событий раунда/паузы вне физики.
-- now — os.time()/os.clock() для таймера между розыгрышами; если не передан,
-- берётся os.clock() (иначе вызов падал с «arithmetic on a nil value»).
function M.handleRound(s, now)
    if s.state ~= "round" then return end
    if now == nil then now = os.clock() end
    if not s.roundUntil then
        s.roundUntil = now + 1.2
    end
    if now >= s.roundUntil then
        s.roundUntil = nil
        local dir = (s.scoreL + s.scoreR) % 2 == 0 and 1 or -1
        M.resetBall(s, dir)
        s.state = "play"
        s.msg = ""
    end
end

return M
