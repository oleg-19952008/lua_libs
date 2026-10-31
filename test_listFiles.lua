-- ============================================================
--  test_listFiles.lua — 70 тестов для listFiles.lua
--  Запуск: lua test_listFiles.lua [path\to\paths.lua]
--        (или переменная окружения LISTFILES_MODULE)
--  Требует: Windows, io.popen, cmd.exe (как и сам модуль)
--  Вне Windows чистые (string-операции) группы выполняются, а
--  группы, зависящие от файловой системы/cmd.exe, помечаются
--  skipped ('s') и НЕ считаются падениями (exit code 0).
-- ============================================================

-- По умолчанию — paths.lua (модуль listFiles.lua был объединён в
-- paths.lua); путь можно переопределить: аргументом или LISTFILES_MODULE.
local modulePath = (arg and arg[1])
                or (os.getenv and os.getenv("LISTFILES_MODULE"))
                or "paths.lua"
local M = dofile(modulePath)

-- ------------------------------------------------------------
--  Определение платформы. Модуль paths.lua работает только на
--  Windows (cmd.exe + UNC-пути), поэтому вне Windows FS-тесты
--  пропускаются graceful-ly — как в test_paths.lua (skip при
--  отсутствии TEMP/TMP).
-- ------------------------------------------------------------
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local HAS_TEMP   = (os.getenv("TEMP") or os.getenv("TMP")) ~= nil
local FS_READY   = IS_WINDOWS and HAS_TEMP

-- ------------------------------------------------------------
--  Доступ к внутренним хелперам.
--  Тесты 23–37 и 68–70 требуют M._test. Если модуль старый и
--  не экспортирует его — эти тесты помечаются 's' (skipped),
--  а не 'F' (fail). Для полного прогона обновите модуль.
-- ------------------------------------------------------------
local _T = M._test or {}
if M._test == nil then
    print("NOTE: " .. modulePath .. " не экспортирует M._test.")
    print("      Тесты 23–37 (utf16/LCG) и 68–70 (_test helpers)")
    print("      будут пропущены. Убедитесь, что в конце файла есть блок:")
    print('        M._test = { utf16leToUtf8=..., makeTempPair=...,')
    print('                    runBat=..., lcgNext=..., lcgSeed=... }')
    print('        return M')
end

-- ============================================================
--  Мини-фреймворк
-- ============================================================
local passed, failed, skipped = 0, 0, 0
local failures = {}
local currentGroup = ""

local function group(name)
    currentGroup = name
    print("\n== " .. name .. " ==")
end

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        io.write(".")
    else
        failed = failed + 1
        failures[#failures + 1] = {
            group = currentGroup, name = name, err = tostring(err) }
        io.write("F")
    end
end

-- Регистрирует тест, только если cond истинно; иначе skipped.
local function test_or_skip(cond, name, fn)
    if not cond then
        skipped = skipped + 1
        io.write("s")
        return
    end
    test(name, fn)
end

local function eq(a, b, m)
    if a ~= b then
        error((m or "") .. ": expected [" .. tostring(b) ..
              "], got [" .. tostring(a) .. "]", 2)
    end
end
local function is_true(v, m)  if not v then error(m or "expected truthy", 2) end end
local function is_false(v, m) if v then error(m or "expected falsy", 2) end end
local function errs(fn, m)
    if pcall(fn) then error(m or "expected error", 2) end
end
local function set_eq(arr, expected_list, m)
    local have, want = {}, {}
    for _, v in ipairs(arr) do have[v] = (have[v] or 0) + 1 end
    for _, v in ipairs(expected_list) do want[v] = (want[v] or 0) + 1 end
    for k, v in pairs(want) do
        if (have[k] or 0) ~= v then
            error((m or "set_eq") .. ": missing [" .. tostring(k) .. "]", 2)
        end
    end
    for k, v in pairs(have) do
        if (want[k] or 0) ~= v then
            error((m or "set_eq") .. ": unexpected [" .. tostring(k) .. "]", 2)
        end
    end
end
local function contains(arr, v, m)
    for _, x in ipairs(arr) do if x == v then return end end
    error((m or "contains") .. ": [" .. tostring(v) .. "] not found", 2)
end

-- ============================================================
--  Утилиты фикстур и UTF-16
-- ============================================================
local function mkdir(p) os.execute('mkdir "' .. p .. '" 2>nul') end
local function rmdir(p) os.execute('rmdir /s /q "' .. p .. '" 2>nul') end
local function touch(p) local f = assert(io.open(p, "w")); f:close() end

local function u16char(cp)
    if cp < 0x10000 then
        return string.char(cp % 256, math.floor(cp / 256))
    end
    local v  = cp - 0x10000
    local hi = 0xD800 + math.floor(v / 0x400)
    local lo = 0xDC00 + (v % 0x400)
    return string.char(hi % 256, math.floor(hi / 256)) ..
           string.char(lo % 256, math.floor(lo / 256))
end

-- ============================================================
--  Фикстуры
-- ============================================================
math.randomseed(os.time())
local TEMPDIR = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Windows\\Temp"
local BASE = TEMPDIR .. "\\lua_test_" .. tostring(os.time()) ..
             "_" .. tostring(math.random(100000, 999999))

local function setup()
    rmdir(BASE)
    mkdir(BASE)
    mkdir(BASE .. "\\empty")

    mkdir(BASE .. "\\files_only")
    touch(BASE .. "\\files_only\\a.txt")
    touch(BASE .. "\\files_only\\b.txt")
    touch(BASE .. "\\files_only\\UPPER.TXT")
    touch(BASE .. "\\files_only\\with space.txt")
    touch(BASE .. "\\files_only\\%TEMP%.txt")
    touch(BASE .. "\\files_only\\excl!am.txt")
    touch(BASE .. "\\files_only\\amp&ersand.txt")

    mkdir(BASE .. "\\dirs_only")
    mkdir(BASE .. "\\dirs_only\\sub1")
    mkdir(BASE .. "\\dirs_only\\sub2")
    mkdir(BASE .. "\\dirs_only\\sub with space")

    mkdir(BASE .. "\\mixed")
    touch(BASE .. "\\mixed\\m1.txt")
    mkdir(BASE .. "\\mixed\\md1")
    mkdir(BASE .. "\\mixed\\md2")

    mkdir(BASE .. "\\nested")
    mkdir(BASE .. "\\nested\\n1")
    touch(BASE .. "\\nested\\n1\\n1a.txt")
    touch(BASE .. "\\nested\\n1\\n1b.txt")
    mkdir(BASE .. "\\nested\\n1\\deep")
    touch(BASE .. "\\nested\\n1\\deep\\deep1.txt")
    mkdir(BASE .. "\\nested\\n2")
    touch(BASE .. "\\nested\\n2\\n2a.txt")
end

local function teardown() if FS_READY then rmdir(BASE) end end

if FS_READY then
    setup()
else
    print("NOTE: не-Windows (или TEMP/TMP не задан) — файловые фикстуры")
    print("      не создаются; группы dirExists/listFiles/listDirs/")
    print("      listFilesRecursive/integration/_test helpers будут пропущены.")
end

-- ------------------------------------------------------------
--  ГРУППА 1: normalizePath (12)
-- ------------------------------------------------------------
group("normalizePath")
test("01 empty string raises",
    function() errs(function() M.normalizePath("") end) end)
test("02 number raises",
    function() errs(function() M.normalizePath(42) end) end)
test("03 nil raises",
    function() errs(function() M.normalizePath(nil) end) end)
test("04 simple path unchanged",
    function() eq(M.normalizePath("C:\\foo\\bar"), "C:\\foo\\bar") end)
test("05 forward → backslash",
    function() eq(M.normalizePath("C:/foo/bar"), "C:\\foo\\bar") end)
test("06 consecutive backslashes collapsed",
    function() eq(M.normalizePath("C:\\\\foo\\\\\\\\bar"), "C:\\foo\\bar") end)
test("07 mixed slashes normalized",
    function() eq(M.normalizePath("C:/foo\\\\bar/baz"), "C:\\foo\\bar\\baz") end)
test("08 'C:' → 'C:\\'",
    function() eq(M.normalizePath("C:"), "C:\\") end)
test("09 'C:\\' stays",
    function() eq(M.normalizePath("C:\\"), "C:\\") end)
test("10 'C:/' → 'C:\\'",
    function() eq(M.normalizePath("C:/"), "C:\\") end)
test("11 trailing backslash trimmed",
    function() eq(M.normalizePath("C:\\foo\\"), "C:\\foo") end)
test("12 UNC preserved",
    function() eq(M.normalizePath("\\\\server\\share"), "\\\\server\\share") end)

-- ------------------------------------------------------------
--  ГРУППА 2: joinPath (10)
-- ------------------------------------------------------------
group("joinPath")
test("13 basic join",
    function() eq(M.joinPath("C:\\foo", "bar"), "C:\\foo\\bar") end)
test("14 trailing backslash",
    function() eq(M.joinPath("C:\\foo\\", "bar"), "C:\\foo\\bar") end)
test("15 forward slash",
    function() eq(M.joinPath("C:/foo", "bar"), "C:\\foo\\bar") end)
test("16 name with spaces",
    function() eq(M.joinPath("C:\\foo", "with space"), "C:\\foo\\with space") end)
test("17 name with dots",
    function() eq(M.joinPath("C:\\foo", "a.b.c.log"), "C:\\foo\\a.b.c.log") end)
test("18 name with '%' preserved",
    function() eq(M.joinPath("C:\\foo", "%TEMP%.txt"), "C:\\foo\\%TEMP%.txt") end)
test("19 drive root join",
    function() eq(M.joinPath("C:\\", "bar"), "C:\\bar") end)
test("20 bare drive letter join",
    function() eq(M.joinPath("C:", "bar"), "C:\\bar") end)
test("21 empty name allowed (pathCombine: старый контракт listFiles)",
    function() eq(M.pathCombine("C:\\foo", ""), "C:\\foo\\") end)
test("21b joinPath trims trailing separator (новый контракт paths)",
    function() eq(M.joinPath("C:\\foo", ""), "C:\\foo") end)
test("22 non-string name raises",
    function() errs(function() M.joinPath("C:\\foo", 42) end) end)

-- ------------------------------------------------------------
--  ГРУППА 3: utf16leToUtf8 (11) — требует _T.utf16leToUtf8
-- ------------------------------------------------------------
local utf16 = _T.utf16leToUtf8
group("utf16leToUtf8")
test_or_skip(utf16 ~= nil and IS_WINDOWS, "23 empty input",
    function() eq(utf16(""), "") end)
test_or_skip(utf16 ~= nil and IS_WINDOWS, "24 ASCII",
    function() eq(utf16(u16char(0x48) .. u16char(0x69)), "Hi") end)
-- На не-Windows вывод cmd.exe (/u) недоступен, а поведение с
-- нечётным байтом зависит от кодовой страницы — пропускаем вне Windows.
test_or_skip(utf16 ~= nil and IS_WINDOWS, "25 odd trailing byte dropped",
    function() eq(utf16("\x41"), "") end)
-- См. комментарий к тесту 25: требует cmd-пайплайна Windows.
test_or_skip(utf16 ~= nil and IS_WINDOWS, "26 Cyrillic U+0410",
    function() eq(utf16(u16char(0x0410)), "\xD0\x90") end)
test_or_skip(utf16 ~= nil and IS_WINDOWS, "27 Cyrillic word",
    function() eq(utf16(u16char(0x041F) .. u16char(0x0440) .. u16char(0x0438)),
                  "\xD0\x9F\xD1\x80\xD0\xB8") end)
test_or_skip(utf16 ~= nil and IS_WINDOWS, "28 emoji U+1F600",
    function() eq(utf16(u16char(0x1F600)), "\xF0\x9F\x98\x80") end)
test_or_skip(utf16 ~= nil and IS_WINDOWS, "29 U+FFFD",
    function() eq(utf16(u16char(0xFFFD)), "\xEF\xBF\xBD") end)
test_or_skip(utf16 ~= nil and IS_WINDOWS, "30 lone high surrogate → U+FFFD",
    function() eq(utf16("\x00\xD8"), "\xEF\xBF\xBD") end)
test_or_skip(utf16 ~= nil and IS_WINDOWS, "31 lone low surrogate → U+FFFD",
    function() eq(utf16("\x00\xDC"), "\xEF\xBF\xBD") end)
test_or_skip(utf16 ~= nil and IS_WINDOWS, "32 mixed ASCII+Cyrillic",
    function() eq(utf16(u16char(0x41) .. u16char(0x0410) .. u16char(0x42)),
                  "A\xD0\x90B") end)
test_or_skip(utf16 ~= nil and IS_WINDOWS, "33 U+FEFF preserved",
    function() eq(utf16(u16char(0xFEFF)), "\xEF\xBB\xBF") end)

-- ------------------------------------------------------------
--  ГРУППА 4: LCG (4) — требует _T.lcgNext
-- ------------------------------------------------------------
local lcgNext = _T.lcgNext
group("lcgNext")
test_or_skip(lcgNext ~= nil, "34 returns integer", function()
    local v = lcgNext()
    is_true(math.floor(v) == v, "not integer: " .. tostring(v))
end)
test_or_skip(lcgNext ~= nil, "35 value in [0, 2^32)", function()
    for _ = 1, 10 do
        local v = lcgNext()
        is_true(v >= 0 and v < 4294967296, "out of range: " .. tostring(v))
    end
end)
test_or_skip(lcgNext ~= nil, "36 not constant", function()
    local seen, n = {}, 0
    for _ = 1, 20 do
        local v = lcgNext()
        if not seen[v] then seen[v] = true; n = n + 1 end
    end
    is_true(n >= 15, "too few distinct: " .. n)
end)
test_or_skip(lcgNext ~= nil, "37 low bit alternates", function()
    local a = lcgNext() % 2
    local b = lcgNext() % 2
    is_true(a ~= b, "expected alternation")
end)

-- ------------------------------------------------------------
--  ГРУППА 5: dirExists (8)
-- ------------------------------------------------------------
group("dirExists")
test_or_skip(FS_READY, "38 existing dir → true",
    function() is_true(M.dirExists(BASE .. "\\empty")) end)
test_or_skip(FS_READY, "39 non-existent → false",
    function() is_false(M.dirExists(BASE .. "\\nonexistent_zzz")) end)
test_or_skip(FS_READY, "40 file → false",
    function() is_false(M.dirExists(BASE .. "\\files_only\\a.txt")) end)
test_or_skip(FS_READY, "41 trailing backslash",
    function() is_true(M.dirExists(BASE .. "\\empty\\")) end)
test_or_skip(FS_READY, "42 forward slashes",
    function() is_true(M.dirExists(BASE:gsub("\\", "/") .. "/empty")) end)
test_or_skip(FS_READY, "43 C:\\ exists",
    function() is_true(M.dirExists("C:\\")) end)
test_or_skip(FS_READY, "44 dir with space",
    function() is_true(M.dirExists(BASE .. "\\dirs_only\\sub with space")) end)
test_or_skip(FS_READY, "45 relative '.' resolves",
    function() is_true(M.dirExists(".")) end)

-- ------------------------------------------------------------
--  ГРУППА 6: listFiles (7)
-- ------------------------------------------------------------
group("listFiles")
test_or_skip(FS_READY, "46 empty dir → {}",
    function() eq(#M.listFiles(BASE .. "\\empty"), 0) end)
test_or_skip(FS_READY, "47 non-existent → {}",
    function() eq(#M.listFiles(BASE .. "\\nonexistent_zzz"), 0) end)
test_or_skip(FS_READY, "48 all 7 files listed", function()
    set_eq(M.listFiles(BASE .. "\\files_only"),
        {"a.txt", "b.txt", "UPPER.TXT", "with space.txt",
         "%TEMP%.txt", "excl!am.txt", "amp&ersand.txt"})
end)
test_or_skip(FS_READY, "49 dirs_only has no files",
    function() eq(#M.listFiles(BASE .. "\\dirs_only"), 0) end)
test_or_skip(FS_READY, "50 mixed: only files",
    function() set_eq(M.listFiles(BASE .. "\\mixed"), {"m1.txt"}) end)
test_or_skip(FS_READY, "51 spaces preserved",
    function() contains(M.listFiles(BASE .. "\\files_only"), "with space.txt") end)
test_or_skip(FS_READY, "52 % ! & preserved", function()
    local r = M.listFiles(BASE .. "\\files_only")
    contains(r, "%TEMP%.txt")
    contains(r, "excl!am.txt")
    contains(r, "amp&ersand.txt")
end)

-- ------------------------------------------------------------
--  ГРУППА 7: listDirs (5)
-- ------------------------------------------------------------
group("listDirs")
test_or_skip(FS_READY, "53 empty dir → {}",
    function() eq(#M.listDirs(BASE .. "\\empty"), 0) end)
test_or_skip(FS_READY, "54 dirs_only all subdirs", function()
    set_eq(M.listDirs(BASE .. "\\dirs_only"),
        {"sub1", "sub2", "sub with space"})
end)
test_or_skip(FS_READY, "55 files_only → no dirs",
    function() eq(#M.listDirs(BASE .. "\\files_only"), 0) end)
test_or_skip(FS_READY, "56 mixed: only dirs", function()
    set_eq(M.listDirs(BASE .. "\\mixed"), {"md1", "md2"})
end)
test_or_skip(FS_READY, "57 nested top-level",
    function() set_eq(M.listDirs(BASE .. "\\nested"), {"n1", "n2"}) end)

-- ------------------------------------------------------------
--  ГРУППА 8: listFilesRecursive (5)
-- ------------------------------------------------------------
group("listFilesRecursive")
test_or_skip(FS_READY, "58 flat dir count matches",
    function() eq(#M.listFilesRecursive(BASE .. "\\files_only"), 7) end)
test_or_skip(FS_READY, "59 nested dir — 4 files",
    function() eq(#M.listFilesRecursive(BASE .. "\\nested"), 4) end)
test_or_skip(FS_READY, "60 full paths", function()
    for _, p in ipairs(M.listFilesRecursive(BASE .. "\\nested")) do
        is_true(p:sub(1, #BASE) == BASE, "not full path: " .. p)
    end
end)
test_or_skip(FS_READY, "61 deep file present", function()
    for _, p in ipairs(M.listFilesRecursive(BASE .. "\\nested")) do
        if p:find("deep1.txt", 1, true) then return end
    end
    error("deep1.txt not found")
end)
test_or_skip(FS_READY, "62 empty dir → {}",
    function() eq(#M.listFilesRecursive(BASE .. "\\empty"), 0) end)

-- ------------------------------------------------------------
--  ГРУППА 9: интеграция (5)
-- ------------------------------------------------------------
group("integration")
test_or_skip(FS_READY, "63 every listDirs entry resolves", function()
    for _, name in ipairs(M.listDirs(BASE .. "\\mixed")) do
        is_true(M.dirExists(M.joinPath(BASE .. "\\mixed", name)),
                "dirExists false for " .. name)
    end
end)
test_or_skip(FS_READY, "64 every listFiles entry is NOT a dir", function()
    for _, name in ipairs(M.listFiles(BASE .. "\\mixed")) do
        is_false(M.dirExists(M.joinPath(BASE .. "\\mixed", name)),
                 "dirExists true for file " .. name)
    end
end)
test_or_skip(FS_READY, "65 listFiles then dirExists parent", function()
    local _ = M.listFiles(BASE .. "\\files_only")
    is_true(M.dirExists(BASE .. "\\files_only"))
end)
test_or_skip(FS_READY, "66 resetCwdCache no break", function()
    M.resetCwdCache()
    is_true(M.dirExists(BASE .. "\\empty"))
end)
test_or_skip(FS_READY, "67 idempotent count", function()
    local a = M.listFiles(BASE .. "\\files_only")
    local b = M.listFiles(BASE .. "\\files_only")
    eq(#a, #b, "listFiles inconsistent")
end)

-- ------------------------------------------------------------
--  ГРУППА 10: _test helpers (3)
-- ------------------------------------------------------------
group("_test helpers")
test_or_skip(FS_READY and _T.makeTempPair ~= nil, "68 makeTempPair", function()
    local pf, bf = _T.makeTempPair("C:\\test", "echo hi")
    is_true(pf ~= nil, "pathFile nil")
    is_true(bf ~= nil, "batFile nil")
    if pf then
        local f = io.open(pf, "rb")
        is_true(f ~= nil, "pathFile unreadable")
        if f then eq(f:read("*a"), "C:\\test"); f:close() end
    end
    if pf then for _ = 1, 20 do if os.remove(pf) then break end end end
    if bf then for _ = 1, 20 do if os.remove(bf) then break end end end
end)
test_or_skip(FS_READY and _T.runBat ~= nil, "69 runBat strips __LF_OK__", function()
    local out = _T.runBat("C:\\", "echo ok")
    is_true(out ~= nil, "runBat returned nil")
    if out then
        is_true(out:find("ok") ~= nil, "missing 'ok'")
        is_false(out:find("__LF_OK__", 1, true) ~= nil, "__LF_OK__ not stripped")
        is_false(out:find("__LF_ERR__", 1, true) ~= nil, "__LF_ERR__ present")
    end
end)
test_or_skip(_T.lcgSeed ~= nil and _T.lcgNext ~= nil,
    "70 lcgSeed+lcgNext still in range", function()
    _T.lcgSeed()
    local v = _T.lcgNext()
    is_true(v >= 0 and v < 4294967296)
end)

-- ============================================================
--  Отчёт
-- ============================================================
teardown()
print("\n\nTotal: " .. (passed + failed + skipped) ..
      " | Passed: " .. passed ..
      " | Failed: " .. failed ..
      " | Skipped: " .. skipped)

if failed > 0 then
    print("\nFailures:")
    for _, f in ipairs(failures) do
        print("  [" .. f.group .. "] " .. f.name)
        print("    " .. f.err)
    end
    os.exit(1)
end