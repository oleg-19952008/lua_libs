-- ansi.lua
-- Расширенная ANSI-библиотека. Совместима с Lua 5.1, 5.2, 5.3, 5.4, LuaJIT.
-- Лицензия: MIT

local M = {}

local ESC = string.char(27)
local IS_WINDOWS = package.config:sub(1, 1) == "\\"

--------------------------------------------------------------------------------
-- 1. bit.bor без Lua 5.3-синтаксиса в исходнике
--------------------------------------------------------------------------------

local _bor
do
    local ok, mod = pcall(require, "bit")
    if ok and type(mod) == "table" and mod.bor then
        _bor = mod.bor
    else
        local ok2, mod2 = pcall(require, "bit32")
        if ok2 and type(mod2) == "table" and mod2.bor then
            _bor = mod2.bor
        else
            -- Динамическая компиляция: '|' не попадает в парсер Lua 5.1.
            local loader = loadstring or load
            if loader then
                local ok3, chunk = pcall(loader, "return function(a,b) return a | b end")
                if ok3 and chunk then
                    local ok4, f = pcall(chunk)
                    if ok4 then _bor = f end
                end
            end
            if not _bor then
                -- Арифметический fallback (для маленьких DWORD-значений Windows).
                _bor = function(a, b)
                    local res, bit = 0, 1
                    while a > 0 or b > 0 do
                        local abit, bbit = a % 2, b % 2
                        if abit == 1 or bbit == 1 then res = res + bit end
                        a = math.floor(a / 2)
                        b = math.floor(b / 2)
                        bit = bit * 2
                    end
                    return res
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- 2. Windows VT / TTY / политика поддержки цвета
--------------------------------------------------------------------------------

local _win_vt_done = false

local function try_enable_windows_vt()
    if not IS_WINDOWS then return true end
    if _win_vt_done then return true end

    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi or type(ffi) ~= "table" then return false end

    -- x86 Windows: __stdcall обязателен; x64: единое соглашение (принимается).
    local cc = "__stdcall"
    local cdef = string.format([[
        void* %s GetStdHandle(unsigned long nStdHandle);
        int   %s GetConsoleMode(void* hConsoleHandle, unsigned long* lpMode);
        int   %s SetConsoleMode(void* hConsoleHandle, unsigned long dwMode);
    ]], cc, cc, cc)

    -- Повторный cdef бросает ошибку — глушим её.
    pcall(ffi.cdef, cdef)

    local ok = pcall(function()
        local STD_OUTPUT_HANDLE = 0xFFFFFFF5  -- (unsigned long)(-11)
        local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004

        local h = ffi.C.GetStdHandle(STD_OUTPUT_HANDLE)
        if h == nil then error("GetStdHandle") end

        local mode = ffi.new("unsigned long[1]")
        if ffi.C.GetConsoleMode(h, mode) == 0 then error("GetConsoleMode") end

        local newmode = _bor(tonumber(mode[0]), ENABLE_VIRTUAL_TERMINAL_PROCESSING)
        if ffi.C.SetConsoleMode(h, newmode) == 0 then error("SetConsoleMode") end
    end)

    if ok then _win_vt_done = true end
    return ok
end

local function is_tty(handle)
    handle = handle or io.stdout
    if type(handle.isatty) == "function" then
        local ok, res = pcall(handle.isatty, handle)
        if ok then return not not res end
    end
    return nil  -- неизвестно
end

local function env_nonempty(name)
    local v = os.getenv(name)
    return v ~= nil and v ~= ""
end

local function detect_support()
    -- NO_COLOR: любое непустое значение отключает цвет (no-color.org)
    if env_nonempty("NO_COLOR") then return false end

    -- FORCE_COLOR: принудительное включение
    local fc = os.getenv("FORCE_COLOR")
    if fc ~= nil and fc ~= "" and fc ~= "0" then
        if IS_WINDOWS then try_enable_windows_vt() end
        return true
    end

    local term = os.getenv("TERM")
    if term == "dumb" then return false end

    if IS_WINDOWS then
        if env_nonempty("WT_SESSION")
            or env_nonempty("ANSICON")
            or os.getenv("ConEmuANSI") == "ON"
            or env_nonempty("TERM_PROGRAM")
        then
            try_enable_windows_vt()
            return true
        end
        -- обычный старый cmd.exe — цвета не понимает
        return false
    end

    -- Unix: TTY — авторитетный источник.
    local tty = is_tty(io.stdout)
    if tty ~= nil then return tty end

    -- isatty недоступен: осторожная эвристика.
    if term and term ~= "" then return true end
    if env_nonempty("COLORTERM") then return true end
    return false
end

M.enabled = detect_support()

function M.set_enabled(v) M.enabled = not not v end
function M.enable()  M.enabled = true  end
function M.disable() M.enabled = false end
function M.is_enabled() return M.enabled end

--------------------------------------------------------------------------------
-- 3. Таблицы SGR
--------------------------------------------------------------------------------

M.fg = {
    black   = 30, red     = 31, green   = 32, yellow  = 33,
    blue    = 34, magenta = 35, cyan    = 36, white   = 37,
    default = 39,
    bright_black   = 90, bright_red     = 91,
    bright_green   = 92, bright_yellow  = 93,
    bright_blue    = 94, bright_magenta = 95,
    bright_cyan    = 96, bright_white   = 97,
    gray = 90, grey = 90, dark_gray = 90, dark_grey = 90,
    light_red = 91, light_green = 92, light_yellow = 93,
    light_blue = 94, light_magenta = 95,
    light_cyan = 96, light_white = 97,
}

M.bg = {
    black   = 40, red     = 41, green   = 42, yellow  = 43,
    blue    = 44, magenta = 45, cyan    = 46, white   = 47,
    default = 49,
    bright_black   = 100, bright_red     = 101,
    bright_green   = 102, bright_yellow  = 103,
    bright_blue    = 104, bright_magenta = 105,
    bright_cyan    = 106, bright_white   = 107,
}

M.style = {
    reset = 0,
    bold = 1, dim = 2, faint = 2,
    italic = 3, underline = 4,
    slow_blink = 5, blink = 5, rapid_blink = 6,
    reverse = 7, inverse = 7,
    hidden = 8, conceal = 8,
    strikethrough = 9,
    reset_bold = 22, reset_dim = 22,
    reset_italic = 23, reset_underline = 24,
    reset_blink = 25, reset_reverse = 27,
    reset_hidden = 28, reset_strikethrough = 29,
    reset_fg = 39, reset_bg = 49,
}

M.palette = {
    orange = 208, pink = 205, purple = 93,
    teal = 30, lime = 118, gold = 220,
    indigo = 54, crimson = 161, salmon = 209,
    sky = 117, mint = 121, coral = 203,
    violet = 135, olive = 142, maroon = 88,
    navy = 17, forest = 22, brown = 130,
}

--------------------------------------------------------------------------------
-- 4. Валидация и генераторы
--------------------------------------------------------------------------------

local function clamp(n, lo, hi)
    n = tonumber(n)
    if not n or n ~= n then return lo end
    if n < lo then return lo end
    if n > hi then return hi end
    return math.floor(n)
end

function M.clamp_byte(n) return clamp(n, 0, 255) end

function M.fg256(n) return "38;5;" .. clamp(n, 0, 255) end
function M.bg256(n) return "48;5;" .. clamp(n, 0, 255) end
function M.fgRGB(r, g, b)
    return "38;2;" .. clamp(r,0,255) .. ";" .. clamp(g,0,255) .. ";" .. clamp(b,0,255)
end
function M.bgRGB(r, g, b)
    return "48;2;" .. clamp(r,0,255) .. ";" .. clamp(g,0,255) .. ";" .. clamp(b,0,255)
end

function M.hex_to_rgb(hex)
    if type(hex) ~= "string" then return nil end
    hex = hex:gsub("^#", "")
    if #hex == 3 then
        if not hex:match("^%x%x%x$") then return nil end
        hex = hex:gsub("(.)", "%1%1")
    end
    if #hex ~= 6 then return nil end
    if not hex:match("^%x%x%x%x%x%x$") then return nil end
    return tonumber(hex:sub(1,2), 16),
           tonumber(hex:sub(3,4), 16),
           tonumber(hex:sub(5,6), 16)
end

function M.fgHex(hex)
    local r, g, b = M.hex_to_rgb(hex)
    if not r then return nil end
    return M.fgRGB(r, g, b)
end
function M.bgHex(hex)
    local r, g, b = M.hex_to_rgb(hex)
    if not r then return nil end
    return M.bgRGB(r, g, b)
end

M.RESET = function() return M.enabled and (ESC .. "[0m") or "" end

--------------------------------------------------------------------------------
-- 5. UTF-8: декодер, ширина (East Asian Width), токенайзер
--------------------------------------------------------------------------------

local function decode_utf8(s, i)
    local b = s:byte(i)
    if not b then return nil, 0 end
    if b < 0x80 or b < 0xC0 then return b, 1 end
    if b < 0xE0 then
        local b2 = s:byte(i + 1) or 0
        return ((b - 0xC0) * 64) + (b2 - 0x80), 2
    end
    if b < 0xF0 then
        local b2, b3 = s:byte(i + 1) or 0, s:byte(i + 2) or 0
        return ((b - 0xE0) * 4096) + ((b2 - 0x80) * 64) + (b3 - 0x80), 3
    end
    local b2, b3, b4 = s:byte(i+1) or 0, s:byte(i+2) or 0, s:byte(i+3) or 0
    return ((b - 0xF0) * 262144) + ((b2 - 0x80) * 4096)
        + ((b3 - 0x80) * 64) + (b4 - 0x80), 4
end

-- Упрощённый wcwidth. Достаточно для CLI-вывода; покрывает
-- контрольные, комбинирующие, широкие CJK и основные emoji.
local function cp_width(cp)
    if cp == 0 then return 0 end
    if cp < 0x20 or (cp >= 0x7F and cp < 0xA0) then return 0 end
    if cp == 0x200B or cp == 0x200C or cp == 0x200D or cp == 0xFEFF then return 0 end

    -- Комбинирующие (Mn/Me/Cf)
    if (cp >= 0x0300 and cp <= 0x036F)
        or (cp >= 0x0483 and cp <= 0x0489)
        or (cp >= 0x0591 and cp <= 0x05BD)
        or (cp >= 0x0610 and cp <= 0x061A)
        or (cp >= 0x064B and cp <= 0x065F)
        or (cp >= 0x0670 and cp <= 0x0670)
        or (cp >= 0x06D6 and cp <= 0x06DC)
        or (cp >= 0x06DF and cp <= 0x06E4)
        or (cp >= 0x06E7 and cp <= 0x06E8)
        or (cp >= 0x06EA and cp <= 0x06ED)
        or (cp >= 0x1AB0 and cp <= 0x1AFF)
        or (cp >= 0x1DC0 and cp <= 0x1DFF)
        or (cp >= 0x20D0 and cp <= 0x20FF)
        or (cp >= 0xFE20 and cp <= 0xFE2F)
    then return 0 end

    -- Широкие (East Asian Wide / Fullwidth)
    if (cp >= 0x1100 and cp <= 0x115F)
        or (cp >= 0x2E80 and cp <= 0x303E)
        or (cp >= 0x3041 and cp <= 0x33FF)
        or (cp >= 0x3400 and cp <= 0x4DBF)
        or (cp >= 0x4E00 and cp <= 0x9FFF)
        or (cp >= 0xA000 and cp <= 0xA4CF)
        or (cp >= 0xAC00 and cp <= 0xD7A3)
        or (cp >= 0xF900 and cp <= 0xFAFF)
        or (cp >= 0xFE10 and cp <= 0xFE19)
        or (cp >= 0xFE30 and cp <= 0xFE6F)
        or (cp >= 0xFF00 and cp <= 0xFF60)
        or (cp >= 0xFFE0 and cp <= 0xFFE6)
        or (cp >= 0x1F300 and cp <= 0x1F64F)
        or (cp >= 0x1F900 and cp <= 0x1F9FF)
        or (cp >= 0x20000 and cp <= 0x3FFFD)
    then return 2 end

    return 1
end

local function tokenize(s)
    s = tostring(s)
    local tokens, i, n = {}, 1, #s
    while i <= n do
        local b = s:byte(i)
        if b == 27 and s:byte(i + 1) == 0x5B then
            -- CSI: ESC [ params?; intermediates? final(0x40..0x7E)
            local j = i + 2
            while j <= n do
                local c = s:byte(j)
                j = j + 1
                if c >= 0x40 and c <= 0x7E then break end
            end
            tokens[#tokens + 1] = { kind = "ansi", value = s:sub(i, j - 1) }
            i = j
        else
            local cp, size = decode_utf8(s, i)
            if i + size - 1 > n then size = n - i + 1 end
            tokens[#tokens + 1] = {
                kind = "char",
                value = s:sub(i, i + size - 1),
                width = cp_width(cp or 0),
            }
            i = i + size
        end
    end
    return tokens
end

--------------------------------------------------------------------------------
-- 6. parse_spec: имена, палитра, fg/bg, 256, RGB, HEX
--------------------------------------------------------------------------------

local function parse_spec(spec)
    if type(spec) == "number" then return { tostring(spec) } end
    if type(spec) ~= "string" or spec == "" then return nil end

    local prefix, rest = spec:match("^([%a%d]+):(.*)$")
    if prefix then
        if prefix == "fg" then
            if M.fg[rest] then return { tostring(M.fg[rest]) } end
            if M.palette[rest] then return { M.fg256(M.palette[rest]) } end
            return nil
        elseif prefix == "bg" then
            if M.bg[rest] then return { tostring(M.bg[rest]) } end
            if M.palette[rest] then return { M.bg256(M.palette[rest]) } end
            return nil
        elseif prefix == "fg256" or prefix == "bg256" then
            local n = tonumber(rest)
            if not n then return nil end
            return { (prefix == "fg256" and M.fg256 or M.bg256)(n) }
        elseif prefix == "fgRGB" or prefix == "bgRGB" then
            local r, g, b = rest:match("^(%d+);(%d+);(%d+)$")
            if not r then return nil end
            return { (prefix == "fgRGB" and M.fgRGB or M.bgRGB)(
                tonumber(r), tonumber(g), tonumber(b)) }
        elseif prefix == "fgHex" or prefix == "bgHex" then
            local code = (prefix == "fgHex" and M.fgHex or M.bgHex)(rest)
            if not code then return nil end
            return { code }
        end
        return nil
    end

    if spec:match("^#") then
        local code = M.fgHex(spec)
        if not code then return nil end
        return { code }
    end

    if spec:match("^%d+[;%d]*$") then return { spec } end

    if M.fg[spec] then return { tostring(M.fg[spec]) } end
    if M.style[spec] then return { tostring(M.style[spec]) } end
    if M.bg[spec] then return { tostring(M.bg[spec]) } end
    if M.palette[spec] then return { M.fg256(M.palette[spec]) } end
    return nil
end

--------------------------------------------------------------------------------
-- 7. Публичный API
--------------------------------------------------------------------------------

function M.color(text, ...)
    local specs = { ... }
    if #specs == 0 then return tostring(text) end

    local codes = {}
    for _, spec in ipairs(specs) do
        local parsed = parse_spec(spec)
        if parsed then
            for _, c in ipairs(parsed) do codes[#codes + 1] = c end
        end
    end

    if not M.enabled or #codes == 0 then return tostring(text) end
    return ESC .. "[" .. table.concat(codes, ";") .. "m"
        .. tostring(text) .. ESC .. "[0m"
end

function M.write_color(text, ...)   io.write(M.color(text, ...)) end
function M.writeln_color(text, ...) io.write(M.color(text, ...), "\n") end

--------------------------------------------------------------------------------
-- 8. Builder
--------------------------------------------------------------------------------

local Builder = {}
Builder.__index = Builder
Builder.__tostring = function(self) return self:_render() end

local function new_builder()
    return setmetatable({
        _codes = {}, _text = "", _reset_tail = ESC .. "[0m",
    }, Builder)
end

local function resolve_fg(name)
    if type(name) == "number" then return tostring(name) end
    if M.fg[name] then return tostring(M.fg[name]) end
    if M.palette[name] then return M.fg256(M.palette[name]) end
    return nil
end
local function resolve_bg(name)
    if type(name) == "number" then return tostring(name) end
    if M.bg[name] then return tostring(M.bg[name]) end
    if M.palette[name] then return M.bg256(M.palette[name]) end
    return nil
end

function Builder:_add(code)
    if code ~= nil and code ~= "" then
        self._codes[#self._codes + 1] = tostring(code)
    end
    return self
end

function Builder:fg(x)
    if type(x) == "string" and x:match("^#") then return self:_add(M.fgHex(x)) end
    return self:_add(resolve_fg(x))
end
function Builder:bg(x)
    if type(x) == "string" and x:match("^#") then return self:_add(M.bgHex(x)) end
    return self:_add(resolve_bg(x))
end
function Builder:fg256(n)     return self:_add(M.fg256(n)) end
function Builder:bg256(n)     return self:_add(M.bg256(n)) end
function Builder:fgRGB(r,g,b) return self:_add(M.fgRGB(r,g,b)) end
function Builder:bgRGB(r,g,b) return self:_add(M.bgRGB(r,g,b)) end
function Builder:fgHex(h)     return self:_add(M.fgHex(h)) end
function Builder:bgHex(h)     return self:_add(M.bgHex(h)) end

for name in pairs(M.style) do
    Builder[name] = function(self) return self:_add(M.style[name]) end
end

function Builder:sgr(...)
    for _, c in ipairs({ ... }) do self:_add(c) end
    return self
end
function Builder:reset_tail(tail) self._reset_tail = tail; return self end
function Builder:text(s) self._text = self._text .. tostring(s); return self end

function Builder:_render()
    if not M.enabled or #self._codes == 0 then return self._text end
    return ESC .. "[" .. table.concat(self._codes, ";") .. "m"
        .. self._text .. (self._reset_tail or "")
end

function Builder:render() return self:_render() end
function Builder:write()  io.write(self:_render()); return self end
function Builder:print(...) print(self:_render(), ...); return self end

M.builder = new_builder

--------------------------------------------------------------------------------
-- 9. Утилиты: strip, len (codepoints), width (columns), pad, truncate
--------------------------------------------------------------------------------

function M.strip(s)
    local out = {}
    for _, t in ipairs(tokenize(s)) do
        if t.kind == "char" then out[#out + 1] = t.value end
    end
    return table.concat(out)
end

-- Количество codepoint'ов (не колонок терминала!).
function M.len(s)
    local n = 0
    for _, t in ipairs(tokenize(s)) do
        if t.kind == "char" then n = n + 1 end
    end
    return n
end

-- Ширина в колонках терминала (учитывает East Asian Wide / emoji).
function M.width(s)
    local w = 0
    for _, t in ipairs(tokenize(s)) do
        if t.kind == "char" then w = w + t.width end
    end
    return w
end

function M.pad_right(s, width, ch)
    ch = ch or " "
    local pad = width - M.width(s)
    if pad <= 0 then return s end
    return s .. ch:rep(pad)
end
function M.pad_left(s, width, ch)
    ch = ch or " "
    local pad = width - M.width(s)
    if pad <= 0 then return s end
    return ch:rep(pad) .. s
end
function M.pad_center(s, width, ch)
    ch = ch or " "
    local pad = width - M.width(s)
    if pad <= 0 then return s end
    local left = math.floor(pad / 2)
    return ch:rep(left) .. s .. ch:rep(pad - left)
end

function M.truncate(s, width, ellipsis)
    ellipsis = ellipsis or "…"
    s = tostring(s)
    if M.width(s) <= width then return s end

    local target = width - M.width(ellipsis)
    if target < 0 then target = 0 end

    local out, w, had_ansi = {}, 0, false
    for _, t in ipairs(tokenize(s)) do
        if t.kind == "ansi" then
            out[#out + 1] = t.value
            had_ansi = true
        else
            if w + t.width > target then break end
            out[#out + 1] = t.value
            w = w + t.width
        end
    end
    out[#out + 1] = ellipsis
    if had_ansi and M.enabled then out[#out + 1] = ESC .. "[0m" end
    return table.concat(out)
end

local function term_width()
    local w = tonumber(os.getenv("COLUMNS"))
    if w and w > 0 then return w end

    if IS_WINDOWS then
        local f = io.popen("mode con", "r")
        if f then
            local out = f:read("*a") or ""
            f:close()
            local cols = out:match("Columns:%s*(%d+)")
            if cols then return tonumber(cols) end
        end
    else
        local f = io.popen("tput cols 2>/dev/null")
        if f then
            local v = (f:read("*l") or ""):match("^(%d+)")
            f:close()
            if v then return tonumber(v) end
        end
        f = io.popen("stty size < /dev/tty 2>/dev/null")
        if f then
            local out = f:read("*a") or ""
            f:close()
            local _, c = out:match("(%d+)%s+(%d+)")
            if c then return tonumber(c) end
        end
    end
    return 80
end
M.term_width = term_width

function M.center(s, width)
    return M.pad_center(s, width or term_width(), " ")
end

--------------------------------------------------------------------------------
-- 10. Демо
--------------------------------------------------------------------------------

function M.demo()
    local function line(t) print(M.color(t, "bold", "bright_white")) end

    line("=== Базовые цвета ===")
    local order = {
        "black","red","green","yellow","blue","magenta","cyan","white",
        "bright_black","bright_red","bright_green","bright_yellow",
        "bright_blue","bright_magenta","bright_cyan","bright_white",
    }
    local buf = {}
    for _, name in ipairs(order) do
        buf[#buf + 1] = M.color(M.pad_right(name, 16), "fg:" .. name)
    end
    print(table.concat(buf, " "))

    line("\n=== Стили ===")
    for _, s in ipairs({
        "bold","dim","italic","underline","blink",
        "reverse","hidden","strikethrough",
    }) do print(M.color(s, s)) end

    line("\n=== Комбинации ===")
    print(M.color("жирный красный на белом", "bold", "fg:red", "bg:white"))
    print(M.color("курсив magenta на чёрном", "italic", "fg:magenta", "bg:black"))
    print(M.color("подчёркнутый cyan", "underline", "fg:bright_cyan"))

    line("\n=== 256 цветов (первые 16) ===")
    local b2 = {}
    for i = 0, 15 do
        b2[#b2 + 1] = M.color(string.format("%3d ", i), "fg256:" .. i)
    end
    print(table.concat(b2))

    line("\n=== 256 цветов (палитра) ===")
    local row = {}
    for i = 16, 255 do
        row[#row + 1] = M.color(" ", "bg256:" .. i)
        if (i - 15) % 36 == 0 then print(table.concat(row)); row = {} end
    end
    if #row > 0 then print(table.concat(row)) end

    line("\n=== TrueColor (градиент) ===")
    local grad = {}
    for i = 0, 40 do
        local r = math.floor(255 * i / 40)
        local b = 255 - r
        grad[#grad + 1] = M.color("█", "fgRGB:" .. r .. ";0;" .. b)
    end
    print(table.concat(grad))

    line("\n=== Hex ===")
    print(M.color("#ff69b4 hot pink",       "fgHex:#ff69b4"))
    print(M.color("#00ced1 dark turquoise", "fgHex:#00ced1"))
    print(M.color("фон #222 на #f0f0f0",    "fgHex:#222222", "bgHex:#f0f0f0"))

    line("\n=== Палитра (builder: fg/bg + palette) ===")
    local pal = {}
    for name in pairs(M.palette) do
        pal[#pal + 1] = M.color(" " .. name .. " ", "fg:" .. name)
    end
    print(table.concat(pal, " "))

    line("\n=== Билдер: :bg('navy') через palette ===")
    print(M.builder()
        :bold():fg("bright_yellow"):bg("navy")
        :text("  Внимание!  ")
        :render())

    line("\n=== Утилиты (UTF-8 + ширина колонок) ===")
    local colored = M.color("Привет, мир! 🚀", "bold", "red")
    print("raw bytes:     ", #colored)
    print("codepoints:    ", M.len(colored))
    print("columns:       ", M.width(colored))
    print("stripped:      ", M.strip(colored))
    print("centered(30):  ", "|" .. M.pad_center(colored, 30) .. "|")
    print("truncate(8):   ", M.truncate(colored, 8))
    print("truncate(4):   ", M.truncate(colored, 4))
    print("enabled:       ", tostring(M.enabled))
    print("term width:    ", M.term_width())
end

return M

--- примеры и апи.

-- # ansi.lua — Документация

-- Расширенная библиотека ANSI-цветов и стилей для Lua. Совместима с **Lua 5.1, 5.2, 5.3, 5.4** и **LuaJIT**. Лицензия: MIT.

-- ---

-- ## Содержание

-- - [Возможности](#возможности)
-- - [Установка](#установка)
-- - [Быстрый старт](#быстрый-старт)
-- - [Поддержка платформ](#поддержка-платформ)
-- - [API](#api)
  -- - [Управление поддержкой цвета](#управление-поддержкой-цвета)
  -- - [Таблицы цветов и стилей](#таблицы-цветов-и-стилей)
  -- - [Функции окрашивания](#функции-окрашивания)
  -- - [Генераторы SGR-кодов](#генераторы-sgr-кодов)
  -- - [HEX-цвета](#hex-цвета)
  -- - [Builder](#builder)
  -- - [Утилиты для строк](#утилиты-для-строк)
  -- - [Ширина терминала](#ширина-терминала)
-- - [Спецификации цветов (`spec`)](#спецификации-цветов-spec)
-- - [Примеры](#примеры)
-- - [Демо](#демо)

-- ---

-- ## Возможности

-- - **Автоопределение** поддержки цвета (TTY, переменные окружения, Windows VT).
-- - **Windows**: включает Virtual Terminal Processing через FFI (LuaJIT).
-- - **256 цветов** и **TrueColor (RGB)**.
-- - **HEX-цвета** (`#RRGGBB`, `#RGB`).
-- - **Стили**: bold, italic, underline, blink, reverse и др.
-- - **UTF-8**: корректный подсчёт codepoint'ов, ширины колонок (East Asian Width, emoji), обрезка и выравнивание.
-- - **Fluent Builder** для составления сложных строк.
-- - Уважает стандарты [no-color.org](https://no-color.org) (`NO_COLOR`) и `FORCE_COLOR`.
-- - Работает **без FFI** и **без Lua 5.3-синтаксиса** — единый файл для всех версий Lua.

-- ---

-- ## Установка

-- Просто скопируйте файл `ansi.lua` в проект и подключите:

-- ```lua
-- local ansi = require("ansi")
-- ```

-- ---

-- ## Быстрый старт

-- ```lua
-- local ansi = require("ansi")

-- -- Простое окрашивание
-- print(ansi.color("Привет!", "bold", "red"))
-- print(ansi.color("Ошибка", "fg:bright_red", "bg:black", "underline"))

-- -- 256 цветов
-- print(ansi.color("палитра", "fg256:208"))

-- -- TrueColor
-- print(ansi.color("градиент", "fgRGB:255;100;0"))

-- -- HEX
-- print(ansi.color("hot pink", "fgHex:#ff69b4"))

-- -- Builder
-- print(ansi.builder()
    -- :bold():fg("bright_yellow"):bg("navy")
    -- :text("  Внимание!  ")
    -- :render())
-- ```

-- ---

-- ## Поддержка платформ

-- Библиотека автоматически определяет, поддерживает ли вывод цвета:

-- | Окружение | Поведение |
-- |---|---|
-- | **Unix / macOS** | Проверяется `isatty(stdout)`. Если TTY — цвет включён. |
-- | **Windows Terminal, ConEmu, ANSICON** | VT включается автоматически (через FFI или принудительно). |
-- | **Старый cmd.exe** | Цвет отключён (не поддерживает ANSI). |
-- | **`TERM=dumb`** | Цвет отключён. |
-- | **`NO_COLOR`** (непустое значение) | Цвет **принудительно отключён**. |
-- | **`FORCE_COLOR`** (непустое, не `0`) | Цвет **принудительно включён**. |

-- ### Переопределение

-- ```lua
-- ansi.enable()          -- принудительно включить
-- ansi.disable()         -- принудительно выключить
-- ansi.set_enabled(false)
-- print(ansi.is_enabled())
-- ```

-- > Даже если цвет отключён, все функции возвращают корректные строки **без ANSI-последовательностей** — код не «сломается» в перенаправленном выводе.

-- ---

-- ## API

-- ### Управление поддержкой цвета

-- | Функция | Описание |
-- |---|---|
-- | `ansi.enabled` | Текущее состояние (boolean). |
-- | `ansi.is_enabled()` | Возвращает `true`, если цвет включён. |
-- | `ansi.enable()` | Включает цвет. |
-- | `ansi.disable()` | Выключает цвет. |
-- | `ansi.set_enabled(v)` | Устанавливает состояние (`not not v`). |
-- | `ansi.RESET()` | Возвращает код сброса (`ESC[0m`) или пустую строку. |

-- ---

-- ### Таблицы цветов и стилей

-- #### `ansi.fg` — цвета переднего плана

-- ```lua
-- black, red, green, yellow, blue, magenta, cyan, white, default,
-- bright_black, bright_red, bright_green, bright_yellow,
-- bright_blue, bright_magenta, bright_cyan, bright_white,
-- -- алиасы:
-- gray, grey, dark_gray, dark_grey,
-- light_red, light_green, light_yellow,
-- light_blue, light_magenta, light_cyan, light_white
-- ```

-- #### `ansi.bg` — цвета фона

-- Те же имена, что и в `ansi.fg`, но для фона.

-- #### `ansi.style` — стили

-- ```lua
-- reset, bold, dim, faint, italic, underline,
-- slow_blink, blink, rapid_blink,
-- reverse, inverse, hidden, conceal, strikethrough,
-- reset_bold, reset_dim, reset_italic, reset_underline,
-- reset_blink, reset_reverse, reset_hidden,
-- reset_strikethrough, reset_fg, reset_bg
-- ```

-- #### `ansi.palette` — 256-цветная палитра

-- ```lua
-- orange, pink, purple, teal, lime, gold,
-- indigo, crimson, salmon, sky, mint, coral,
-- violet, olive, maroon, navy, forest, brown
-- ```

-- ---

-- ### Функции окрашивания

-- ```lua
-- ansi.color(text, ...spec) -> string
-- ansi.write_color(text, ...spec)
-- ansi.writeln_color(text, ...spec)
-- ```

-- - `text` — что окрасить (приводится к строке).
-- - `...spec` — одна или несколько спецификаций (см. раздел [spec](#спецификации-цветов-spec)).

-- ```lua
-- print(ansi.color("OK", "bold", "fg:green"))
-- ansi.writeln_color("Done", "italic", "fg:cyan")
-- ```

-- ---

-- ### Генераторы SGR-кодов

-- Возвращают строку-код вида `38;5;n` или `38;2;r;g;b`, готовую для передачи в `ansi.color` / `Builder:sgr`.

-- ```lua
-- ansi.fg256(n)     -> "38;5;n"      -- n: 0..255
-- ansi.bg256(n)     -> "48;5;n"
-- ansi.fgRGB(r,g,b) -> "38;2;r;g;b"
-- ansi.bgRGB(r,g,b) -> "48;2;r;g;b"
-- ansi.clamp_byte(n)-> 0..255
-- ```

-- ---

-- ### HEX-цвета

-- ```lua
-- ansi.hex_to_rgb("#ff69b4") -> 255, 105, 180
-- ansi.hex_to_rgb("#f0a")    -> 255, 0, 170   -- 3-значная форма
-- ansi.hex_to_rgb("bad")     -> nil          -- невалидно

-- ansi.fgHex("#ff69b4") -> "38;2;255;105;180"
-- ansi.bgHex("#222222") -> "48;2;34;34;34"
-- ```

-- Поддерживаются формы `#RGB` и `#RRGGBB`.

-- ---

-- ### Builder

-- Fluent-конструктор для составления цепочек стилей и текста.

-- ```lua
-- local s = ansi.builder()
-- ```

-- **Методы стилей** (динамически сгенерированы из `ansi.style`):

-- ```lua
-- b:bold()  b:italic()  b:underline()  b:blink()
-- b:reverse()  b:hidden()  b:strikethrough()
-- b:dim()  -- и остальные
-- ```

-- **Методы цвета:**

-- ```lua
-- b:fg(name|number|"#hex")  b:bg(name|number|"#hex")
-- b:fg256(n)  b:bg256(n)
-- b:fgRGB(r,g,b)  b:bgRGB(r,g,b)
-- b:fgHex("#ff00aa")  b:bgHex("#000000")
-- ```

-- **Прочее:**

-- ```lua
-- b:text("строка")        -- добавить текст
-- b:sgr(codes...)         -- произвольные SGR-коды
-- b:reset_tail(custom)    -- заменить финальный сброс (по умолчанию ESC[0m)
-- b:render()  b:_render() -- получить строку
-- b:write()               -- вывести через io.write
-- b:print(...)            -- вывести через print
-- ```

-- **Пример:**

-- ```lua
-- print(ansi.builder()
    -- :bold():italic()
    -- :fg("bright_yellow"):bg("navy")
    -- :text("  Внимание!  ")
    -- :render())
-- ```

-- Builder поддерживает `__tostring`, поэтому его можно использовать в конкатенации:

-- ```lua
-- local msg = "результат: " .. tostring(ansi.builder():fg("lime"):text("OK"))
-- ```

-- ---

-- ### Утилиты для строк

-- Все функции корректно игнорируют ANSI-последовательности и учитывают UTF-8.

-- ```lua
-- ansi.strip(s)                    -- удалить все ANSI-коды
-- ansi.len(s)                      -- число codepoint'ов (не колонок!)
-- ansi.width(s)                    -- ширина в колонках терминала
-- ```

-- **Выравнивание** (по колонкам терминала):

-- ```lua
-- ansi.pad_right(s, width [, ch])  -- дополнить справа
-- ansi.pad_left(s, width [, ch])   -- дополнить слева
-- ansi.pad_center(s, width [, ch]) -- центрировать
-- ```

-- **Обрезка с сохранением ANSI:**

-- ```lua
-- ansi.truncate(s, width [, ellipsis]) -- по умолчанию ellipsis = "…"
-- ```

-- Пример:

-- ```lua
-- local s = ansi.color("Привет, мир! 🚀", "bold", "red")

-- print(ansi.width(s))         -- 15 (Привет=6 + ", "=2 + мир=3 + "!"=1 + "🚀"=2 + " "=1... с учётом ширины)
-- print(ansi.strip(s))         -- "Привет, мир! 🚀"
-- print("|" .. ansi.pad_center(s, 30) .. "|")
-- print(ansi.truncate(s, 8))   -- "Привет…"
-- ```

-- ---

-- ### Ширина терминала

-- ```lua
-- ansi.term_width() -> number
-- ```

-- Определяет ширину терминала в колонках:

-- 1. `$COLUMNS`
-- 2. Windows: `mode con`
-- 3. Unix: `tput cols` → `stty size < /dev/tty`
-- 4. Fallback: `80`

-- ```lua
-- ansi.center(s [, width]) -- центрировать по ширине (по умолчанию — term_width())
-- ```

-- ---

-- ## Спецификации цветов (`spec`)

-- Функция `ansi.color(text, ...spec)` и методы Builder принимают спецификации в нескольких форматах.

-- | Формат | Пример | Описание |
-- |---|---|---|
-- | **Имя fg** | `"red"` | `ansi.fg.red` → `31` |
-- | **Имя bg** | `"bg:red"` | `ansi.bg.red` → `41` |
-- | **Имя fg (явно)** | `"fg:bright_red"` | `ansi.fg.bright_red` → `91` |
-- | **Палитра** | `"orange"` | `ansi.palette.orange` → `fg256:208` |
-- | **Палитра как bg** | `"bg:navy"` | `bg256:17` |
-- | **Стиль** | `"bold"`, `"underline"` | `ansi.style.bold` → `1` |
-- | **256 fg** | `"fg256:208"` | `38;5;208` |
-- | **256 bg** | `"bg256:17"` | `48;5;17` |
-- | **RGB fg** | `"fgRGB:255;100;0"` | `38;2;255;100;0` |
-- | **RGB bg** | `"bgRGB:0;0;0"` | `48;2;0;0;0` |
-- | **HEX fg** | `"#ff69b4"` или `"fgHex:#ff69b4"` | `38;2;255;105;180` |
-- | **HEX bg** | `"bgHex:#222222"` | `48;2;34;34;34` |
-- | **Готовый SGR** | `"1;31"` | вставляется как есть |
-- | **Число** | `31` | превращается в `"31"` |

-- Невалидные спецификации **молча игнорируются**.

-- ```lua
-- ansi.color("текст", "bold", "fg:red", "bgHex:#fff")
-- ```

-- ---

-- ## Примеры

-- ### Логирование с уровнями

-- ```lua
-- local ansi = require("ansi")

-- local function log(level, msg)
    -- local colors = {
        -- INFO  = { "fg:bright_cyan" },
        -- WARN  = { "fg:bright_yellow", "bold" },
        -- ERROR = { "fg:bright_red", "bold", "underline" },
    -- }
    -- local tag = ansi.color("[" .. level .. "]", unpack(colors[level] or {}))
    -- print(tag, msg)
-- end

-- log("INFO",  "сервер запущен")
-- log("WARN",  "мало памяти")
-- log("ERROR", "соединение потеряно")
-- ```

-- ### Прогресс-бар

-- ```lua
-- local function progress(p, width)
    -- width = width or 40
    -- local filled = math.floor(width * p)
    -- local bar = ansi.color(("█"):rep(filled), "fg:lime")
              -- .. ansi.color(("░"):rep(width - filled), "fg:bright_black")
    -- io.write("\r[" .. bar .. "] " .. math.floor(p * 100) .. "%")
    -- io.flush()
-- end
-- ```

-- ### Таблица с выравниванием

-- ```lua
-- local rows = {
    -- { "Имя", "Возраст" },
    -- { "Алиса", "30" },
    -- { "Боб", "25" },
-- }
-- for _, row in ipairs(rows) do
    -- print(ansi.pad_right(row[1], 20) .. ansi.pad_left(row[2], 10))
-- end
-- ```

-- ### Градиент

-- ```lua
-- local parts = {}
-- for i = 0, 40 do
    -- local r = math.floor(255 * i / 40)
    -- local b = 255 - r
    -- parts[#parts + 1] = ansi.color("█", "fgRGB:" .. r .. ";0;" .. b)
-- end
-- print(table.concat(parts))
-- ```

-- ---

-- ## Демо

-- Полное демо можно запустить одной командой:

-- ```lua
-- require("ansi").demo()
-- ```

-- Оно выведет:

-- - базовые 16 цветов,
-- - все стили,
-- - комбинации,
-- - первые 16 и полную палитру 256 цветов,
-- - TrueColor-градиент,
-- - примеры HEX,
-- - именованную палитру,
-- - пример использования Builder,
-- - работу утилит (`len`, `width`, `strip`, `pad_*`, `truncate`).

-- ---

-- ## Замечания

-- - Библиотека **не изменяет** глобальное состояние терминала, кроме явного включения VT на Windows (через FFI).
-- - При отключённом цвете (`ansi.disable()`, `NO_COLOR`, не-TTY) все функции возвращают исходный текст без ANSI-кодов — строки остаются «чистыми».
-- - `ansi.len(s)` считает **codepoint'ы**, а `ansi.width(s)` — **колонки терминала**. Для выравнивания всегда используйте `width`.
-- - На Windows без LuaJIT VT-режим включить нельзя — цвет будет отключён, но код продолжит работать без ошибок.

