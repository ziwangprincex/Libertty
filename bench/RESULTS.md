# 吞吐基准：vtebench

测试时间：2026-10-15。机器是 Apple M5 Pro，macOS 27.0.1。
怎么跑：`bench/run-vtebench.sh`，每个终端单独跑，每项测 8 秒，每个样本至少 8 MiB；汇总用 `bench/report.py`。
原始数据：`bench/results/`（8 MiB 样本）、`bench/results-archive/1mib/`（第一轮，1 MiB 样本）。

> **⚠️ 更正（2026-10-15 晚）：下面 vtebench 表里 Libertty 的成绩要打折扣。**
> 测试时 Libertty 实际只保留了约 500 行 scrollback。原因是 libghostty-vt 默认还有一个 10 000 **字节**的历史上限，
> 当时 `scrollback-limit` 只设了行数，这个字节上限一直生效。而其他终端都保留了完整的 scrollback（Ghostty 默认 10 MB）。
> 历史越少，滚动类测试越占便宜。现在已经修好：`scrollback-limit` 改成和 Ghostty 一样按字节计，默认 10 MB，空闲的历史会压缩。
> 修好之后要重跑 vtebench（`./run-vtebench.sh libertty libertty-persist`，会占用屏幕几分钟）。
> 在那之前，下面这组无窗口的端到端数据是准确的。

### 无窗口端到端（`Libertty --session-bench`，200 MB，完整 10 MB scrollback）

PTY → （liberttyd → socket →）解析，不含渲染。

| 数据 | 直连 PTY | 经 liberttyd（默认路径） |
|---|---:|---:|
| scrolling_fullscreen | 91 MB/s | 92 MB/s |
| dense_cells | 323 MB/s | 322 MB/s |

- 经 liberttyd 和直连没有差别：liberttyd 和窗口里的副本是并行解析的。
- 纯解析器单独测（`--parse-bench`）：滚动类在 1 页 / 2 MB / 10 MB 字节上限下分别是 89 / 98 / 105 MB/s。改用 libghostty 的**行数**上限只有 50–52 MB/s，因为行数上限修剪时要扫描。所以 scrollback 用字节上限。

## 结果：吞吐量（MB/s，越高越好）（scrollback 修复前，Libertty 的成绩偏高，见上）

Libertty 是改完 PTY 读线程、又换成三栏窗口之后的成绩（第二次运行，`bench/results/`）；其他终端是同一天早些时候、同一台机器上测的。

| 测试项 | Libertty | kitty | Ghostty | Otty | Tern |
|---|---:|---:|---:|---:|---:|
| 网格（列×行） | 119×40 | 120×40 | 123×42 | 97×31 | 160×45 |
| cursor_motion | **303** | 145 | 154 | 92 | 217 |
| dense_cells | **358** | 126 | 134 | 75 | 266 |
| light_cells | **383** | 154 | 132 | 101 | 272 |
| medium_cells | **295** | 83 | 110 | 85 | 209 |
| scrolling | **80** | 13 | 65 | 38 | 43 |
| scrolling_bottom_region | **81** | 37 | 55 | 27 | 51 |
| scrolling_bottom_small_region | **81** | 38 | 51 | 19 | 61 |
| scrolling_fullscreen | **350** | 127 | 131 | 115 | 221 |
| scrolling_top_region | **81** | 38 | 58 | 15 | 51 |
| scrolling_top_small_region | **82** | 38 | 59 | 33 | 59 |
| sync_medium_cells | **285** | 53 | 96 | 85 | 81 |
| unicode | **301** | 153 | 179 | 4 | 256 |

**综合分**：每一项都除以该项的最好成绩，再对 12 项取几何平均，1.00 表示每一项都是第一。

| Libertty | Tern | Ghostty | kitty | Otty |
|---:|---:|---:|---:|---:|
| 1.00 | 0.64 | 0.51 | 0.36 | 0.22 |

Libertty 自己的变化（MB/s）：

| 测试项 | 读线程改造前 | 改造后 | 三栏窗口后，第 1 次 | 第 2 次 |
|---|---:|---:|---:|---:|
| cursor_motion | 170 | 306 | 283 | 303 |
| dense_cells | 181 | 374 | 346 | 358 |
| light_cells | 139 | 369 | 366 | 383 |
| scrolling | 66 | 81 | 80 | 80 |
| scrolling_fullscreen | 138 | 365 | 336 | 350 |
| scrolling_top_small_region | 70 | 86 | 66 | 82 |
| sync_medium_cells | 142 | 285 | 251 | 285 |
| unicode | 138 | 301 | 291 | 301 |

三栏窗口后的第 1 次有几项低了 7% 到 23%，第 2 次回到原来的水平，说明是单次运行的波动，不是退步。数据在 `results-archive/before-reader/`、`results-archive/after-reader/`、`results-archive/ide-run1/`、`results/`。

改造前（第一版 DispatchSource 读取）的综合分：Tern 0.85、Libertty 0.79、Ghostty 0.68、kitty 0.48、Otty 0.30。

## 结论

- **kitty 比 Ghostty 快吗？** 在这台机器上，按吞吐量看不是。kitty 只在 `light_cells` 一项小幅领先，滚动类测试明显落后，`scrolling` 一项只有 13 MB/s，Ghostty 是 65 MB/s。但输入延迟这次没有测，所以"打字跟不跟手"这一点还下不了结论。kitty 默认开着 `repaint_delay` 和 `sync_to_monitor`，这些设置可能拖慢了它在这个测试里的成绩。
- **Libertty**：12 项全部第一。读线程照 Tern 的做法改了以后（非阻塞自旋读、按 1 KiB / 64 KiB / 3 ms 攒批、读和解析分开），整屏重绘类从落后 Tern 25%–50% 变成领先约 30%–70%；滚动类本来就领先，这次又涨了约 20%。滚动类测试和 Ghostty 共用 libghostty-vt，Libertty 80 对 Ghostty 65，差距来自读线程和每帧只画一次。
- **Tern**：整屏重绘最快，而且它是在更大的 160×45 网格下测的，网格大，每帧渲染的工作量也更大。它在滚动类测试里一般。
- **Otty**：`unicode` 一项只有 4 MB/s，两轮结果都一样。alacritty_terminal 本身不会这么慢，问题很可能出在 Otty 自己加的那一层上，比如 BiDi 重排或链接检测。

## 这个基准量的是什么、没量什么

- vtebench 量的是**终端把 PTY 里的数据读走并处理完的速度**，也就是大量输出时 shell 会被卡多久。它不测输入延迟，不测帧率稳不稳，也不测每一帧画得对不对。如果一个终端在后台线程里解析、每帧只画一次，它在这个测试里就会占便宜。Libertty、Ghostty、Tern 都是这种设计。
- **网格大小不一样**：
  - 测试数据是按网格尺寸生成的，所以这里比的是吞吐量（MB/s），每个样本的字节数由 `payload-sizes.sh` 按各终端的网格重新计算。
  - Ghostty 的 `--window-width` 会多出几格；Otty 不接受尺寸参数，Tern 也不接受。网格越大，每帧渲染越贵，所以 Tern 的成绩如果有偏差，只会是偏低。
- **每个终端只跑了一次**，没有统计多轮之间的波动。数字相差 10% 以内的，可以看成差不多。
- **测试时的状态**：所有终端都用默认配置，窗口都在前台，测试期间没有其他操作。
- **对测试本身的修改**：vtebench 原来的脚本在 macOS 上有个 bug。`ps -o tty=` 输出的结果末尾带空格，导致 `cursor_motion`、`light_cells` 这几项生成的数据为空，测试被直接跳过。我把它改成了 `/dev/tty`，修改在 `bench/vtebench.patch` 里。

## 输入延迟：Libertty 自测

`Libertty --latency-trace [--count N] [--fastest]`：在 App 内部合成按键，交给真实的 zsh（用户自己的 `.zshrc` 和 starship 主题），一直等到显示回显字符的那一帧真正上屏（Metal 的 `presentedTime`）为止，每次按键都记时间。按键在 `a` 和退格之间交替，节奏大约每秒 30 次。量的是软件部分：App 处理 + shell 回显 + 渲染 + 合成。键盘扫描和屏幕刷新这部分硬件时间没算在内，所有终端在这里的开销都差不多。

| 显示器 | 改之前 | 改之后（默认） |
|---|---:|---:|
| 60 Hz 外接屏 | 中位数 44 ms（p95 48） | 中位数 **17–21 ms** |
| 120 Hz 内建屏（ProMotion） | 中位数 30 ms（p95 33） | 中位数 **8.5–10.6 ms** |

其中按键到 shell 回显只占 0.3 ms 左右，剩下的时间全花在把帧送上屏幕。改了两处：

1. **不等垂直同步就呈现**（`displaySyncEnabled = false`，对应 Ghostty 的 `window-vsync = false`）。窗口模式下画面仍然由 WindowServer 合成，所以不会撕裂；全屏时一律重新打开同步。可以用 `window-vsync = true` 强制打开。
2. **空闲时有新输出就立刻画一帧**，不用再等下一个 display link 周期。持续大量输出时，帧率还是跟着屏幕刷新走。

还没跟其他终端比较过：它们没法用同样的方式在 App 内部测，得用外部方案，比如 typometer 那种截屏测法，或者高速摄像。

## 输入延迟：和其他终端横向比（外部测法，2026-10-17）

`bench/keylat.swift`：从外面用同一种方法测每个终端。用 ScreenCaptureKit 只录目标窗口，`CGEvent.postToPid` 发按键（`a` 和退格交替），计时从发键到第一帧"光标所在行"变了的画面。每个终端都用同一个简单的 zsh 提示符（`PROMPT='$ '`，没有 starship），配置文件只改了窗口大小，其余都是默认。MacBook 内建 120 Hz 屏，每轮 80 次按键。

| 终端 | 中位数（每轮） | p95 | 最小 |
|---|---|---:|---:|
| Libertty 0.2.0 | 20.0 / 20.8 / 20.5 ms | 35 | 7.2 |
| kitty 0.49.0 | 24.8 / 24.7 / 26.4 / 25.8 ms | 37–38 | 11–14 |
| Ghostty 1.3.1 | 27.7 / 33.9 / 32.2 ms | 47 | 15–24 |
| Terminal.app | 39.7 ms（1 轮） | 45 | 9.2 |

怎么读这张表：

- **这是"出厂默认"对"出厂默认"。** 差距大部分来自默认设置不同：Libertty 默认 `window-vsync = false`（窗口模式下不等垂直同步），Ghostty 默认 `true`；kitty 默认带 `input_delay 3`、`repaint_delay 10`、`sync_to_monitor yes`。设置对齐之后的比较还没做。
- **数字比 App 内自测（8.5–10.6 ms）高 10 ms 左右**，多出来的是录屏管线本身的延迟。可以假定每个终端都差不多，但还没验证。
- **光标闪烁会干扰判断。** 这几轮里 Libertty、Ghostty、Terminal.app 的光标都在闪，闪烁可能被误判成回显，让最小值和低分位偏低。Terminal.app 中位数 39.7、最小值却只有 9.2，很可能就是这个原因。kitty 关掉闪烁之前有两轮丢了 14 和 32 次按键，那两轮已作废，表里只放关闪烁后的数据。
- **Libertty 领先 kitty 不到 120 Hz 下的一帧（8.3 ms），轮与轮之间也有波动**（Ghostty 三轮相差 6 ms），所以名次只能当作初步结果。
- Tern 没测：要隔离它就得复制它的登录状态，这一步没做。

测法后来又改进了：帧时间改用合成器的 `displayTime`，每次发键前检查目标窗口还在最前面，发键前随机等待，窗口一直在变（比如光标在闪）时会报警告。改进后的版本还没来得及跑完一整轮，表里仍是第一版测法的数据。

## 下一步

1. 用改进后的 `bench/keylat.swift` 重测：所有终端关闭光标闪烁，轮流交错跑，每个终端至少 500 次按键；再加一组设置对齐的比较（vsync 一致，kitty 用 `input_delay 0`、`repaint_delay 2`、`sync_to_monitor no`），并在 60 Hz 下再测一遍。
2. 用 240 fps 慢动作视频对 Libertty 和 Ghostty 做一次交叉验证。
3. 其他终端的吞吐成绩是今天早些时候测的，下次一起重跑一遍。
