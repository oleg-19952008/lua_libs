-- ============================================================
--  paths.lua — Windows-only, Lua 5.1.4+, pure Lua
-- ============================================================
--
--  Универсальный модуль для работы с путями и ФС на Windows:
--  разбор путей, листинг каталогов, проверка существования,
--  CWD процесса и каталог скрипта.
--
--  Публичный API:
--
--    Разбор путей (чистые функции, без доступа к ФС):
--      M.normalizePath(path)     -> нормализованный путь (assert на мусор)
--      M.isAbsolutePath(path)    -> boolean (см. оговорку про "\foo")
--      M.getFileName(path)       -> имя файла или "" для корня
--      M.getExtension(path)      -> ".ext" в нижнем регистре или ""
--      M.getDirName(path)        -> каталог (без имени файла)
--
--    Склейка:
--      M.joinPath(dir, name)     -> нормализованный путь (nil-толерантен)
--      M.pathCombine(a, b)       -> алиас joinPath (обратная совместимость)
--
--    Среда:
--      M.getCwd()                -> CWD процесса (кэш; для корня диска "C:\")
--      M.resetCwdCache()         -> сброс кэша CWD после chdir из хоста
--      M.getScriptDir()          -> каталог, из которого запущен скрипт
--
--    ФС:
--      M.fileExists(path)        -> boolean (только регулярные файлы)
--      M.dirExists(path)         -> boolean (только папки)
--      M.listFiles(dir)          -> массив имён файлов, без рекурсии
--      M.listFilesRecursive(dir) -> массив ПОЛНЫХ путей, рекурсивно
--      M.listDirs(dir)           -> массив имён подпапок, без рекурсии
--
--  КОДИРОВКИ:
--    Входные пути ожидаются в UTF-8. Конвертация из ANSI/CP1251 —
--    на вызывающем. os.getenv("TEMP") для кириллических юзеров
--    возвращает ACP-байты — для temp-каталога это ок (fopen/cmd
--    интерпретируют как ACP), но НЕ смешивайте arg[1] (ACP) с
--    путями, которые вы передаёте в M.listFiles.
--    ИСКЛЮЧЕНИЕ — arg[0] в M.getScriptDir: он приходит в ACP,
--    а runBat/makeAbs ждут UTF-8 (см. комментарий к функции).
--
--  Почему не `io.popen('dir /b "path"')`:
--    * OEM-кодировка вывода → кракозябры. `cmd /u` даёт UTF-16LE,
--      декодируем в UTF-8 сами.
--    * %VAR% в пути раскрывается cmd'ом даже в кавычках. Путь
--      уходит в файл, читается через `set /p P=<...`.
--    * Спецсимволы & | < > ^ " — в .bat внутри "..." литералы;
--      %P% подставляется однократно (`/v:off` — ! не тронут).
--    * Построчный dir /b терял ведущие пробелы. Сейчас разделитель
--      — \r\n в UTF-16LE (в именах Windows запрещён), пробелы целы.
--    * pipe читается в режиме "rb": в UTF-16LE любой ASCII-символ
--      содержит байт 0x00, текстовый режим fread на Windows обрезает
--      поток на первом нуле — вывод терялся целиком сразу после BOM
--      ("\xFF\xFE"), и dirExists всегда возвращал false.
--    * UTF-8 BOM ("EF BB BF") в выводе cmd /u невозможен: весь raw
--      — UTF-16LE, его BOM (FF FE) снимается в runBat. Поэтому в
--      listEntries фильтруется только мусор с управляющим первым
--      байтом (< 0x20); по первому байту 0xEF строки НЕ отбрасываются
--      — это валидное начало UTF-8 для U+F000–U+FFFF (ＦＵＬＬＷＩＤＴＨ
--      "Ａ", CJK-совместимость "豈", PUA), иначе имена таких файлов
--      молча исчезали бы из листинга.
--    * Литералы "%VAR%" в целевом пути: путь уходит в temp-файл,
--      set /p читает его побайтово (без раскрытия), а внутри .bat
--      путь попадает в команды ТОЛЬКО через подстановку %P%.
--      Командный процессор раскрывает переменные однократно при
--      парсинге строки и НЕ делает второго прохода по значению
--      переменной — литерал "%TEMP%" внутри %P% остаётся литералом.
--      Кавычки вокруг "%P%" защищают & | < > ^, флаг /v:off — ! от
--      delayed expansion. Относительные пути резолвятся лексически
--      относительно CWD процесса до записи в temp-файл.
--
--  Temp-файлы и коллизии:
--    Имя = "_lf_" + 16 hex (два вызова локального LCG по 32-бита,
--    каждый форматируется как две 16-битные половины: %04x%04x).
--    %08x в MSVC/Lua 5.1 может приводить 32-битный C-int к UB на
--    значениях ≥ 2^31 (на x86 часто 80000000; на x64 поведение
--    зависит от инструкций) — такой формат не используется.
--    Seed = os.time + os.clock() (мкс) + %RANDOM%³ (если io.popen
--    доступен; иначе только os.time + os.clock). Финальный
--    `% 2^32` режет seed до 32 бит, поэтому уникальных имён на
--    процесс не более 2^32, а межпроцессная коллизия — ~2^-32
--    (при совпадении seed'ов два процесса дадут одинаковую
--    последовательность имён). %RANDOM%³ добавляет до ~45 бит
--    энтропии, но большая часть теряется на `% 2^32`.
--    После записи содержимое сверяется чтением — от подмены во
--    время записи. Микро-TOCTOU между verify и popen остаётся:
--    для привилегированных сценариев на общем TEMP — закрывать
--    нативным CreateFile с SECURITY_ATTRIBUTES.
--
--  Ограничения:
--    * Windows-only; io.popen; chcp 65001 надёжен на Win10/11.
--    * Каждый вызов listXxx / dirExists / fileExists — spawn cmd
--      и два temp-файла; на порядок медленнее прямого dir /b.
--      Для тысяч вызовов — кэшируйте у себя.
--    * fileExists: `if exist` возвращает true для устройств
--      NUL, CON, PRN, AUX, COM1.. и т.п. — это ограничение
--      `if exist`, без нативных вызовов не обходится. Для
--      «настоящих» файлов работает корректно (включая нечитаемые
--      и занятые эксклюзивно — проверка идёт в обход fopen).
--    * Нет таймаута на io.popen: висящий UNC-шаринг подвесит
--      вызов (в 5.1 без C-модуля нерешаемо).
--    * p:read("*a") держит вывод целиком (пик ~2–3×). Огромные
--      деревья — обход через listDirs.
--    * Путь > 1023 символов обрезается `set /p`.
--    * Метаданных (size/mtime) нет — только имена и пути.
--    * Контракт listXxx: {} и для несуществующей, и для пустой
--      папки. Нужно различать — вызывающий проверяет dirExists
--      перед listFiles (или после, если {} — ожидаемый случай).
--    * Относительные пути разрешаются относительно CWD процесса
--      (тот же базовый каталог, что у io.open/fopen). CWD кэши-
--      руется на процесс; если хост меняет рабочий каталог через
--      lfs.chdir/FFI — вызовите M.resetCwdCache(), иначе модуль
--      будет резолвить относительные пути по устаревшему CWD.
--      os.execute("cd ...") на родителя не влияет и сброса не требует.
--    * Пути вида "D:" (диск без слэша, отличный от текущего) cmd
--      разрешает по запомненным текущим директориям дисков —
--      используйте явный "D:\".
--    * dirExists через pushd на UNC временно мапит диск — побочный
--      эффект + задержка; без нативных вызовов неизбежно.
--    * В GUI-хосте каждый io.popen может мигать консольным окном
--      (CREATE_NO_WINDOW недоступен без FFI/C-модуля).
--
--  Идеал при разрешённых C-модулях: lfs.dir + lfs.attributes,
--  либо LuaJIT FFI + FindFirstFileW.
-- ============================================================

local M = {}

-- ============================================================
--  1. Разбор путей (чистые функции, без доступа к ФС)
-- ============================================================

local function normalizePath(path)
    assert(type(path) == "string", "normalizePath: path must be a string")
    assert(path ~= "",                "normalizePath: path must not be empty")

    path = path:gsub("%/", "\\")

    if path:match("^\\\\") then
        local tail = path:gsub("[\\\\]+", "\\")
        path = "\\\\" .. tail:gsub("^\\+", "")
    else
        path = path:gsub("[\\\\]+", "\\")
    end

    if path:match("^%a:\\?$") then
        return path:sub(1, 2) .. "\\"
    end

    local trimmed = path:gsub("\\+$", "")
    if trimmed == "" then return path end
    return trimmed
end

-- isAbsolutePath отвечает на вопрос «путь начинается с якоря?»,
-- НО не на вопрос «путь полностью определён без CWD?».
-- "\foo" и "/foo" — это корень ТЕКУЩЕГО диска: чтобы получить
-- полный путь, нужен CWD (см. makeAbs). makeAbs обрабатывает
-- их в отдельной ветке; isAbsolutePath("\\foo") == true — это
-- осознанно: для чистого разбора строк без ФС такое соглашение
-- удобно, но вызывающий должен помнить, что резолв всё равно
-- требует CWD.
local function isAbsolutePath(path)
    if type(path) ~= "string" or path == "" then return false end
    if path:match("^%a:[/\\]")    then return true end  -- C:\ or C:/
    if path:match("^[/\\][/\\]")  then return true end  -- UNC
    if path:match("^[/\\]")       then return true end  -- корень текущего диска
    return false
end

local function getFileName(path)
    if type(path) ~= "string" then return nil end
    -- Корни не имеют компонента-имени: "C:\", "C:", "\\", "/", UNC-корень.
    if path:match("^%a:[\\/]?$") then return "" end
    if path:match("^[\\/]+$")    then return "" end
    -- UNC-корень "\\server\share" (с опциональным хвостовым слэшем) —
    -- тоже корень, не файл.
    if path:match("^\\\\[^\\/]+[\\/][^\\/]+[\\/]?$") then return "" end

    local trimmed = path:gsub("[\\/]+$", "")
    if trimmed == "" then return "" end
    return trimmed:match("([^\\/]+)$") or trimmed
end

--  Расширение — от последней точки до конца, при условиях:
--    * точка не в позиции 1 (иначе ".bashrc" — dotfile, ext = "");
--    * за точкой что-то есть (иначе "a." — trailing dot, ext = "").
--  Примеры:
--    "file.tar.gz"     -> ".gz"
--    ".config.json"    -> ".json"
--    ".bashrc"         -> ""
--    "a."              -> ""
--    "a.b.c"           -> ".c"
local function getExtension(path)
    local name = getFileName(path)
    if not name or name == "" then return "" end
    local dot = name:find("%.[^%.]*$")
    if not dot then return "" end
    if dot == 1       then return "" end   -- .bashrc
    if dot == #name   then return "" end   -- a.
    return name:sub(dot):lower()
end

local function getDirName(path)
    if type(path) ~= "string" or path == "" then return nil end
    -- Корень диска: "C:" / "C:\" -> "C:\"
    if path:match("^%a:[\\/]?$") then
        return path:sub(1, 2) .. "\\"
    end

    local trimmed = path:gsub("[\\/]+$", "")
    if trimmed == "" then return "\\" end           -- "/" или "\"

    -- UNC-корень "\\server\share" — родитель для его содержимого
    -- не "\\server", а он сам (\\server — не каталог, а хост).
    if trimmed:match("^\\\\[^\\/]+[\\/][^\\/]+$") then
        return trimmed
    end

    -- Drive-relative: "C:foo" -> "C:\" (родитель — корень C:).
    -- Без этого general-ветка ниже не находит слэш и даёт ".".
    if trimmed:match("^%a:[^\\/]") then
        return trimmed:sub(1, 2) .. "\\"
    end

    local dir = trimmed:match("^(.*)[\\/][^\\/]*$")
    if dir == nil then return "." end               -- имя без каталога
    if dir == "" then return "\\" end               -- "/foo" -> "\"
    if dir:match("^%a:$") then return dir .. "\\" end
    return dir
end

-- ============================================================
--  2. Локальный LCG — не трогаем глобальный math.random
-- ============================================================
--  Хост мог засидить math.random для воспроизводимости тестов/
--  симуляций. Пересев из библиотеки — дурной тон. Здесь свой
--  32-битный LCG; 32-битная арифметика точна в Lua 5.1 (double,
--  53 бита мантиссы).
--  ВНИМАНИЕ: как и у любого LCG mod 2^k с нечётным инкрементом,
--  младший бит lcgNext() чередуется с периодом 2, старшие биты
--  короткого хвоста имеют заметные корреляции. Здесь это безвредно
--  (нужна лишь уникальность имени temp-файла на процесс). Для
--  любых других целей (выбор, симуляция, криптография) — НЕ
--  использовать.

local lcgState = 0
local lcgSeeded = false

local function lcgNext()
    lcgState = (lcgState * 1664525 + 1013904223) % 4294967296
    return lcgState
end

local function lcgSeed()
    if lcgSeeded then return end
    lcgSeeded = true

    local entropy = 0
    if io.popen then
        local p = io.popen(
            "cmd /c echo %RANDOM%%RANDOM%%RANDOM% & echo %RANDOM%%RANDOM%%RANDOM% 2>nul",
            "r")
        if p then
            local a = p:read("*l")
            local b = p:read("*l")
            p:close()
            local na, nb = tonumber(a), tonumber(b)
            if na then entropy = na end
            if nb then entropy = (entropy + nb * 31) % 4294967296 end
        end
    end

    lcgState = (os.time()
        + math.floor((os.clock() or 0) * 1000000)
        + entropy) % 4294967296
    for _ = 1, 8 do lcgNext() end
end
-- Переименование через cmd (UTF-16LE-путь переживает кириллицу).
-- newName — только имя файла, без каталога, и только [A-Za-z0-9_-] + расширение:
-- это единственное, что вписывается в тело .bat; старый путь идёт через %P%.

-- ============================================================
--  3. UTF-16LE -> UTF-8
-- ============================================================

local function utf16leToUtf8(s)
    local out, i, n = {}, 1, #s
    while i + 1 <= n do
        local code = s:byte(i) + s:byte(i + 1) * 256
        i = i + 2
        if code >= 0xD800 and code <= 0xDBFF and i + 1 <= n then
            local lo2 = s:byte(i) + s:byte(i + 1) * 256
            if lo2 >= 0xDC00 and lo2 <= 0xDFFF then
                code = 0x10000 + (code - 0xD800) * 0x400 + (lo2 - 0xDC00)
                i = i + 2
            end
        end
        if code >= 0xD800 and code <= 0xDFFF then
            code = 0xFFFD  -- одиночный суррогат → replacement char
        end
        if code < 0x80 then
            out[#out + 1] = string.char(code)
        elseif code < 0x800 then
            out[#out + 1] = string.char(
                0xC0 + math.floor(code / 0x40),
                0x80 + code % 0x40)
        elseif code < 0x10000 then
            out[#out + 1] = string.char(
                0xE0 + math.floor(code / 0x1000),
                0x80 + math.floor(code / 0x40) % 0x40,
                0x80 + code % 0x40)
        else
            out[#out + 1] = string.char(
                0xF0 + math.floor(code / 0x40000),
                0x80 + math.floor(code / 0x1000) % 0x40,
                0x80 + math.floor(code / 0x40) % 0x40,
                0x80 + code % 0x40)
        end
    end
    return table.concat(out)
end

-- ============================================================
--  4. Temp: безопасный каталог, запись с verify, очистка
-- ============================================================

local function isSafeDir(d)
    return type(d) == "string"
       and d ~= ""
       and not d:find("[%%!]", 1, false)
end

local function tempCandidates()
    local c = {}
    local t = os.getenv("TEMP"); if t then c[#c + 1] = t end
    local u = os.getenv("TMP");  if u then c[#c + 1] = u end
    local p = os.getenv("USERPROFILE")
    if p then c[#c + 1] = p .. "\\AppData\\Local\\Temp" end
    c[#c + 1] = "C:\\Windows\\Temp"
    return c
end

local function writeAndVerify(path, content)
    local f = io.open(path, "wb")
    if not f then return false end
    local ok = pcall(function() f:write(content) end)
    f:close()
    if not ok then return false end
    local r = io.open(path, "rb")
    if not r then return false end
    local back = r:read("*a")
    r:close()
    return back == content
end

local function removeWithRetry(path)
    for i = 1, 4 do
        if os.remove(path) then return true end
        if i < 4 then
            local t = os.clock()
            while os.clock() - t < 0.02 do end
        end
    end
    return false
end

local function makeTempPair(pathContent, batBody)
    lcgSeed()
    for _, dir in ipairs(tempCandidates()) do
        if isSafeDir(dir) then
            dir = dir:gsub("\\+$", "")
            if dir ~= "" then
                for _ = 1, 5 do
                    local a, b = lcgNext(), lcgNext()
                    local base = string.format("_lf_%04x%04x%04x%04x",
                        math.floor(a / 65536), a % 65536,
                        math.floor(b / 65536), b % 65536)
                    local pathFile = dir .. "\\" .. base .. ".tmp"
                    local batFile  = dir .. "\\" .. base .. ".bat"

                    -- %~dp0 в .bat = каталог самого батника: путь к
                    -- temp-файлу не интерполируется в тело (иначе
                    -- TEMP с % или ! сломал бы парсинг).
                    -- chcp 65001 + 2>&1 — не шумим в stderr хоста.
                    --
                    -- set "P=" перед set /p: у хоста в окружении
                    -- могла остаться переменная P от предыдущего
                    -- сценария. Без сброса при провале set /p
                    -- (temp-файл исчез/битый) P сохранит чужое
                    -- значение, if not defined P не сработает, и
                    -- dir пойдёт по чужому пути.
                    --
                    -- __LF_ERR__ печатается отдельной строкой без
                    -- `&`-склейки: `echo __LF_ERR__ & exit /b 1`
                    -- дал бы хвостовой пробел в маркере (echo
                    -- включает всё до `&`), и проверка в runBat
                    -- промахнулась бы. Две отдельные строки с
                    -- одинаковым условием эквивалентны и чище.
                    local bat =
                        "@echo off\r\n" ..
                        "chcp 65001 >nul 2>&1\r\n" ..
                        'set "P="\r\n' ..
                        'set /p P=<"%~dp0' .. base .. '.tmp" 2>nul\r\n' ..
                        "if not defined P echo __LF_ERR__\r\n" ..
                        "if not defined P exit /b 1\r\n" ..
                        batBody .. "\r\n" ..
                        "echo __LF_OK__\r\n"

                    if writeAndVerify(pathFile, pathContent)
                       and writeAndVerify(batFile, bat) then
                        return pathFile, batFile
                    end
                    removeWithRetry(pathFile)
                    removeWithRetry(batFile)
                end
            end
        end
    end
    return nil, nil
end

-- ============================================================
--  5. CWD процесса (UTF-16LE через cmd /u, кэш на процесс)
-- ============================================================
--  `cmd /u /c cd`: /u форсирует UTF-16LE независимо от ACP/OEM
--  консоли, иначе кириллица в CWD шла бы в temp-файл в CP866 и
--  читалась под chcp 65001 как мусор.
--  Хвостовой "\" снимаем, но у корня диска его восстанавливаем:
--  "C:" в Windows = «текущая директория на C:», а "C:\" = корень;
--  для публичного API ожидаемо именно "C:\".

local cachedCwd

local function processCwd()
    if cachedCwd then return cachedCwd end
    local f = io.popen("cmd /u /c cd", "rb")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then return nil end
    if raw:sub(1, 2) == "\255\254" then raw = raw:sub(3) end
    local cwd = utf16leToUtf8(raw):gsub("[\r\n]+$", "")
    if cwd == "" then return nil end
    cwd = cwd:gsub("[\\/]+$", "")
    -- Корень диска: не "C:", а "C:\".
    if cwd:match("^%a:$") then cwd = cwd .. "\\" end
    if cwd == "" then return nil end
    cachedCwd = cwd
    return cachedCwd
end

local function resetCwdCache()
    cachedCwd = nil
end

-- ============================================================
--  6. Лексическое разрешение путей относительно CWD
-- ============================================================
--  Резолвим в Lua, а не внутри bat: bat лежит в temp и его %CD%
--  указывал бы на temp-каталог, а не на рабочий каталог вызывающего.
--  Неудача popen НЕ кэшируется (см. processCwd).

local function makeAbs(path)
    path = normalizePath(path)

    -- уже абсолютный (буква диска со слэшем или UNC)?
    if path:match("^%a:[\\]") or path:match("^\\\\") then
        return path
    end

    -- "\foo" — корень текущего диска (после normalizePath "/foo"
    -- тоже приходит сюда). Должно стоять до ветки "C:foo" ниже:
    -- иначе сегмент foo приклеится к CWD и получится C:\cwd\foo.
    if path:match("^\\") then
        local cwd = processCwd()
        if not cwd then return nil end
        local drive = cwd:match("^(%a:)")
        if not drive then return nil end
        return drive .. path
    end

    -- корень диска "C:" без слэша -> "C:\"
    if path:match("^%a:$") then
        return path .. "\\"
    end

    -- "C:foo" — drive-relative с хвостом: семантику cmd (текущая
    -- директория диска, известная только ядру) без нативных
    -- вызовов повторить нельзя; консервативно трактуем как "C:\foo".
    local drive = path:match("^(%a):")
    if drive and path:sub(2, 2) == ":" then
        local rest = path:sub(3):gsub("^\\+", "")
        local joined = drive .. ":\\" .. rest
        if #joined > 3 then
            joined = joined:gsub("\\+$", "")
        end
        return joined
    end

    -- обычный относительный путь: склеиваем с CWD процесса и
    -- лексически снимаем "." / ".." (без доступа к диску).
    local cwd = processCwd()
    if not cwd then return nil end

    local stack = {}
    for seg in cwd:gmatch("[^\\/]+") do stack[#stack + 1] = seg end
    for seg in path:gmatch("[^\\/]+") do
        if seg == "." then
            -- skip
        elseif seg == ".." then
            if #stack > 1 then table.remove(stack) end
        else
            stack[#stack + 1] = seg
        end
    end
    local joined = table.concat(stack, "\\")
    if joined:match("^%a:[^\\]") then
        joined = joined:sub(1, 2) .. "\\" .. joined:sub(3)
    end
    return joined
end

-- ============================================================
--  7. Каталог скрипта
-- ============================================================
--  arg[0] = "renamer.lua"          → processCwd()
--  arg[0] = "sub\renamer.lua"      → processCwd()\sub
--  arg[0] = "C:\prog\renamer.lua"  → C:\prog
--  arg[0] = "C:\renamer.lua"       → C:\
--  arg[0] = nil / ""               → processCwd() (или ".")
--
--  ВАЖНО (кодировка): arg[0] приходит от ОС в ACP (Lua на Windows
--  собран с ANSI entry point). makeAbs/runBat ждут UTF-8. Если
--  каталог запуска содержит не-ASCII символы и arg[0] содержит
--  компонент пути (а не только имя файла), результат может
--  содержать байты ACP там, где остальной модуль ждёт UTF-8.
--  Fast-path ниже покрывает самый частый случай — arg[0] без
--  слэшей ("renamer.lua", запуск из CWD): тогда arg[0] как путь
--  вообще не используется, и getScriptDir возвращает чистый
--  UTF-8 из processCwd(). Полная поддержка не-ASCII в путях
--  запуска требует FFI/C-модуля (GetModuleFileNameW) либо
--  wmain-интерпретатора.

local function getScriptDir()
    local src = arg and arg[0]
    if not src or src == "" then
        return processCwd() or "."
    end
    -- Fast path: arg[0] = "renamer.lua" (без разделителей) —
    -- каталог скрипта совпадает с CWD, arg[0] как путь не нужен.
    if not src:find("[\\/]") then
        return processCwd() or "."
    end
    local abs = makeAbs(src)
    if abs then return getDirName(abs) end
    -- fallback, если popen недоступен и путь относительный
    return getDirName(normalizePath(src))
end

-- ============================================================
--  8. runBat — исполнение .bat с безопасной передачей пути
-- ============================================================
--  Ключевые детали механизма (подробно в шапке файла):
--    * Путь кладётся в temp-файл как есть; set /p читает его
--      побайтово, без раскрытия переменных на чтении.
--    * Внутри батника путь живёт в %P%. Литералы "%VAR%" внутри
--      %P% cmd НЕ раскрывает повторно: значение переменной —
--      результат, а не вход парсера. Поэтому batBody обязан
--      обращаться к пути ТОЛЬКО через "%P%" внутри двойных кавычек
--      (кавычки защищают & | < > ^ " от синтаксиса; /v:off — ! от
--      delayed expansion).
--    * Относительный вход резолвится лексически в Lua (контракт
--      «как у fopen») до записи в temp-файл.

local function runBat(target, batBody)
    if not io.popen then return nil end

    local abs = makeAbs(target)
    if not abs then return nil end
    if abs:find("[\r\n]", 1, false) then return nil end

    for attempt = 1, 5 do
        local pathFile, batFile = makeTempPair(abs, batBody)
        if not pathFile then return nil end

        local cmd = 'cmd /v:off /u /s /c ""' .. batFile .. '""'
        local p = io.popen(cmd, "rb")
        if not p then
            removeWithRetry(pathFile); removeWithRetry(batFile)
            return nil
        end
        local raw = p:read("*a")
        p:close()
        removeWithRetry(pathFile)
        removeWithRetry(batFile)

        if raw:sub(1, 2) == "\255\254" then raw = raw:sub(3) end
        local out = utf16leToUtf8(raw)

        -- __LF_ERR__: set /p не увидел temp-файл. Ретрай бессмыслен
        -- — либо у хоста нет доступа к TEMP, либо set /p не сработал
        -- вообще. %s* — терпимость к хвостовому пробелу: если
        -- echo-разделитель когда-нибудь случайно окажется перед `&`
        -- (правка в bat-шаблоне), маркер всё равно распознаётся.
        if out:find("__LF_ERR__%s*$") then
            return nil
        end

        -- Маркер в конце .bat: если его нет — другой процесс снёс
        -- наш .bat в TOCTOU-окне (verify → popen). Пробуем ещё раз.
        -- Срезаем только ХВОСТОВОЙ маркер: реальный файл с именем
        -- __LF_OK__ (если есть) остаётся в листинге.
        if out:find("__LF_OK__\r\n$") or out:find("__LF_OK__$") then
            out = out:gsub("__LF_OK__\r\n$", ""):gsub("__LF_OK__$", "")
            return out
        end

        if attempt == 5 then
            -- Пять попыток не дали __LF_OK__ — вывод может быть
            -- обрезан или чужой. nil честнее, чем частичный мусор:
            -- listXxx вернут {}, dirExists/fileExists вернут false.
            return nil
        end

        -- Desync от возможного коллизионного процесса: к моменту
        -- retry наши процессы проработали разное CPU-время.
        lcgState = (lcgState
            + math.floor((os.clock() or 0) * 1000000) * (attempt + 1))
            % 4294967296
        for _ = 1, attempt * 7 do lcgNext() end
    end
    return nil
end

-- ============================================================
--  9. ФС: существование, листинг
-- ============================================================

-- Проверка «это файл» через `if exist`. В отличие от io.open:
--   * путь уходит в cmd через /u (UTF-16LE) — кириллица работает;
--   * нечитаемые / эксклюзивно занятые файлы находятся (проверка
--     на уровне namespace, а не через fopen);
--   * `if exist "%P%\"` истинно только для каталогов — так мы
--     отсекаем директории (io.open на директорию в Windows тоже
--     даёт NULL, но не по всем причинам);
--   * устройства NUL/CON/PRN/AUX/COM1.. `if exist` считает
--     существующими — это ограничение, см. шапку.
-- Цена — spawn cmd и два temp-файла на вызов.
local function fileExists(path)
    if type(path) ~= "string" or path == "" then return false end
    local p = normalizePath(path)
    -- В Lua-строке '\\' = один '\'. В bat получаем `if exist "%P%\"`
    -- — кавычки вокруг пути, замыкающая `\` внутри кавычек; cmd
    -- трактует хвостовой `\` как признак каталога.
    local out = runBat(p,
        'if exist "%P%\\" (echo 0) else if exist "%P%" (echo 1) else (echo 0)')
    return out ~= nil and out:sub(1, 1) == "1"
end

-- Существование директории: pushd успешен → это папка. Никакого
-- парсинга локализованного текста dir. Проверка первого символа
-- (не find) — детерминированно.
local function dirExists(path)
    local p = normalizePath(path)
    local out = runBat(p,
        'pushd "%P%" >nul 2>nul && (echo 1 & popd) || (echo 0)')
    return out ~= nil and out:sub(1, 1) == "1"
end

local function listEntries(path, mode)
    local target = path:sub(-1) == "\\" and (path .. "*") or (path .. "\\*")
    local args = ({
        files          = "/b /a-d",
        filesRecursive = "/b /s /a-d",
        dirs           = "/b /ad",
    })[mode]

    local out = runBat(target, 'dir ' .. args .. ' "%P%" 2>nul')
    if not out then return {} end

    local entries = {}
    for line in out:gmatch("[^\r\n]+") do
        -- Отсев мусора при неудачном chcp: управляющие байты
        -- (0x00–0x1F) в начале строки не могут быть началом
        -- легального имени (NTFS запрещает их в именах вообще).
        -- НИКАКОЙ фильтрации по 0xEF: первый байт 0xEF — валидное
        -- начало UTF-8 для U+F000–U+FFFF (Fullwidth Forms "Ａ",
        -- CJK Compatibility Ideographs "豈", PUA). UTF-8 BOM
        -- (EF BB BF) в выводе cmd /u физически невозможен: весь
        -- raw — UTF-16LE, а его BOM (FF FE) снят в runBat.
        local first = line:byte(1)
        if first and first >= 32 then
            entries[#entries + 1] = line
        end
    end
    return entries
end

local function listFiles(dir)
    return listEntries(normalizePath(dir), "files")
end

local function listFilesRecursive(dir)
    return listEntries(normalizePath(dir), "filesRecursive")
end

local function listDirs(dir)
    return listEntries(normalizePath(dir), "dirs")
end

-- ============================================================
--  10. Склейка путей
-- ============================================================
--  Единая функция для обоих старых имён (joinPath/pathCombine).
--
--  Контракт:
--    * nil / "" на любом аргументе — толерантно (совместимо с
--      path_utils.pathCombine); не-строки — error.
--    * Первый аргумент нормализуется (слэши, /, хвостовой \).
--    * Второй аргумент нормализуется по слэшам.
--    * Если b абсолютный (C:\x, \\server\share, \foo) — он
--      выигрывает и возвращается как нормализованный. Это
--      соглашение .NET Path.Combine и Python os.path.join;
--      снимает сюрприз «C:\foo\C:\x».
--    * Изменение контракта относительно старого listFiles.joinPath:
--      joinPath(dir, "") теперь возвращает normalizePath(dir)
--      (раньше — dir .. "\"), joinPath(dir, nil) больше не падает
--      (раньше — assert). Сделано ради совместимости с pathCombine.
--      Тесты должны учитывать (см. M._test).
local function joinPath(a, b)
    local hasA = a ~= nil and a ~= ""
    local hasB = b ~= nil and b ~= ""
    if hasA and type(a) ~= "string" then
        error("joinPath: first argument must be a string or nil", 2)
    end
    if hasB and type(b) ~= "string" then
        error("joinPath: second argument must be a string or nil", 2)
    end
    if not hasA and not hasB then return "" end
    if not hasA then return normalizePath(b) end
    if not hasB then return normalizePath(a) end

    if isAbsolutePath(b) then
        return normalizePath(b)
    end

    local p = normalizePath(a)
    local q = b:gsub("%/", "\\")
    if p:sub(-1) == "\\" then
        return p .. q
    end
    return p .. "\\" .. q
end
local function renameFile(oldPath, newName)
    if type(newName) ~= "string" or not newName:match("^[%w_%-]+%.%w+$") then
        return nil, "unsafe new name"
    end
    local out = runBat(normalizePath(oldPath),
        'ren "%P%" "' .. newName .. '" >nul 2>nul && (echo 1) || (echo 0)')
    if out and out:sub(1, 1) == "1" then return true end
    return nil, "ren failed (файл занят, цель существует или нет доступа)"
end
-- ============================================================
--  11. Экспорт
-- ============================================================

M.normalizePath     = normalizePath
M.isAbsolutePath    = isAbsolutePath

M.getFileName       = getFileName
M.getExtension      = getExtension
M.getDirName        = getDirName

M.joinPath          = joinPath
M.pathCombine       = joinPath   -- алиас (обратная совместимость)

M.getCwd            = processCwd -- кэш; resetCwdCache сбрасывает
M.resetCwdCache     = resetCwdCache
M.getScriptDir      = getScriptDir

M.fileExists        = fileExists
M.dirExists         = dirExists

M.listFiles         = listFiles
M.listFilesRecursive = listFilesRecursive
M.listDirs          = listDirs
M.renameFile        = renameFile
-- Внутренние функции для тестов. Не использовать в проде:
-- контракт и наличие могут меняться без предупреждения.
M._test = {
    utf16leToUtf8   = utf16leToUtf8,
    makeAbs         = makeAbs,
    makeTempPair    = makeTempPair,
    writeAndVerify  = writeAndVerify,
    removeWithRetry = removeWithRetry,
    runBat          = runBat,
    lcgNext         = lcgNext,
    lcgSeed         = lcgSeed,
    -- Сброс LCG к детерминированному состоянию (state = 0,
    -- seeded = false). После вызова первый lcgNext() вернёт
    -- 1013904223 — удобно для юнит-тестов makeTempPair.
    lcgReset        = function() lcgState = 0; lcgSeeded = false end,
}

return M