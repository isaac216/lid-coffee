-- lid-coffee：闔上 MacBook 螢幕照跑程式，Claude Code 閒置或闔滿上限時數就強制睡眠。Hammerspoon 模組。
-- 放在 ~/.hammerspoon/lid-coffee/，~/.hammerspoon/init.lua 加一行 require("lid-coffee") 載入。
-- 安裝（含免密碼的 sudoers）、設定、確認有沒有在跑，見同資料夾的 README.md。
--
-- 回傳模組表 M。watcher、計時器、選單列物件都存進 M，require 會把 M 留在 package.loaded。
-- 只存 local 或不存，會被 Lua 回收，之後無聲停止。
local M = {}

-- ── 闔上螢幕：鎖定、關內建螢幕；Claude Code 閒置或闔滿上限時數強制睡眠 ──
-- 搭配 `sudo pmset -a disablesleep 1`：那個設定讓闔上螢幕不睡眠、程式照跑，但內建螢幕會繼續亮著，也不會鎖定。
-- macOS 沒有「闔上螢幕」的事件可以訂閱，只能每 30 秒查一次 ioreg 的 AppleClamshellState（一次約 10 ms CPU）。
-- 間隔就是闔上到鎖定最多多久：這段時間內再打開，不用 Touch ID。
-- 查到闔上：
--   1. 這次闔上還沒鎖過就 hs.caffeinate.lockScreen()，開蓋要 Touch ID 或密碼。
--      不靠系統「關螢幕後多久要密碼」的設定，那個設定改成幾分鐘也照鎖。鎖定不影響程式執行。
--   2. 螢幕還亮著就 pmset displaysleepnow。
--   3. 防呆：Claude 智慧感應（預設）看 Claude Code 自己的狀態簿，從闔上起連續 LID_CLAUDE_IDLE_MINUTES 沒有 session 在跑就睡
--      （背景 subagent 還在跑也算在跑；busy 卻連續 LID_CLAUDE_STALE_MINUTES 沒寫入的當成卡住，見 claudeScan）；
--      選時數的闔滿上限就睡。睡法都是關掉 disablesleep（變 🥛）再睡眠，不管原本是 ☕ 還是 🥛。開蓋重新計時。
--      睡著後開蓋就切回 ☕、回到 LID_DEFAULT（lidBackToCoffee），不停在 🥛。
-- 上限在選單列 ☕ 的選單選（見下一段），存在 hs.settings 的 lidMaxHours（時數，或智慧感應的代號），
-- 重新載入、重開機都還在；沒選過是 LID_DEFAULT。
-- ☕、🥛 都跑：disablesleep 若在闔著時才被關掉（終端機或 agent 下的 pmset），macOS 會不會自己補睡沒實測過；
-- pmset 的 sleep 設 0 的機器閒置也不會睡，所以由這裡補送睡眠。
-- 有外接螢幕時不鎖、不關螢幕也不計時：外接螢幕加闔上是正常的外接模式，displaysleepnow 會連外接那台一起關掉。
-- 逾時送睡眠、之後開蓋切回 ☕、計時器出錯、狀態簿讀不到、有 claude 程序沒登記、session 卡住或找不到 transcript
-- 才寫 lid-timeout.log，平常不寫。
local LID_POLL_SECONDS = 30   -- 也是逾時送了睡眠沒睡成時的重試間隔。送出到睡著約 30 秒，改短會在睡著前重複送睡眠
local LID_HOUR_CHOICES = { 0.5, 1, 2, 3, 4, 6, 8, 12 }   -- 選單列可選的上限時數，要別的時數改這裡
local LID_CLAUDE = "claude"          -- Claude 智慧感應：lidMaxHours 存的值
local LID_CLAUDE_IDLE_MINUTES = 10   -- Claude 智慧感應：闔著時連續這麼久沒有 session 在跑就睡
local LID_CLAUDE_STALE_MINUTES = 30  -- Claude 智慧感應：busy 的 session 連續這麼久沒寫入（transcript、背景指令輸出）就當成卡住，不算在跑
local LID_DEFAULT = LID_CLAUDE       -- 沒選過時的上限，也是自動睡眠後開蓋切回的上限
local HOME = os.getenv("HOME")
local LID_LOG = HOME .. "/.hammerspoon/lid-timeout.log"
local CLAUDE_SESSIONS = HOME .. "/.claude/sessions"   -- Claude Code 自己的狀態簿，一個程序一個 <pid>.json
local CLAUDE_PROJECTS = HOME .. "/.claude/projects"   -- transcript：<專案>/<sessionId>.jsonl，subagent 的在 <專案>/<sessionId>/subagents/

-- hs.settings 存的值不在選單裡（沒選過，或清單改過）就用預設
local function lidValidHours(h)
  if h == LID_CLAUDE then return h end
  for _, c in ipairs(LID_HOUR_CHOICES) do
    if h == c then return c end
  end
  return LID_DEFAULT
end

local function lidHoursText(h)
  if h == LID_CLAUDE then return "Claude 智慧感應" end
  if h < 1 then return string.format("%g 分鐘", h * 60) end
  return string.format("%g 小時", h)
end

-- 選單、提示與 tooltip 用：「最多 2 小時」或「Claude 智慧感應，閒置 10 分鐘就睡」
local function lidLimitText(h)
  if h == LID_CLAUDE then return string.format("Claude 智慧感應，閒置 %d 分鐘就睡", LID_CLAUDE_IDLE_MINUTES) end
  return "最多 " .. lidHoursText(h)
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
local lidLockSent = false       -- 這次闔上已經送過鎖定
local lidSystemSlept = false    -- 睡著後到下次完整醒來之間為 true。這段期間的短暫醒來（DarkWake）交給系統，不再送睡眠
local lidTimeoutSlept = false   -- 逾時送的睡眠真的睡了，開蓋後切回 ☕ 並提示一次
local lidSleepReason = nil      -- 這次送睡眠的原因，log 與開蓋提示用
local lidBackToCoffee           -- 開蓋後切回 ☕ 的函式，定義在下一段（要更新選單列圖示）
local lidClaudeLastBusy = nil   -- 智慧感應：這次闔上最後一次查到 session 在跑的時間（os.time）
local lidRegistryWarned = false -- 智慧感應：狀態簿讀不到的 log 只寫一次
local lidUnregistered = {}      -- 智慧感應：記過「沒登記」的 claude 程序，pid → true，同一個只記一次
local lidSessionWarned = {}     -- 智慧感應：記過「卡住」或「找不到 transcript」的 session，sessionId → true，同一個只記一次

local function lidResetCount()
  lidClosedSince, lidTimeoutTries, lidLockSent = nil, 0, false
  lidClaudeLastBusy = nil
end

M.lidScreenWatcher = hs.caffeinate.watcher.new(function(event)
  local w = hs.caffeinate.watcher
  if event == w.screensDidSleep then
    lidDisplayAsleep = true
  elseif event == w.screensDidWake then
    lidDisplayAsleep = false
    if lidTimeoutSlept then
      lidTimeoutSlept = false
      lidBackToCoffee()
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
    lidLog(string.format("闔上 %.1f 小時（%s），第 %d 次送睡眠。disablesleep 0：%s",
      (os.time() - lidClosedSince) / 3600, lidSleepReason, lidTimeoutTries, ok and "成功" or "失敗（sudo -n）"))
  end
  M.lidSleepTimer = hs.timer.doAfter(3, function() hs.caffeinate.systemSleep() end)
end

-- Claude 智慧感應：看 Claude Code 自己寫的狀態簿 ~/.claude/sessions/<pid>.json（CHANGELOG 叫 session registry）。
-- Cursor／VS Code 擴充、終端機互動 CLI、claude -p 實測都會寫，程序結束就刪。status 有四種（2.1.310 原始碼與實測）：
--   busy     回合中（模型在想、在回、在跑工具），或委派的工作還在跑：subagent（含 run_in_background 的背景 subagent）、
--            Workflow、teammate → 算在跑。主回合結束、只剩背景 subagent 時也是 busy，subagent 結束才變 idle
--   waiting  等你回答（權限、提問）→ 不算：闔著沒人回答
--   shell    只有終端機互動 CLI 會寫：回合結束、只剩背景指令（dev server 這類可能永遠不結束）→ 不算。
--            擴充與 claude -p 這時寫 idle。背景指令跑的 claude -p 自己會登記，照它自己的 status 算
--   idle     閒置 → 不算
-- 上限：狀態簿沒有心跳，卡住的 session 會一直是 busy。所以 busy 還要這個 session 最近 LID_CLAUDE_STALE_MINUTES 內
-- 有寫入（主 transcript、<sessionId>/ 底下各 subagent 與 Workflow agent 的 jsonl、背景指令的輸出檔）才算；
-- 沒有就當成卡住、不算，記一次 log。找不到 transcript（例如 --no-session-persistence）就照狀態簿算，記一次 log。
-- 網路流量、程序名稱這類間接訊號會被沒有產值的活動誤報，不用。pid 已經不在的檔不算（被強制結束的 session 會留下檔）。
-- 狀態簿有檔卻讀不出 pid（改版換了格式）、或有叫 claude 的程序沒登記，各記一次 log，不影響判斷；讀不到時當閒置，寧可睡。

local claudeProjectOf = {}   -- sessionId → transcript 所在的專案資料夾名（~/.claude/projects 底下）；找到才記，找不到下一輪再找
local claudeTmpRoot          -- 背景指令輸出的根目錄 /private/tmp/claude-<uid>；第一次用到才查 uid，查不到是 false

-- 專案資料夾名是 cwd 換掉英數以外的字元，太長再截斷加雜湊；不自己算，逐一找哪個資料夾有 <sessionId>.jsonl
local function claudeProjectDir(sid)
  if claudeProjectOf[sid] then return claudeProjectOf[sid] end
  local ok, iter, dirObj = pcall(hs.fs.dir, CLAUDE_PROJECTS)
  if not (ok and iter) then return nil end
  for name in iter, dirObj do
    if name:sub(1, 1) ~= "." and hs.fs.attributes(CLAUDE_PROJECTS .. "/" .. name .. "/" .. sid .. ".jsonl", "mode") == "file" then
      claudeProjectOf[sid] = name
      dirObj:close()
      return name
    end
  end
  return nil
end

-- path 底下（往下 depth 層）所有檔案裡最新的修改時間，跟 newest 比大小後回傳；資料夾不在就原樣回傳。
-- hs.fs.attributes 會跟著 symlink 走：tasks/ 裡背景 subagent 的 .output 是指向它 jsonl 的 symlink
local function newestWrite(path, depth, newest)
  local ok, iter, dirObj = pcall(hs.fs.dir, path)
  if not (ok and iter) then return newest end
  for name in iter, dirObj do
    if name ~= "." and name ~= ".." then
      local a = hs.fs.attributes(path .. "/" .. name)
      if a and a.mode == "directory" then
        if depth > 0 then newest = newestWrite(path .. "/" .. name, depth - 1, newest) end
      elseif a and a.modification and a.modification > newest then
        newest = a.modification
      end
    end
  end
  return newest
end

-- 這個 session 最後一次寫入的時間（os.time 的秒數）；找不到 transcript 回 nil
local function claudeLastWrite(sid)
  local proj = claudeProjectDir(sid)
  if not proj then return nil end
  local base = CLAUDE_PROJECTS .. "/" .. proj .. "/" .. sid
  local newest = newestWrite(base, 4, hs.fs.attributes(base .. ".jsonl", "modification") or 0)
  if claudeTmpRoot == nil then
    local uid = (hs.execute("/usr/bin/id -u") or ""):match("%d+")
    claudeTmpRoot = uid and ("/private/tmp/claude-" .. uid) or false
  end
  if claudeTmpRoot then newest = newestWrite(claudeTmpRoot .. "/" .. proj .. "/" .. sid .. "/tasks", 0, newest) end
  return newest
end

-- 讀 sessionsDir（平常是 CLAUDE_SESSIONS）裡每個登記檔，回傳有沒有 session 算在跑，以及每個 session 一行的判斷（診斷用）。
-- quiet：載入時的診斷用，不寫 log、不記「記過了」，log 留給闔著時的判斷寫
local function claudeScan(sessionsDir, quiet)
  local ps = hs.execute("/bin/ps -axo pid=,comm=") or ""
  local alive, claudePids = {}, {}
  for line in ps:gmatch("[^\n]+") do
    local pid, comm = line:match("^%s*(%d+)%s+(.-)%s*$")
    if pid then
      alive[pid] = true
      if comm == "claude" or comm:match("/claude$") then claudePids[pid] = comm end
    end
  end

  local now = os.time()
  local busy, registered, files, lines = false, {}, 0, {}
  local ok, iter, dirObj = pcall(hs.fs.dir, sessionsDir)
  if ok and iter then
    for name in iter, dirObj do
      if name:match("^%d+%.json$") then
        files = files + 1
        local f = io.open(sessionsDir .. "/" .. name)
        local text = f and f:read("a") or ""
        if f then f:close() end
        local pid = text:match('"pid"%s*:%s*(%d+)')
        if pid then
          registered[pid] = true
          local status = text:match('"status"%s*:%s*"(%a+)"') or "?"
          local sid = text:match('"sessionId"%s*:%s*"([%w%-]+)"')
          local label = string.format("%s（pid %s）%s", text:match('"name"%s*:%s*"([^"]*)"') or "?", pid, status)
          local verdict
          if not alive[pid] then
            verdict = "程序已結束，不算"
          elseif status ~= "busy" then
            verdict = "不算"
          else
            local last = sid and claudeLastWrite(sid)
            if not last then
              busy = true
              verdict = "算在跑（找不到 transcript，照狀態簿）"
              if sid and not quiet and not lidSessionWarned[sid] then
                lidSessionWarned[sid] = true
                lidLog(string.format("Claude session %s：找不到 transcript，照狀態簿算在跑，卡住也看不出來", label))
              end
            elseif now - last <= LID_CLAUDE_STALE_MINUTES * 60 then
              busy = true
              verdict = string.format("算在跑（%d 分鐘前有寫入）", (now - last) // 60)
            else
              verdict = string.format("不算：%d 分鐘沒寫入，當成卡住", (now - last) // 60)
              if not quiet and not lidSessionWarned[sid] then
                lidSessionWarned[sid] = true
                lidLog(string.format("Claude session %s，%s（上限 %d 分鐘）", label, verdict, LID_CLAUDE_STALE_MINUTES))
              end
            end
          end
          lines[#lines + 1] = label .. "：" .. verdict
        end
      end
    end
  end

  if not quiet and files > 0 and next(registered) == nil and not lidRegistryWarned then
    lidRegistryWarned = true
    lidLog(string.format("Claude 狀態簿 %s 有 %d 個檔，讀不出 pid（格式可能改了），智慧感應看不到任何 session", sessionsDir, files))
  end
  for pid, comm in pairs(claudePids) do
    if not quiet and not registered[pid] and not lidUnregistered[pid] then
      lidUnregistered[pid] = true
      -- 不是 session 的輔助程序本來就不登記：Claude in Chrome 的 MCP（--claude-in-chrome-mcp）、claude mcp serve
      local cmd = hs.execute("/bin/ps -o command= -p " .. pid) or ""
      if not (cmd:find("--claude-in-chrome-mcp", 1, true) or cmd:find(" mcp serve", 1, true)) then
        lidLog(string.format("claude 程序 pid %s（%s）沒寫狀態簿，智慧感應看不到它", pid, comm))
      end
    end
  end
  return busy, lines
end

local function claudeBusy()
  return (claudeScan(CLAUDE_SESSIONS))
end

-- 闔著時要不要送睡眠，順便記下原因：選時數看闔了多久；智慧感應看連續多久沒有 session 在跑（闔上當下起算）
local function lidShouldSleep()
  local now = os.time()
  if lidMaxHours ~= LID_CLAUDE then
    lidSleepReason = "上限 " .. lidHoursText(lidMaxHours)
    return now - lidClosedSince >= lidMaxHours * 3600
  end
  if claudeBusy() then lidClaudeLastBusy = now end
  lidSleepReason = string.format("Claude 閒置滿 %d 分鐘", LID_CLAUDE_IDLE_MINUTES)
  return now - (lidClaudeLastBusy or lidClosedSince) >= LID_CLAUDE_IDLE_MINUTES * 60
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
  if not lidLockSent then
    lidLockSent = true   -- 每次闔上只送一次；開蓋由 lidResetCount 改回
    hs.caffeinate.lockScreen()
  end
  if not lidDisplayAsleep then
    hs.execute("/usr/bin/pmset displaysleepnow")
    lidDisplayAsleep = true   -- 螢幕本來就睡著時不會再送 screensDidSleep，自己標記；醒來由 screensDidWake 改回
  end
  -- 送過睡眠沒睡成就照送，不再重判：智慧感應這時查到在跑，disablesleep 也已經關了
  if not lidSystemSlept and (lidTimeoutTries > 0 or lidShouldSleep()) then
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
-- 選單列常駐一個圖示：☕ = 闔上照跑（到睡眠條件為止，見上一段），🥛 = 闔上就睡（正常休息）。
-- 點圖示開選單：選智慧感應或一個時數 = 改成那一項並切成 ☕；選 🥛 切回正常睡眠。
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
  noSleepMenu:setTooltip(on and string.format("闔上照跑，%s（點一下改上限或切回正常睡眠）", lidLimitText(lidMaxHours))
    or "闔上就睡（點一下選照跑的上限）")
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
    hs.alert.show(on and string.format("☕ 闔上照跑（%s）", lidLimitText(lidMaxHours)) or "🥛 闔上就睡（正常休息）")
  else
    hs.alert.show("沒有切換（取消了，或密碼沒過）")
  end
end

-- 選上限：記下來再切成 ☕。已經是 ☕ 也照下 pmset，重下一次沒有影響，還會跳提示確認新的上限。
local function setLidHours(h)
  lidMaxHours = h
  hs.settings.set("lidMaxHours", h)
  setNoSleep(true)
end

-- 自動睡眠後開蓋：切回 ☕、回到 LID_DEFAULT（Claude 智慧感應）並存進 hs.settings，之後照常，直到從選單或熱鍵再改。
-- 只用 sudo -n：開蓋時還在鎖定畫面，密碼視窗會卡住 Hammerspoon。沒切成就留在 🥛，提示裡講。
-- 計數當場清掉：開蓋 30 秒內又闔上時，下一輪不會當成上一次闔上、馬上又送睡眠（2026-10-24 開蓋 15 秒又闔上看到的）。
lidBackToCoffee = function()
  local reason = lidSleepReason or lidLimitText(lidMaxHours)
  lidResetCount()
  lidMaxHours = LID_DEFAULT
  hs.settings.set("lidMaxHours", lidMaxHours)
  hs.execute("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1 2>/dev/null")
  local on = noSleepOn()
  showNoSleepState(on)
  lidLog(string.format("開蓋，切回 ☕（%s）：%s", lidLimitText(lidMaxHours), on and "成功" or "失敗（sudo -n）"))
  hs.alert.show(string.format("剛才自動睡眠（%s）；", reason)
    .. (on and string.format("已切回 ☕ %s", lidLimitText(lidMaxHours)) or "切回 ☕ 失敗（sudo -n），現在是 🥛"), 10)
end

-- 每次點圖示都重建選單，打勾跟著當下狀態走
local function noSleepMenuItems()
  local on = noSleepOn()
  showNoSleepState(on)
  local items = {
    { title = "☕ " .. lidLimitText(LID_CLAUDE), checked = on and lidMaxHours == LID_CLAUDE,
      fn = function() setLidHours(LID_CLAUDE) end },
    { title = "☕ 闔上照跑，最多：", disabled = true },
  }
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

-- 載入診斷用：回傳目前狀態的四行文字，由 ~/.hammerspoon/init.lua 寫進 last-load.txt。
-- 第四行是智慧感應現在看到的每個 session（不寫 log），蓋子開著也照算，闔上時就是照這個判斷
function M.statusLines()
  local lines = {}
  lines[1] = string.format("闔上計時器 running=%s  每 %d 秒  上限：%s（hs.settings lidMaxHours=%s）",
    tostring(M.lidTimer ~= nil and M.lidTimer:running()), LID_POLL_SECONDS, lidLimitText(lidMaxHours),
    tostring(hs.settings.get("lidMaxHours")))
  lines[2] = "闔上不睡 SleepDisabled=" .. tostring(noSleepOn()) .. "  選單列圖示=" .. tostring(noSleepMenu and noSleepMenu:title())
  local menu = {}
  for _, it in ipairs(noSleepMenuItems()) do
    menu[#menu + 1] = (it.checked and "✓" or "") .. it.title
  end
  lines[3] = "選單列選單：" .. table.concat(menu, " | ")
  local ok, busy, sessions = pcall(claudeScan, CLAUDE_SESSIONS, true)
  lines[4] = not ok and ("智慧感應：判斷出錯 " .. tostring(busy))
    or string.format("智慧感應：%s。%s", busy and "有 session 在跑" or "沒有 session 在跑",
      #sessions > 0 and table.concat(sessions, "；") or "狀態簿沒有登記")
  return lines
end

return M
