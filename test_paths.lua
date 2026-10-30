-- ============================================================
--  test_paths.lua — тесты для paths.lua
-- ============================================================
--  Windows-only. Запуск (из каталога с paths.lua):
--      lua51 test_paths.lua
--  или:  lua test_paths.lua
--
--  Покрытие:
--    * чистый разбор путей (normalizePath, isAbsolutePath,
--      getFileName, getExtension, getDirName)
--    * склейка (joinPath/pathCombine)
--    * UTF-16LE → UTF-8 (BMP, суррогаты, одиночные суррогаты)
--    * LCG (детерминизм после сброса)
--    * makeAbs (абсолютные/относительные, drive-relative)
--    * getScriptDir с подменой arg[0]
--    * getCwd / resetCwdCache
--    * ФС: fileExists, dirExists, listFiles, listDirs,
--      listFilesRecursive на созданном временном каталоге
-- ============================================================

package.path = package.path .. ";./?.lua"
local paths = require("paths")
local T = paths._test

-- ============================================================
-- Assertion framework
-- ============================================================
local NPass, NFail = 0, 0
local Failures = {}

local function pass() NPass = NPass + 1 end

local function fail(label, actual, expected)
    NFail = NFail + 1
    Failures[#Failures + 1] = string.format("%s\n     expected: %s\n     actual:   %s",
        label, tostring(expected), tostring(actual))
end

local function eq(actual, expected, label)
    if actual == expected then pass() else fail(label, actual, expected) end
end

local function ok(cond, label)
    if cond then pass() else fail(label, "truthy", cond) end
end

local function isNil(v, label)
    if v == nil then pass() else fail(label, v, nil) end
end

local function isNotNil(v, label)
    if v ~= nil then pass() else fail(label, nil, "non-nil") end
end

local function throws(fn, label)
    if pcall(fn) then fail(label, "no error", "error") else pass() end
end

local function dumpArr(a)
    if type(a) ~= "table" then return tostring(a) end
    local parts = {}
    for i, v in ipairs(a) do parts[i] = tostring(v) end
    return "[" .. table.concat(parts, ", ") .. "]"
end

local function arrEq(a, b, label)
    if type(a) ~= "table" or type(b) ~= "table" then
        return fail(label, a, b)
    end
    if #a ~= #b then return fail(label .. " (length)", #a, #b) end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return fail(label .. " [" .. i .. "]", a[i], b[i])
        end
    end
    pass()
end

local function arrHas(a, v, label)
    if type(a) ~= "table" then return fail(label, a, "table") end
    for _, x in ipairs(a) do
        if x == v then return pass() end
    end
    fail(label, dumpArr(a), "contains " .. tostring(v))
end

local function sh(cmd)
    local p = io.popen(cmd, "r")
    if p then p:read("*a"); p:close() end
end

-- ============================================================
-- 1. normalizePath
-- ============================================================
print("== normalizePath ==")

eq(paths.normalizePath("C:\\"),  "C:\\",     "C:\\")
eq(paths.normalizePath("C:"),    "C:\\",     "C:")
eq(paths.normalizePath("C:\\foo"),       "C:\\foo",       "C:\\foo")
eq(paths.normalizePath("C:\\foo\\"),     "C:\\foo",       "trailing \\")
eq(paths.normalizePath("C:/foo/bar"),    "C:\\foo\\bar",  "/ -> \\")
eq(paths.normalizePath("C:\\\\foo\\\\\\\\bar"), "C:\\foo\\bar", "many slashes")
eq(paths.normalizePath("\\\\server\\share"),   "\\\\server\\share", "UNC")
eq(paths.normalizePath("\\\\\\server\\share"), "\\\\server\\share", "UNC 3->2")
eq(paths.normalizePath("\\foo"),  "\\foo",  "\\foo")
eq(paths.normalizePath("/foo"),   "\\foo",  "/foo")
eq(paths.normalizePath("foo"),    "foo",    "relative")
eq(paths.normalizePath("foo/"),   "foo",    "relative trailing /")

throws(function() paths.normalizePath("")  end, "empty")
throws(function() paths.normalizePath(nil) end, "nil")
throws(function() paths.normalizePath(123) end, "number")

-- ============================================================
-- 2. isAbsolutePath
-- ============================================================
print("== isAbsolutePath ==")

ok(paths.isAbsolutePath("C:\\foo"),        "C:\\foo")
ok(paths.isAbsolutePath("C:/foo"),         "C:/foo")
ok(paths.isAbsolutePath("C:\\"),           "C:\\")
ok(paths.isAbsolutePath("\\\\server\\share"), "UNC")
ok(paths.isAbsolutePath("/foo"),           "/foo")
ok(paths.isAbsolutePath("\\foo"),          "\\foo")

ok(not paths.isAbsolutePath("foo"),    "foo")
ok(not paths.isAbsolutePath("C:"),     "C: (drive, no slash)")
ok(not paths.isAbsolutePath("C:foo"),  "C:foo (drive-relative)")
ok(not paths.isAbsolutePath(""),       "empty")
ok(not paths.isAbsolutePath(nil),      "nil")

-- ============================================================
-- 3. getFileName
-- ============================================================
print("== getFileName ==")

eq(paths.getFileName("C:\\"),  "", "C:\\")
eq(paths.getFileName("C:"),    "", "C:")
eq(paths.getFileName("\\"),    "", "\\")
eq(paths.getFileName("/"),     "", "/")
eq(paths.getFileName("\\\\server\\share"),  "", "UNC root")
eq(paths.getFileName("\\\\server\\share\\"),"", "UNC root trailing")
eq(paths.getFileName("C:\\foo.txt"),        "foo.txt", "C:\\foo.txt")
eq(paths.getFileName("C:\\dir\\file"),      "file",    "dir/file")
eq(paths.getFileName("C:\\foo\\"),          "foo",     "trailing \\")
eq(paths.getFileName("foo"),       "foo",     "bare")
eq(paths.getFileName("foo.bar"),   "foo.bar", "dotted")
eq(paths.getFileName("\\\\srv\\shr\\file.txt"), "file.txt", "UNC file")

isNil(paths.getFileName(nil), "nil")

-- ============================================================
-- 4. getExtension
-- ============================================================
print("== getExtension ==")

eq(paths.getExtension("C:\\foo.TXT"),   ".txt", ".TXT lowercased")
eq(paths.getExtension("file.tar.gz"),   ".gz",  "last ext")
eq(paths.getExtension(".config.json"),  ".json",".config.json")
eq(paths.getExtension(".bashrc"),       "",     ".bashrc (dotfile)")
eq(paths.getExtension("a."),            "",     "trailing dot")
eq(paths.getExtension("a.b.c"),         ".c",   "a.b.c")
eq(paths.getExtension("a"),             "",     "no ext")
eq(paths.getExtension("C:\\"),          "",     "root")
eq(paths.getExtension(""),              "",     "empty")

-- ============================================================
-- 5. getDirName
-- ============================================================
print("== getDirName ==")

eq(paths.getDirName("C:"),                  "C:\\",  "C:")
eq(paths.getDirName("C:\\"),                "C:\\",  "C:\\")
eq(paths.getDirName("C:\\foo\\file.txt"),   "C:\\foo", "dir/file")
eq(paths.getDirName("C:\\foo"),             "C:\\",  "C:\\foo -> C:\\")
eq(paths.getDirName("foo"),                 ".",     "bare -> .")
eq(paths.getDirName("/foo"),                "\\",    "/foo -> \\")
eq(paths.getDirName("\\foo"),               "\\",    "\\foo -> \\")
eq(paths.getDirName("C:foo"),               "C:\\",  "drive-relative")
eq(paths.getDirName("\\\\server\\share"),   "\\\\server\\share", "UNC root")
eq(paths.getDirName("\\\\server\\share\\f"),"\\\\server\\share", "UNC file")

isNil(paths.getDirName(nil), "nil")
isNil(paths.getDirName(""),  "empty")

-- ============================================================
-- 6. joinPath / pathCombine
-- ============================================================
print("== joinPath ==")

eq(paths.joinPath("C:\\",   "foo"), "C:\\foo",    "C:\\ + foo")
eq(paths.joinPath("C:\\dir","foo"), "C:\\dir\\foo","C:\\dir + foo")
eq(paths.joinPath("dir",    "foo"), "dir\\foo",   "dir + foo")
eq(paths.joinPath("dir/",   "foo"), "dir\\foo",   "dir/ + foo")
eq(paths.joinPath("dir",    "C:\\abs"), "C:\\abs","absolute b wins")
eq(paths.joinPath("dir",    "\\foo"),   "\\foo",  "rooted b wins")
eq(paths.joinPath(nil,      "foo"), "foo",        "nil + foo")
eq(paths.joinPath("foo",    nil),   "foo",        "foo + nil")
eq(paths.joinPath(nil,      nil),   "",           "nil + nil")
eq(paths.joinPath("",       ""),    "",           "empty + empty")
eq(paths.joinPath("dir",    ""),    "dir",        "dir + empty")

throws(function() paths.joinPath(123, "foo") end, "number a")
throws(function() paths.joinPath("foo", 123) end, "number b")

eq(paths.pathCombine("dir", "foo"), "dir\\foo", "pathCombine basic")
-- pathCombine — режим обратной совместимости со старым listFiles.lua:
-- пустой второй аргумент оставляет хвостовой слэш (joinPath — нет).
eq(paths.pathCombine("dir", ""),    "dir\\",  "pathCombine dir + empty")
eq(paths.pathCombine("dir\\", "x"), "dir\\x", "pathCombine trailing kept")
ok(not (paths.joinPath == paths.pathCombine), "joinPath ~= pathCombine (разные контракты)")

-- ============================================================
-- 7. utf16leToUtf8
-- ============================================================
print("== utf16leToUtf8 ==")

local function u16(s) return T.utf16leToUtf8(s) end

eq(u16("\65\0"),          "A",                "ASCII A")
eq(u16("\48\4"),          "\208\176",         "Cyrillic а (U+0430)")
eq(u16("\45\78"),         "\228\184\173",     "CJK 中 (U+4E2D)")
eq(u16("\61\216\0\222"),  "\240\159\152\128", "😀 U+1F600 surrogate pair")
eq(u16("\61\216"),        "\239\191\189",     "lone high surrogate")
eq(u16("\0\222"),         "\239\191\189",     "lone low surrogate")
eq(u16(""),               "",                 "empty")
eq(u16("\0\0"),           "\0",               "null char")
eq(u16("\65\0\66"),       "A",                "trailing odd byte ignored")

-- ============================================================
-- 8. LCG
-- ============================================================
print("== LCG ==")

T.lcgReset()
eq(T.lcgNext(), 1013904223, "first after reset (state = 0)")

T.lcgReset(); local a1, a2 = T.lcgNext(), T.lcgNext()
T.lcgReset(); local b1, b2 = T.lcgNext(), T.lcgNext()
ok(a1 == b1 and a2 == b2, "deterministic after reset")

T.lcgReset()
local s1, s2 = T.lcgNext(), T.lcgNext()
ok(s1 ~= s2,                     "sequence advances")
ok(s1 >= 0 and s1 < 4294967296,  "in 32-bit range")

-- ============================================================
-- 9. makeAbs
-- ============================================================
print("== makeAbs ==")

local abs = T.makeAbs

eq(abs("C:\\foo"),            "C:\\foo",            "already absolute")
eq(abs("\\\\srv\\share\\x"),  "\\\\srv\\share\\x",  "UNC absolute")
eq(abs("C:"),                 "C:\\",               "C: root")
eq(abs("D:foo"),              "D:\\foo",            "D: drive-relative")
eq(abs("D:\\some\\path"),     "D:\\some\\path",     "D: absolute")

local cwd = paths.getCwd()
if cwd then
    isNotNil(cwd:match("^%a:"), "cwd has drive letter")

    local rel = abs("foo\\bar")
    isNotNil(rel, "makeAbs(relative)")
    if rel then
        eq(rel:match("^(%a:)"), cwd:match("^(%a:)"), "relative -> same drive as CWD")
        ok(rel:match("foo\\bar$") ~= nil, "relative tail preserved")
    end

    local up = abs("..")
    isNotNil(up, "makeAbs(..)")
    if up then
        eq(up:match("^(%a:)"), cwd:match("^(%a:)"), "makeAbs(..) stays on drive")
    end

    eq(abs("\\foo"), cwd:match("^(%a:)") .. "\\foo", "\\foo uses CWD drive")
else
    print("  (skipped CWD-dependent: getCwd() returned nil)")
end

-- ============================================================
-- 10. getScriptDir с подменой arg
-- ============================================================
print("== getScriptDir ==")

local _savedArg = arg

arg = { [0] = "renamer.lua" }
local sd1 = paths.getScriptDir()
isNotNil(sd1, "arg[0] = filename")
if cwd then eq(sd1, cwd, "arg[0] = filename → CWD") end

arg = { [0] = "sub\\renamer.lua" }
local sd2 = paths.getScriptDir()
isNotNil(sd2, "arg[0] with subdir")
if sd2 and cwd then
    ok(sd2:match("sub$") ~= nil, "subdir appended to CWD")
end

arg = { [0] = "C:\\prog\\renamer.lua" }
eq(paths.getScriptDir(), "C:\\prog", "arg[0] absolute path")

arg = { [0] = "C:\\renamer.lua" }
eq(paths.getScriptDir(), "C:\\", "arg[0] at drive root")

arg = { [0] = nil }; local sd3 = paths.getScriptDir()
isNotNil(sd3, "arg[0] = nil → CWD")

arg = { [0] = "" };  local sd4 = paths.getScriptDir()
isNotNil(sd4, "arg[0] = empty → CWD")

arg = _savedArg

-- ============================================================
-- 11. getCwd / resetCwdCache
-- ============================================================
print("== getCwd ==")

if cwd then
    isNotNil(cwd:match("^%a:"),       "cwd starts with drive")
    eq(paths.getCwd(), cwd,           "cached: same value")

    paths.resetCwdCache()
    local c2 = paths.getCwd()
    eq(c2, cwd, "after reset: same value")
else
    print("  (skipped: getCwd() returned nil)")
end

-- ============================================================
-- 12. Filesystem (создаём временный каталог)
-- ============================================================
print("== Filesystem ==")

local tmp = os.getenv("TEMP") or os.getenv("TMP")
if not tmp then
    print("  (skipped: TEMP/TMP not set)")
else
    tmp = tmp:gsub("\\+$", "")
    local testDir = tmp .. "\\_paths_test_" .. os.time()

    -- Вдруг осталось от упавшего прогона
    sh('rmdir /s /q "' .. testDir .. '" 2>nul')
    sh('mkdir "' .. testDir .. '" 2>nul')
    sh('mkdir "' .. testDir .. '\\sub" 2>nul')
    sh('mkdir "' .. testDir .. '\\subdir" 2>nul')

    local function wf(name, content)
        local f = io.open(testDir .. "\\" .. name, "wb")
        if not f then return false end
        f:write(content); f:close(); return true
    end
    wf("file1.txt",  "hello")
    wf("file2.lua",  "return 1")
    wf("sub\\file3.txt", "world")

    -- dirExists -------------------------------------------------
    ok(paths.dirExists(testDir),                           "dirExists(testDir)")
    ok(paths.dirExists(testDir .. "\\sub"),                "dirExists(sub)")
    ok(not paths.dirExists(testDir .. "\\nonexistent"),    "dirExists missing")
    ok(not paths.dirExists(testDir .. "\\file1.txt"),      "dirExists on file -> false")

    -- fileExists ------------------------------------------------
    ok(paths.fileExists(testDir .. "\\file1.txt"),         "fileExists(file1)")
    ok(paths.fileExists(testDir .. "\\file2.lua"),         "fileExists(file2)")
    ok(paths.fileExists(testDir .. "\\sub\\file3.txt"),    "fileExists(sub/file3)")
    ok(not paths.fileExists(testDir .. "\\nope.txt"),      "fileExists missing")
    ok(not paths.fileExists(testDir),                      "fileExists on dir -> false")

    -- forward slashes: модуль должен нормализовать -------------
    ok(paths.fileExists(testDir .. "/file1.txt"),          "fileExists via /")

    -- listFiles -------------------------------------------------
 local lf = paths.listFiles(testDir)
ok(#lf >= 2,                          "listFiles non-empty")
arrHas(lf, "file1.txt",               "listFiles has file1")
arrHas(lf, "file2.lua",               "listFiles has file2")

-- listFiles должен содержать ТОЛЬКО файлы (dir /b /a-d):
-- каталоги sub и subdir сюда попасть не должны.
local hasDir = false
for _, v in ipairs(lf) do
    if v == "sub" or v == "subdir" then hasDir = true end
end
ok(not hasDir, "listFiles excludes directories")
    -- sub/file3.txt НЕ должен быть в нерекурсивном листинге
    local foundRec = false
    for _, v in ipairs(lf) do
        if v == "sub\\file3.txt" or v == "sub/file3.txt" then foundRec = true end
    end
    ok(not foundRec, "listFiles is non-recursive")

    -- listFiles non-existent / empty
    arrEq(paths.listFiles(testDir .. "\\nope"), {}, "listFiles missing -> {}")
    arrEq(paths.listFiles(testDir .. "\\subdir"), {}, "listFiles empty -> {}")

    -- listDirs --------------------------------------------------
    local ld = paths.listDirs(testDir)
    ok(#ld >= 2,              "listDirs non-empty")
    arrHas(ld, "sub",         "listDirs has sub")
    arrHas(ld, "subdir",      "listDirs has subdir")
    -- Файлы в listDirs попасть не должны
    local hasFile = false
    for _, v in ipairs(ld) do
        if v == "file1.txt" or v == "file2.lua" then hasFile = true end
    end
    ok(not hasFile, "listDirs excludes files")

    -- listFilesRecursive ---------------------------------------
    local lr = paths.listFilesRecursive(testDir)
    ok(#lr >= 3, "listFilesRecursive non-empty")
    local byName = {}
    for _, p in ipairs(lr) do
        local n = paths.getFileName(p)
        byName[n] = p
    end
    isNotNil(byName["file1.txt"],         "recursive has file1")
    isNotNil(byName["file2.lua"],         "recursive has file2")
    isNotNil(byName["file3.txt"],         "recursive has file3 (в подпапке)")
    if byName["file3.txt"] then
        ok(byName["file3.txt"]:match("sub") ~= nil,
           "file3 path contains 'sub'")
        -- full path returned, not just name
        ok(byName["file3.txt"]:match("^%a:") ~= nil,
           "recursive entries are full paths")
    end

    -- cleanup --------------------------------------------------
    sh('rmdir /s /q "' .. testDir .. '" 2>nul')
end

-- ============================================================
-- Summary
-- ============================================================
print("")
print(string.rep("-", 60))
print(string.format("PASS: %d   FAIL: %d   (total %d)",
    NPass, NFail, NPass + NFail))
print(string.rep("-", 60))
if NFail > 0 then
    print("")
    print("Failures:")
    for _, msg in ipairs(Failures) do
        print("  * " .. msg)
    end
    os.exit(1)
end
os.exit(0)