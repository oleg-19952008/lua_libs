-- random.lua
-- Генератор случайных байт для утилиты переименования.
-- Lua 5.1.4, Windows. Без C-модулей, io.popen, os.execute.
--
-- Использование как модуля:
--   local random = dofile("random.lua")   -- или require после настройки путей
--   random.initRandom()                   -- один раз при старте
--   local bytes = random.getRandomBytes(16)

local M = {}

local DEBUG = false

-- Максимальное число байт за один вызов.
-- Защита от случайного/намеренного запроса гигантского буфера.
local MAX_BYTES = 65536
M.MAX_BYTES = MAX_BYTES

-- Хеш строки с модульной арифметикой.
-- Смешивает несколько источников энтропии.
-- В Lua 5.1 нет побитовых операций — используем арифметическую свёртку.
local function hash_string(s)
    local h = 5381
    for i = 1, #s do
        -- h * 33 + байт; произведение не превышает 2^53, потери точности нет.
        h = (h * 33 + string.byte(s, i)) % 2147483647
    end
    return h
end

--- Возвращает строку из n случайных байт (0x00–0xFF).
-- Это единственное место, где вызывается math.random.
-- Для замены источника на криптостойкий достаточно переписать тело функции.
function M.getRandomBytes(n)
    if type(n) ~= "number" or n <= 0 or n ~= n
        or n == math.huge or n == -math.huge then
        return ""
    end

    n = math.floor(n)
    if n <= 0 or n > MAX_BYTES then
        return ""
    end

    local bytes = {}
    for i = 1, n do
        bytes[i] = string.char(math.random(0, 255))
    end
    return table.concat(bytes)
end

--- Инициализирует seed генератора.
-- Вызывать один раз при старте скрипта до первого getRandomBytes.
-- Опциональный custom_seed позволяет воспроизводимость.
function M.initRandom(custom_seed)
    local seed

    if type(custom_seed) == "number" and custom_seed == custom_seed
        and custom_seed ~= math.huge and custom_seed ~= -math.huge then
        seed = math.floor(custom_seed)
    else
        -- Источник 1: время в секундах.
        local t = os.time()
        -- Источник 2: время процесса с масштабированием до микросекунд.
        local c = math.floor(os.clock() * 1000000)
        -- Источник 3: адрес таблицы ("table: 0x...").
        local addr_str = tostring({})
        local hex = addr_str:match("0x(%x+)")
        local addr = hex and tonumber(hex, 16) or 0
        -- Источник 4: шум из серии замеров os.clock().
        local noise = 0
        for i = 1, 10 do
            noise = (noise + math.floor(os.clock() * 1000000)
                + i * 2654435761) % 2147483647
        end
        -- Источник 5: текущее потребление памяти сборщиком мусора (в байтах).
        local mem = math.floor(collectgarbage("count") * 1024)

        local raw = table.concat({
            tostring(t),
            tostring(c),
            tostring(addr),
            tostring(noise),
            tostring({}),
            tostring(os.clock()),
            tostring(mem),
        }, "|")
        seed = hash_string(raw)
    end

    -- Приводим seed к безопасному диапазону 1..2147483646.
    -- math.abs() — явная защита от отрицательных значений (хотя % в Lua
    -- и так даёт неотрицательный результат при положительном делителе).
    seed = math.abs(seed) % 2147483646 + 1
    math.randomseed(seed)

    if DEBUG then
        print("[DEBUG] random seed = " .. tostring(seed))
    end

    -- Прогрев: 15 холостых вызовов.
    for _ = 1, 15 do
        M.getRandomBytes(1)
    end
end

-- Самотест. Запускается только при прямом вызове файла (lua random.lua),
-- но не при require/dofile как модуля.
local function run_self_test()
    local all_ok = true

    local function check(name, ok, detail)
        if ok then
            print("[OK] " .. name)
        else
            print("[FAIL] " .. name .. (detail and (": " .. detail) or ""))
            all_ok = false
        end
    end

    M.initRandom()

    -- Краевые случаи.
    check("getRandomBytes(nil) == \"\"",        M.getRandomBytes(nil) == "")
    check("getRandomBytes(0) == \"\"",          M.getRandomBytes(0) == "")
    check("getRandomBytes(-5) == \"\"",         M.getRandomBytes(-5) == "")
    check("getRandomBytes(MAX_BYTES + 1) == \"\"",
        M.getRandomBytes(MAX_BYTES + 1) == "")
    check("getRandomBytes(1) длина 1",          #M.getRandomBytes(1) == 1)
    check("getRandomBytes(9) длина 9",          #M.getRandomBytes(9) == 9)
    check("getRandomBytes(9.9) длина 9",        #M.getRandomBytes(9.9) == 9)

    local n_tests = 1000
    local len = 9
    local seen = {}
    local unique = 0
    local len_ok = true
    local range_ok = true
    local counts = {0, 0, 0, 0}
    local total_bytes = 0

    for i = 1, n_tests do
        local s = M.getRandomBytes(len)

        if #s ~= len then len_ok = false end

        if seen[s] == nil then
            seen[s] = 1
            unique = unique + 1
        else
            seen[s] = seen[s] + 1
        end

        for j = 1, #s do
            local b = string.byte(s, j)
            total_bytes = total_bytes + 1

            if b < 0 or b > 255 then range_ok = false end

            local idx
            if b <= 63 then idx = 1
            elseif b <= 127 then idx = 2
            elseif b <= 191 then idx = 3
            else idx = 4 end
            counts[idx] = counts[idx] + 1
        end
    end

    check("длина каждой строки ровно " .. len, len_ok)
    check("все байты в диапазоне 0..255", range_ok)
    check("уникальных строк >= 950 (получено " .. unique .. ")", unique >= 950)

    local expected = total_bytes / 4
    local min_count = math.floor(expected * 0.8)
    local max_count = math.ceil(expected * 1.2)
    local dist_ok = true
    local dist_detail = ""

    for i = 1, 4 do
        if counts[i] < min_count or counts[i] > max_count then
            dist_ok = false
            dist_detail = dist_detail .. string.format(
                "диапазон %d: %d (ожид. %d..%d); ",
                i, counts[i], min_count, max_count)
        end
    end

    check("распределение по 4 диапазонам (отклонение <= 20%)", dist_ok, dist_detail)

    -- Разные seed → разные последовательности.
    M.initRandom(123456789)
    local seq_1 = M.getRandomBytes(9)
    M.initRandom(987654321)
    local seq_2 = M.getRandomBytes(9)
    local seq_1_clean = (seq_1:gsub("%c", "?"))
    local seq_2_clean = (seq_2:gsub("%c", "?"))
    check("разные seed дают разные последовательности", seq_1 ~= seq_2,
        "seq1=" .. seq_1_clean .. " seq2=" .. seq_2_clean)

    -- Отрицательный seed не ломает инициализацию.
    M.initRandom(-42)
    check("отрицательный seed не ломает инициализацию",
        #M.getRandomBytes(9) == 9)

    -- Отпечаток для ручной проверки двух последовательных запусков.
    M.initRandom()
    local fingerprint = M.getRandomBytes(9)
    local hex = fingerprint:gsub(".", function(ch)
        return string.format("%02X", string.byte(ch))
    end)
    print("[INFO] Отпечаток текущего запуска (сравните при двух запусках): " .. hex)

    if all_ok then
        print("Все тесты пройдены")
    else
        print("Некоторые тесты не пройдены")
    end
end

-- Автозапуск самотеста только при прямом выполнении файла.
-- При require/dofile arg[0] указывает на вызывающий скрипт, а не на этот файл.
if arg and arg[0] and arg[0]:lower():match("random%.lua$") then
    run_self_test()
end

return M