-- input.lua
-- Неблокирующий ввод с клавиатуры для терминальной игры.
-- Windows: через runBat-механизм paths.lua было бы слишком медленно,
-- поэтому используем io.read("l") в отдельном потоке (luathreading) — но его может не быть.
-- Универсальный вариант: читаем по одному символу через os.clock + pcall(io.read).
-- Для POSIX используем stty raw mode; для Windows — io.read() без буфера (работает в cmd).

local M = {}

local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local queue = {}
local savedStty = nil

--- Включить режим "по нажатию" (без Enter).
function M.enableRawMode()
    if IS_WINDOWS then
        -- В Windows console.io.read блокирует до Enter, если не использовать
        -- специальные хаки. Пробуем chcp/консольные флаги через ffi при наличии LuaJIT.
        local ok = pcall(function()
            local ffi = require("ffi")
            ffi.cdef[[
                typedef void* HANDLE;
                HANDLE GetStdHandle(int n);
                int SetConsoleMode(HANDLE h, int mode);
                int GetConsoleMode(HANDLE h, int *mode);
            ]]
            local handle = ffi.C.GetStdHandle(-11) -- STD_INPUT_HANDLE
            local mode = ffi.new("int[1]")
            ffi.C.GetConsoleMode(handle, mode)
            -- ENABLE_PROCESSED_INPUT (0x1) only: отключаем line input
            ffi.C.SetConsoleMode(handle, 0x1)
        end)
        return ok
    else
        -- Сохраняем текущие настройки и ставим raw
        local f = io.popen("stty -g 2>/dev/null")
        if f then
            savedStty = f:read("*a")
            f:close()
        end
        os.execute("stty raw -echo 2>/dev/null")
        return true
    end
end

--- Вернуть терминал в исходное состояние.
function M.disableRawMode()
    if not IS_WINDOWS and savedStty and #savedStty > 0 then
        os.execute("stty " .. savedStty:gsub("[^%w%-=%s]", "") .. " 2>/dev/null")
    elseif not IS_WINDOWS then
        os.execute("stty cooked echo 2>/dev/null")
    end
end

--- Опросить ввод: возвращает таблицу нажатых клавиш с прошлого вызова.
-- Поддерживаются: w s a d q space arrows (как escape-секвенсии -> up/down/left/right).
function M.poll()
    local keys = {}
    -- Читаем сколько есть неблокирующе. io.read не поддерживает select на stdin
    -- переносимо, поэтому читаем один символ, если он доступен.
    -- На POSIX можно проверить через popen("read -t 0"), но это дорого.
    -- Компромисс: io.read(0) возвращает "" если данных нет (Lua 5.2+ на не-tty),
    -- на tty блокируется. Используем обходной путь: read со sleep-таймером невозможна.
    -- Поэтому для игры используем короткий blocking read: читаем 1 байт с таймаутом
    -- через os.time — не работает переносимо.
    --
    -- Практичное решение: читаем сразу все доступные байты через debug.gethook? Нет.
    -- Оставляем простой подход: неблокирующий peek только на LuaJIT+POSIX через poll().
    local okLJ, ffi = pcall(require, "ffi")
    if okLJ and not IS_WINDOWS then
        local okp = pcall(function()
            ffi.cdef[[
                int poll(struct pollfd *fds, unsigned long nfds, int timeout);
                struct pollfd { int fd; short events; short revents; };
            ]]
            local pfd = ffi.new("struct pollfd[1]")
            pfd[0].fd = 0
            pfd[0].events = 1 -- POLLIN
            while true do
                local r = ffi.C.poll(pfd, 1, 0)
                if r <= 0 then break end
                local ch = io.read(1)
                if not ch or ch == "" then break end
                table.insert(keys, ch)
            end
        end)
        if okp then
            return M.normalize(keys)
        end
    end
    -- Фолбэк: читаем строку целиком (блокирующе до Enter). Игра будет реагировать
    -- на Enter-подтверждённые команды — приемлемо для демо.
    local line = io.read("*l")
    if line then
        for i = 1, #line do
            table.insert(keys, line:sub(i, i))
        end
    end
    return M.normalize(keys)
end

--- Превратить сырые байты в имена клавиш.
function M.normalize(bytes)
    local out = {}
    local i = 1
    while i <= #bytes do
        local ch = bytes[i]
        if ch == "\27" and bytes[i + 1] == "[" then
            local c3 = bytes[i + 2]
            if c3 == "A" then table.insert(out, "up")
            elseif c3 == "B" then table.insert(out, "down")
            elseif c3 == "C" then table.insert(out, "right")
            elseif c3 == "D" then table.insert(out, "left")
            end
            i = i + 3
        elseif ch == " " then
            table.insert(out, "space")
            i = i + 1
        else
            table.insert(out, ch)
            i = i + 1
        end
    end
    return out
end

return M
