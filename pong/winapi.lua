-- winapi.lua
-- Тонкая обёртка над kernel32.dll через ffi (LuaJIT) для Windows-консоли:
--   raw-режим ввода, чтение нажатий клавиш (ReadConsoleInputA),
--   sleep без busy-wait (Sleep), широкая консоль (SetConsoleCP).
-- На Lua 5.1 без LuaJIT (нет ffi) или не-Windows все функции возвращают nil/false —
-- вызывающий код обязан иметь фолбэк.

local M = {}

local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local ffi = nil
if IS_WINDOWS then
    local ok, f = pcall(require, "ffi")
    if ok then ffi = f end
end

M.available = function() return ffi ~= nil end

if not ffi then
    -- Заглушки: всё недоступно
    M.sleep          = function(ms) return false end
    M.enableRawMode  = function() return false end
    M.disableRawMode = function() end
    M.pollKeys       = function() return nil end
    M.wideCP         = function() return false end
    return M
end

ffi.cdef[[
    typedef void* HANDLE;
    typedef unsigned long DWORD;
    typedef int BOOL;

    HANDLE GetStdHandle(int nStdHandle);
    BOOL   GetConsoleMode(HANDLE hConsoleHandle, DWORD *lpMode);
    BOOL   SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
    BOOL   GetNumberOfConsoleInputEvents(HANDLE hInput, DWORD *pNumber);
    DWORD  WaitForSingleObject(HANDLE hHandle, DWORD dwMilliseconds);
    void   Sleep(DWORD dwMilliseconds);
    BOOL   ReadConsoleInputA(HANDLE hConsoleInput, void *lpBuffer, DWORD nLength, DWORD *lpNumberOfEventsRead);
    BOOL   FlushConsoleInputBuffer(HANDLE hConsoleHandle);
    BOOL   SetConsoleOutputCP(UINT CodePage);
    UINT   GetConsoleOutputCP();
]]

local INVALID_HANDLE = ffi and ffi.cast("void*", -1)

local ENABLE_PROCESSED_INPUT      = 0x0001
local ENABLE_WINDOW_INPUT         = 0x0008
local ENABLE_MOUSE_INPUT          = 0x0010
local ENABLE_EXTENDED_FLAGS       = 0x0080
local WAIT_OBJECT_0               = 0

local KEY_EVENT                   = 1 -- FIRST_EVENT in INPUT_RECORD

-- struct KEY_EVENT_RECORD (WinAPI):
--   BOOL bKeyDown;            -> int (4 байта)
--   WORD wRepeatCount;        -> 2
--   WORD wVirtualKeyCode;     -> 2
--   WORD wVirtualScanCode;    -> 2
--   union { CHAR c; WCHAR w } -> 2
--   BOOL bControlKeyState;    -> DWORD (4)
ffi.cdef[[
    typedef struct {
        int    bKeyDown;
        short  wRepeatCount;
        short  wVirtualKeyCode;
        short  wVirtualScanCode;
        char   unicodeChar[2];
        int    dwControlKeyState;
    } KEY_EVENT_RECORD;

    typedef struct {
        int EventType;
        KEY_EVENT_RECORD KeyEvent;
    } INPUT_RECORD_KB;
]]

local inputRecordSize = ffi.sizeof("INPUT_RECORD_KB")

local STD_INPUT_HANDLE  = -10
local STD_OUTPUT_HANDLE = -11

-- Корректная проверка валидности HANDLE:
--   * ffi.NULL   — NULL-хэндл (GetStdHandle возвращает его, когда консоль недоступна);
--     раньше сравнивали cdata с nil ("h == nil") — это не детектировало NULL и молча
--     пропускало вызовы kernel32 с невалидным хэндлом;
--   * INVALID_HANDLE (-1) — явный признак ошибки.
local function validHandle(h)
    if h == nil then return false end          -- на всякий случай (не cdata)
    if h == ffi.NULL then return false end
    if h == INVALID_HANDLE then return false end
    return true
end

local function outHandle()
    local ok, h = pcall(ffi.C.GetStdHandle, STD_OUTPUT_HANDLE)
    if not ok or not validHandle(h) then return nil end
    return h
end

local function inHandle()
    local ok, h = pcall(ffi.C.GetStdHandle, STD_INPUT_HANDLE)
    if not ok or not validHandle(h) then return nil end
    return h
end

--------------------------------------------------------------------------------
-- Сон (миллисекунды) — вместо busy-wait
--------------------------------------------------------------------------------

function M.sleep(ms)
    ffi.C.Sleep(math.floor(ms))
    return true
end

--------------------------------------------------------------------------------
-- Широкая кодовая страница вывода (UTF-8), чтобы рамка не разъезжалась
--------------------------------------------------------------------------------

function M.wideCP()
    local h = outHandle()
    if not h then return false end
    -- 65001 = UTF-8. Работает в ConHost и Windows Terminal.
    pcall(function() ffi.C.SetConsoleOutputCP(65001) end)
    return true
end

--------------------------------------------------------------------------------
-- Raw-режим консоли
--------------------------------------------------------------------------------

local savedMode = nil

function M.enableRawMode()
    local h = inHandle()
    if not h then return false end
    local mode = ffi.new("DWORD[1]")
    if ffi.C.GetConsoleMode(h, mode) == 0 then return false end
    savedMode = mode[0]
    -- Отключаем line input + echo, оставляем processed input, включаем window input.
    -- (сумма констант — чтобы код компилировался и в plain Lua 5.1 без битовых операторов)
    local newMode = ENABLE_PROCESSED_INPUT + ENABLE_WINDOW_INPUT + ENABLE_EXTENDED_FLAGS
    if ffi.C.SetConsoleMode(h, newMode) == 0 then
        savedMode = nil
        return false
    end
    -- Сбрасываем накопленные события, чтобы не «выстрелить» старым вводом
    pcall(function() ffi.C.FlushConsoleInputBuffer(h) end)
    return true
end

function M.disableRawMode()
    if savedMode == nil then return end
    local h = inHandle()
    if h then pcall(function() ffi.C.SetConsoleMode(h, savedMode) end) end
    savedMode = nil
end

--------------------------------------------------------------------------------
-- Опрос клавиш: возвращает массив имён клавиш ("w","space","up"...) или nil,
-- если механизм недоступен (тогда вызывающий использует фолбэк io.read).
--------------------------------------------------------------------------------

local VK_NAMES = {
    [0x08] = "back", [0x09] = "tab", [0x0D] = "enter", [0x1B] = "esc",
    [0x20] = "space",
    [0x21] = "pgup", [0x22] = "pgdn",
    [0x23] = "end",  [0x24] = "home",
    [0x25] = "left", [0x26] = "up", [0x27] = "right", [0x28] = "down",
}

local function vkName(vk, ch)
    if vk == 0 and ch and ch:byte() >= 32 and ch:byte() < 127 then
        return ch:lower()
    end
    local name = VK_NAMES[vk]
    if name then return name end
    -- Буквы/цифры через VK (VK_A=0x41..VK_Z=0x5A, VK_0=0x30..VK_9=0x39)
    if vk >= 0x41 and vk <= 0x5A then return string.char(vk + 32) end
    if vk >= 0x30 and vk <= 0x39 then return string.char(vk) end
    return nil
end

function M.pollKeys(timeoutMs)
    local h = inHandle()
    if not h then return nil end
    timeoutMs = timeoutMs or 0

    local pending = ffi.new("DWORD[1]")
    if ffi.C.GetNumberOfConsoleInputEvents(h, pending) == 0 then return {} end
    if pending[0] == 0 then
        -- Ждём прихода событий до timeoutMs, чтобы не крутить CPU впустую
        local r = ffi.C.WaitForSingleObject(h, timeoutMs)
        if r ~= WAIT_OBJECT_0 then return {} end
        if ffi.C.GetNumberOfConsoleInputEvents(h, pending) == 0 then return {} end
        if pending[0] == 0 then return {} end
    end

    local keys = {}
    local rec = ffi.new("INPUT_RECORD_KB[?]", 32)
    local read = ffi.new("DWORD[1]")
    local left = pending[0]
    while left > 0 do
        local want = math.min(left, 32)
        if ffi.C.ReadConsoleInputA(h, rec, want, read) == 0 then break end
        for i = 0, read[0] - 1 do
            local r = rec[i]
            if r.EventType == KEY_EVENT and r.KeyEvent.bKeyDown ~= 0 then
                local chByte = r.KeyEvent.unicodeChar[0]
                local ch = nil
                if chByte >= 32 and chByte < 127 then ch = string.char(chByte) end
                local name = vkName(r.KeyEvent.wVirtualKeyCode, ch)
                if name then keys[#keys + 1] = name end
            end
        end
        left = left - read[0]
    end
    return keys
end

return M
