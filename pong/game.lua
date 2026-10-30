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
        randFn = nil,     -- источник случайности (0..1); иначе math.random
        lastNow = 0,      -- «часы» последнего кадра; обновляет main.lua перед update/handleRound
    }
    return s
end

--- Сброс мяча в центр; dir = +1 (направо) или -1 (налево).
-- randFn — источник угла подачи (0..1); если передан, запоминается в s.randFn,
-- чтобы handleRound использовал тот же детерминированный поток без math.random.
function M.resetBall(s, dir, randFn)
    local c = s.cfg
    s.ballX = math.floor(c.width / 2)
    s.ballY = math.floor(c.height / 2)
    if randFn then s.randFn = randFn end
    local src = s.randFn or math.random
    local angle = (src() * 2 - 1) * 0.35
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

    -- Мяч: шаг разбивается на подшаги (substepping), чтобы быстрый мяч не
    -- «туннелировал» сквозь ракетку/стенку за один кадр.
    -- ВАЖНО №1 (аудит): число подшагов считаем от ОСТАТОЧНОЙ дистанции до
    -- ближайшей границы по каждой оси, а НЕ от полной скорости. Старая формула
    -- при |vy| >= height-1 давала sy ≈ ±1 — ровно половину периода зеркала;
    -- мяч залипал в цикле «отскок→возврат» и никогда не долетал до ворот.
    -- ВАЖНО №2 (аудит): для оси X берём дистанцию до ЛИНИИ РАКЕТКИ, а не до
    -- линии ворот. Иначе медленный мяч шагал крупными подшагами и проверял
    -- попадание в ракетку только в конце шага — промах мимо края ракетки
    -- превращался в «фантомный сейв»: мяч телепортировался на поверхность
    -- ракетки и отбивался, хотя реально пролетал над/под её краем.
    local lx = c.paddleX_L
    local rx = c.width - lx - 1  -- правая ракетка симметрично, ширина 2

    local yTop, yBot = 1, c.height - c.ballH + 1
    -- Линии пересечения, после которых мяч считается пропущенным (см. гол ниже).
    local xGoalL, xGoalR = -c.ballW, c.width + 1

    -- Максимальный размер подшага: строго меньше ширины зоны detection ракетки
    -- (3 клетки) и меньше шага, при котором возможно двойное прохождение
    -- поля по Y за один подшаг.
    local maxStep = 0.5

    local function axisRemainder(v, pos, linePaddle, lineGoal)
        if v == 0 then return 0 end
        local d = (v > 0) and (lineGoal - pos) or (pos - lineGoal)
        if v > 0 and pos < linePaddle then
            local dp = linePaddle - pos
            if dp > 0 and dp < d then d = dp end
        elseif v < 0 and pos > linePaddle then
            local dp = pos - linePaddle
            if dp > 0 and dp < d then d = dp end
        end
        if d < 0 then d = 0 end
        return d
    end

    local remY
    if s.vy > 0 then
        remY = yBot - s.ballY
    elseif s.vy < 0 then
        remY = s.ballY - yTop
    else
        remY = 0
    end
    if remY < 0 then remY = 0 end
    local remXL = axisRemainder(s.vx, s.ballX, lx + 2, xGoalL)
    local remXR = axisRemainder(s.vx, s.ballX, rx - c.ballW, xGoalR)
    local remX = math.max(remXL, remXR)

    local nsub = math.floor(math.max(remY, remX) / maxStep) + 1
    if nsub < 1 then nsub = 1 end
    if nsub > 256 then nsub = 256 end   -- страховка от взрыва при абсурдных vx/vy
    local sx = s.vx / nsub
    local sy = s.vy / nsub

    for _ = 1, nsub do
        s.ballX = s.ballX + sx
        s.ballY = s.ballY + sy

        -- Отскок от верх/низ. Нормализация «зеркальным» отображением по модулю
        -- периода 2*(H-1): корректно обрабатывает и двойное прохождение поля
        -- за подшаг (сверхбыстрый мяч), чего не делал однократный clamp.
        local period = 2 * (c.height - c.ballH)
        if s.ballY < 1 or s.ballY > c.height - c.ballH + 1 then
            local y = (s.ballY - 1) % period          -- [0, period)
            if y > period / 2 then y = period - y end -- зеркальная половина
            s.ballY = 1 + y
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

    -- Гол: мяч «пропущен», когда ЦЕЛИКОМ за линией ворот.
    -- ВАЖНО (аудит): раньше левый гол проверялся как `ballX + ballW < 1`, но
    -- физика оставляет мяч на линии ракетки lx+2=5 и дальше не двигает его,
    -- если он уже пересекал зону ракетки в прошлом кадре (remX=0). Условие
    -- `ballX < 5` недостижимо — мяч залипал на границе зоны навсегда (вечный
    -- розыгрыш). Правая сторона симметрично: `ballX > rx - 1`.
    if s.ballX < lx then
        s.scoreR = s.scoreR + 1
        s.state = "round"
        s.msg = "Right scores!"
    elseif s.ballX > rx then
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
-- now — «часы» вызывающего (main.lua передаёт os.clock()); если не передан,
-- берётся s.lastNow (его обновляет main.lua каждый кадр), и лишь затем os.clock().
-- ВАЖНО: handleRound НЕ должен сбрасывать roundUntil при внешнем переходе
-- round->play (SPACE из меню-подобных состояний) — иначе старые «зависшие»
-- часы roundUntil будут мгновенно ре-сервисить раунд в вечном цикле.
function M.handleRound(s, now)
    if s.state ~= "round" then return end
    if now == nil then now = s.lastNow or os.clock() end
    if not s.roundUntil then
        s.roundUntil = now + 1.2
    end
    if now >= s.roundUntil then
        s.roundUntil = nil
        local dir = (s.scoreL + s.scoreR) % 2 == 0 and 1 or -1
        -- подача использует тот же детерминированный randFn, что и resetBall выше
        M.resetBall(s, dir)
        s.state = "play"
        s.msg = ""
    end
end

return M
