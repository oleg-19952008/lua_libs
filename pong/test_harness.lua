-- ============================================================
--  test_harness.lua — общий мини-фреймворк для тестов игры Pong.
--  Совместим с Lua 5.1 / 5.4 / LuaJIT (Windows 10).
--  Использование:
--      local H = dofile("test_harness.lua")
--      H.group("game")
--      H.test("name", function() ... end)   -- декларация; assert'ы внутри
--      H.skipTest("reason")                 -- условный пропуск из тела теста
--      os.exit(H.finish())                  -- запуск всех + итог + код возврата
--  Аргументы командной строки, переданные в H.filterFromArg(arg), фильтруют
--  запуск по подстроке имени или по номеру теста.
-- ============================================================

local M = { passed = 0, failed = 0, skipped = 0, errors = {}, tests = {} }

local currentGroup = "?"
local pendingOnly = nil   -- список имён тестов для запуска (set в main по argv)

--------------------------------------------------------------------------------
-- Тесты — ДЕКЛАРАЦИИ. Порядок реестра фиксирован; запуск — в M.run().
-- Это даёт: стабильную нумерацию, фильтр по именам, независимость от
-- порядка регистрации и от ошибок при загрузке модулей.
--------------------------------------------------------------------------------

local seq = 0

function M.test(name, fn)
    seq = seq + 1
    table.insert(M.tests, { id = seq, group = currentGroup, name = name, fn = fn })
end

--- Значение фильтра из argv (запуск только указанных тестов по подстроке).
function M.setFilter(list)
    pendingOnly = list
end

--- arg -> фильтр (пустой список = без фильтра).
function M.filterFromArg(argv)
    local list = {}
    if argv then
        for i = 1, #argv do list[#list + 1] = argv[i] end
    end
    if #list > 0 then M.setFilter(list) end
end

local function matches(id, name)
    if not pendingOnly then return true end
    for _, pat in ipairs(pendingOnly) do
        if pat ~= "" and (name:find(pat, 1, true) or tostring(id) == pat) then
            return true
        end
    end
    return false
end

function M.run()
    for _, t in ipairs(M.tests) do
        if t.group ~= currentGroup then
            currentGroup = t.group
            print(string.format("--- %s ---", currentGroup))
        end
        if not pendingOnly or matches(t.id, t.name) then
            local ok, err = pcall(t.fn)
            if ok then
                M.passed = M.passed + 1
                print(string.format("  [PASS] #%02d %s", t.id, t.name))
            elseif type(err) == "table" and err.__pongSkip then
                -- условный пропуск: skipTest(reason) из тела теста
                M.skipped = M.skipped + 1
                print(string.format("  [SKIP] #%02d %s (%s)",
                    t.id, t.name, tostring(err.reason)))
            else
                M.failed = M.failed + 1
                table.insert(M.errors, t.name .. ": " .. tostring(err))
                print(string.format("  [FAIL] #%02d %s\n         %s",
                    t.id, t.name, tostring(err)))
            end
        end
    end
end

--- Пропуск внутри тела теста (условия не подошли): error({__skip=...}).
function M.skipTest(reason)
    error({ __pongSkip = true, reason = tostring(reason) }, 0)
end

--- Завершение файла тестов: печатает итог, возвращает код для os.exit.
function M.finish()
    M.run()
    print("")
    print(string.format("Итого: %d passed, %d failed, %d skipped",
        M.passed, M.failed, M.skipped))
    if M.failed > 0 then
        print("Провалившие:")
        for _, e in ipairs(M.errors) do print("  - " .. e) end
    end
    return M.failed == 0 and 0 or 1
end

--------------------------------------------------------------------------------
-- Хелперы окружения
--------------------------------------------------------------------------------

M.IS_WINDOWS = package.config:sub(1, 1) == "\\"

function M.isWindows10()
    if not M.IS_WINDOWS then return false end
    -- Проверка именно десятки: cmd ver -> "Microsoft Windows [Version 10.0.xxxx...]"
    -- (на Lua 5.1.4 x64 popen('ver') может не работать — тогда fallback на os.version()).
    local f = io.popen and io.popen("cmd /c ver")
    if f then
        local out = f:read("*a") or ""
        f:close()
        if out:find("Version 10%.", 1, false) then return true end
    end
    if os.version then
        local v = os.version()
        if v and v:find("Windows", 1, false) then
            if v:find("Version 10%.", 1, false) or v:find("NT 10%.", 1, false) then
                return true
            end
        end
    end
    return false
end

--- arg[0] из lua.exe (полный путь, как его видит сам интерпретатор).
-- На Win10: lua5.1.exe -> "C:\\...\\lua5.1.exe", luajit.exe -> "C:\\...\\luajit.exe".
-- Возвращает nil, если получить не удалось.
function M.hostExe()
    if not M.IS_WINDOWS then return nil end
    local a0 = rawget(_G, "arg") and arg[0]
    if type(a0) ~= "string" or a0 == "" then return nil end
    -- Проверяем существование файла: на 5.1 без -u это может быть и "lua" без пути.
    local f = io.open(a0, "rb")
    if f then f:close(); return a0 end
    -- Попытка через where/for: вдруг a0 — голое имя exe в PATH
    if io.popen then
        local p = io.popen('where ' .. a0 .. ' 2>nul', 'r')
        if p then
            local line = p:read("*l"); p:close()
            if line and line ~= "" then
                local g = io.open(line, "rb")
                if g then g:close(); return line end
            end
        end
    end
    return nil
end

--- Каталог скрипта (пути работают и с "\", и с "/").
function M.scriptDir()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    return src:match("^(.*[/\\])") or "./"
end

--- Загрузка модуля из каталога теста (рядом лежат game.lua, term.lua...).
function M.load(name)
    local path = M.scriptDir() .. name .. ".lua"
    local chunk, err = loadfile(path)
    assert(chunk, "не удалось загрузить " .. path .. ": " .. tostring(err))
    return chunk()
end

--------------------------------------------------------------------------------
-- Временный каталог через стандартные средства Lua (работает на Win10 в
-- любом интерпретаторе; пути модуля paths.lua проверяются отдельно в FS-секции)
--------------------------------------------------------------------------------

local tmpCounter = 0

function M.makeTmpDir(prefix)
    prefix = prefix or "pong_test_"
    local base = os.getenv("TEMP") or os.getenv("TMP") or M.scriptDir()
    base = base:gsub("[\\/]+$", "")
    for _ = 1, 32 do
        tmpCounter = tmpCounter + 1
        local name = base .. "\\" .. prefix .. tostring(os.time())
            .. "_" .. tostring(tmpCounter) .. "_" .. tostring(math.random(100000, 999999))
        -- mkdir через cmd (bat-разделитель CRLF важен для cmd)
        local ok = false
        if os.execute then
            local q = '"' .. name .. '"'
            local r1 = os.execute('mkdir ' .. q .. ' >nul 2>nul')
            ok = (r1 == true or r1 == 0)
        end
        if not ok then
            local sepOk = (io.open(name .. "\\probe.tmp", "wb") ~= nil)
            if sepOk then
                local pf = io.open(name .. "\\probe.tmp", "wb"); if pf then pf:close() end
                os.remove(name .. "\\probe.tmp")
                ok = true
            end
        end
        if ok then return name end
    end
    return nil
end

function M.join(dir, name)
    if dir:sub(-1) == "\\" or dir:sub(-1) == "/" then return dir .. name end
    return dir .. "\\" .. name
end

function M.writeFile(path, content)
    local f = assert(io.open(path, "wb"), "writeFile: " .. path)
    f:write(content)
    f:close()
    return path
end

function M.readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

function M.pathExists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

--- Рекурсивное удаление дерева (только наши temp-каталоги!).
function M.rmtree(dir)
    if not dir or dir == "" then return end
    if M.IS_WINDOWS then
        os.execute('rmdir /s /q "' .. dir .. '" >nul 2>nul')
    else
        os.execute('rm -rf "' .. dir .. '" 2>/dev/null')
    end
end

--------------------------------------------------------------------------------
-- Перехват io.write (для проверки вывода term.present/init/shutdown)
--------------------------------------------------------------------------------

--- Подменяет io.write; возвращает функцию restore.
function M.captureWrite()
    local saved = io.write
    local buf = {}
    io.write = function(...)
        for i = 1, select("#", ...) do
            local v = select(i, ...)
            buf[#buf + 1] = tostring(v)
        end
        return saved and true or true
    end
    local function get() return table.concat(buf) end
    local function restore() io.write = saved end
    return get, restore
end

--- Разбивает ANSI-поток на «видимые» строки (без escape-последовательностей).
-- Возвращает массив строк длиной до последней \r\n; escape-коды вырезаны.
function M.visibleLines(stream)
    -- вырезаем CSI-последовательности: ESC [ params final-byte
    local clean = stream:gsub("\27%[[%d;%?]*[%a]", "")
    local lines = {}
    for line in clean:gmatch("([^\r\n]*)") do
        lines[#lines + 1] = line
    end
    return lines
end

return M
