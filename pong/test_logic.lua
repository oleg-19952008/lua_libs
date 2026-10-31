-- ============================================================
--  test_logic.lua — дотошный тест №1: ЛОГИКА игры Pong.
--  Проверяет контракт game.lua как state machine и скорера:
--    * машина состояний menu->play->round->(play|over) и переходы,
--    * корректность засчёта голов (кто забил, кому, когда),
--    * инварианты счёта (монотонность, +1 за гол, победа ровно на winScore),
--    * подача после раунда: чередование направления по чётности общего счёта,
--      детерминированность через randFn, отсутствие math.random в потоке,
--    * handleRound: пауза 1.2 «секунды» по переданным часам, идемпотентность,
--      отсутствие вечного ре-сервиса при внешнем round->play,
--    * неизменность физики в не-play состояниях, защита от vx==0,
--    * границы ракеток (clamp), поведение ИИ (мёртвая зона, скорость).
--  Тест не зависит от ОС и терминала: только чистая логика + harness-фильтр.
--  Запуск:  lua5.1 test_logic.lua   (код возврата 0 = успех)
-- ============================================================

local H = dofile("test_harness.lua")
local G = H.load("game")

-- В harness нет M.group — фиксируем группу через upvalue, которую читает H.test.
local curGroup = "?"
H.test = (function(name, fn)
    table.insert(H.tests, { id = #H.tests + 1, group = curGroup, name = name, fn = fn })
end)
H.group = function(g) curGroup = g end

--------------------------------------------------------------------------------
-- Вспомогательные функции
--------------------------------------------------------------------------------

--- Детерминированный LCG [0,1): свой поток вместо math.random — чтобы
-- ловить любые утечки глобальной случайности в логику.
local function makeRng(seed)
    local st = seed or 12345
    return function()
        st = (st * 1103515245 + 12345) % 2147483648
        return st / 2147483648
    end
end

local function freshState(cfg)
    local s = G.newState(cfg or G.CONFIG)
    s.randFn = makeRng(777)
    return s
end

local function startPlay(s, dir)
    s.state = "play"
    G.resetBall(s, dir or 1, s.randFn)
end

local noKeys = {}
local function up(k)   return { w = k ~= false } end
local function down(k) return { s = k ~= false } end

--- Инварианты состояния, которые обязаны держаться ВСЕГДА.
local function checkInvariants(s, ctx)
    local c = s.cfg
    ctx = ctx or ""
    assert(s.scoreL >= 0 and s.scoreR >= 0,
        ctx .. ": отрицательный счёт L=" .. s.scoreL .. " R=" .. s.scoreR)
    assert(s.leftY >= 1 and s.leftY <= c.height - c.paddleH,
        ctx .. ": левая ракетка вне поля: leftY=" .. s.leftY)
    assert(s.rightY >= 1 and s.rightY <= c.height - c.paddleH,
        ctx .. ": правая ракетка вне поля: rightY=" .. s.rightY)
    if s.state == "play" then
        assert(s.ballY >= 1 and s.ballY <= c.height - c.ballH + 1,
            ctx .. ": мяч вне поля по Y: ballY=" .. s.ballY)
        assert(s.vx ~= 0, ctx .. ": нулевой vx в состоянии play")
    end
end

--------------------------------------------------------------------------------
-- Группа: newState / resetBall
--------------------------------------------------------------------------------
H.group("state-machine")

H.test("newState: начальные значения соответствуют контракту", function()
    local c = G.CONFIG
    local s = G.newState(c)
    assert(s.state == "menu", "стартовое состояние != menu: " .. tostring(s.state))
    assert(s.scoreL == 0 and s.scoreR == 0, "стартовый счёт ненулевой")
    assert(s.frame == 0, "frame != 0")
    assert(s.vx == 0 and s.vy == 0, "в меню мяч уже летит")
    assert(s.ballX == math.floor(c.width / 2), "мяч не в центре X")
    assert(s.ballY == math.floor(c.height / 2), "мяч не в центре Y")
    local padExpect = math.floor(c.height / 2 - c.paddleH / 2)
    assert(s.leftY == padExpect and s.rightY == padExpect, "ракеты не отцентрованы")
    checkInvariants(s, "newState")
end)

H.test("resetBall: позиция, вектор подачи и знак vx по dir", function()
    for _, dir in ipairs({ 1, -1 }) do
        local s = freshState()
        startPlay(s, dir)
        local c = s.cfg
        assert(s.ballX == math.floor(c.width / 2), "dir=" .. dir .. ": X не центр")
        assert(s.ballY == math.floor(c.height / 2), "dir=" .. dir .. ": Y не центр")
        assert(s.vx == dir * c.ballSpeed0,
            ("dir=%d: vx=%.6f, ожидалось %.6f"):format(dir, s.vx, dir * c.ballSpeed0))
        assert(math.abs(s.vy) <= 0.35 * c.ballSpeed0 + 1e-12,
            "vy вне диапазона угла подачи ±0.35")
        -- подача НЕ должна мгновенно давать гол/раунд
        assert(s.state == "play", "после подачи состояние не play")
    end
end)

H.test("resetBall: randFn запоминается и больше не зовёт math.random", function()
    local s = freshState()
    s.state = "play"
    -- Ядовитый math.random: любой вызов из логики уронит тест.
    local savedRandom = math.random
    local leaked = false
    math.random = function() leaked = true; return 0.5 end
    local okCall = pcall(function() G.resetBall(s, 1, makeRng(42)) end)
    for _ = 1, 50 do
        if s.state == "play" then G.update(s, noKeys) end
        G.handleRound(s, (s.lastNow or 0) + 0.5)
        s.lastNow = (s.lastNow or 0) + 0.5
    end
    math.random = savedRandom
    assert(okCall, "resetBall с randFn упал")
    assert(not leaked, "логика вызвала math.random — утечка глобальной случайности")
    assert(s.randFn ~= nil, "randFn не запомнен в состоянии")
end)

H.test("подача детерминирована при одинаковом randFn-потоке", function()
    local function run()
        local s = freshState()
        startPlay(s, 1)
        local firstVy = s.vy
        -- догоняем до первого события (касание лицевой правой или полёт)
        for _ = 1, 200 do
            if s.state ~= "play" then break end
            G.update(s, noKeys)
        end
        return { vy = firstVy, x = s.ballX, y = s.ballY, st = s.state }
    end
    local a, b = run(), run()
    assert(a.vy == b.vy and a.x == b.x and a.y == b.y and a.st == b.st,
        "два прогона с одним seed разошлись — недетерминированная логика")
end)

--------------------------------------------------------------------------------
-- Группа: update в не-play состояниях
--------------------------------------------------------------------------------
H.group("state-machine-guard")

H.test("menu/pause/round/over: update не двигает мяч и не меняет счёт", function()
    for _, st in ipairs({ "menu", "pause", "round", "over" }) do
        local s = freshState()
        startPlay(s, 1)
        s.state = st
        local snapX, snapY, snapVx, snapVy = s.ballX, s.ballY, s.vx, s.vy
        local sl, sr = s.scoreL, s.scoreR
        for i = 1, 30 do
            G.update(s, (i % 2 == 0) and down() or up())
        end
        assert(s.ballX == snapX and s.ballY == snapY, st .. ": мяч сместился в \"" .. st .. "\"")
        assert(s.vx == snapVx and s.vy == snapVy, st .. ": вектор изменился в \"" .. st .. "\"")
        assert(s.scoreL == sl and s.scoreR == sr, st .. ": счёт изменился в \"" .. st .. "\"")
        assert(s.frame == 30, st .. ": frame должен тикать всегда, получил " .. s.frame)
        checkInvariants(s, st)
    end
end)

H.test("update: игрок упирается в границы поля (clamp), не вылетает", function()
    local s = freshState()
    startPlay(s, 1)
    -- Замечание по реализации: clamp в update применяется к leftY, но ИИ на
    -- том же кадре может увести rightY; для игрока проверяем, что после
    -- долгого движения вверх leftY НЕ РАСТЁТ и зажат в [1, H-paddleH].
    -- Точное значение зависит от float-накопления (0.9*23 != ровно 6.2),
    -- поэтому тестируем контракт границ, а не конкретный float.
    for _ = 1, 300 do G.update(s, up()) end
    assert(s.leftY >= 1, "верхний clamp нарушен: leftY=" .. s.leftY)
    local yTop = s.leftY
    for _ = 1, 50 do G.update(s, up()) end
    assert(s.leftY == yTop, "зажатая у верха ракетка всё ещё двигается")
    for _ = 1, 600 do G.update(s, down()) end
    assert(s.leftY <= s.cfg.height - s.cfg.paddleH,
        "нижний clamp нарушен: leftY=" .. s.leftY)
    local yBot = s.leftY
    for _ = 1, 50 do G.update(s, down()) end
    assert(s.leftY == yBot, "зажатая у низа ракетка всё ещё двигается")
    checkInvariants(s, "clamp")
end)

H.test("update: стрелки up/down работают так же, как W/S", function()
    local a, b = freshState(), freshState()
    startPlay(a, 1); startPlay(b, 1)
    for _ = 1, 10 do
        G.update(a, up())
        G.update(b, { up = true })
    end
    assert(a.leftY == b.leftY, "W/S и стрелки дают разный результат")
    for _ = 1, 10 do
        G.update(a, down())
        G.update(b, { down = true })
    end
    assert(a.leftY == b.leftY, "S и Down дают разный результат")
end)

H.test("update: одновременные up+down = покой (компенсация)", function()
    local s = freshState()
    startPlay(s, 1)
    local y0 = s.leftY
    G.update(s, { w = true, s = true })
    assert(s.leftY == y0, "одновременные W+S сместили ракетку")
end)

H.test("ИИ: мёртвая зона |diff|<=0.8 — не дёргается у цели", function()
    local s = freshState()
    startPlay(s, 1)
    -- ставим ракету ИИ точно на траекторию центра мяча
    s.rightY = s.ballY + s.cfg.ballH / 2 - s.cfg.paddleH / 2
    local y0 = s.rightY
    s.ballX = s.cfg.width / 2 - 1  -- далеко от правой стороны, vx мал → diff стабилен
    G.update(s, noKeys)
    assert(s.rightY == y0, "ИИ дёрнулся внутри мёртвой зоны")
end)

H.test("ИИ: шаг не быстрее aiSpeed и не дальше цели (overshoot запрещён)", function()
    local s = freshState()
    startPlay(s, 1)
    s.rightY = 1
    s.ballY = s.cfg.height - 2          -- цель далеко внизу
    local before = s.rightY
    G.update(s, noKeys)
    local step = s.rightY - before
    assert(step <= s.cfg.aiSpeed + 1e-12, "ИИ шагну быстрее aiSpeed: " .. step)
    assert(step > 0, "ИИ не поехал к мячу")
    checkInvariants(s, "ai")
end)

--------------------------------------------------------------------------------
-- Группа: голы и скоринг
--------------------------------------------------------------------------------
H.group("scoring")

H.test("гол слева направо: bx>=width -> очко Left, msg/state корректны", function()
    local s = freshState()
    s.state = "play"
    s.ballX = s.cfg.width - 1   -- левый край мяча у линии ворот
    s.ballY = 1                  -- выше обеих ракет? поставим ракеты в угол наоборот
    s.leftY, s.rightY = s.cfg.height - s.cfg.paddleH, s.cfg.height - s.cfg.paddleH
    s.vx, s.vy = 0.9, 0
    G.update(s, noKeys)
    assert(s.scoreL == 1, "гол в правые ворота не засчитан Left (scoreL=" .. s.scoreL .. ")")
    assert(s.scoreR == 0, "Right получил незаслуженное очко")
    assert(s.state == "round", "после гола состояние != round: " .. s.state)
    assert(s.msg == "Left scores!", "неверное сообщение гола: " .. tostring(s.msg))
    checkInvariants(s, "goal-right")
end)

H.test("гол справа налево: bx<=-ballW -> очко Right", function()
    local s = freshState()
    s.state = "play"
    s.ballX = -s.cfg.ballW       -- уже на линии полного пропуска
    s.leftY, s.rightY = 1, 1
    s.vx, s.vy = -0.9, 0
    G.update(s, noKeys)
    assert(s.scoreR == 1, "гол в левые ворота не засчитан Right (scoreR=" .. s.scoreR .. ")")
    assert(s.scoreL == 0, "Left получил незаслуженное очко")
    assert(s.state == "round" and s.msg == "Right scores!",
        "state/msg неверны: " .. s.state .. " / " .. tostring(s.msg))
end)

H.test("промах мимо ракетки: залипание на лицевой + дискретный гол на след. кадре", function()
    local c = G.CONFIG
    local s = freshState()
    startPlay(s, 1)
    s.rightY = 1                     -- ракета вверху, мяч летит внизу
    s.ballY = c.height - 1
    s.vx, s.vy = c.ballSpeed0, 0
    local faceR = c.width - c.paddleX_L - 1 - c.ballW  -- лицевая сторона правой ракетки
    -- Кадр 1: мяч долетает до лицевой стороны и ОСТАНАВЛИВАЕТСЯ на ней
    -- (промах не засчитывается мгновенно — «залипание», контракт шага 2).
    G.update(s, noKeys)
    assert(s.state == "play", "гол засчитан слишком рано (кадр 1): " .. s.state)
    assert(math.abs(s.ballX - faceR) < 1e-9,
        "после промаха мяч должен залипнуть на лицевой x=" .. faceR .. ", x=" .. s.ballX)
    assert(s.scoreL == 0 and s.scoreR == 0, "преждевременное очко")
    -- Кадр 2: ракета всё ещё вне зоны мяча -> дискретная фиксация гола (шаг 1).
    G.update(s, noKeys)
    assert(s.state == "round", "на втором кадре гол не зафиксирован: " .. s.state)
    assert(s.scoreL == 1 and s.scoreR == 0,
        string.format("промах справа должен дать очко Left, получили L=%d R=%d",
            s.scoreL, s.scoreR))
    checkInvariants(s, "miss-goal")
end)

H.test("полётные кадры без событий: смещение мяча строго на vx и vy за кадр", function()
    -- Чистый контракт интегратора шага (game.lua, шаг 3): пока нет
    -- стены/ракетки/ворот, позиция обновляется как x+=vx, y+=vy. Любое
    -- другое значение = баг физики. Мяч в центре поля, ракетки задвинуты
    -- в противоположный от мяча угол — событие невозможно несколько кадров.
    local s = freshState()
    startPlay(s, 1)
    local c = G.CONFIG
    s.ballX, s.ballY = math.floor(c.width / 2), math.floor(c.height / 2)
    s.vx, s.vy = 0.45, 0.07          -- обе компоненты ненулевые: проверяем X и Y
    s.leftY, s.rightY = 1, 1         -- ракетки вверху; мяч по центру -> мимо
    for _ = 1, 8 do
        local x0, y0 = s.ballX, s.ballY
        G.update(s, noKeys)
        assert(s.state == "play", "неожиданное событие из чистого полёта: " .. s.state)
        assert(math.abs((s.ballX - x0) - 0.45) < 1e-12,
            "кадр сместил X на " .. (s.ballX - x0) .. ", ожидалось ровно vx=0.45")
        assert(math.abs((s.ballY - y0) - 0.07) < 1e-12,
            "кадр сместил Y на " .. (s.ballY - y0) .. ", ожидалось ровно vy=0.07")
    end
end)

H.test("отражение от верхней стены: vy меняет знак, |vy| сохраняется", function()
    local s = freshState()
    startPlay(s, 1)
    s.ballX, s.ballY = 32, 1
    s.vx, s.vy = 0.2, -0.3           -- летит вверх к стене
    s.leftY, s.rightY = 9, 9         -- подальше от траектории
    G.update(s, noKeys)
    assert(s.state == "play", "стена не должна завершать розыгрыш: " .. s.state)
    assert(s.vy == 0.3, "vy после отражения от стены: " .. s.vy .. ", ожидалось +0.3")
    assert(s.ballY >= 1, "мяч ушёл выше потолка: ballY=" .. s.ballY)
end)

H.test("отражение от ракетки: vx меняет знак, скорость растёт не более чем на accel", function()
    local s = freshState()
    startPlay(s, 1)
    local c = G.CONFIG
    -- левая ракетка: faceL = paddleX_L + paddleW + 1
    local faceL = c.paddleX_L + c.paddleW + 1
    s.leftY = 10
    s.ballY = 11                     -- центр мяча внутри ракетки
    s.ballX = faceL                  -- мяч ровно на лицевой стороне
    s.vx, s.vy = -c.ballSpeed0, 0.1
    G.update(s, noKeys)
    assert(s.state == "play", "касание ракетки не должно завершать розыгрыш")
    assert(s.vx > 0, "vx не развернулся при ударе о ракетку: " .. s.vx)
    local sp = math.sqrt(s.vx * s.vx + s.vy * s.vy)
    assert(sp <= c.ballSpeed0 * c.ballAccel + 1e-9,
        "скорость после удара выросла сильнее, чем на множитель accel: " .. sp)
    assert(s.ballX >= faceL - 1e-9, "мяч протолкнуло сквозь ракетку: x=" .. s.ballX)
end)

H.test("ровно одно очко за розыгрыш: после гола update больше не скорит", function()
    local s = freshState()
    s.state = "play"
    s.ballX = s.cfg.width - 0.5
    s.leftY, s.rightY = 1, 1
    s.vx, s.vy = 0.9, 0
    G.update(s, noKeys)
    local l1, r1 = s.scoreL, s.scoreR
    for _ = 1, 100 do G.update(s, noKeys) end
    assert(s.scoreL == l1 and s.scoreR == r1,
        "счёт изменился после перехода в round — двойной засчёт!")
end)

H.test("победа ровно на winScore: over, верный msg, в over счёт не растёт", function()
    local s = freshState()
    local w = s.cfg.winScore
    local now = 0
    for goal = 1, w do
        -- Ставим мяч НА линию полного пропуска и оставляем летящим туда же:
        -- по контракту (шаг 0) update обязан зафиксировать ровно одно очко.
        s.state = "play"
        s.ballX = s.cfg.width - 0.5
        s.leftY, s.rightY = 1, 1
        s.vx, s.vy = 0.9, 0
        G.update(s, noKeys)
        assert(s.scoreL == goal,
            string.format("после розыгрыша %d scoreL=%d (ожидалось %d)", goal, s.scoreL, goal))
        if goal < w then
            assert(s.state == "round", "на счёте " .. goal .. " преждевременный over")
            -- протокол main.lua: handleRound вызывается КАЖДЫЙ кадр с
            -- монотонными часами; раунд длится ~1.2 сек реального времени
            repeat
                now = now + 1 / 60
                s.lastNow = now
                G.handleRound(s, now)
            until s.state == "play" or now > 10
            assert(s.state == "play", "handleRound не вернул в play за 10 сек часов")
        else
            assert(s.state == "over", "на winScore состояние != over: " .. s.state)
            assert(s.msg:find("YOU WIN", 1, true), "msg не про победу игрока: " .. s.msg)
        end
    end
    -- в over очки больше не начисляются
    local before = s.scoreL
    s.ballX = s.cfg.width - 0.5; s.vx = 0.9
    G.update(s, noKeys)
    assert(s.scoreL == before, "очки капнули в состоянии over")
end)

H.test("CPU WINS: зеркальный путь до over для Right", function()
    local s = freshState()
    local w = s.cfg.winScore
    local now = 0
    for goal = 1, w do
        s.state = "play"
        s.ballX = -s.cfg.ballW + 0.5
        s.leftY, s.rightY = 1, 1
        s.vx, s.vy = -0.9, 0
        G.update(s, noKeys)
        assert(s.scoreR == goal,
            string.format("после розыгрыша %d scoreR=%d", goal, s.scoreR))
        if goal < w then
            assert(s.state == "round", "преждевременный over на " .. goal)
            repeat
                now = now + 1 / 60
                s.lastNow = now
                G.handleRound(s, now)
            until s.state == "play" or now > 10
        else
            assert(s.state == "over", "не over для CPU, state=" .. s.state)
            assert(s.msg:find("CPU WINS", 1, true), "msg не про победу CPU: " .. s.msg)
        end
    end
    assert(s.scoreR == w, "финальный счёт Right != winScore")
end)

--------------------------------------------------------------------------------
-- Группа: handleRound / подачи
--------------------------------------------------------------------------------
H.group("serve-alternation")

H.test("handleRound: таймер 1.2 сек по переданным часам, без преждевременного сброса", function()
    local s = freshState()
    s.state = "round"; s.roundUntil = nil; s.lastNow = 100
    G.handleRound(s, 100)
    assert(s.state == "round", "раунд закрылся раньше таймера")
    assert(s.roundUntil ~= nil, "roundUntil не выставлен при первом визите")
    G.handleRound(s, 100 + 1.19)
    assert(s.state == "round", "раунд закрылся на t<1.2")
    G.handleRound(s, 100 + 1.21)
    assert(s.state == "play", "раунд не закрылся по истечении таймера")
    assert(s.roundUntil == nil, "roundUntil не очищен после закрытия")
    assert(s.ballX == math.floor(s.cfg.width / 2), "после раунда мяч не в центре")
end)

H.test("handleRound: вне round — полный no-op", function()
    for _, st in ipairs({ "menu", "play", "pause", "over" }) do
        local s = freshState()
        if st == "play" then startPlay(s, 1) else s.state = st end
        local x, sl, sr = s.ballX, s.scoreL, s.scoreR
        G.handleRound(s, (s.lastNow or 0) + 100)
        assert(s.state == st and s.ballX == x and s.scoreL == sl and s.scoreR == sr,
            st .. ": handleRound тронул состояние вне round")
    end
end)

H.test("чередование подач: dir = +1 при чётном общем счёте, -1 при нечётном", function()
    -- Контракт game.lua:314: (scoreL+scoreR)%2==0 -> dir=1 (направо).
    -- Проверяем фактическое поведение машины состояний, а не свою фантазию:
    -- фиксируем знаменатель (общий счёт) и сверяем знак vx после подачи.
    local cases = { {0,0,1}, {1,0,-1}, {0,1,-1}, {1,1,1}, {2,1,-1}, {3,2,-1}, {4,3,-1} }
    for _, t in ipairs(cases) do
        local l, r, expectedDir = t[1], t[2], t[3]
        local s = freshState()
        s.scoreL, s.scoreR = l, r
        s.state = "round"
        s.lastNow = 0
        s.roundUntil = -1  -- таймер уже истёк: подача произойдёт сразу
        G.handleRound(s, 0)
        assert(s.state == "play", "после истечения round не перешли в play")
        assert(s.vx == expectedDir * s.cfg.ballSpeed0,
            string.format("счёт %d:%d (Σ=%d): vx=%.4f, ожидался dir=%+d",
                l, r, l + r, s.vx, expectedDir))
    end
end)

H.test("no eternal re-serve: внешний round->play не ре-триггерит старый roundUntil", function()
    local s = freshState()
    s.state = "round"; s.roundUntil = nil; s.lastNow = 10
    G.handleRound(s, 10)             -- ставит roundUntil = 11.2
    assert(s.state == "round")
    -- main.lua жмёт SPACE: внешний переход в play ДО истечения таймера
    s.state = "play"
    G.resetBall(s, 1)
    G.handleRound(s, 10.5)           -- не должен ничего делать в play
    assert(s.state == "play", "handleRound вернул в round из play")
    assert(s.roundUntil == nil or s.roundUntil > 10.5,
        "зависший roundUntil может мгновенно ре-сервисить раунд")
end)

--------------------------------------------------------------------------------
-- Группа: интеграция — полная партия
--------------------------------------------------------------------------------
H.group("full-match")

H.test("полная партия бот против стены: счёт растёт по +1, игра завершается за разумное время", function()
    local s = freshState()
    s.randFn = makeRng(2026)
    startPlay(s, 1)
    local totalGoals = 0
    local lastTotal = 0
    local now = 0
    local frames = 0
    while s.state ~= "over" and frames < 200000 do
        frames = frames + 1
        now = now + 1 / 60
        s.lastNow = now
        -- игрок «стенка»: держим ракетку по мячу с лёгким лагом (реалистично imperfect)
        if s.state == "play" then
            local center = s.leftY + s.cfg.paddleH / 2
            if s.ballY + 0.5 < center - 0.5 then G.update(s, up())
            elseif s.ballY + 0.5 > center + 0.5 then G.update(s, down())
            else G.update(s, noKeys) end
        else
            G.update(s, noKeys)
        end
        G.handleRound(s, now)
        local total = s.scoreL + s.scoreR
        assert(total - lastTotal == 0 or total - lastTotal == 1,
            "счёт прыгнул больше чем на 1 за кадр: " .. lastTotal .. "->" .. total)
        if total > lastTotal then totalGoals = totalGoals + 1 end
        lastTotal = total
        checkInvariants(s, "match@frame" .. frames)
    end
    assert(s.state == "over", "партия не завершилась за " .. frames .. " кадров")
    assert(s.scoreL == s.cfg.winScore or s.scoreR == s.cfg.winScore,
        string.format("победа не на winScore: L=%d R=%d", s.scoreL, s.scoreR))
    assert(totalGoals == s.scoreL + s.scoreR,
        "число событий гола != финальному счёту")
end)

H.test("стресс: 3000 случайных вводов не роняют машину и не нарушают инварианты", function()
    local rng = makeRng(999)
    local s = freshState()
    startPlay(s, 1)
    local now = 0
    for i = 1, 3000 do
        now = now + 1 / 60
        s.lastNow = now
        local r = rng()
        local keys = (r < 0.3 and up()) or (r < 0.6 and down()) or noKeys
        G.update(s, keys)
        G.handleRound(s, now)
        if s.state == "over" then
            s.state = "menu"; s.scoreL, s.scoreR = 0, 0
            s.state = "play"; G.resetBall(s, 1)
        end
        checkInvariants(s, "stress@" .. i)
    end
end)

os.exit(H.finish())
