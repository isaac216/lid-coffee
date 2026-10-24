# lid-coffee ☕

闔上 MacBook 螢幕後讓程式照跑（Claude Code、下載、編譯），闔上就鎖定、開蓋要 Touch ID；預設是 Claude 智慧感應：讀 Claude Code 自己的狀態簿，沒有 session 在跑滿 10 分鐘就睡，也可以改成固定時數。用選單列的 ☕／🥛 圖示切換。

Keep a MacBook running with the lid closed, lock the screen on close, and put it to sleep once Claude Code's own session registry has shown no busy session for 10 minutes, or after a fixed number of hours. Requires [Hammerspoon](https://www.hammerspoon.org/); adds a ☕ / 🥛 menu bar toggle.

> **要先裝 Hammerspoon。** lid-coffee 是一段 Lua 腳本，本身沒有 App 可以點，要由 Hammerspoon 載入才會跑。Hammerspoon 是免費、開源的 macOS 自動化工具，常駐在選單列，會載入 `~/.hammerspoon/` 裡的腳本。沒用過也可以照著裝，〈安裝〉從裝 Hammerspoon 寫起。

## 為什麼需要

MacBook 闔上螢幕觸發的是 Clamshell Sleep，跟閒置睡眠分開算。`pmset sleep 0` 擋不住（實測過）；`caffeinate` 防的也是閒置睡眠，闔上的情況沒單獨測。擋得住的是：

```bash
sudo pmset -a disablesleep 1
```

只開這個會有兩個問題。闔上後內建螢幕還亮著、也沒鎖定，要等 `displaysleep` 的閒置計時器熄了才鎖，這段時間打開不用密碼；開了也不會自己關，忘了切回來，機器放進包包會一路跑到沒電。

lid-coffee 補這兩件事：闔上就鎖定並關內建螢幕；Claude Code 閒置了、或闔滿上限，就把 `disablesleep` 關回 0 並睡眠。

## 怎麼用

| 操作 | 結果 |
|---|---|
| 選單列顯示 ☕ | 闔上照跑（`disablesleep 1`），到上限為止 |
| 選單列顯示 🥛 | 闔上就睡，正常休息（`disablesleep 0`） |
| 點圖示，選「☕ Claude 智慧感應」 | 預設。闔著時有 Claude Code session 在跑就照跑，不限時數；連續 10 分鐘沒有就睡。並切成 ☕（見〈Claude 智慧感應〉） |
| 點圖示，選一個時數 | 不看 Claude Code，上限改成那個時數，並切成 ☕。可選 30 分鐘、1、2、3、4、6、8、12 小時 |
| 點圖示，選「🥛 闔上就睡」 | 切回正常睡眠 |
| `Cmd+Ctrl+L` | 直接切換 ☕／🥛，上限沿用最後一次選的 |
| 自動睡眠後，開蓋 | 自動切回 ☕ Claude 智慧感應（選時數的也改回來）；之後照這個設定，直到再改 |

在終端機直接下 `pmset` 改的，60 秒內會同步到圖示。

## 闔上之後做什麼

每 30 秒查一次蓋子（`ioreg` 的 `AppleClamshellState`，一次約 10 ms CPU）。macOS 沒有闔上螢幕的事件可以訂閱，只能輪詢。查到闔上：

1. 這次闔上還沒鎖過，就 `hs.caffeinate.lockScreen()`，開蓋要 Touch ID 或密碼。程式照跑。不靠系統設定裡「關螢幕後多久要密碼」，那個設定是幾分鐘也照鎖
2. 內建螢幕還亮著，就 `pmset displaysleepnow`。所以闔上到鎖定、螢幕熄掉最多 30 秒，這段時間內打開不用 Touch ID
3. 智慧感應從闔上起連續 10 分鐘沒有 session 在跑、或選時數的闔滿上限，就 `sudo -n pmset -a disablesleep 0`（變 🥛），3 秒後睡眠。醒來開蓋自動切回 ☕ Claude 智慧感應（`LID_DEFAULT`），跳 10 秒提示；要闔上就睡，自己切成 🥛。切回 ☕ 一樣只用 `sudo -n`，沒切成就留在 🥛，提示裡會講

其他規則：

- 開蓋就重新計時；自動睡眠後開蓋又馬上闔上，也從頭算，不會當成上一次闔上而馬上再睡
- ☕、🥛 都會查。`disablesleep` 若在闔著時才被關掉，macOS 會不會自己補睡沒實測過，所以由 lid-coffee 補送睡眠
- 接著外接螢幕時不鎖定、不關螢幕也不計時。外接螢幕加闔上是正常的外接模式，`displaysleepnow` 會連外接那台一起關掉
- 自動睡眠只用 `sudo -n`，不跳密碼視窗，因為闔著沒人能輸入，視窗會一直卡住 Hammerspoon。沒睡成就 30 秒後重試
- 睡著後會不定時短暫醒來（`pmset -g log` 裡的 DarkWake），這段期間交給系統，不再送睡眠

### Claude 智慧感應

預設的睡眠條件。闔著時每 30 秒讀一次 Claude Code 自己寫的狀態簿 `~/.claude/sessions/<pid>.json`（每個 Claude Code 程序一個檔，程序結束就刪掉），有任何一個 `status` 是 `busy`、而且那個 pid 還在，就算有 session 在跑。從闔上當下起，連續 10 分鐘沒有就睡；有就一直跑，不限時數。

`status` 怎麼寫，Claude Code 2.1.308 的程式碼裡是：

| status | 什麼時候 | 智慧感應 |
|---|---|---|
| `busy` | 回合中（模型在想、在回、在跑工具），或委派的 subagent 還在跑 | 算在跑 |
| `waiting` | 等你回答：核准權限、回答提問 | 不算，闔著沒人回答 |
| `shell` | 回合結束，只剩背景指令（dev server、監看迴圈這類可能一直不結束） | 不算 |
| `idle` | 閒置 | 不算 |

只看狀態簿，不看網路流量、程序在不在這類間接訊號：那些會被沒有產值的活動（閒置連線、忘了關的背景程序）誤報，讓機器一直不睡。

實測會寫狀態簿的啟動方式：Cursor／VS Code 擴充（`entrypoint` 是 `claude-vscode`）、終端機互動 `claude`（`cli`）、`claude -p`（`sdk-cli`）。官方 CHANGELOG 叫它 session registry，但沒有寫成文件，改版可能換格式。為了知道有沒有漏，下面兩種情況各在 `lid-timeout.log` 記一次，不影響睡不睡：

- 狀態簿有檔，卻讀不出 pid（格式可能改了）：這時一律當閒置，寧可睡
- 有叫 `claude` 的程序沒登記：Claude in Chrome 的 MCP（`--claude-in-chrome-mcp`）、`claude mcp serve` 這類不是 session 的輔助程序不記

別人的做法：[caffeinate-claude](https://github.com/bmoeskau/caffeinate-claude) 這類工具用 Claude Code 的 hook（`UserPromptSubmit` 開、`Stop` 關）自己記狀態，預設 1 小時逾時。Claude Code 自己已經記了，lid-coffee 直接讀，不用改 hook 設定。

限制：

- 回合結束後只剩背景指令（`shell`）不算在跑：有產值的背景建置也會在 10 分鐘後跟著睡眠暫停，開蓋繼續
- `/loop` 這類等一段時間再繼續的 session，等的期間是 `idle`，10 分鐘後就睡，開蓋醒來才繼續
- Claude 桌面版、在 VM 裡跑的 session 沒查會不會寫這個狀態簿
- 被強制結束的 session 會留下登記檔，靠「pid 還在」排除；pid 剛好被別的程序重用時會誤判，機率很低
- 只在 macOS：lid-coffee 靠 Hammerspoon，Windows 不適用

## 安裝

需要：

- MacBook（有螢幕蓋的筆電）
- Hammerspoon，免費，第 1 步裝
- 管理者帳號，第 4 步要輸入一次密碼

目前在 MacBook Air M3、macOS 26.6、Hammerspoon 1.1.1 上使用。以下指令都貼到「終端機」（Terminal）執行。

### 1. 裝 Hammerspoon

有 [Homebrew](https://brew.sh/) 的話：

```bash
brew install --cask hammerspoon
```

沒有的話，到 [Hammerspoon 官網](https://www.hammerspoon.org/) 下載 zip，解壓後把 `Hammerspoon.app` 拖進「應用程式」資料夾。

### 2. 打開 Hammerspoon，設成開機自動啟動

從「應用程式」打開 Hammerspoon，選單列會多一個鎚子圖示。點它 → Preferences，勾「Launch Hammerspoon at login」。lid-coffee 只在 Hammerspoon 開著時有作用，所以要開機自動啟動。

Preferences 裡的「Enable Accessibility」（輔助使用權限）是給控制鍵盤滑鼠、搬視窗的腳本用的。lid-coffee 沒有這類動作，熱鍵走的是不需要這個權限的系統介面，不開也能用。

### 3. 放進 lid-coffee

有 git 的話貼這兩行：

```bash
git clone https://github.com/isaac216/lid-coffee.git ~/.hammerspoon/lid-coffee
printf '\nrequire("lid-coffee")\n' >> ~/.hammerspoon/init.lua
```

第一行把 lid-coffee 下載到 `~/.hammerspoon/lid-coffee/`。第二行在 Hammerspoon 的設定檔 `~/.hammerspoon/init.lua` 最後加一行載入它，檔案不存在會自動建立。

沒有 git 的話（第一次打 `git` 會跳出安裝開發者工具的視窗），改貼這三行，直接下載程式檔：

```bash
mkdir -p ~/.hammerspoon/lid-coffee
curl -fsSL https://raw.githubusercontent.com/isaac216/lid-coffee/main/init.lua -o ~/.hammerspoon/lid-coffee/init.lua
printf '\nrequire("lid-coffee")\n' >> ~/.hammerspoon/init.lua
```

接著點選單列的鎚子 → Reload Config。選單列多出 ☕ 或 🥛，就是載入成功。

有兩個 `init.lua`，別搞混：`~/.hammerspoon/init.lua` 是 Hammerspoon 的設定檔，只加上面那一行；`~/.hammerspoon/lid-coffee/init.lua` 是 lid-coffee 本身。

### 4. 設定免密碼

讓 `pmset -a disablesleep 0` 與 `1` 這兩條指令不用密碼。沒設的話，手動切換 ☕／🥛 會跳管理者密碼視窗，闔滿上限的自動睡眠則會失敗：它只用 `sudo -n`，闔著時沒人能輸入密碼。

```bash
tmp=$(mktemp)
echo "$(whoami) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1" > "$tmp"
visudo -cf "$tmp" && sudo install -m 0440 -o root -g wheel "$tmp" /etc/sudoers.d/pmset-disablesleep
rm "$tmp"
sudo -k; sudo -n /usr/bin/pmset -a disablesleep 0 && echo OK   # 不問密碼就印 OK
```

`sudo install` 那行會問一次密碼。只放行這兩條指令，其他 `sudo` 照樣要密碼。檔名不能含 `.`，sudo 會略過 `/etc/sudoers.d/` 裡檔名帶點的檔。

### 5. 開始用

點選單列的 🥛，選「☕ Claude 智慧感應」或一個時數，變成 ☕ 就好了。之後闔上螢幕，程式照跑；智慧感應在 10 分鐘沒有 Claude Code session 在跑時自動睡眠，選時數的到上限睡。

### 更新

```bash
git -C ~/.hammerspoon/lid-coffee pull
```

用 curl 裝的，重跑一次上面 `curl` 那行。更新完 Reload Config。

## 設定

改 `lid-coffee/init.lua` 裡的常數，存檔後 Reload Config：

| 常數 | 預設 | 意思 |
|---|---|---|
| `LID_HOUR_CHOICES` | `{ 0.5, 1, 2, 3, 4, 6, 8, 12 }` | 選單可選的上限時數 |
| `LID_DEFAULT` | `LID_CLAUDE` | 沒選過時的上限，也是自動睡眠後開蓋切回的上限；改成數字就是那個時數 |
| `LID_CLAUDE_IDLE_MINUTES` | `10` | 智慧感應：闔著時連續多久沒有 session 在跑就睡 |
| `LID_POLL_SECONDS` | `30` | 多久查一次蓋子，也是闔上到鎖定、螢幕熄掉最多多久。自動睡眠沒睡成時也隔這麼久重試；送出到睡著約 30 秒，改短會在睡著前重複送 |

熱鍵在 `hs.hotkey.bind({"cmd", "ctrl"}, "l", ...)` 那行改。

選過的上限存在 `hs.settings` 的 `lidMaxHours`（智慧感應存 `claude`），Reload、重開機都還在；自動睡眠後開蓋改回 `LID_DEFAULT`。查目前的上限：

```bash
defaults read org.hammerspoon.Hammerspoon lidMaxHours
```

## 確認有沒有在跑

選單列沒出現 ☕／🥛：點鎚子 → Console，看有沒有紅字。最常見的是資料夾放錯，`~/.hammerspoon/lid-coffee/init.lua` 要存在；從 GitHub 下載 ZIP 解壓出來的資料夾叫 `lid-coffee-main`，要改名成 `lid-coffee`。

```bash
pmset -g | grep SleepDisabled                    # 1 = ☕；從沒設過時這行不會出現
cat ~/.hammerspoon/lid-timeout.log               # 只在自動睡眠、之後開蓋切回 ☕、計時器出錯、狀態簿讀不到或有 claude 程序沒登記時寫
pmset -g log | grep 'Entering Sleep' | tail -3   # 一次要跑幾秒
```

每次載入後約 30 秒，`~/.hammerspoon/last-load.txt` 會多一行「闔上計時器第一輪：蓋子開著」，有這行才算計時器真的在跑。

自動睡眠有觸發時，`lid-timeout.log` 會記一行，例如「闔上 1.4 小時（Claude 閒置滿 10 分鐘），第 1 次送睡眠。disablesleep 0：成功」，選時數的寫「（上限 2 小時）」；`pmset -g log` 隨後有 `Software Sleep pid=<Hammerspoon 的 pid>`（`pgrep -x Hammerspoon`）。開蓋後會再記一行「開蓋，切回 ☕（Claude 智慧感應，閒置 10 分鐘就睡）：成功」。

要短時間測自動睡眠：在 `LID_HOUR_CHOICES` 暫加 `0.05`（選單顯示 3 分鐘）並選它，闔上 5 分鐘再打開，測完拿掉、選回原本的上限。測智慧感應：沒有 session 在跑時闔上，約 10 分鐘後該睡。

## 注意

- MacBook Air 沒有風扇。☕ 時放進包包，有 Claude Code session 在跑就會悶著跑，不限時數；選時數的跑到上限才睡。收包前按 `Cmd+Ctrl+L` 切成 🥛；手上的工作還要跑完，就選短的上限
- 用電池時會一路跑到睡眠條件成立或沒電
- 開蓋用 Touch ID 解鎖，要在系統設定的「Touch ID 與密碼」打開解鎖 Mac。重開機後第一次解鎖、或隔太久沒輸入密碼，macOS 會改要密碼
- 鎖定與自動睡眠都要 Hammerspoon 在跑。Hammerspoon 沒開，闔上不會鎖（要等螢幕閒置熄掉），`disablesleep` 也不會自己關
- 闔著時 Hammerspoon 重新載入設定，計時從頭算
- 內建螢幕靠名稱認，比對「內建」或「Built-in」。系統是其他語言時，把 `hs.screen.allScreens()` 看到的內建螢幕名稱加進 `onlyBuiltinScreens()`，不然會一直當成接著外接螢幕，什麼都不做

## 移除

先切成 🥛（或 `sudo pmset -a disablesleep 0`），再：

```bash
sudo rm /etc/sudoers.d/pmset-disablesleep
rm -rf ~/.hammerspoon/lid-coffee
```

最後拿掉 `~/.hammerspoon/init.lua` 裡的 `require("lid-coffee")`，Reload Config。不再用 Hammerspoon 的話，把它從「應用程式」刪掉。

## 授權

MIT，見 [LICENSE](LICENSE)。
