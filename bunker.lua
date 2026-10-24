-- bunker.lua : мониторинг бункера (3 комнаты) на голографическом проекторе
-- Запуск:   bunker.lua setup   (калибровка датчиков)
--           bunker.lua         (рабочий режим)
-- Горячие клавиши в рабочем режиме:
--   x  - отзеркалить ось X     z - отзеркалить ось Z
--   s  - поменять оси X и Z    +/- - масштаб голограммы
--   q  - выход

local component = require("component")
local event = require("event")
local term = require("term")
local computer = require("computer")
local serialization = require("serialization")

local args = {...}
local gpu = component.gpu

---------------------------------------------------------------------
-- НАСТРОЙКИ ГЕОМЕТРИИ (можно менять)
---------------------------------------------------------------------
local ROOM_N  = 3      -- количество комнат
local VPB     = 2      -- вокселей на 1 блок бункера
local ROOM_W  = 10     -- ширина комнаты в вокселях (5 блоков * 2)
local DEPTH   = 10     -- глубина комнаты в вокселях
local WALL_H  = 4      -- высота стен в слоях
local X0, Z0  = 8, 18  -- левый-верхний угол карты в сетке 48x48
local DOORS   = true   -- проёмы между комнатами
local MAX_SLOT = 8     -- сколько игроков различаем по высоте маркера

-- Цвета голограммы (номера палитры 1..3)
local C_WALL, C_FLOOR_ON, C_MARK = 1, 2, 3
local COLORS = {0x2288FF, 0x22DD66, 0xFF3322} -- стены, занятая комната, маркер

local CFG_PATH = "/home/bunker.cfg"

---------------------------------------------------------------------
-- КОНФИГ
---------------------------------------------------------------------
local function loadCfg()
  local cfg = {}
  local f = io.open(CFG_PATH, "r")
  if f then
    local t = serialization.unserialize(f:read("*a"))
    f:close()
    if type(t) == "table" then cfg = t end
  end
  local defaults = {
    rooms = {{}, {}, {}},
    names = {"Комната 1", "Комната 2", "Комната 3"},
    flipx = false, flipz = false, swap = false,
    scale = 1.0,
    timeout = 120,   -- секунд без движения -> игрок считается ушедшим (0 = никогда)
    players = {},    -- белый список ников, пусто = любые сущности
    sens = nil,      -- чувствительность датчиков (0..1), nil = по умолчанию
  }
  for k, v in pairs(defaults) do
    if cfg[k] == nil then cfg[k] = v end
  end
  return cfg
end

local cfg = loadCfg()

local function saveCfg()
  local f = assert(io.open(CFG_PATH, "w"))
  f:write(serialization.serialize(cfg))
  f:close()
end

---------------------------------------------------------------------
-- КАЛИБРОВКА
---------------------------------------------------------------------
-- Ждёт первое событие движения, затем 'window' секунд собирает данные
local function collect(timeoutFirst, window)
  local res, start = {}, nil
  local giveUp = computer.uptime() + timeoutFirst
  while true do
    local now = computer.uptime()
    if start and now > start + window then break end
    if not start and now > giveUp then break end
    local _, addr, x, y, z = event.pull(0.2, "motion")
    if addr then
      start = start or now
      local r = res[addr] or {n = 0, sx = 0, sz = 0}
      r.n, r.sx, r.sz = r.n + 1, r.sx + x, r.sz + z
      res[addr] = r
    end
  end
  return res
end

local function setup()
  term.clear()
  print("=== КАЛИБРОВКА ДАТЧИКОВ ===")
  print("В бункере должен быть только один игрок.")
  local used = {}
  for i = 1, ROOM_N do
    while true do
      print("")
      print("Комната " .. i .. ": встаньте ТОЧНО В ЦЕНТР комнаты (под датчиком)")
      print("и переступайте на месте ~5 секунд...")
      local res = collect(120, 5)
      local best, bn = nil, 0
      for a, r in pairs(res) do
        if r.n > bn then best, bn = a, r.n end
      end
      if not best then
        print("Датчик не ответил. Повтор.")
      elseif bn < 3 then
        print("Слишком мало данных (" .. bn .. "). Двигайтесь активнее. Повтор.")
      elseif used[best] then
        print("Этот датчик уже привязан к другой комнате. Повтор.")
      else
        used[best] = true
        cfg.rooms[i] = {
          addr = best,
          ox = res[best].sx / bn, -- смещение датчика относительно центра комнаты
          oz = res[best].sz / bn,
        }
        print(string.format("OK: %s...  событий: %d  смещение: %.2f / %.2f",
          best:sub(1, 8), bn, cfg.rooms[i].ox, cfg.rooms[i].oz))
        break
      end
    end
  end
  saveCfg()
  print("")
  print("Готово, конфиг сохранён в " .. CFG_PATH)
  print("Теперь запустите bunker.lua и проверьте оси (клавиши x, z, s).")
end

if args[1] == "setup" then
  setup()
  return
end

---------------------------------------------------------------------
-- ПРОВЕРКИ ОБОРУДОВАНИЯ
---------------------------------------------------------------------
if not component.isAvailable("hologram") then
  print("Голографический проектор не найден!")
  return
end
local holo = component.hologram

local roomOf = {}
for i = 1, ROOM_N do
  local a = cfg.rooms[i] and cfg.rooms[i].addr
  if a then roomOf[a] = i else
    print("Комната " .. i .. " не откалибрована. Запустите: bunker.lua setup")
    return
  end
end

local allowed, useWhitelist = {}, false
for _, n in ipairs(cfg.players) do allowed[n] = true; useWhitelist = true end

if cfg.sens then
  for addr in component.list("motion_sensor") do
    pcall(component.invoke, addr, "setSensitivity", cfg.sens)
  end
end

---------------------------------------------------------------------
-- ГОЛОГРАММА
---------------------------------------------------------------------
local floor, max, min = math.floor, math.max, math.min
local function clamp(v, a, b) return max(a, min(b, v)) end

local function ix0(i) return X0 + 1 + (i - 1) * (ROOM_W + 1) end
local iz0 = Z0 + 1

local function drawFloor(i, color)
  for x = ix0(i), ix0(i) + ROOM_W - 1 do
    for z = iz0, iz0 + DEPTH - 1 do
      holo.fill(x, z, 1, 1, color)
    end
  end
end

local function drawStatic()
  holo.clear()
  for idx = 1, 3 do holo.setPaletteColor(idx, COLORS[idx]) end
  pcall(holo.setRotationSpeed, 0, 0, 1, 0)
  pcall(holo.setRotation, 0, 0, 1, 0)
  holo.setScale(cfg.scale)
  local xEnd = X0 + ROOM_N * (ROOM_W + 1)
  local zEnd = Z0 + DEPTH + 1
  local doorZ = Z0 + 1 + floor(DEPTH / 2) - 1
  for x = X0, xEnd do
    for z = Z0, zEnd do
      local onX = ((x - X0) % (ROOM_W + 1) == 0)
      local border = (z == Z0 or z == zEnd)
      if border or onX then
        local isDoor = DOORS and onX and not border and x > X0 and x < xEnd
          and (z == doorZ or z == doorZ + 1)
        if isDoor then
          holo.fill(x, z, 1, 1, C_WALL)
        else
          holo.fill(x, z, 1, WALL_H, C_WALL)
        end
      end
    end
  end
  for i = 1, ROOM_N do drawFloor(i, C_WALL) end
end

---------------------------------------------------------------------
-- СОСТОЯНИЕ
---------------------------------------------------------------------
local players = {}     -- ник -> {room, rx, rz, slot, last}
local slots = {}       -- слот -> ник
local floorColor = {}  -- room -> текущий цвет пола
local drawn = {}       -- room -> список нарисованных колонок маркеров
local dirty = {}
local logLines = {}
local needRender = true

local function addLog(msg)
  table.insert(logLines, os.date("%H:%M") .. "  " .. msg)
  while #logLines > 8 do table.remove(logLines, 1) end
  needRender = true
end

local function freeSlot(name)
  for s = 1, MAX_SLOT do
    if not slots[s] then slots[s] = name; return s end
  end
  return MAX_SLOT
end

-- применяем флаги осей
local function transform(rx, rz)
  local a, b = rx, rz
  if cfg.swap then a, b = b, a end
  if cfg.flipx then a = -a end
  if cfg.flipz then b = -b end
  return a, b
end

local function drawRoom(i)
  for _, c in ipairs(drawn[i] or {}) do holo.fill(c[1], c[2], 2, 32, 0) end
  drawn[i] = {}
  local list = {}
  for _, p in pairs(players) do
    if p.room == i then list[#list + 1] = p end
  end
  local want = (#list > 0) and C_FLOOR_ON or C_WALL
  if floorColor[i] ~= want then
    drawFloor(i, want)
    floorColor[i] = want
  end
  for _, p in ipairs(list) do
    local a, b = transform(p.rx, p.rz)
    local cx = ix0(i) + ROOM_W / 2 + a * VPB
    local cz = iz0 + DEPTH / 2 + b * VPB
    local vx = clamp(floor(cx - 0.5), ix0(i), ix0(i) + ROOM_W - 2)
    local vz = clamp(floor(cz - 0.5), iz0, iz0 + DEPTH - 2)
    local top = clamp(WALL_H + p.slot * 3, 2, 32)
    for dx = 0, 1 do
      for dz = 0, 1 do
        holo.fill(vx + dx, vz + dz, 2, top, C_MARK)
        drawn[i][#drawn[i] + 1] = {vx + dx, vz + dz}
      end
    end
  end
end

---------------------------------------------------------------------
-- ЭКРАН
---------------------------------------------------------------------
local function render()
  gpu.setBackground(0x000000)
  term.clear()
  gpu.setForeground(0xFFFFFF)
  print("=== БУНКЕР: МОНИТОРИНГ ===")
  print("")
  for i = 1, ROOM_N do
    local names = {}
    for n, p in pairs(players) do
      if p.room == i then names[#names + 1] = string.format("%s [#%d]", n, p.slot) end
    end
    table.sort(names)
    gpu.setForeground(#names > 0 and 0x22DD66 or 0x777777)
    print(cfg.names[i] .. ": " .. (#names > 0 and table.concat(names, ", ") or "пусто"))
  end
  gpu.setForeground(0xAAAAAA)
  print("")
  print("[#N] = маркер на голограмме, чем больше N, тем выше столбик")
  print("")
  gpu.setForeground(0xFFFFFF)
  print("Последние события:")
  gpu.setForeground(0xCCCCCC)
  for _, l in ipairs(logLines) do print(l) end
  gpu.setForeground(0x666666)
  print("")
  print(string.format("оси: swap=%s flipX=%s flipZ=%s | масштаб %.2f",
    tostring(cfg.swap), tostring(cfg.flipx), tostring(cfg.flipz), cfg.scale))
  print("x/z - зеркало, s - обмен осей, +/- масштаб, q - выход")
  gpu.setForeground(0xFFFFFF)
end

---------------------------------------------------------------------
-- ОБРАБОТКА СОБЫТИЙ
---------------------------------------------------------------------
local function handleMotion(addr, x, z, name)
  local r = roomOf[addr]
  if not r then return end
  if useWhitelist and not allowed[name] then return end
  local room = cfg.rooms[r]
  local p = players[name]
  if not p then
    p = {slot = freeSlot(name)}
    players[name] = p
    addLog(name .. " появился: " .. cfg.names[r])
  elseif p.room ~= r then
    if p.room then dirty[p.room] = true end
    addLog(name .. ": " .. cfg.names[p.room] .. " -> " .. cfg.names[r])
  end
  p.room = r
  p.rx = x - (room.ox or 0)
  p.rz = z - (room.oz or 0)
  p.last = computer.uptime()
  dirty[r] = true
end

local function markAllDirty()
  for i = 1, ROOM_N do dirty[i] = true end
  needRender = true
end

local function handleKey(char)
  if char == 120 then cfg.flipx = not cfg.flipx; saveCfg(); markAllDirty()       -- x
  elseif char == 122 then cfg.flipz = not cfg.flipz; saveCfg(); markAllDirty()   -- z
  elseif char == 115 then cfg.swap = not cfg.swap; saveCfg(); markAllDirty()     -- s
  elseif char == 43 or char == 61 then                                           -- +
    cfg.scale = min(5, cfg.scale + 0.25); holo.setScale(cfg.scale); saveCfg(); needRender = true
  elseif char == 45 then                                                         -- -
    cfg.scale = max(0.33, cfg.scale - 0.25); holo.setScale(cfg.scale); saveCfg(); needRender = true
  elseif char == 113 then return true                                            -- q
  end
end

local function checkTimeouts()
  if cfg.timeout <= 0 then return end
  local now = computer.uptime()
  for name, p in pairs(players) do
    if now - p.last > cfg.timeout then
      dirty[p.room] = true
      slots[p.slot] = nil
      players[name] = nil
      addLog(name .. " не виден, убран с карты")
    end
  end
end

---------------------------------------------------------------------
-- ГЛАВНЫЙ ЦИКЛ
---------------------------------------------------------------------
local function main()
  drawStatic()
  markAllDirty()
  local lastDraw = 0
  while true do
    local ev = {event.pull(0.2)}
    local name = ev[1]
    if name == "motion" then
      handleMotion(ev[2], ev[3], ev[5], ev[6])
    elseif name == "key_down" then
      if handleKey(ev[3]) then return end
    elseif name == "interrupted" then
      return
    end
    checkTimeouts()
    local now = computer.uptime()
    if now - lastDraw > 0.25 then
      for i = 1, ROOM_N do
        if dirty[i] then drawRoom(i); dirty[i] = false; needRender = true end
      end
      if needRender then render(); needRender = false end
      lastDraw = now
    end
  end
end

local ok, err = pcall(main)
gpu.setForeground(0xFFFFFF)
if not ok and tostring(err):find("interrupted") == nil then
  print("Ошибка: " .. tostring(err))
else
  print("Остановлено.")
end
