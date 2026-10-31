-- ============================================================
--  test_deep_logic.lua — ГЛУБИННЫЕ тесты логики игры Pong (game.lua)
--  Целевой хост: Lua 5.1.4 (Windows x64), lua5.1.exe.
--  Тесты чисто вычислительные: не требуют консоли, ffi и LuaJIT,
--  поэтому исполняются на голом lua5.1.exe без пропусков.
--  Запуск:  lua5.1.exe test_deep_logic.lua   [фильтр-подстрока ...]
-- ============================================================

local H = dofile("test_harness.lua")
H.filterFromArg(arg)

local game = H.load("game")
local C    = game.CONFIG

--------------------------------------------------------------------------------
-- Вспомогательные функции
--------------------------------------------------------------------------------

-- Детерминированный LCG (32 бита): одинаковая последовательность на любом
-- хосте — матчи воспроизводимы байт-в-байт между запусками.
local function makeRand(seed)
    local s = seed or 12345
    return function()
        s = (s * 1103515245 + 12345) % 2147483648
        return s / 2147483648
    end
end

-- Дискретное «время» для handleRound: каждый вызов возвращает t+step секунд.
local function clockStep(step)
    local t = 0
    return function()
        t = t + step
        return t
    end
end

--------------------------------------------------------------------------------
-- A. Полёт мяча в вакууме: отскоки от стенок, угол подачи, взятие ворот
--    (ракетки убраны заля, чтобы исключить столкновения с ними)
--------------------------------------------------------------------------------

H.test("A1. vacuum: vacuum flight — wall bounce, monotonic X, goal to right", function()
    local s = game.newState(C)
    s.state = "play"
    s.leftY  = -20            -- ракетки вне поля -> чистый полёт
    s.rightY = -20
    s.ballX, s.ballY = 10, 11
    s.vx, s.vy = C.ballSpeed0, 0.30 * C.ballSpeed0   -- вниз-вправо

    local bounces = 0
    local prevVy  = s.vy
    local lastX   = s.ballX
    local frames  = 0

    while s.state == "play" and frames < 1000 do
        game.update(s, {})
        frames = frames + 1

        -- инвариант: мяч всегда внутри поля, пока идёт розыгрыш
        assert(s.ballY >= 1 and s.ballY <= C.height - C.ballH + 1,
            ("frame %d: ballY=%f вне [1..%d]"):format(frames, s.ballY, C.height))

        -- детект отскока по смене знака vy
        if s.vy ~= prevVy then
            bounces = bounces + 1
            assert(math.abs(s.vy) == math.abs(prevVy),
                ("отскок исказил |vy|: %f -> %f"):format(prevVy, s.vy))
        end
        prevVy = s.vy

        -- X монотонен по направлению vx до самого гола
        assert((s.ballX - lastX) * s.vx >= -1e-9,
            ("X дёрнулся назад: %f -> %f (vx=%f)"):format(lastX, s.ballX, s.vx))
        lastX = s.ballX
    end

    assert(s.state == "round", ("мяч не дошёл до ворот за %d кадров"):format(frames))
    assert(bounces >= 1, "не было ни одного отскока от стенки")
    assert(s.scoreR == 1 and s.scoreL == 0,
        ("гол засчитан не в те ворота: L=%d R=%d"):format(s.scoreL, s.scoreR))
    assert(s.msg == "Right scores!", "сообщение гола неверное: " .. tostring(s.msg))
    -- скорость вдоль траектории постоянна: vy не менялся модулем
    assert(math.abs(s.vy) == 0.30 * C.ballSpeed0,
        ("|vy| изменился за полёт: %f"):format(s.vy))
end)

--------------------------------------------------------------------------------
-- B. Геомлия удара о ракетку: край верх/низ, центр, ограничение угла, ускорение
--------------------------------------------------------------------------------

H.test("B1. paddle bounce: top edge up, bottom edge down, center flat, accel & angle cap", function()
    -- --- удар о ВЕРХНИЙ край левой ракетки -> мяч уходит вверх ---
    local s = game.newState(C)
    s.state = "play"
    s.rightY = -20
    s.leftY  = 10
    s.ballX, s.ballY = C.paddleX_L + 3, 10          -- центр мяча у верхнего края
    s.vx, s.vy = -C.ballSpeed0, 0
    local speedBefore = math.sqrt(s.vx * s.vx + s.vy * s.vy)

    game.update(s, {})

    assert(s.state == "play", "после удара состояние должно остаться play, а it " .. s.state)
    assert(s.vx > 0, ("после отражения vx должен стать > 0, получили %f"):format(s.vx))
    assert(s.vy < 0, ("верхний край обязан задать восходящий vy, получили %f"):format(s.vy))

    local speedAfter = math.sqrt(s.vx * s.vx + s.vy * s.vy)
    assert(math.abs(speedAfter - speedBefore * C.ballAccel) < 1e-9,
        ("ускорение после удара != ballAccel (%f vs %f)"):format(
            speedAfter, speedBefore * C.ballAccel))
    -- вертикальная составляющая ограничена maxBounceAngle от новой скорости
    assert(math.abs(s.vy) <= math.sin(C.maxBounceAngle) * speedAfter + 1e-9,
        ("|vy| превысил максимальный угол отскока: %f > %f"):format(
            math.abs(s.vy), math.sin(C.maxBounceAngle) * speedAfter))

    -- --- зеркало: удар о НИЖНИЙ край -> мяч уходит вниз ---
    local s2 = game.newState(C)
    s2.state = "play"
    s2.rightY = -20
    s2.leftY  = 10
    s2.ballX, s2.ballY = C.paddleX_L + 3, 10 + C.paddleH - 1
    s2.vx, s2.vy = -C.ballSpeed0, 0
    game.update(s2, {})
    assert(s2.vx > 0 and s2.vy > 0,
        ("нижний край обязан задать нисходящий отскок: vx=%f vy=%f"):format(s2.vx, s2.vy))

    -- --- центр ракетки: rel ~ 0 -> почти горизонтальный выстрел ---
    local s3 = game.newState(C)
    s3.state = "play"
    s3.rightY = -20
    s3.leftY  = 10
    s3.ballX, s3.ballY = C.paddleX_L + 3, 10 + math.floor(C.paddleH / 2) - 1
    s3.vx, s3.vy = -C.ballSpeed0, 0
    game.update(s3, {})
    assert(s3.vx > 0 and math.abs(s3.vy) < 0.25 * C.ballSpeed0,
        ("центровой удар дал слишком крутой угол: vy=%f"):format(s3.vy))

    -- --- правая ракетка: симметричный отскок влево ---
    local s4 = game.newState(C)
    s4.state = "play"
    s4.leftY  = -20
    s4.rightY = 10
    local rx = C.width - C.paddleX_L - 1
    s4.ballX, s4.ballY = rx - 2, 10 + math.floor(C.paddleH / 2) - 1
    s4.vx, s4.vy = C.ballSpeed0, 0
    game.update(s4, {})
    assert(s4.vx < 0, ("правая ракетка обязана отбить влево, vx=%f"):format(s4.vx))
end)

--------------------------------------------------------------------------------
-- C. Эволюция полного матча: цикл round->play, чередование подач, финал
--    (случайность — детерминированный LCG; таймер раунда — дискретный)
--------------------------------------------------------------------------------

H.test("C1. full match evolution: frozen round, serve alternation, terminal invariants", function()
    local rand = makeRand(20261031)
    local now  = clockStep(0.5)          -- шаг 0.5 c; пауза раунда 1.2 c => 3 шага
    local s = game.newState(C)
    s.state = "play"
    game.resetBall(s, 1, rand)           -- первая подача направо

    local goals  = {}                    -- протокол голов: {scoreL, scoreR, msg}
    local frames = 0
    local MAXF   = 60000

    while s.state ~= "over" and frames < MAXF do
        frames = frames + 1
        if s.state == "play" then
            game.update(s, {})
        elseif s.state == "round" then
            table.insert(goals, { scoreL = s.scoreL, scoreR = s.scoreR, msg = s.msg })
            local bx, by, bl, br = s.ballX, s.ballY, s.scoreL, s.scoreR
            game.handleRound(s, now())
            if s.state == "round" then   -- пауза ещё не истекла
                assert(s.ballX == bx and s.ballY == by,
                    "мяч сместился во время паузы раунда")
                assert(s.scoreL == bl and s.scoreR == br,
                    "счёт изменился во время паузы раунда")
            else                          -- раунд закрыт -> новый розыгрыш
                assert(s.state == "play",
                    "после round ожидается play, получено " .. s.state)
                assert(s.roundUntil == nil, "roundUntil не сброшен после старта розыгрыша")
                assert(s.msg == "", "после возобновления осталось сообщение: " .. s.msg)
                local cx, cy = math.floor(C.width / 2), math.floor(C.height / 2)
                assert(s.ballX == cx and s.ballY == cy,
                    ("мяч не вернулся в центр после паузы: (%f,%f)"):format(s.ballX, s.ballY))
                local expectDir = ((s.scoreL + s.scoreR) % 2 == 0) and 1 or -1
                assert(s.vx == expectDir * C.ballSpeed0,
                    ("подача #%d: ожидаемый dir=%+d, vx=%f"):format(#goals, expectDir, s.vx))
            end
        end
    end

    assert(s.state == "over",
        ("матч не завершился за %d кадров (счёт %d:%d)"):format(frames, s.scoreL, s.scoreR))

    -- инварианты завершения
    assert(s.scoreL == C.winScore or s.scoreR == C.winScore,
        ("победа засчитана без достижения winScore: %d:%d"):format(s.scoreL, s.scoreR))
    assert(not (s.scoreL >= C.winScore and s.scoreR >= C.winScore),
        "обе стороны одновременно достигли winScore — противоречие правил")

    -- протокол голов: ровно один гол за раунд, счёт никогда не уменьшается
    local lastL, lastR = 0, 0
    for _, g in ipairs(goals) do
        assert(g.scoreL >= lastL and g.scoreR >= lastR, "счёт когда-либо уменьшался")
        assert((g.scoreL - lastL) + (g.scoreR - lastR) == 1,
            "за один раунд забито не ровно один гол")
        assert(g.msg == "Left scores!" or g.msg == "Right scores!",
            "сообщение гола отсутствует или неверно: " .. tostring(g.msg))
        lastL, lastR = g.scoreL, g.scoreR
    end
    assert(lastL == s.scoreL and lastR == s.scoreR,
        "последняя запись протокола не совпала с итоговым счётом")

    -- финальное сообщение соответствует победителю
    local winner = s.scoreL > s.scoreR and "YOU WIN" or "CPU WINS"
    assert(s.msg:find(winner, 1, true),
        ("финальное сообщение не про победителя (%s): %s"):format(winner, s.msg))
    assert(s.msg:find("[SPACE]", 1, true) and s.msg:find("[q]", 1, true),
        "финальное сообщение не обещает управления SPACE/q: " .. s.msg)
    assert(#goals >= 1, "протокол голов пуст")
end)

--------------------------------------------------------------------------------
-- D. Угольные случаи физики: отсутствие туннелированияи и защита границ
--------------------------------------------------------------------------------

H.test("D1. no tunneling: huge vx cannot skip paddle; clamps hold", function()
    -- Очень быстрый мяч (как после долгого разгона) всё равно обязан
    -- отразиться от ракетки, а не пройти сквозь неё (substepping).
    local s = game.newState(C)
    s.state = "play"
    s.rightY = -20
    s.leftY  = 10
    s.ballX, s.ballY = 30, 12
    s.vx, s.vy = -8.0, 0                 -- 8 клеток за кадр >> ширины ракетки зоны
    local bounced = false
    for _ = 1, 30 do
        game.update(s, {})
        if s.vx > 0 then bounced = true; break end
    end
    assert(bounced, "быстрый мяч прошёл сквозь левую ракетку (туннелирование)")
    assert(s.state == "play", "мяч улетел в ворота вместо отражения: " .. s.state)

    -- Ракетки жёстко зажаты в поле приheld вечно «вниз»
    local held = { s = true }
    for _ = 1, 200 do game.update(s, held) end
    assert(s.leftY >= 1 and s.leftY <= C.height - C.paddleH,
        ("игрок вылетел за поле вниз: leftY=%f"):format(s.leftY))
    local heldUp = { w = true }
    for _ = 1, 400 do game.update(s, heldUp) end
    assert(s.leftY >= 1,
        ("игрок вылетел за поле вверх: leftY=%f"):format(s.leftY))
end)

--------------------------------------------------------------------------------
-- E. Детерминизм: одинаковый seed -> идентичный матч (важно для регрессий)
--------------------------------------------------------------------------------

H.test("E1. determinism: same seed replays byte-identical match", function()
    local function runMatch(seed)
        local rand = makeRand(seed)
        local now  = clockStep(0.5)
        local s = game.newState(C)
        s.state = "play"
        game.resetBall(s, 1, rand)
        local trace = {}
        local frames = 0
        while s.state ~= "over" and frames < 60000 do
            frames = frames + 1
            if s.state == "play" then
                game.update(s, {})
            elseif s.state == "round" then
                game.handleRound(s, now())
            end
            table.insert(trace, string.format("%d|%d|%d|%.6f|%.6f",
                frames, s.scoreL, s.scoreR, s.ballX, s.ballY))
        end
        return s, table.concat(trace, ";")
    end

    local sa, ta = runMatch(777)
    local sb, tb = runMatch(777)
    assert(ta == tb, "повтор того же seed дал иной след матча — логика недетерминирована")
    assert(sa.scoreL == sb.scoreL and sa.scoreR == sb.scoreR, "итоговый счёт разошёлся")

    -- другой seed обязан дать иной след (иначе randFn вообще не используется)
    local sc, tc = runMatch(424242)
    assert(tc ~= ta, "разные seed дали идентичный матч — randFn игнорируется resetBall")
    assert(sc.state == "over", "матч с другим seed не завершился")
end)

--------------------------------------------------------------------------------
-- F. Граничные условия физики: залипание пропущенного мяча, ложные голы
--    (баги №1/№2 из аудита; регрессионные)
--------------------------------------------------------------------------------

H.test("F1. missed ball reaches goal line; no phantom goals inside field", function()
    -- (a) Пропущенный мяч обязан дойти до линии ворот и засчитать гол.
    -- Старый баг: левый гол проверялся как `ballX < lx`, но физика останавливает
    -- мяч на линии ракетки lx+2=5 — условие недостижимо, розыгрыш вечный.
    local s = game.newState(C)
    s.state = "play"
    s.leftY  = -20            -- обе ракетки «сломаны» и вне поля -> чистый пропуск
    s.rightY = -20
    s.ballX, s.ballY = 30, 11
    s.vx, s.vy = -C.ballSpeed0, 0
    local frames = 0
    while s.state == "play" and frames < 500 do
        game.update(s, {})
        frames = frames + 1
    end
    assert(s.state == "round",
        ("пропущенный влево мяч залип: %d кадров без гола (X=%.3f)"):format(frames, s.ballX))
    assert(s.scoreR == 1 and s.msg == "Right scores!",
        ("гол не в те ворота или сообщение неверно: L=%d R=%d msg=%s"):format(
            s.scoreL, s.scoreR, tostring(s.msg)))

    -- (b) Правая сторона симметрично (старый баг зеркальный).
    local r = game.newState(C)
    r.state = "play"; r.leftY = -20; r.rightY = -20
    r.ballX, r.ballY = 30, 11
    r.vx, r.vy = C.ballSpeed0, 0
    frames = 0
    while r.state == "play" and frames < 500 do
        game.update(r, {})
        frames = frames + 1
    end
    assert(r.state == "round",
        ("пропущенный вправо мяч залип: %d кадров без гола (X=%.3f)"):format(frames, r.ballX))
    assert(r.scoreL == 1 and r.msg == "Left scores!", "правый гол засчитан неверно")

    -- (c) Регрессия на ранний гол: гол НЕ должен фиксироваться, пока правый
    -- край мяча ещё внутри поля (клетки 1..width). Проверяем каждый кадр.
    local g = game.newState(C)
    g.state = "play"; g.leftY = -20; g.rightY = -20
    g.ballX, g.ballY = 55, 11
    g.vx, g.vy = C.ballSpeed0, 0
    for _ = 1, 40 do
        game.update(g, {})
        if g.state ~= "play" then break end
        assert(g.ballX + C.ballW <= C.width,
            ("мяч ещё в поле (X=%.3f..%.3f), а состояние уже не play"):format(
                g.ballX, g.ballX + C.ballW - 1))
    end
    assert(g.state == "round", "гола вообще не случилось за 40 кадров")
end)

--------------------------------------------------------------------------------
-- G. Инварианты столкновений: нет фантомных отскоков, модуль скорости цел
--------------------------------------------------------------------------------

H.test("G1. no phantom paddle bounce when paddles are out of reach", function()
    -- Ракетки задраны максимально вверх (leftY=rightY=1), мяч летит по нижней
    -- части поля (Y=18). Зона detection [leftY..leftY+paddleH-1]=[1..5] с ним
    -- не пересекается НИ при каком X. Старый баг: remX считался от дальней
    -- границы и substep проскакивал зону встречной ракетки целиком, порождая
    -- отскок vx->-vx с пересчётом угла при пустой ракетке («фантом»).
    local s = game.newState(C)
    s.state = "play"
    s.leftY, s.rightY = 1, 1
    s.ballX, s.ballY = 10, 18
    s.vx, s.vy = C.ballSpeed0, -0.2 * C.ballSpeed0
    local speedPrev = math.sqrt(s.vx * s.vx + s.vy * s.vy)
    local dirPrev   = s.vx > 0 and 1 or -1
    local bounces   = 0
    local frames    = 0
    while s.state == "play" and frames < 600 do
        game.update(s, {})
        frames = frames + 1
        local dirNow = s.vx > 0 and 1 or -1
        if dirNow ~= dirPrev then
            bounces = bounces + 1
            error(("фантомный отскок на кадре %d: vx %.4f -> %.4f при Y=%.2f, " ..
                   "обе ракетки в [1..%d]"):format(frames, dirPrev, dirNow, s.ballY,
                   C.paddleH))
        end
        -- скорость в вакууме стенковых отскоков сохраняется точно
        local sp = math.sqrt(s.vx * s.vx + s.vy * s.vy)
        assert(math.abs(sp - speedPrev) < 1e-12,
            ("скорость исказилась на кадре %d: %.6f -> %.6f"):format(frames, speedPrev, sp))
        speedPrev = sp
    end
    assert(bounces == 0, "за " .. frames .. " кадров случились отскоки от пустых ракеток")
    assert(s.state == "round" and s.scoreR == 1,
        "мяч должен был долететь до левых ворот (scoreR=1)")
end)

--------------------------------------------------------------------------------
-- H. Стресс-физика: экстремальные скорости, двойные проходы поля, отсутствие
--    зависаний и выход за границы
--------------------------------------------------------------------------------

H.test("H1. extreme speeds: bounded runtime, in-field clamp, eventual goal", function()
    local cases = {
        { vx =  8.0, vy =  7.0 },   -- очень быстрый вправо-вниз
        { vx = -9.0, vy = 11.0 },   -- быстрее высоты поля за кадр
        { vx =  0.45, vy =  0.0 },  -- минимальная подача
        { vx = 20.0, vy = -20.0 },  -- абсурд: больше двух полей по диагонали
    }
    for _, cs in ipairs(cases) do
        local s = game.newState(C)
        s.state = "play"
        s.leftY, s.rightY = math.floor(C.height / 2 - C.paddleH / 2),
                           math.floor(C.height / 2 - C.paddleH / 2)
        s.ballX, s.ballY = math.floor(C.width / 2), math.floor(C.height / 2)
        s.vx, s.vy = cs.vx, cs.vy
        local frames = 0
        local wallBounces = 0
        local prevVy = s.vy
        while s.state == "play" and frames < 3000 do
            game.update(s, {})
            frames = frames + 1
            -- инвариант границ: пока идёт розыгрыш, Y мяча строго в поле
            assert(s.ballY >= 1 and s.ballY <= C.height - C.ballH + 1,
                ("случай (%g,%g): Y=%.4f вне [1..%.1f] на кадре %d"):format(
                    cs.vx, cs.vy, s.ballY, C.height - C.ballH + 1, frames))
            -- X обязан остаться в разумных пределах (не улетел в NaN/inf)
            assert(s.ballX == s.ballX and s.ballX > -1000 and s.ballX < 2000,
                ("случай (%g,%g): X=%s на кадре %d"):format(cs.vx, cs.vy,
                    tostring(s.ballX), frames))
            if s.vy ~= prevVy then wallBounces = wallBounces + 1 end
            prevVy = s.vy
        end
        assert(s.state ~= "play",
            ("случай (%g,%g): завис на %d кадров (X=%.2f vx=%.2f)"):format(
                cs.vx, cs.vy, frames, s.ballX, s.vx))
        -- быстрый мяч либо отбит ракетками/стенками, либо дошёл до ворот;
        -- главное — завершение за конечное число кадров (см. assert выше)
        assert(frames < 3000, "слишком долгий розыгрыш")
    end
end)

return os.exit(H.finish())
