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
    s.fx, s.fy = 0, 0   -- дробь позиции при подаче обнуляется
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

--- Дискретизация непрерывной позиции мяча в клетки терминала.
-- Позиция хранится целыми ballX/ballY, дробь накапливается в s.fx/s.fy —
-- иначе при |v| < 1 клетка не менялась бы ни за один кадр («залипание»).
-- Возвращает nx, ny (клетки), fx, fy (остатки дроби).
local function discretize(s, bx, by)
    local nx = math.floor(bx + 0.5)
    local ny = math.floor(by + 0.5)
    local fx = (s.fx or 0) + (bx - nx)
    local fy = (s.fy or 0) + (by - ny)
    -- Перенос накопившейся дроби в целые клетки (страховочные циклы;
    -- за нормальную игру |fx| остаётся < 1).
    while fx >= 1 do fx = fx - 1 nx = nx + 1 end
    while fx <= -1 do fx = fx + 1 nx = nx - 1 end
    while fy >= 1 do fy = fy - 1 ny = ny + 1 end
    while fy <= -1 do fy = fy + 1 ny = ny - 1 end
    return nx, ny, fx, fy
end

--- dirL/dirR: -1 вверх, 0 покой, +1 вниз (для игрока слева, W/S или стрелки).
-- ИИ ходит автоматически к мячу.
function M.update(s, keys)
    local c = s.cfg
    s.frame = s.frame + 1

    if s.state ~= "play" then
        return
    end

    -- Служебные поля непрерывной позиции (см. discretize): создаём, если
    -- состояние собрано вне newState/resetBall (ручные таблицы в тестах).
    if s.fx == nil then s.fx = 0 end
    if s.fy == nil then s.fy = 0 end

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
    -- Физика мяча: фиксированный шаг + событийное разрешение столкновений.
    -- Контракт (закреплён тестами test_logic.lua):
    --   1) За кадр мяч смещается РОВНО на (vx, vy) — никаких «недошагов»
    --      и телепортов; события (стены/лицевые/линии голов) разрешаются
    --      внутри шага в хронологическом порядке по времени достижения,
    --      остаток кадра доматывается по новому вектору;
    --   2) Сейв проверяется по перекрытию по Y В ТОЧКЕ касания лицевой
    --      стороны ракетки — «фантомных» отскоков от пустых участков нет;
    --   3) Промах: мяч залипает ровно на лицевой стороне (без прыжка к
    --      воротам); на следующем кадре шаг 0/1 решает — сейв (ракета
    --      вернулась под мяч) или дискретный гол (ушла);
    --   4) Гол засчитывается ровно один раз за розыгрыш: как только левый
    --      край мяча пересёк линию полного пропуска (шаг 0 — условие
    --      начала кадра, либо событие внутри шага 2);
    --   5) Стена меняет только знак vy (|v| не искажается);
    --   6) Позиция хранится целыми клетками терминала, дробь шага
    --      накапливается в s.fx/s.fy (иначе при |v|<1 мяч стоял бы на месте).
    ------------------------------------------------------------------------

    local EPS = 1e-9
    local yTop, yBot = 1, c.height - c.ballH + 1   -- границы левого края мяча по Y

    -- Позиция ЛЕВОГО КРАЯ мяча:
    local lx = c.paddleX_L                          -- левая ракетка: клетки [lx..lx+1]
    local rx = c.width - lx - 1                     -- правая ракетка: клетки [rx..rx+1]
    local faceL = lx + 2                            -- лицевая сторона левой ракетки
    local faceR = rx - c.ballW                      -- лицевая сторона правой ракетки
    local edgeL, edgeR = faceL, faceR               -- линии касания лицевых сторон
    local goalL, goalR = -c.ballW, c.width  -- линии полного пропуска (гол)

    -- Непрерывная позиция = клетка + накопленная дробь (см. пункт 6).
    local bx = s.ballX + (s.fx or 0)
    local by = s.ballY + (s.fy or 0)
    local vx, vy = s.vx, s.vy

    -- Защита от нулевой горизонтальной скорости (иначе события по X
    -- недостижимы и кадр вырождается): минимальный |vx|.
    if vx == 0 then vx = 0.05 end

    ------------------------------------------------------------------------
    -- ШАГ 0. Дискретные события начала кадра (позиция — непрерывная клетка
    -- + накопленная дробь, см. discretize):
    --   a) Гол: левый край мяча пересёк линию полного пропуска (это могло
    --      произойти на прошлом шаге после промаха или прямого полёта в
    --      ворота) — фиксируем гол и выходим;
    --   b) Залипание на лицевой стороне встречной ракетки (после промаха в
    --      прошлом кадре), мяч всё ещё летит К ней — ракета была подставлена
    --      между кадрами: либо сейв (перекрытие по Y), либо пропуск/гол.
    -- Так исключается и «залипание у ворот» (прошедший линию мяч больше не
    -- блокируется зоной detection), и «телепорт» (гол не находится
    -- внутрикадровым поиском событий раньше времени).
    ------------------------------------------------------------------------
    local stuckL = (vx < 0 and bx <= edgeL + EPS)
    local stuckR = (vx > 0 and bx >= edgeR - EPS)

    if bx <= goalL then
        s.scoreR = s.scoreR + 1
        s.state, s.msg = "round", "Right scores!"
    elseif bx >= goalR then
        s.scoreL = s.scoreL + 1
        s.state, s.msg = "round", "Left scores!"
    end

    if s.state == "play" and (stuckL or stuckR) then
        local padY = stuckL and s.leftY or s.rightY
        if by + c.ballH - 1 >= padY and by <= padY + c.paddleH - 1 then
            -- Сейв из залипания: отскок по формуле удара.
            local rel = clamp(((by + c.ballH / 2) - (padY + c.paddleH / 2)) / (c.paddleH / 2), -1, 1)
            local speed = math.sqrt(vx * vx + vy * vy) * c.ballAccel
            local dirOut = stuckL and 1 or -1
            vx = dirOut * math.abs(math.cos(rel * c.maxBounceAngle)) * speed
            -- Знак vy задаётся точкой попадания (выше центра ракетки — вверх):
            -- rel=-1 соответствует ВЕРХНЕМУ краю (меньший Y) и обязан давать
            -- восходящий отскок (vy<0).
            vy = math.sin(math.abs(rel) * c.maxBounceAngle) * speed * rel
            bx = (dirOut > 0) and faceL or faceR
            by = clamp(by, yTop, yBot)
            local nx, ny, fxn, fyn = discretize(s, bx, by)
            s.fx, s.fy = fxn, fyn
            s.ballX, s.ballY, s.vx, s.vy = nx, ny, vx, vy
            return
        end
        -- Ракета успели уйти — пропуск состоялся (дискретно, без телепорта).
        if stuckL then
            s.scoreR = s.scoreR + 1
            s.state, s.msg = "round", "Right scores!"
        else
            s.scoreL = s.scoreL + 1
            s.state, s.msg = "round", "Left scores!"
        end
    end

    if s.state ~= "play" then
        if s.scoreL >= c.winScore or s.scoreR >= c.winScore then
            s.state = "over"
            -- Управление на экране конца матча — SPACE (реванш) / q (выход), см. main.lua
            if s.scoreL >= c.winScore then
                s.msg = "YOU WIN!  [SPACE] again  [q] quit"
            else
                s.msg = "CPU WINS! [SPACE] again  [q] quit"
            end
        end
        -- Мяч остаётся ровно там, где остановился (у лицевой стороны или за
        -- линией ворот); дробь при переходе в раунд обнуляется — подача всё
        -- равно ставит мяч в центр.
        s.fx, s.fy = nil, nil
        s.ballX, s.ballY = math.floor(bx + 0.5), clamp(math.floor(by + 0.5), yTop, yBot)
        s.vx, s.vy = vx, vy
        return
    end

    ------------------------------------------------------------------------
    -- ШАГ 2. Фиксированный шаг интегрирования: за кадр мяч смещается РОВНО
    -- на (vx, vy) — классический Pong-тайминг, без «недошагов». Все события
    -- (стены, лицевые стороны ракеток, линии голов) разрешаются ВНУТРИ шага
    -- по времени достижения t ∈ [0,1]; после отражения остаток кадра
    -- доматывается по новому вектору (максимум 2 стены за шаг — больше
    -- физически не влезает при |v| < высоты поля). Обработка событий идёт
    -- строго в хронологическом порядке, поэтому:
    --   * мяч никогда не пересекает событие «молча» (нет фантомов и телепортов);
    --   * гол засчитывается ровно в тот кадр, когда левый край мяча реально
    --     пересёк линию полного пропуска (или достиг её из полости ворот);
    --   * сейв проверяется по перекрытию по Y В ТОЧКЕ касания лицевой стороны.
    -- Позиция мяча хранится ЦЕЛЫМИ числами (клетки терминала): дробная
    -- часть накапливается в s.fx/s.fy (см. discretize).
    ------------------------------------------------------------------------
    local remaining = 1                             -- доля кадра (в шагах = 1.0)
    local guard = 0

    while remaining > EPS do
        guard = guard + 1
        if guard > 4 then break end                 -- страховка от вырожденных векторов

        -- Время (в долях оставшегося шага) до ближайшего события по X.
        local dEdge, kindX
        if vx < 0 then
            if bx > edgeL then dEdge = (bx - edgeL) / (-vx); kindX = "edgeL"
            else               dEdge = (bx - goalL) / (-vx); kindX = "goalL"
            end
        else
            if bx < edgeR then dEdge = (edgeR - bx) / vx; kindX = "edgeR"
            else             dEdge = (goalR - bx) / vx; kindX = "goalR"
            end
        end
        if dEdge < 0 then dEdge = 0 end             -- мы уже на линии/за ней

        -- Время до стены по Y (если летим к стене).
        local dWall
        if vy > EPS then
            dWall = (yBot - by) / vy
        elseif vy < -EPS then
            dWall = (by - yTop) / (-vy)
        else
            dWall = nil
        end
        if dWall and dWall < 0 then dWall = 0 end

        local t = remaining
        local ev = nil
        if dWall ~= nil and dWall < t then t, ev = dWall, "wall" end
        if dEdge < t then t, ev = dEdge, kindX end

        -- Продвигаемся к событию (или до конца кадра).
        bx = bx + vx * t
        by = by + vy * t
        remaining = remaining - t

        if ev == "wall" then
            vy = -vy                                -- только знак vy, |v| не трогаем
            -- Страховка от float-дрейфа: держим мяч в границах поля.
            if by < yTop then by = yTop elseif by > yBot then by = yBot end

        elseif ev == "goalL" or ev == "goalR" then
            -- Линия полного пропуска достигнута внутри шага — дискретный гол.
            if ev == "goalL" then
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
            -- Гол: фиксируем позицию как есть (мяч за линией ворот), дробь
            -- сбрасываем — раунд всё равно перезапускает подачу из центра.
            s.fx, s.fy = nil, nil
            s.ballX, s.ballY, s.vx, s.vy = math.floor(bx + 0.5), clamp(math.floor(by + 0.5), yTop, yBot), vx, vy
            return

        elseif ev == "edgeL" or ev == "edgeR" then
            ------------------------------------------------------------------
            -- Касание лицевой стороны встречной ракетки. Перекрытие по Y
            -- проверяется В ТОЧКЕ касания: сейв (отскок с ускорением и
            -- переостатком кадра) либо промах (мяч залипает на лицевой —
            -- ракета успела уйти; гол зафиксируется шагом 0/1 в следующем
            -- кадре, без телепорта к воротам).
            ------------------------------------------------------------------
            local padY = (ev == "edgeL") and s.leftY or s.rightY
            local hit = (by + c.ballH - 1 >= padY) and (by <= padY + c.paddleH - 1)
            if not hit then
                bx = (ev == "edgeL") and faceL or faceR
                break                               -- залипание: вектор не меняем
            end
            local rel = clamp(((by + c.ballH / 2) - (padY + c.paddleH / 2)) / (c.paddleH / 2), -1, 1)
            local speed = math.sqrt(vx * vx + vy * vy) * c.ballAccel
            local dirOut = (ev == "edgeL") and 1 or -1
            vx = dirOut * math.abs(math.cos(rel * c.maxBounceAngle)) * speed
            -- Знак vy задаётся точкой попадания (выше центра ракетки — вверх):
            -- rel<0 (меньший Y, верхний край) обязан давать восходящий отскок.
            vy = math.sin(math.abs(rel) * c.maxBounceAngle) * speed * rel
            bx = (dirOut > 0) and faceL or faceR
            -- Остаток кадра доматывается ниже по новому вектору.
        end
    end

    -- Финишная страховка: мяч обязан остаться в границах поля по Y
    -- (нормализация float-дрейфа на случай вырожденных векторов).
    by = clamp(by, yTop, yBot)

    -- Дискретизация в клетки терминала с переносом дроби (см. discretize).
    local nx, ny, fxn, fyn = discretize(s, bx, by)
    s.fx, s.fy = fxn, fyn
    s.ballX, s.ballY = nx, ny
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
