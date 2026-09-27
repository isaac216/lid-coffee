# lid-coffee ☕

闔上 MacBook 螢幕後讓程式照跑（Claude Code、下載、編譯），連續闔滿上限時數就自動睡眠。是一個 Hammerspoon 模組，用選單列的 ☕／🥛 圖示切換。

Keep a MacBook running with the lid closed, and put it to sleep after N hours. A Hammerspoon module with a ☕ / 🥛 menu bar toggle.

## 為什麼需要

MacBook 闔上螢幕觸發的是 Clamshell Sleep，跟閒置睡眠分開算。`pmset sleep 0` 擋不住（實測過）；`caffeinate` 防的也是閒置睡眠，闔上的情況沒單獨測。擋得住的是：

```bash
sudo pmset -a disablesleep 1
```

只開這個會有兩個問題。闔上後內建螢幕還亮著，要等 `displaysleep` 的閒置計時器才熄；開了也不會自己關，忘了切回來，機器放進包包會一路跑到沒電。

lid-coffee 補這兩件事：闔上就關內建螢幕，闔滿上限時數就把 `disablesleep` 關回 0 並睡眠。

## 怎麼用

| 操作 | 結果 |
|---|---|
| 選單列顯示 ☕ | 闔上照跑（`disablesleep 1`），到上限時數為止 |
| 選單列顯示 🥛 | 闔上就睡，正常休息（`disablesleep 0`） |
| 點圖示，選一個時數 | 上限改成那個時數，並切成 ☕。可選 30 分鐘、1、2、3、4、6、8、12 小時，沒選過是 4 小時 |
| 點圖示，選「🥛 闔上就睡」 | 切回正常睡眠 |
| `Cmd+Ctrl+L` | 直接切換 ☕／🥛，上限沿用最後一次選的 |

在終端機直接下 `pmset` 改的，60 秒內會同步到圖示。

## 闔上之後做什麼

每 30 秒查一次蓋子（`ioreg` 的 `AppleClamshellState`，一次約 1 ms CPU）。macOS 沒有闔上螢幕的事件可以訂閱，只能輪詢。查到闔上：

1. 內建螢幕還亮著，就 `pmset displaysleepnow`。所以闔上後螢幕最多亮 30 秒
2. 從第一次查到闔上起算，連續闔滿上限時數，就 `sudo -n pmset -a disablesleep 0`（變 🥛），3 秒後睡眠。醒來開蓋會跳 10 秒提示，還要闔上照跑就自己切回 ☕

其他規則：

- 開蓋就重新計時
- ☕、🥛 都會查。`disablesleep` 若在闔著時才被關掉，macOS 會不會自己補睡沒實測過，所以由 lid-coffee 補送睡眠
- 接著外接螢幕時不動作也不計時。外接螢幕加闔上是正常的外接模式，`displaysleepnow` 會連外接那台一起關掉
- 自動睡眠只用 `sudo -n`，不跳密碼視窗，因為闔著沒人能輸入，視窗會一直卡住 Hammerspoon。沒睡成就 30 秒後重試
- 睡著後會不定時短暫醒來（`pmset -g log` 裡的 DarkWake），這段期間交給系統，不再送睡眠

## 安裝

需要 [Hammerspoon](https://www.hammerspoon.org/)。目前在 MacBook Air M3、macOS 26.6、Hammerspoon 1.1.1 上使用。

1. clone 進 Hammerspoon 的設定資料夾：

   ```bash
   git clone https://github.com/isaac216/lid-coffee.git ~/.hammerspoon/lid-coffee
   ```

2. `~/.hammerspoon/init.lua`（沒有就新建）加一行，然後點選單列的 Hammerspoon 圖示 → Reload Config：

   ```lua
   require("lid-coffee")
   ```

3. 讓 `pmset -a disablesleep 0` 與 `1` 這兩條指令不用密碼。沒裝的話，手動切換 ☕／🥛 會跳管理者密碼視窗，闔滿上限的自動睡眠則會失敗（它只用 `sudo -n`）：

   ```bash
   tmp=$(mktemp)
   echo "$(whoami) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1" > "$tmp"
   visudo -cf "$tmp" && sudo install -m 0440 -o root -g wheel "$tmp" /etc/sudoers.d/pmset-disablesleep
   rm "$tmp"
   sudo -k; sudo -n /usr/bin/pmset -a disablesleep 0 && echo OK   # 不問密碼就印 OK
   ```

   只放行這兩條指令，其他 `sudo` 照樣要密碼。檔名不能含 `.`，sudo 會略過 `/etc/sudoers.d/` 裡檔名帶點的檔。

4. 點選單列的 🥛，選一個時數，變成 ☕ 就好了。

## 設定

改 `lid-coffee/init.lua` 裡的常數，存檔後 Reload Config：

| 常數 | 預設 | 意思 |
|---|---|---|
| `LID_HOUR_CHOICES` | `{ 0.5, 1, 2, 3, 4, 6, 8, 12 }` | 選單可選的上限時數 |
| `LID_DEFAULT_HOURS` | `4` | 沒選過時的上限 |
| `LID_POLL_SECONDS` | `30` | 多久查一次蓋子，也是闔上後螢幕最多亮多久 |

熱鍵在 `hs.hotkey.bind({"cmd", "ctrl"}, "l", ...)` 那行改。

選過的上限存在 `hs.settings` 的 `lidMaxHours`，Reload、重開機都還在。查目前的上限：

```bash
defaults read org.hammerspoon.Hammerspoon lidMaxHours
```

## 確認有沒有在跑

```bash
pmset -g | grep SleepDisabled                    # 1 = ☕；從沒設過時這行不會出現
cat ~/.hammerspoon/lid-timeout.log               # 只在自動睡眠、計時器出錯時寫
pmset -g log | grep 'Entering Sleep' | tail -3   # 一次要跑幾秒
```

每次載入後約 30 秒，`~/.hammerspoon/last-load.txt` 會多一行「闔上計時器第一輪：蓋子開著」，有這行才算計時器真的在跑。

自動睡眠有觸發時，`lid-timeout.log` 會記一行，例如「闔上 4.0 小時（上限 4 小時），第 1 次送睡眠。disablesleep 0：成功」，`pmset -g log` 隨後有 `Software Sleep pid=<Hammerspoon 的 pid>`（`pgrep -x Hammerspoon`）。

要短時間測自動睡眠：在 `LID_HOUR_CHOICES` 暫加 `0.05`（選單顯示 3 分鐘）並選它，闔上 5 分鐘再打開，測完拿掉、選回原本的時數。

## 注意

- MacBook Air 沒有風扇。☕ 時放進包包，機器會悶著跑到上限時數才睡。收包前按 `Cmd+Ctrl+L` 切成 🥛；手上的工作還要跑完，就選短的上限
- 用電池時會一路跑到上限時數或沒電
- 自動睡眠要 Hammerspoon 在跑。Hammerspoon 沒開，`disablesleep` 也不會自己關
- 闔著時 Hammerspoon 重新載入設定，計時從頭算
- 內建螢幕靠名稱認，比對「內建」或「Built-in」。系統是其他語言時，把 `hs.screen.allScreens()` 看到的內建螢幕名稱加進 `onlyBuiltinScreens()`，不然會一直當成接著外接螢幕，什麼都不做

## 移除

先切成 🥛（或 `sudo pmset -a disablesleep 0`），再：

```bash
sudo rm /etc/sudoers.d/pmset-disablesleep
rm -rf ~/.hammerspoon/lid-coffee
```

最後拿掉 `init.lua` 的 `require("lid-coffee")`，Reload Config。
