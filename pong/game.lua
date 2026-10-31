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
        goalLog = {},     -- протокол голов: ровно одна запись на раунд (см. popGoal)
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
    -- Физика мяча: СОБЫТИЙНАЯ МОДЕЛЬ, ОДНО СОБЫТИЕ ЗА КАДР.
    -- За один update() мяч продвигается НЕ ДАЛЬШЕ одного ближайшего
    -- значимого события (отскок от стенки / касание лицевой стороны
    -- ракетки / линия гола). Стенковый отскок завершает кадр — иначе
    -- «домотка» того же кадра порождала телепорт сквозь ракетку и голы
    -- «не в те ворота».
    -- Линии ворот (X — позиция ЛЕВОГО КРАЯ мяча, поле [1 .. width]):
    --   лицевые стороны ракеток: edgeL = paddleX_L + 2,
    --                             edgeR = width - paddleX_L - 1 - ballW;
    --   линии полного пропуска (гол): goalL = -ballW, goalR = width + 1 —
    --   мяч целиком за краем поля. Инвариант edgeL > goalL и edgeR < goalR:
    --   ракета всегда ПЕРЕД линией ворот, поэтому прямой «телепорт» в гол с
    --   поля невозможен — сначала мяч обязан пройти лицевую сторону
    --   (сейв или промах), и только из полости за ракеткой достижима
    --   линия гола.
    -- Исправленные баги предыдущих версий:
    --   1) «Фантомные» отскоки/сейвы: перекрытие по Y проверяется в ТОЧКЕ
    --      касания лицевой стороны ракетки (по времени достижения), а не
    --      после перемещения по всему шагу;
    --   2) Искажение |v| на отскоках: стенка меняет только знак vy; удар о
    --      ракетку задаёт канонические компоненты
    --      vx = cos(rel*A)*speed, vy = sin(rel*A)*speed, где
    --      speed = |v|*ballAccel — модуль вектора после удара строго равен
    --      speed (старый вариант домножал vy на rel и терял нормировку);
    --   3) Недостижимые правые ворота (goalR = width при физике,
    --      останавливающей мяч на edgeR = width-1-ballW): теперь
    --      goalR = width + 1, симметрично goalL = -ballW;
    --   4) «Телепорт сквозь ракетку»: раньше при стенковом отскоке,
    --      случившемся раньше события по X, тот же кадр доматывал мяч до
    --      лицевой стороны ИЛИ линии ворот (забивал «не в те ворота»).
    --      Теперь за кадр исполняется ровно одно событие;
    --   5) Приоритет гола над сейвом: как только левый край мяча пересёк
    --      линию полного пропуска, розыгрыш завершается немедленно —
    --      возврат встречной ракетки между кадрами запоздал (шаг 0 стоит
    --      перед шагом 1);
    --   6) Залипание пропущенного мяча: мяч, оставленный на edge-линии,
    --      доматывается до линии гола в тот же кадр промаха — vx не меняет
    --      знака, розыгрыш гарантированно завершается.
    ------------------------------------------------------------------------

    local EPS = 1e-9
    local yTop, yBot = 1, c.height - c.ballH + 1   -- границы левого края мяча по Y
    local period = 2 * (c.height - c.ballH)         -- период зеркального отражения

    -- Точное значение Y после продвижения dy с отражением от стенок.
    -- Для малых перелётов даёт y+dy без ветвлений; для больших — корректную
    -- развёртку (folding) по периоду 2*(yBot-yTop). Страховка от float-
    -- погрешности событийных матов: результат всегда в [yTop..yBot].
    local function advanceY(y, dy)
        if dy >= 0 then
            if y + dy <= yBot then return y + dy end
        else
            if y + dy >= yTop then return y + dy end
        end
        local m = (y - yTop + dy) % period
        if m < 0 then m = m + period end
        if m > period / 2 then m = period - m end
        return yTop + m
    end

    -- Позиция ЛЕВОГО КРАЯ мяча:
    local lx = c.paddleX_L                          -- левая ракетка: клетки [lx..lx+1]
    local rx = c.width - lx - 1                     -- правая ракетка: клетки [rx..rx+1]
    local faceL = lx + 2                            -- лицевая сторона левой ракетки
    local faceR = rx - c.ballW                      -- лицевая сторона правой ракетки
    local edgeL, edgeR = faceL, faceR               -- линии касания лицевых сторон
    local goalL, goalR = -c.ballW, c.width + 1      -- линии полного пропуска (гол)

    local bx, by = s.ballX, s.ballY
    local vx, vy = s.vx, s.vy

    -- Защита от нулевой горизонтальной скорости (иначе события по X
    -- недостижимы и кадр вырождается): минимальный |vx|.
    if vx == 0 then vx = 0.05 end

    --- Пересчёт угла/скорости при сейве о ракетку (общий код шагов 1 и 2).
    -- rel = точка попадания (-1 верхний край .. +1 нижний); знак vy — по
    -- точке попадания: выше центра ракетки (rel<0, меньший Y) мяч уходит
    -- вверх (vy<0). Модуль вектора после удара строго равен speed.
    local function bounceOff(padY)
        local rel = clamp(((by + c.ballH / 2) - (padY + c.paddleH / 2)) / (c.paddleH / 2), -1, 1)
        local speed = math.sqrt(vx * vx + vy * vy) * c.ballAccel
        local dirOut = (vx < 0) and 1 or -1
        vx = dirOut * math.abs(math.cos(rel * c.maxBounceAngle)) * speed
        vy = math.sin(rel * c.maxBounceAngle) * speed
        bx = (dirOut > 0) and faceL or faceR
    end

    --- Завершение розыгрыша голом. Направление по знаку vx: мяч летел влево
    -- (vx<0) -> отличилась правая сторона (scoreR), и наоборот.
    local function finishRound()
        if vx < 0 then
            s.scoreR = s.scoreR + 1
            s.state, s.msg = "round", "Right scores!"
        else
            s.scoreL = s.scoreL + 1
            s.state, s.msg = "round", "Left scores!"
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
        s.ballX, s.ballY, s.vx, s.vy = bx, by, vx, vy
    end

    ------------------------------------------------------------------------
    -- ШАГ 0. Гол засчитывается ДИСКРЕТНО и с ПРИОРИТЕТОМ над сейвом: если
    -- левый край мяча уже пересёк линию полного пропуска (это случилось на
    -- прошлом шаге — промах доматывает мяч до goalL/goalR сразу), розыгрыш
    -- завершён; возврат ракетки между кадрами запоздал.
    ------------------------------------------------------------------------
    if bx <= goalL or bx >= goalR then
        finishRound()
        return
    end

    ------------------------------------------------------------------------
    -- ШАГ 1. Мяч стоит на лицевой стороне встречной ракетки (промах был
    -- ранее, но goal ещё не достигнут — возможно, при ballW==0?) и всё ещё
    -- летит К ней — значит ракета была подставлена между кадрами: сейв
    -- (перекрытие по Y) либо немедленный пропуск с доматыванием до ворот.
    ------------------------------------------------------------------------
    if (vx < 0 and bx <= edgeL + EPS) or (vx > 0 and bx >= edgeR - EPS) then
        local padY = (vx < 0) and s.leftY or s.rightY
        if by + c.ballH - 1 >= padY and by <= padY + c.paddleH - 1 then
            bounceOff(padY)
        else
            -- Ракета успела уйти — пропуск состоялся: доматываем мяч до
            -- линии полного пропуска (vx не менялся). Гол будет зафиксирован
            -- шагом 0 в следующем кадре — залипания нет, т.к. цель точная.
            bx = (vx < 0) and goalL or goalR
        end
        s.ballX, s.ballY, s.vx, s.vy = bx, by, vx, vy
        return
    end

    ------------------------------------------------------------------------
    -- ШАГ 2. Полёт до БЛИЖАЙШЕГО события кадра (ровно одно событие):
    --   * «wall» — отскок от верхней/нижней стенки: vy меняет знак, кадр
    --     завершается (никакой домотки — защита от телепорта);
    --   * «edge» — касание лицевой стороны ракетки: сейв (перекрытие по Y
    --     в точке касания) или промах — мяч остаётся ровно на лицевой
    --     стороне и в СЛЕДУЮЩЕМ кадре шаг 1 решит: сейв (ракета вернулась)
    --     или гол (ушла);
    --   * «goal» — пересечение линии полного пропуска. Возможно ТОЛЬКО
    --     когда мяч уже в полости ворот (за лицевой стороной ракетки):
    --     инвариант edge < goal гарантирует, что с поля событие «edge»
    --     всегда ближе — прямого телепорта в гол нет.
    ------------------------------------------------------------------------
    local dEdge
    if vx < 0 then
        if bx > edgeL then dEdge = (bx - edgeL) / (-vx) end
    else
        if bx < edgeR then dEdge = (edgeR - bx) / vx end
    end

    local dGoal
    if dEdge == nil then               -- мяч уже в полости ворот — цель «гол»
        if vx < 0 then
            dGoal = (bx - goalL) / (-vx)
        else
            dGoal = (goalR - bx) / vx
        end
    end

    local dWall
    if vy > EPS then
        dWall = (yBot - by) / vy
    elseif vy < -EPS then
        dWall = (by - yTop) / (-vy)
    else
        dWall = nil
    end

    local dX = dEdge
    if dX == nil then dX = dGoal end
    local xKind = (dEdge ~= nil) and "edge" or "goal"

    if dX == nil then
        -- Ни одного события по X (теоретически недостижимо: |vx| >= 0.05).
        -- Продвигаем Y и завершаем кадр.
        by = advanceY(by, vy)
        s.ballX, s.ballY = bx, by
        s.vx, s.vy = vx, vy
        return
    end

    if dWall ~= nil and dWall < dX then
        -- Событие кадра — стенка. Одно событие за кадр: отражаем vy,
        -- ставим мяч точно на границу и завершаем update().
        bx = bx + vx * dWall
        by = (dWall * vy > 0) and yBot or yTop
        vy = -vy
    else
        -- Событие кадра — граница по X.
        bx = bx + vx * dX
        by = advanceY(by, vy * dX)

        if xKind == "goal" then
            finishRound()
            return
        end

        -- «edge»: касание лицевой стороны встречной ракетки. Перекрытие по
        -- Y проверяется В ТОЧКЕ касания (никаких фантомных отскоков от
        -- пустых участков).
        local padY = (vx < 0) and s.leftY or s.rightY
        if by + c.ballH - 1 >= padY and by <= padY + c.paddleH - 1 then
            bounceOff(padY)
        else
            -- Промах: доматываем мяч до линии гола за то же время (vx не
            -- менялся) — розыгрыш завершится шагом 0 следующим кадром.
            bx = (vx < 0) and goalL or goalR
        end
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
    if not s.roundStarted then
        -- Первый вход в состояние «round»: фиксируем факт старта паузы и
        -- момент её окончания. Флаг нужен и для дедупликации протокола
        -- (см. goalCounted ниже): один гол = ровно одна запись.
        s.roundStarted = true
        s.goalCounted  = true   -- в это состояние мяч попал ровно одним голом
    end
    if not s.roundUntil then
        s.roundUntil = now + 1.2
    end
    if now >= s.roundUntil then
        s.roundUntil   = nil
        s.roundStarted = nil
        s.goalCounted  = nil
        local dir = (s.scoreL + s.scoreR) % 2 == 0 and 1 or -1
        -- подача использует тот же детерминированный randFn, что и resetBall выше
        M.resetBall(s, dir)
        s.state = "play"
        s.msg = ""
    end
end

--- Сколько голов зафиксировано с момента последнего вызова (0 или 1).
-- Контракт: цикл main.lua / тестов ДОЛЖЕН вызывать эту функцию каждый кадр
-- пребывания в состоянии "round" — она возвращает 1 ровно один раз на вход
-- в раунд (dedup по флагу s.goalCounted, который ставит handleRound).
-- Так исключается многократный учёт одного гола, когда состояние «round»
-- сохраняется несколько кадров подряд.
function M.popGoal(s)
    if s.state == "round" and s.goalCounted then
        s.goalCounted = false
        return { scoreL = s.scoreL, scoreR = s.scoreR, msg = s.msg }
    end
    return nil
end

return M
