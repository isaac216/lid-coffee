-- lid-coffee：闔上 MacBook 螢幕照跑程式，連續闔滿上限時數強制睡眠。Hammerspoon 模組。
-- 放在 ~/.hammerspoon/lid-coffee/，~/.hammerspoon/init.lua 加一行 require("lid-coffee") 載入。
-- 安裝（含免密碼的 sudoers）、設定、確認有沒有在跑，見同資料夾的 README.md。
--
-- 回傳模組表 M。watcher、計時器、選單列物件都存進 M，require 會把 M 留在 package.loaded。
-- 只存 local 或不存，會被 Lua 回收，之後無聲停止。
local M = {}

-- ── 闔上螢幕：關內建螢幕；連續闔滿上限時數強制睡眠 ──
-- 搭配 `sudo pmset -a disablesleep 1`：那個設定讓闔上螢幕不睡眠、程式照跑，但內建螢幕會繼續亮著。
-- macOS 沒有「闔上螢幕」的事件可以訂閱，只能每 30 秒查一次 ioreg 的 AppleClamshellState（一次約 1 ms CPU）。
-- 查到闔上：
--   1. 螢幕還亮著就 pmset displaysleepnow。
--   2. 防呆：從第一次查到闔上起算滿上限時數，就關掉 disablesleep（變 🥛）再睡眠，不管原本是 ☕ 還是 🥛。開蓋重新計時。
-- 上限時數在選單列 ☕ 的選單選（見下一段），存在 hs.settings 的 lidMaxHours，重新載入、重開機都還在；沒選過是 4 小時。
-- ☕、🥛 都跑：disablesleep 若在闔著時才被關掉（終端機或 agent 下的 pmset），macOS 會不會自己補睡沒實測過；
-- pmset 的 sleep 設 0 的機器閒置也不會睡，所以由這裡補送睡眠。
-- 有外接螢幕時不動作也不計時：外接螢幕加闔上是正常的外接模式，displaysleepnow 會連外接那台一起關掉。
-- 逾時送睡眠、計時器出錯才寫 lid-timeout.log，平常不寫。
local LID_POLL_SECONDS = 30
local LID_HOUR_CHOICES = { 0.5, 1, 2, 3, 4, 6, 8, 12 }   -- 選單列可選的上限時數，要別的時數改這裡
local LID_DEFAULT_HOURS = 4
local LID_LOG = os.getenv("HOME") .. "/.hammerspoon/lid-timeout.log"

-- hs.settings 存的值不在 LID_HOUR_CHOICES 裡（沒選過，或清單改過）就用預設
local function lidValidHours(h)
  for _, c in ipairs(LID_HOUR_CHOICES) do
    if h == c then return c end
  end
  return LID_DEFAULT_HOURS
end

local function lidHoursText(h)
  if h < 1 then return string.format("%g 分鐘", h * 60) end
  return string.format("%g 小時", h)
end

local lidMaxHours = lidValidHours(hs.settings.get("lidMaxHours"))

-- 內建螢幕靠名稱認：hs.screen:name() 回的是在地化名稱（繁中是「內建Retina顯示器」）。
-- 系統是其他語言時，把那個語言的名稱加進比對，不然永遠當成接著外接螢幕，什麼都不做。
local function onlyBuiltinScreens()
  for _, s in ipairs(hs.screen.allScreens()) do
    local name = s:name() or ""
    if not (name:find("內建", 1, true) or name:find("Built-in", 1, true)) then
      return false
    end
  end
  return true
end

local function lidLog(msg)
  local f = io.open(LID_LOG, "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S  ") .. msg .. "\n")
    f:close()
  end
end

local lidDisplayAsleep = false
local lidClosedSince = nil      -- 第一次查到闔上的時間（os.time）
local lidTimeoutTries = 0       -- 這次闔上逾時後送過幾次睡眠
local lidSystemSlept = false    -- 睡著後到下次完整醒來之間為 true。這段期間的短暫醒來（DarkWake）交給系統，不再送睡眠
local lidTimeoutSlept = false   -- 逾時送的睡眠真的睡了，開蓋後提示一次

local function lidResetCount()
  lidClosedSince, lidTimeoutTries = nil, 0
end

M.lidScreenWatcher = hs.caffeinate.watcher.new(function(event)
  local w = hs.caffeinate.watcher
  if event == w.screensDidSleep then
    lidDisplayAsleep = true
  elseif event == w.screensDidWake then
    lidDisplayAsleep = false
    if lidTimeoutSlept then
      lidTimeoutSlept = false
      hs.alert.show(string.format("闔上滿 %s，剛才自動睡眠，已切成 🥛", lidHoursText(lidMaxHours)), 10)
    end
  elseif event == w.systemWillSleep then
    lidSystemSlept = true
    if lidTimeoutTries > 0 then lidTimeoutSlept = true end
  elseif event == w.systemDidWake then
    lidSystemSlept = false
  end
end):start()

-- 逾時：先關 disablesleep（開著時睡眠指令會被擋），3 秒後睡眠。
-- 只用 sudo -n，不退回密碼視窗：闔著沒人能輸入，視窗會一直卡住 Hammerspoon。
-- 沒睡成（sudo 失敗、睡眠被擋）就收不到 systemWillSleep，下一輪自動重試；log 只記前 5 次。
local function lidTimeoutSleep()
  lidTimeoutTries = lidTimeoutTries + 1
  local _, ok = hs.execute("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null")
  if lidTimeoutTries <= 5 then
    lidLog(string.format("闔上 %.1f 小時（上限 %s），第 %d 次送睡眠。disablesleep 0：%s",
      (os.time() - lidClosedSince) / 3600, lidHoursText(lidMaxHours), lidTimeoutTries, ok and "成功" or "失敗（sudo -n）"))
  end
  M.lidSleepTimer = hs.timer.doAfter(3, function() hs.caffeinate.systemSleep() end)
end

local function lidTick()
  if not onlyBuiltinScreens() then
    lidResetCount()
    return "有外接螢幕，跳過"
  end
  local out = hs.execute("/usr/sbin/ioreg -r -k AppleClamshellState -d 1") or ""
  if out:find('"AppleClamshellState" = No', 1, true) then
    lidResetCount()
    lidSystemSlept = false
    return "蓋子開著"
  end
  if not out:find('"AppleClamshellState" = Yes', 1, true) then
    return "讀不到蓋子狀態"   -- 這輪跳過，計時照舊
  end
  lidClosedSince = lidClosedSince or os.time()
  if not lidDisplayAsleep then
    hs.execute("/usr/bin/pmset displaysleepnow")
    lidDisplayAsleep = true   -- 螢幕本來就睡著時不會再送 screensDidSleep，自己標記；醒來由 screensDidWake 改回
  end
  if not lidSystemSlept and os.time() - lidClosedSince >= lidMaxHours * 3600 then
    lidTimeoutSleep()
  end
  return "蓋子闔著"
end

-- 包 pcall：出錯時計時器照跑，錯誤只記第一次。
-- 載入後第一輪的結果補寫進 last-load.txt，外部查得到計時器有沒有真的在跑。
local lidErrorLogged, lidFirstTickDone = false, false
M.lidTimer = hs.timer.doEvery(LID_POLL_SECONDS, function()
  local ok, res = pcall(lidTick)
  if not ok and not lidErrorLogged then
    lidErrorLogged = true
    lidLog("計時器出錯：" .. tostring(res))
  end
  if not lidFirstTickDone then
    lidFirstTickDone = true
    local f = io.open(os.getenv("HOME") .. "/.hammerspoon/last-load.txt", "a")
    if f then
      f:write(os.date("%Y-%m-%d %H:%M:%S") .. "  闔上計時器第一輪：" .. (ok and "" or "出錯 ") .. tostring(res) .. "\n")
      f:close()
    end
  end
end)

-- ── Cmd+Ctrl+L：切換「闔上不睡」（pmset disablesleep）──
-- 選單列常駐一個圖示：☕ = 闔上照跑（到上限時數為止，見上一段），🥛 = 闔上就睡（正常休息）。
-- 點圖示開選單：選一個時數 = 上限改成那個時數並切成 ☕；選 🥛 切回正常睡眠。
-- 熱鍵只切換 ☕／🥛，上限沿用選單最後一次選的。
-- pmset 要 root。/etc/sudoers.d/pmset-disablesleep 放行這兩條指令免密碼（裝法見 README.md）；
-- 那個檔不在時 sudo -n 會失敗，退回 macOS 的管理者密碼視窗。
-- 在終端機直接下 pmset 改的，60 秒內會同步到圖示。
local function noSleepOn()
  local out = hs.execute("/usr/bin/pmset -g")
  return out ~= nil and out:find("SleepDisabled%s+1") ~= nil
end

local noSleepMenu = hs.menubar.new()
M.noSleepMenu = noSleepMenu

local function showNoSleepState(on)
  noSleepMenu:setTitle(on and "☕" or "🥛")
  noSleepMenu:setTooltip(on and string.format("闔上照跑，最多 %s（點一下改時數或切回正常睡眠）", lidHoursText(lidMaxHours))
    or "闔上就睡（點一下選照跑時數）")
end

local function setNoSleep(on)
  local cmd = "/usr/bin/pmset -a disablesleep " .. (on and "1" or "0")
  local _, ok = hs.execute("/usr/bin/sudo -n " .. cmd .. " 2>/dev/null")
  if not ok then
    hs.osascript.applescript('do shell script "' .. cmd .. '" with administrator privileges')
  end
  local now = noSleepOn()
  showNoSleepState(now)
  if now == on then
    hs.alert.show(on and string.format("☕ 闔上照跑（最多 %s）", lidHoursText(lidMaxHours)) or "🥛 闔上就睡（正常休息）")
  else
    hs.alert.show("沒有切換（取消了，或密碼沒過）")
  end
end

-- 選時數：記下上限再切成 ☕。已經是 ☕ 也照下 pmset，重下一次沒有影響，還會跳提示確認新的上限。
local function setLidHours(h)
  lidMaxHours = h
  hs.settings.set("lidMaxHours", h)
  setNoSleep(true)
end

-- 每次點圖示都重建選單，打勾跟著當下狀態走
local function noSleepMenuItems()
  local on = noSleepOn()
  showNoSleepState(on)
  local items = { { title = "☕ 闔上照跑，最多：", disabled = true } }
  for _, h in ipairs(LID_HOUR_CHOICES) do
    items[#items + 1] = { title = lidHoursText(h), indent = 1, checked = on and h == lidMaxHours,
      fn = function() setLidHours(h) end }
  end
  items[#items + 1] = { title = "-" }
  items[#items + 1] = { title = "🥛 闔上就睡", checked = not on, fn = function() setNoSleep(false) end }
  return items
end

noSleepMenu:setMenu(noSleepMenuItems)
hs.hotkey.bind({"cmd", "ctrl"}, "l", function() setNoSleep(not noSleepOn()) end)
showNoSleepState(noSleepOn())
M.noSleepSync = hs.timer.doEvery(60, function() showNoSleepState(noSleepOn()) end)

-- 載入診斷用：回傳目前狀態的三行文字，由 ~/.hammerspoon/init.lua 寫進 last-load.txt
function M.statusLines()
  local lines = {}
  lines[1] = string.format("闔上計時器 running=%s  每 %d 秒  闔滿 %s強制睡眠（hs.settings lidMaxHours=%s）",
    tostring(M.lidTimer ~= nil and M.lidTimer:running()), LID_POLL_SECONDS, lidHoursText(lidMaxHours),
    tostring(hs.settings.get("lidMaxHours")))
  lines[2] = "闔上不睡 SleepDisabled=" .. tostring(noSleepOn()) .. "  選單列圖示=" .. tostring(noSleepMenu and noSleepMenu:title())
  local menu = {}
  for _, it in ipairs(noSleepMenuItems()) do
    menu[#menu + 1] = (it.checked and "✓" or "") .. it.title
  end
  lines[3] = "選單列選單：" .. table.concat(menu, " | ")
  return lines
end

return M
