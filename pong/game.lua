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

    ------------------------------------------------------------------------
    -- Физика мяча: континуальная модель (аудит, переписано с нуля).
    -- Предыдущие версии ломались трёх видов, все исправлены здесь:
    --   1) «Фантомные» отскоки/сейвы: дискретные substep'ы проверяли
    --      столкновение ПОСЛЕ перемещения по всей длине шага, поэтому мяч,
    --      пролетевший в кадре над/под краем ракетки, телепортировался на её
    --      поверхность и отбивался. Теперь перекрытие по Y проверяется в
    --      ТОЧКЕ касания лицевой стороны ракетки (в момент времени tHit);
    --   2) Ранние/залипшие голы: зоны detection и ворот пересекались. Гол
    --      теперь — событие траектории: достигается только если мяч реально
    --      долетел до линии полного пропуска за остаток кадра;
    --   3) Искажение |v| при стенке внутри подшага: каждый сегмент — точный
    --      отрезок прямой, vy меняет только знак.
    -- События (стенка, лицевая сторона ракетки, линия ворот) находятся
    -- аналитически по времени достижения; цикл событий в пределах кадра.
    ------------------------------------------------------------------------

    local EPS = 1e-9
    local yTop, yBot = 1, c.height - c.ballH + 1   -- границы левого края мяча по Y
    local period = 2 * (c.height - c.ballH)         -- период зеркального отражения

    -- События по X (позиция ЛЕВОГО КРАЯ мяча):
    local lx = c.paddleX_L                          -- левая ракетка: клетки [lx..lx+1]
    local rx = c.width - lx - 1                     -- правая ракетка: клетки [rx..rx+1]
    local faceL = lx + 2                            -- сейв слева: позиция мяча после отскока
    local faceR = rx - c.ballW                      -- сейв справа
    local edgeL, edgeR = faceL, faceR               -- линии касания лицевых сторон
    local goalL, goalR = -c.ballW, c.width + 1 - c.ballW  -- полный пропуск (гол)

    local bx, by = s.ballX, s.ballY
    local vx, vy = s.vx, s.vy

    -- Защита от нулевой горизонтальной скорости (иначе события по X
    -- недостижимы и кадр вырождается): минимальный |vx|.
    if vx == 0 then vx = 0.05 end

    -- Максимум событий ограничен длиной хода кадра |v| (каждое событие
    -- съедает > 0 пути, кроме стенка-у-стенки, которые чередуются не чаще
    -- чем через проход поля). 64 — с огромным запасом для любых скоростей.
    for _seg = 1, 64 do
        -- Время (по параметру d — путь вдоль (vx,vy), d>=0) до событий:
        local dWall
        if vy > EPS then
            dWall = (yBot - by) / vy
        elseif vy < -EPS then
            dWall = (by - yTop) / (-vy)
        else
            dWall = nil
        end
        local dHit, dGoal
        if vx < 0 then
            if bx > edgeL + EPS then dHit = (bx - edgeL) / (-vx) else dHit = nil end
            dGoal = (bx - goalL) / (-vx)
        else
            if bx < edgeR - EPS then dHit = (edgeR - bx) / vx else dHit = nil end
            dGoal = (goalR - bx) / vx
        end

        local dMin, kind = dGoal, "goal"
        if dHit ~= nil and dHit < dMin then dMin, kind = dHit, "paddle" end
        if dWall ~= nil and dWall >= -EPS and dWall < dMin then dMin, kind = dWall, "wall" end

        if dMin <= 0 then
            -- Стоим точно на границе события (после сейва/отражения) —
            -- разрешаем его без продвижения, иначе движение невозможно.
            dMin = 0
        end

        bx = bx + vx * dMin
        by = by + vy * dMin

        if kind == "wall" then
            vy = -vy
        elseif kind == "paddle" then
            local padY = (vx < 0) and s.leftY or s.rightY
            if by + c.ballH - 1 >= padY and by <= padY + c.paddleH - 1 then
                -- Сейв: угол по точке попадания + ускорение
                local rel = clamp(((by + c.ballH / 2) - (padY + c.paddleH / 2)) / (c.paddleH / 2), -1, 1)
                local speed = math.sqrt(vx * vx + vy * vy) * c.ballAccel
                local dirOut = (vx < 0) and 1 or -1
                vx = dirOut * math.abs(math.cos(rel * c.maxBounceAngle)) * speed
                vy = math.sin(rel * c.maxBounceAngle) * speed
                bx = (dirOut > 0) and faceL or faceR
            else
                -- Промах: мяч прошёл лицевую сторону мимо края ракетки.
                -- Сдвигаемся за линию касания — событие больше не повторится.
                bx = bx + ((vx < 0) and -EPS or EPS)
            end
        else -- goal: мяч реально долетел до линии полного пропуска
            if vx < 0 then
                s.scoreR = s.scoreR + 1
                s.state = "round"
                s.msg = "Right scores!"
            else
                s.scoreL = s.scoreL + 1
                s.state = "round"
                s.msg = "Left scores!"
            end
            break
        end
    end

    -- Финишная нормализация Y (страховка от накопления float-погрешности):
    -- зеркальное отображение по периоду 2*(H-ballH).
    if by < yTop or by > yBot then
        local y = (by - 1) % period
        if y > period / 2 then y = period - y end
        by = 1 + y
    end

    s.ballX, s.ballY = bx, by
    s.vx, s.vy = vx, vy

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
