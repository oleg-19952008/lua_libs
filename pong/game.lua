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
    -- Физика мяча: событийная модель, ОДНО событие за кадр.
    -- Исправленные баги предыдущих версий:
    --   1) «Фантомные» отскоки/сейвы: столкновение проверялось ПОСЛЕ
    --      перемещения по всему шагу; теперь перекрытие по Y вычисляется в
    --      ТОЧКЕ касания лицевой стороны ракетки (по времени достижения);
    --   2) Ранние голы: раньше «гол» был событием траектории и выбирался
    --      внутри кадра как min(dWall, dHit, dGoal) — при промахе мимо
    --      ракетки следующий сегмент мгновенно доматывал мяч до линии ворот
    --      (мяч телепортировался к гола за один кадр). Теперь гол — это
    --      ДИСКРЕТНОЕ условие начала кадра: засчитывается только когда левый
    --      край мяча реально пересёк линию полного пропуска (шаг 0), либо
    --      когда достигнута линия ворот из полости за ракеткой (шаг 3);
    --   3) Залипание пропущенного мяча: после промаха мяч остаётся на
    --      лицевой стороне; пока ракета не вернулась под мяч, на следующем
    --      кадре фиксируется пропуск (шаг 1) — мёртвой зоны больше нет;
    --   4) Искажение |v| на стенке: vy меняет только знак.
    ------------------------------------------------------------------------

    local EPS = 1e-9
    local yTop, yBot = 1, c.height - c.ballH + 1   -- границы левого края мяча по Y
    local period = 2 * (c.height - c.ballH)         -- период зеркального отражения

    -- Позиция ЛЕВОГО КРАЯ мяча:
    local lx = c.paddleX_L                          -- левая ракетка: клетки [lx..lx+1]
    local rx = c.width - lx - 1                     -- правая ракетка: клетки [rx..rx+1]
    local faceL = lx + 2                            -- лицевая сторона левой ракетки
    local faceR = rx - c.ballW                      -- лицевая сторона правой ракетки
    local edgeL, edgeR = faceL, faceR               -- линии касания лицевых сторон
    local goalL, goalR = -c.ballW, c.width  -- линии полного пропуска (гол)

    local bx, by = s.ballX, s.ballY
    local vx, vy = s.vx, s.vy

    -- Защита от нулевой горизонтальной скорости (иначе события по X
    -- недостижимы и кадр вырождается): минимальный |vx|.
    if vx == 0 then vx = 0.05 end

    ------------------------------------------------------------------------
    -- ШАГ 0. Гол засчитывается ДИСКРЕТНО: если левый край мяча уже пересёк
    -- линию полного пропуска (это могло произойти на прошлом шаге после
    -- промаха или прямого полёта в ворота) — фиксируем гол и выходим.
    -- Так исключается и «залипание» (прошедший лицевую сторону мяч больше
    -- не блокируется зоной detection), и «телепорт» (гол не находится
    -- внутрикадровым поиском событий раньше времени).
    -- ВАЖНО: гол проверяется ДО касания лицевой стороны (шаг 2): при
    -- больших |vx| за один кадр мяч может пересечь и ракетку, и линию
    -- ворот; событие по X берётся ближайшее, поэтому гол имеет приоритет.
    ------------------------------------------------------------------------
    if bx <= goalL then
        s.scoreR = s.scoreR + 1
        s.state, s.msg = "round", "Right scores!"
    elseif bx >= goalR then
        s.scoreL = s.scoreL + 1
        s.state, s.msg = "round", "Left scores!"
    end
    if s.state ~= "play" then
        s.ballX, s.ballY, s.vx, s.vy = bx, by, vx, vy
        if s.scoreL >= c.winScore or s.scoreR >= c.winScore then
            s.state = "over"
            -- Управление на экране конца матча — SPACE (реванш) / q (выход), см. main.lua
            if s.scoreL >= c.winScore then
                s.msg = "YOU WIN!  [SPACE] again  [q] quit"
            else
                s.msg = "CPU WINS! [SPACE] again  [q] quit"
            end
        end
        return
    end

    ------------------------------------------------------------------------
    -- ШАГ 1. Мяч стоит точно на лицевой стороне встречной ракетки (после
    -- промаха в прошлом кадре) и всё ещё летит К ней — значит ракета была
    -- подставлена между кадрами. Либо сейв (перекрытие по Y), либо гол.
    ------------------------------------------------------------------------
    if (vx < 0 and bx <= edgeL + EPS) or (vx > 0 and bx >= edgeR - EPS) then
        local padY = (vx < 0) and s.leftY or s.rightY
        if by + c.ballH - 1 >= padY and by <= padY + c.paddleH - 1 then
            local rel = clamp(((by + c.ballH / 2) - (padY + c.paddleH / 2)) / (c.paddleH / 2), -1, 1)
            local speed = math.sqrt(vx * vx + vy * vy) * c.ballAccel
            local dirOut = (vx < 0) and 1 or -1
            vx = dirOut * math.abs(math.cos(rel * c.maxBounceAngle)) * speed
            -- Знак vy задаётся точкой попадания (выше центра ракетки — вверх),
            -- а не знаком rel: на левой ракетке rel=-1 соответствует ВЕРХНЕМУ
            -- краю (меньший Y) и обязан давать восходящий отскок (vy<0).
            vy = math.sin(math.abs(rel) * c.maxBounceAngle) * speed * rel
            bx = (dirOut > 0) and faceL or faceR
        else
            -- Ракета успели уйти — пропуск состоялся.
            if vx < 0 then
                s.scoreR = s.scoreR + 1
                s.state, s.msg = "round", "Right scores!"
            else
                s.scoreL = s.scoreL + 1
                s.state, s.msg = "round", "Left scores!"
            end
            if s.scoreL >= c.winScore or s.scoreR >= c.winScore then
                s.state = "over"
                if s.scoreL >= c.winScore then
                    s.msg = "YOU WIN!  [SPACE] again  [q] quit"
                else
                    s.msg = "CPU WINS! [SPACE] again  [q] quit"
                end
            end
        end
        s.ballX, s.ballY, s.vx, s.vy = bx, by, vx, vy
        return
    end

    ------------------------------------------------------------------------
    -- ШАГ 2. Полёт до следующего события. Граница движения — лицевая
    -- сторона встречной ракетки (за неё мяч без проверки Y не проходит —
    -- защита от фантомных отскоков) ИЛИ линия гола (для мячей, уже
    -- находящихся в полости ворот — защита от залипания). Событие «стенка»
    -- может произойти раньше. За пределы одного события кадр не выходит:
    -- никакого телепорта к воротам.
    ------------------------------------------------------------------------
    local limit
    if vx < 0 then
        if bx > edgeL then limit = (bx - edgeL) / (-vx) else limit = (bx - goalL) / (-vx) end
    else
        if bx < edgeR then limit = (edgeR - bx) / vx else limit = (goalR - bx) / vx end
    end

    local dWall
    if vy > EPS then
        dWall = (yBot - by) / vy
    elseif vy < -EPS then
        dWall = (by - yTop) / (-vy)
    else
        dWall = nil
    end

    local dMin, kind
    if dWall ~= nil and dWall < limit then
        dMin, kind = dWall, "wall"
    else
        dMin, kind = limit, "edge"
    end

    bx = bx + vx * dMin
    by = by + vy * dMin

    if kind == "wall" then
        vy = -vy
    elseif bx <= goalL or bx >= goalR then
        ------------------------------------------------------------------
        -- Достигнута линия гола (мяч был в полости ворот) — сразу в этом
        -- же кадре: иначе розыгрыш мог бы зависнуть между шагами 0/1.
        ------------------------------------------------------------------
        if vx < 0 then
            s.scoreR = s.scoreR + 1
            s.state, s.msg = "round", "Right scores!"
        else
            s.scoreL = s.scoreL + 1
            s.state, s.msg = "round", "Left scores!"
        end
        if s.scoreL >= c.winScore or s.scoreR >= c.winScore then
            s.state = "over"
            if s.scoreL >= c.winScore then
                s.msg = "YOU WIN!  [SPACE] again  [q] quit"
            else
                s.msg = "CPU WINS! [SPACE] again  [q] quit"
            end
        end
        s.ballX, s.ballY, s.vx, s.vy = bx, by, vx, vy
        return
    else
        ------------------------------------------------------------------
        -- Касание лицевой стороны: перекрытие по Y проверяется В ТОЧКЕ
        -- касания (никаких фантомных отскоков от пустых участков).
        ------------------------------------------------------------------
        local padY = (vx < 0) and s.leftY or s.rightY
        if by + c.ballH - 1 >= padY and by <= padY + c.paddleH - 1 then
            -- Сейв: угол по точке попадания + ускорение
            local rel = clamp(((by + c.ballH / 2) - (padY + c.paddleH / 2)) / (c.paddleH / 2), -1, 1)
            local speed = math.sqrt(vx * vx + vy * vy) * c.ballAccel
            local dirOut = (vx < 0) and 1 or -1
            vx = dirOut * math.abs(math.cos(rel * c.maxBounceAngle)) * speed
            -- Знак vy — по точке попадания (см. шаг 1): выше центра ракетки
            -- (rel<0, меньший Y) -> мяч уходит вверх (vy<0).
            vy = math.sin(math.abs(rel) * c.maxBounceAngle) * speed * rel
            bx = (dirOut > 0) and faceL or faceR
        end
        -- Промах: мяч остаётся ровно на лицевой стороне ракетки; дальше
        -- шаг 1 решит — сейв (ракета вернулась) или гол (ушла).
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
