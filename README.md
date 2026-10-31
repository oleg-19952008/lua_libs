# lua-libs

Набор чистопородных Lua-библиотек без внешних зависимостей (только стандартная библиотека).
Основная целевая платформа — **Lua 5.1.4 / Windows**, за исключением `color.lua`
(кроссплатформенная) и `base64.lua` (Lua 5.1+, кроссплатформенная).

## Содержание

| Файл | Назначение | Платформа | Тесты |
|---|---|---|---|
| [`base64.lua`](base64.lua) | Base64-кодек: RFC 4648 + URL-safe | любая, Lua 5.1+ | — |
| [`color.lua`](color.lua) | Расширенная ANSI-раскраска терминала (MIT) | любая (Win VT + POSIX TTY) | — |
| [`paths.lua`](paths.lua) | Пути и файловая система Windows | только Windows | `test_paths.lua`, `test_listFiles.lua` |
| [`random.lua`](random.lua) | Генератор случайных байт, многоисточниковый seed | Windows, Lua 5.1.4 | self-test в самом файле |

## Запуск тестов

```bat
lua51 test_paths.lua          :: чистый разбор + ФС-секции paths.lua
lua51 test_listFiles.lua      :: 70+ тестов list*/exists (грузит paths.lua)
lua51 test_listFiles.lua path\to\другой_модуль.lua   :: явная подмена модуля
lua random.lua                :: встроенный self-test генератора
```

Тесты путей требуют Windows (`io.popen` + `cmd.exe`). Чистые секции разбора
работоспособны и под другим Lua — проверено на `lua5.1` (101 assertion, 0 fail).

---

## base64.lua

Компактный Base64-кодек для Lua 5.1+ без внешних зависимостей. Поддерживает
стандартный (RFC 4648) и URL-safe (RFC 4648 §5) алфавиты.

**API**

| Функция | Описание |
|---|---|
| `base64.encode(data [, url_safe])` | Кодирование в Base64; `url_safe = true` → `-`/`_` вместо `+`/`/` и без padding `=`. `error` при не-строке. |
| `base64.encode_url(data)` | Эквивалент `encode(data, true)`. |
| `base64.decode(data)` | Возвращает `decoded, err` — при мусоре `nil, 'invalid base64 …'` вместо исключения. |
| `base64.decode_url(data)` | Декодирование URL-safe варианта. |

```lua
local b64 = require('base64')
b64.encode('hello')       -- 'aGVsbG8='
b64.encode_url('hello')   -- 'aGVsbG8'
b64.decode('aGVsbG8=')    -- 'hello'
```

---

## color.lua

Расширенная ANSI-библиотека. Совместима с Lua 5.1, 5.2, 5.3, 5.4 и LuaJIT.
Лицензия: MIT.

Возможности:

* **Автоопределение поддержки цвета**: TTY, переменные окружения (`NO_COLOR`,
  `FORCE_COLOR`, `TERM=dumb`…), включение Windows Virtual Terminal через
  `GetConsoleMode/SetConsoleMode` (с арифметическим `bor`-fallback, если нет
  `bit`/`bit32`). Всё это можно переопределить: `M.set_enabled(v)`,
  `M.enable()`, `M.disable()`, `M.is_enabled()`.
* **Палитры**: 16 базовых (`M.fg.*`, `M.bg.*`), стили (`M.style.*`: bold, dim,
  italic, underline, blink, reverse, hidden, strike), 256-цветные (`M.fg256`,
  `M.bg256`), TrueColor (`M.fgRGB/bgRGB`), HEX (`M.hex_to_rgb`, `M.fgHex`,
  `M.bgHex`), расширенная таблица `M.palette`.
* **Применение**: `M.color(text, ...)` (комбинация fg/bg/style), `M.write_color`,
  `M.writeln_color`, цепочечный `M.builder()` и `M.demo()`.
* **UTF-8-утилиты для работы с уже раскрашенным текстом**: `M.strip` (снятие
  escape-последовательностей), `M.len`, `M.width` (ширина с учётом wide/CJK),
  `M.pad_right/pad_left/pad_center`, `M.truncate` (с многоточием), `M.center`,
  `M.term_width`.
* Утилита `M.clamp_byte(n)` и константа сброса `M.RESET()`.

```lua
local c = require('color')
c.writeln_color('Ошибка!', c.fg.red, c.style.bold)
print(c.pad_center(c.color('MENU', c.fg.cyan), 20))
```

---

## paths.lua

Windows-only модуль работы с путями и файловой системой на чистом Lua
(Lua 5.1.4+): разбор путей, склейка, листинг каталогов, проверка существования,
CWD процесса и каталог скрипта. Реализация листинга обходит классические
проблемы `dir /b` через `cmd /u` (вывод в UTF-16LE с ручным декодированием),
передачу пути через temp-файл + `set /p` (защита от раскрытия `%VAR%`, спецсимволов
`& | < > ^` и delayed expansion) и чтение пайпа в бинарном режиме.

**Публичный API**

Разбор путей (чистые функции, без доступа к ФС):

| Функция | Описание |
|---|---|
| `M.normalizePath(path [, trimTrailingSlash])` | Нормализация: `/`→`\`, схлопывание повторных разделителей, `"C:"`→`"C:\"`; assert на пустую/не-строку. По умолчанию хвостовой `\` снимается; `trimTrailingSlash=false` — сохраняется (режим совместимости `pathCombine`). |
| `M.isAbsolutePath(path)` | `true` для `C:\…`, UNC `\\server\share` и корня текущего диска `\foo` (полный резолв `\foo` всё равно требует CWD). |
| `M.getFileName(path)` | Имя файла или `""` для корней (диск, `\`, UNC-share). |
| `M.getExtension(path)` | `.ext` в нижнем регистре; `""` для dot-файлов (`.bashrc`) и точек на конце (`a.`). |
| `M.getDirName(path)` | Каталог без имени файла; корректно для корней дисков, UNC и drive-relative `C:foo`. |

Склейка:

| Функция | Описание |
|---|---|
| `M.joinPath(dir, name)` | Нормализованный путь; nil/`""`-толерантен; абсолютный `name` выигрывает (соглашение .NET/Python); `joinPath(dir, "") == dir`. |
| `M.pathCombine(a, b)` | Режим обратной совместимости со старым `listFiles.lua`: хвостовой разделитель сохраняется, `pathCombine(dir, "") == dir .. "\"`. |

Среда: `M.getCwd()` (кэш; `"C:\"` для корня диска), `M.resetCwdCache()` (после
chdir из хоста), `M.getScriptDir()`.

Файловая система: `M.fileExists(path)` (только регулярные файлы; `if exist`
не отличает устройства NUL/CON/COM1…), `M.dirExists(path)`, `M.listFiles(dir)`
(имена файлов, без рекурсии), `M.listFilesRecursive(dir)` (полные пути),
`M.listDirs(dir)`, `M.renameFile(oldPath, newName)` (валидация «безопасного»
имени, `nil, err` при отказе).

Контракты и ограничения (выборочно): `{}` и для пустой, и для несуществующей
папки (проверяйте `dirExists` отдельно); входные пути ожидаются в UTF-8; каждый
вызов листинга спавнит `cmd` и два temp-файла (медленно — кэшируйте); нет
метаданных (size/mtime); путь >1023 символа обрезается `set /p`; относительные
пути резолвятся по закэшированному CWD процесса. Для внутреннего использования
тестами экспортируется `M._test` (`utf16leToUtf8`, `makeTempPair`, `runBat`,
`lcgNext/lcgSeed/lcgReset` и др.) — контракт может меняться без предупреждения.

---

## random.lua

Генератор случайных байт для утилиты переименования. Lua 5.1.4, Windows;
без C-модулей, `io.popen` и `os.execute`.

| Элемент | Описание |
|---|---|
| `M.initRandom([custom_seed])` | Инициализация seed: свёртка-хеш нескольких источников энтропии (время, часы, прочее); опциональный числовой `custom_seed` — для воспроизводимости; seed приводится к диапазону `1..2147483646`. |
| `M.getRandomBytes(n)` | Строка из `n` байт `0x00–0xFF`; единственное место вызова `math.random`; защита от гигантских буферов (`M.MAX_BYTES = 65536`, больше/некорректное значение → `""`). |
| `M.MAX_BYTES` | Максимум байт за вызов (65536). |
| self-test | `lua random.lua` прогоняет внутренние проверки (диапазоны, распределение, детерминизм seed) и печатает отпечаток запуска. |

```lua
local random = dofile("random.lua")
random.initRandom()
local bytes = random.getRandomBytes(16)
```

---

## Тестовые файлы

* **test_paths.lua** — тесты `paths.lua`: чистый разбор (`normalizePath`,
  `isAbsolutePath`, `getFileName`, `getExtension`, `getDirName`), склейка
  (`joinPath`/`pathCombine` — разные контракты), UTF-16LE→UTF-8 (BMP, суррогаты),
  LCG, `makeAbs`, `getScriptDir`, `getCwd/resetCwdCache`, секции ФС на временном
  каталоге. Запуск: `lua51 test_paths.lua` из каталога модуля.
* **test_listFiles.lua** — 70+ тестов листинга (`listFiles`, `listDirs`,
  `listFilesRecursive`, `dirExists`, фикстуры с пробелами, `%`, `!`, `&`,
  кириллицей) плюс группы `_test`-хелперов. Исторически писался под отдельный
  модуль `listFiles.lua`, который был объединён в `paths.lua`; теперь по
  умолчанию загружает `paths.lua` (можно переопределить первым аргументом или
  переменной окружения `LISTFILES_MODULE`). Тесты, требующие недоступных
  хелперов, помечаются skipped, а не failed.
