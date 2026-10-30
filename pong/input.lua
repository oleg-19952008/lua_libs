-- input.lua
-- Неблокирующий ввод с клавиатуры для терминальной игры.
-- Windows (LuaJIT): Console API через winapi.lua (ReadConsoleInputA) —
--   работает и в pipe, и в настоящей консоли, реагирует на нажатие без Enter.
-- POSIX (LuaJIT): stty raw + poll() на stdin.
-- Фолбэк (Lua 5.1.4 без ffi): блокирующее чтение строк через io.read.

local M = {}

local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local function script_dir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("(.*[/\\])") or "./"
end

local okWinApi, winapi = pcall(function()
    return loadfile(script_dir() .. "winapi.lua")()
end)
if not okWinApi then winapi = nil end

local queue = {}          -- очередь «удерживаемых» клавиш для фолбэк-режима
local savedStty = nil
local useWinApi = false
local useLjPosix = false

--------------------------------------------------------------------------------
-- Raw-режим
--------------------------------------------------------------------------------

function M.enableRawMode()
    if IS_WINDOWS then
        if winapi and winapi.available() then
            local ok = winapi.enableRawMode()
            if ok then
                useWinApi = true
                winapi.wideCP()
                return true
            end
        end
        return false
    else
        local f = io.popen("stty -g 2>/dev/null")
        if f then
            savedStty = f:read("*a")
            f:close()
        end
        os.execute("stty raw -echo 2>/dev/null")
        local okLJ, ffi = pcall(require, "ffi")
        useLjPosix = okLJ and ffi ~= nil
        return true
    end
end

function M.disableRawMode()
    if IS_WINDOWS then
        if useWinApi then
            winapi.disableRawMode()
            useWinApi = false
        end
    else
        if savedStty and #savedStty > 0 then
            os.execute("stty " .. savedStty:gsub("[^%w%-=%s]", "") .. " 2>/dev/null")
        else
            os.execute("stty cooked echo 2>/dev/null")
        end
    end
end

--------------------------------------------------------------------------------
-- Опрос ввода
--------------------------------------------------------------------------------

--- Подсчёт доступных байт на stdin (POSIX). Возвращает nil, если метод недоступен.
local function availBytes()
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil end
    local okRes, res = pcall(function()
        ffi.cdef[[ int read(int fd, void *buf, unsigned long count); ]]
        -- FIONREAD через ioctl слишком платформозависим; проще: неблокирующий read 1 байта
        return true
    end)
    return nil
end

--- Неблокирующее чтение всех доступных байт stdin (POSIX + LuaJIT poll).
local function posixPoll(ffi)
    local pfd = ffi.new("struct pollfd[1]")
    pfd[0].fd = 0
    pfd[0].events = 1 -- POLLIN
    local keys = {}
    while true do
        local r = ffi.C.poll(pfd, 1, 0)
        if r <= 0 then break end
        local ch = io.read(1)
        if not ch or ch == "" then break end
        table.insert(keys, ch)
    end
    return keys
end

--- Неблокирующий опрос: возвращает таблицу «нажатых» клавиш за последний интервал.
-- timeoutMs — сколько ждать при отсутствии событий (Windows Console API).
function M.poll(timeoutMs)
    if IS_WINDOWS and useWinApi then
        local keys = winapi.pollKeys(timeoutMs or 0)
        if keys then return keys end
        return {}
    end

    if not IS_WINDOWS then
        local okLJ, ffi = pcall(require, "ffi")
        if okLJ and useLjPosix then
            -- poll() доступен только в настоящей tty; в pipe его лучше не использовать
            local isTty = savedStty ~= nil and #savedStty > 0
            if isTty then
                local okInit = pcall(function()
                    ffi.cdef[[
                        struct pollfd { int fd; short events; short revents; };
                        int poll(struct pollfd *fds, unsigned long nfds, int timeout);
                    ]]
                end)
                if okInit then
                    local ok, keys = pcall(posixPoll, ffi)
                    if ok then return M.normalize(keys) end
                end
            end
        end
    end

    -- Фолбэк без raw-режима: читаем строку целиком (блокирующе до Enter),
    -- символы строки считаем «удерживаемыми» до следующей строки.
    local line = io.read("*l")
    local keys = {}
    if line then
        for i = 1, #line do
            table.insert(keys, line:sub(i, i))
        end
    end
    return M.normalize(keys)
end

--------------------------------------------------------------------------------
-- Нормализация сырых байт в имена клавиш (для POSIX-потока)
--------------------------------------------------------------------------------

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

M.winapi = winapi

return M
