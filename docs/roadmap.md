# Libertty roadmap：对齐 Tern / Rex

功能对齐清单，参考对象是 Tern 和 Rex（需求见 memory `feature-parity-tern-rex`）。

- **Tern** 的功能来源：`tern --help` 和二进制里的 changelog。
- **Rex** 的功能来源：Superlogical 的公开文档，以及 Mitchell Hashimoto 的公开发言。
- 状态标记：✅ 已完成　🚧 进行中　⬜ 未开始

## 1. 窗口 / 标签 / 分屏

| 功能 | Tern | Rex | Libertty |
|---|---|---|---|
| 新窗口 ⌘N | ✓ | ✓ | ✅ |
| 新标签 ⌘T（侧栏标签列表，可拖动排序、重命名、⌘1…8 切换） | ✓ | ✓ | ✅ |
| 分屏：右 ⌘D、下 ⌘⇧D | ✓ | ✓ | ✅（真机验证过） |
| 拖动分隔条调大小、双击均分、⌃⌘= 均分 | ✓ | ✓ | ✅ |
| ⌘⌥ 方向键切换焦点、⌘W 关闭当前 pane | ✓ | ✓ | ✅ |
| 卡片式 pane：圆角 12、3px 间隙、"长出 / 融化"动效（320ms，`--out` 曲线） | ✓ | — | ✅ |
| 未聚焦 pane 变暗（0.65），光标变空心 | ✓ | — | ✅ |
| Liquid tabs 高亮动效 | ✓ | — | ✅ 侧栏选中卡片在标签之间“流”过去：前沿先到、后沿跟上（减少动态效果时直接跳） |
| 三指滑动切换标签 | ✓ | — | ✅（系统设置里“页面间轻扫”设成三指时） |
| 标签总览（Mission Control 式） | ✓ | — | ✅ ⌘⇧\（Window ▸ Show All Tabs，Ghostty 的 toggle_tab_overview）：每个标签实时渲染成缩略图（分屏按布局拼好），从当前标签缩小展开、选中的放大回去；方向键 / 回车 / ⌘1…9 / Esc |
| 命令面板 ⌘⇧P（Ghostty 的 toggle_command_palette）：命令、本窗口的标签、后台会话、主题，模糊匹配 | ✓ | — | ✅ 样式对齐 Tern：下面窗口压暗、搜索框 + esc 键帽、范围胶囊（All / Panes / Commands / Sessions / Themes，Tab 切换）、分组标题、图标块、快捷键拆成键帽、选中行带强调色竖标、底部操作提示 |
| UI 对齐 Tern（自己实现，不拷 Tern 的 CSS / 资源） | ✓ | — | ✅ 一张"画布"：工具栏、侧栏、缝隙同一个框色（深色下比终端底深一档），pane 是 10pt 圆角卡片、间距 6pt；分屏时焦点 pane 顶上一条强调色线；界面字体 Geist（OFL，随 App 打包）；侧栏行 30pt、选中白卡（深色下 8% 白）、底部 Filter tabs；`pane-headers = never/split/always`（默认 never，同 Tern）：程序/目录名、路径、网格尺寸，焦点 pane 上有浮窗/放大/关闭；`tab-bar = sidebar/top`：标签横排在工具栏里（按目录末段命名、点击切换、双击内联改名、拖动排序、中键或 × 关闭、右键菜单、放不下时收窄再滚动），此时侧栏只留文件树；`tests/fixtures/tab-strip.txt` |
| Quick Terminal：从屏幕边缘滑出的终端（Ghostty 同名功能），`quick-terminal-position/size/autohide/hotkey`，里面的会话也持久化 | — | — | ✅ |
| 有程序在运行时，关窗前确认 | ✓ | ✓ | ✅（可在设置里关掉） |
| **全局快捷键**：在任何 App 里一键开新窗口（默认 ⌃⌥T） | — | — | ✅ Carbon `RegisterEventHotKey`，不需要辅助功能权限；真机验证过 |
| 全局显示 / 隐藏（Tern `global_hotkey`，默认空） | ✓ | — | ✅ 窗口在别的桌面时挪到当前桌面，而不是把你切走 |
| 关掉最后一个窗口后继续运行；点 Dock 图标重新开窗；Dock 菜单 New Window | ✓ | ✓ | ✅ |
| 新窗口、新标签、分屏继承当前 pane 的目录（OSC 7） | ✓ | ✓ | ✅ 真机验证过 |
| 移动 pane / 标签（Rex：Move Pane to Tab / New Tab、Move Tab to New Window、拖出成窗口） | — | ✓ | ✅ `move_surface_to_new_tab`、`move_surface_to_tab:N`、`move_surface_to_new_window`、`move_tab_to_new_window`；窗口菜单、命令面板、右键菜单；侧栏标签拖到别的窗口就移过去（窗口唯一的标签也行，那个窗口随之关闭），拖出所有窗口就成新窗口；顶部标签栏也能拖出成窗口。程序全程不断。⬜ 拖动 pane 本身（目前只能用命令） |
| 鼠标悬停即聚焦（Rex "Focus follows mouse"、Ghostty `focus-follows-mouse`） | — | ✓ | ✅ 只在终端 pane 之间切换，不抢查找框、改名框、文档和编辑器的焦点；拖动时不切 |
| 侧栏按状态过滤（Rex：activity filter） | — | ✓ | ✅ 过滤框末尾的按钮（选中时实心）、命令面板、`show_tabs:working|waiting|attention|all`（再按一次回到全部）：只列程序在工作 / 等你 / 完成或失败的标签，状态变了行就跟着出现或消失；和名字过滤叠加；计数显示 "1/4"。`tests/fixtures/sidebar-activity.txt` |
| 跳转目录（Rex：Go to Directory 面板页） | — | ✓ | ✅ 命令面板的 Folders：pane 所在目录、shell 最近去过的目录（存在数据目录）、输入 / 或 ~ 开头的路径时列出子目录；回车在那里开新标签；`go_to_directory`、文件菜单。⬜ 在当前 pane 里 cd |

## 2. 会话持久化与多路复用（Tern 和 Rex 的核心）

| 功能 | Tern | Rex | Libertty |
|---|---|---|---|
| 后台 daemon 持有 PTY 和终端状态，关窗后会话还在 | ✓ `tern daemon` | ✓ 服务端 | ✅ `liberttyd`：每个会话一个 PTY + 一份无界面的 libghostty-vt 终端。退出 App、App 崩溃（`kill -9` 实测）、App 更新，程序都继续跑；下次启动按原样恢复窗口、标签、分屏 |
| 重新连接时恢复屏幕：libghostty-vt `snapshot` | ✓ | ✓ 二进制快照 | ✅ 用 libghostty-vt 的二进制快照（屏幕、scrollback、模式，连没写完的转义序列都在），之后接实时输出；窗口那边是副本，负责渲染和回答程序的查询 |
| 多个窗口同时镜像同一个 pane | ✓ | ✓ 状态机副本 | ✅ `libertty +attach ID`；关掉其中一个只断开它，最后一个关掉才结束程序 |
| daemon 升级不断会话 | — | — | ✅ 新版 liberttyd 通过 SCM_RIGHTS 接过旧版的 PTY 描述符和快照，旧版退出；已连接的窗口自动重连并用新快照追上（实测） |
| 远程主机 | ✓ `tern remote` | ✓ | ✅ File ▸ Connect to Host…（⇧⌘K）/ `libertty +connect HOST`：窗口里的标签和分屏都跑在那台机器上，走用户自己的 ssh（配置、密钥、agent、跳板机都生效；密码和新主机指纹弹窗问，一个 ControlMaster 只问一次）。主机上有自己的 liberttyd：断网、合盖、退出 Libertty 程序都不停，pane 显示"正在重新连接"，连上后用快照追上；下次启动自动重连。第一次连接时把 liberttyd、shell 集成和 terminfo 装到主机的 `~/.libertty`（用主机的 tic 编译），不需要 root。会话命令支持 `--host`。测试用假 ssh（`tests/fixtures/fake-ssh`）跑完整流程：安装、远程 shell 集成、断网重连、重启后重连、结束会话。Linux 主机（x86_64、aarch64）：App 里带静态链接的 liberttyd（`scripts/build-linux-liberttyd.sh`，Zig 交叉编 libghostty-vt + swift.org 的静态 Linux SDK）；daemon 在 Linux 上只用 FoundationEssentials（完整 Foundation 会带进 45 MB 的 ICU），每个 12–13 MB，首次安装经 ssh 传约 5 MB。⚠️ 还没在真的 Linux 机器上跑过 |
| Web 客户端 | ✓ `tern web` | ✓ | ✅ Libertty ▸ Web Access…（`web-access = off/local/network`，默认关）：在浏览器（手机也行，有二维码）里看这台 Mac 上任意 pane 的实时画面并打字。画面由 libghostty-vt 的 HTML 格式化器生成（颜色、粗体、链接都对），按键走和本机一样的键盘编码器（方向键、Ctrl 组合、kitty 键盘协议都按程序要的模式编码），手机有 Esc/Tab/Ctrl/方向键工具条，可以看完整 scrollback。安全：每个连接都要链接里的 256 位密钥（常数时间比较，错多了限流），拒绝别的网站来源，页面脚本只靠每次响应的 nonce 运行，程序写的 OSC 8 链接只保留 http/https/mailto；`local` 只监听本机（配合 ssh -L 或 Tailscale），`network` 是明文 HTTP 会明确提示；`web-access-input = false` 只看不能打字。无窗口测试走真实 WebSocket（页面、密钥、外站来源、画面、打字、Ctrl-C），另外在无头 Chrome 里跑过页面本身（渲染、光标、打字回显） |

实现说明：
- 协议是 Unix socket 上的长度前缀帧（`Sources/LiberttyCore/Wire.swift`），控制消息用 JSON，输出、输入是原始字节；一条连接对应一个会话。
- 性能实测（`--session-bench`，200 MB，完整 10 MB scrollback）：dense_cells 直连 323、经 liberttyd 322 MB/s；scrolling_fullscreen 91 对 92 MB/s。吞吐没有损失（liberttyd 和窗口并行解析）。按键回显多 0.16 ms（0.27 → 0.43 ms）。
- liberttyd 和窗口都会在空闲时压缩 scrollback（libghostty-vt 的增量压缩）。
- 顺手修了一个老 bug：libghostty-vt 默认还有 10 KB 的 scrollback 字节上限，以前 Libertty 实际只留约 500 行。`scrollback-limit` 现在和 Ghostty 一样按字节计，默认 10 MB；小于 100000 的值仍按行数理解，兼容旧配置。
- 布局存在 `~/Library/Application Support/Libertty/windows.json`，每 2 秒有变化才写。会话不在了的 pane（比如重启过电脑）在原目录开新 shell。
- 配置：`session-persistence`（默认开），`window-save-state`（Ghostty 的同名项）。

## 3. 命令行控制

| 功能 | Tern | Libertty |
|---|---|---|
| `libertty +new-window / +new-tab [--cwd] [-e CMD]`、`libertty +action`、`libertty +open` | ✓ | ✅（发给正在运行的 Libertty，没在运行就先启动） |
| `ls / new / send / capture / kill / attach` | ✓ | ✅ `libertty +list-sessions / +new-session / +send / +capture / +kill-session / +attach`，`$LIBERTTY_SESSION` |
| `split / run / focus / wait` | ✓ | ✅ `+action new_split:…`、`+new-session -e`、`+focus ID`、`+wait ID`（退出码原样返回） |
| 按 pane ID 操作布局（Rex：`rex split -b BLOCK --split=below --ratio 30`、`move`） | — | ✅ `+split [ID] [--down] [--ratio 30] [--cwd] [--no-focus] [-e CMD]`（输出新会话 ID）、`+move-pane [ID] --new-tab / --tab N / --new-window`。App 用回复通知告诉 CLI 结果：成功、找不到、被拒（附原因）或出错；被拒时不抢焦点。⬜ swap、resize |
| 发送按键（Rex：`rex send-key`） | — | ✅ `+send-key ID ctrl+c enter up …`：liberttyd 用自己那份终端状态按程序当前模式编码（光标键模式、kitty 键盘协议）；`tests/send-key-test.sh` 验证实际字节 |
| 从 Ghostty 导入配置（Rex："Migrate from Ghostty"） | — | ✅ `+import-ghostty`：读 Ghostty 的配置文件和它引入的文件，只加 Libertty 认识、自己还没设的项；列出不认识和不接受的；先问、备份 |
| 快速失败时保留 pane（Rex："stays open after a quick failure"、`--keep-open`） | — | ✅ `abnormal-command-exit-runtime`（默认 250 ms，Ghostty 同名）内非 0 退出就保留，显示退出码，按键关闭；`wait-after-command`（Ghostty 同名）、`+split --keep-open`；可以重启 Shell；`libertty -e` 一次性运行不保留 |
| `wait --until prompt|idle`、`capture --ansi/--html`、`events` | ✓ | ✅ `+wait ID --until exit|prompt|idle=MS --timeout S`（超时退出 124；提示符靠 OSC 133，idle 由 liberttyd 计时，值上限一天）、`+capture --ansi / --html`（带颜色的文本、带样式的网页）、`+events [--filter …]`（JSON 行：session-started / prompt / command-started / command-finished / directory / session-ended，每个监听者自己的队列，慢的监听者不拖累别人）；`tests/cli-wait-test.sh`（17 项） |
| ssh 到没有这份 terminfo 的主机 | ✓ | ✅ shell 集成给 ssh 包一层，远端用 `TERM=xterm-256color`（Ghostty 的 ssh-env 做法，`ssh-env = false` 关掉）；用户自己定义的 ssh 函数或别名优先 |
| 自带 terminfo | ✓ | ✅ `TERM=xterm-ghostty`：Libertty 的终端就是 libghostty-vt，Ghostty 的 terminfo（MIT）描述得一字不差；App 里带编译好的版本，`TERMINFO` 指过去。程序因此知道支持 undercurl、同步输出等。`term = …` 可以改 |
| 会话命名、agent 集成（Rex：`rex skill setup`、"Let agents name sessions"） | — | ✅ `+rename-session [ID] NAME`（名字存在 liberttyd，升级接管时也带着，标签按名字显示，`+list-sessions`、`+events label` 能看到）；`+status STATE` 任何脚本都能上报 OSC 7501；`+agent-setup` 给 Claude Code 装 hook 和 skill（先列出改动并询问，保留别人的 hook、备份、跟随符号链接、保持文件权限，`--remove` 撤掉）：标签显示工作中 / 等你批准 / 完成，agent 知道自己在哪个 pane，并按任务给会话起名（`agent-session-names`）。真实 Claude Code 跑过一遍。⬜ Codex 等其他 agent |

## 4. 程序状态与通知

| 功能 | Tern | Rex | Libertty |
|---|---|---|---|
| OSC 7501 记录，严格按规范实现 | ✓ | ✓（规范是 Rex 定的） | ✅ 存储、标题和标签显示，新提示符出现时清记录（都在真机上验证过） |
| pane 图标、标签上的状态徽标（工作中 / 等待中 / 完成 / 失败） | ✓ | ✓ | ✅ 侧栏标签上：进度环（OSC 9;4 或 7501 的进度，未知进度时转圈）、等你处理（橙色 !）、完成（绿 ✓）、失败（红 ✗）；Dock 图标数字 = 等你处理的程序数 |
| **自动注入 shell 集成脚本**（OSC 133 提示符标记、OSC 7 当前目录） | ✓ | ✓ | ✅ 三个 shell 的脚本都是自己写的，没用 Ghostty/kitty 的 GPL 脚本，用户的 dotfiles 照常加载：zsh（ZDOTDIR，真机验证过）；bash（`--rcfile` 加上模拟登录加载，DEBUG trap 标记命令边界，在 macOS 自带的 3.2 上用 pty 验证过）；fish（XDG_DATA_DIRS 的 vendor_conf.d，**本机没装 fish，未实测**） |
| 横幅通知（agent 需要人处理、长命令完成） | ✓ | — | ✅ 你不在看那个 pane 时才通知；点通知跳到那个 pane；`notify-on-command-finish(-after)`（Ghostty 同名项），命令名来自 shell 集成发的 `133;C;cmdline_url` |
| 通知收件箱 | ✓ | — | ✅ 工具栏的铃铛：所有通知按时间倒序，有新的时显示角标，点一条跳到对应的 pane |
| agent 完成 / 等你处理时，pane 边缘光环合拢 | ✓ | — | ✅ 颜色跟状态走（完成绿、等待橙、失败红）；正在打字的 pane 不闪 |
| OSC 133 命令块：在命令之间跳转、拿到退出码 | ✓ | ✓ | ✅ ⌘↑/⌘↓ 跳到上/下一个提示符；退出码和耗时用于完成通知 |
| OSC 9 / 777 桌面通知、OSC 9;4 进度 | ✓ | ✓ | ✅ |
| OSC 52 剪贴板（ssh 里的 vim/tmux 复制） | ✓ | ✓ | ✅ 写默认允许，读默认拒绝（`clipboard-read/-write`） |
| 按状态分别设置提醒（Rex："Independently configure tab indicators, system notifications, Dock badges, and sounds"） | — | ✓ | ✅ `program-status-indicator / -notify / -dock-badge / -sound`，默认行为不变 |
| 识别等待输入密码（Rex："Waiting for a password"、`modes` 的 echo/canonical） | — | ✓ | ✅ 关闭回显 + 整行读取 = 读密码；liberttyd 在输出或输入后检查一次，变化时通知窗口（新帧 `inputMode`），App 当作"等你处理（需要登录）"的状态显示；本地 pty 同样检测。`+events` 有 `input-mode` |
| 隐私权限归属（摄像头、麦克风、文件夹等） | — | ✓ | ✅ liberttyd 自己承担责任进程（`responsibility_spawnattrs_setdisclaim`），内嵌带用途说明的 Info.plist（"Libertty Sessions"）；ssh 远程主机上保持 sshd 的权限。⚠️ 实际弹窗需要在真机上试 |

## 5. 终端能力（大部分来自 libghostty-vt，不用自己写）

| 功能 | Libertty |
|---|---|
| 真彩色、粗体、斜体、各种下划线、反色、半透明（faint） | ✅（已用快照验证） |
| 中日韩宽字符居中、emoji 字素簇（mode 2027 默认开启） | ✅（已用快照验证） |
| 内置 JetBrainsMono Nerd Font（OFL-1.1，只在进程内注册） | ✅（Powerline、图标都已验证） |
| 输入法（NSTextInputClient）：组字时在光标处显示带下划线的预编辑文字，候选框跟随光标 | ✅（拼音真机验证过） |
| kitty 键盘协议（libghostty-vt 编码器） | ✅ |
| 括号粘贴、kitty 剪贴板（5522），不安全的粘贴先确认 | ✅ |
| 文本选择：单击、双击选词、三击选行、拖动（用 libghostty-vt 的手势状态机）；⌘C 复制、⌘A 全选；打字时清掉选区 | ✅（双击选词加复制，真机验证过） |
| 选区拖到窗口边缘时自动滚动、Shift 点击扩展选区、⌥ 拖动选矩形块 | ✅ 用 libghostty-vt 手势自带的 autoscroll 和矩形选择 |
| 鼠标上报（程序开启鼠标追踪时，交给 libghostty-vt 的编码器：SGR、URXVT 等格式，点击、拖动、滚轮、悬停）；按住 Shift 绕过上报，改成选择 | ✅（SGR 点击真机验证过） |
| 备用屏滚动：less、man 这类程序里，滚轮转成方向键 | ✅ |
| 超链接（OSC 8）、URL 识别 | ✅ ⌘+悬停加下划线、⌘+点击打开；OSC 8 链接在 pane 左下角显示真实地址；跨软换行的 URL 也能识别；右键 Open/Copy Link |
| 文件路径识别：`path:line:col`（编译器、grep、git diff 的 a/ b/），⌘+点击在 Libertty 标签里打开并跳到那一行；`libertty +open FILE:LINE` | ✅ |
| kitty 图形协议 | ✅ 解析和存储用 libghostty-vt，PNG 用 ImageIO 解码，按协议的三层（文字背景下 / 文字下 / 文字上）画纹理；支持 RGB/RGBA/灰度、分块传输、文件 / 临时文件 / 共享内存三种传输方式、源区域裁剪和缩放（`tests/fixtures/kitty-image.py` 快照验证）。Unicode 占位符（虚拟放置，tmux 透传用）也画：按占位格的颜色和组合符号找图和行列，等比放进它的格子网格（照 Ghostty 的算法）。重新连接 liberttyd 后图片还在：liberttyd 也存图，附加时在快照后把屏上的图重新发给窗口（`--kitty-reattach-probe` 两种放置方式都验证过） |
| 制表符、方块字符自己绘制（不依赖字体字形）：细线、粗线、双线及混合、圆角、对角线、1/8 方块、象限块、阴影 | ✅（`tests/fixtures/boxes.sh` 快照验证） |
| Powerline 符号、分支符号这类自己绘制 | ✅ Powerline 三角、圆头、斜角（U+E0B0–E0BF）、git 图用的分支符号（U+F5D0–F60D，lazygit 等）、盲文点阵都按格子几何画，段与段之间没有缝（`tests/fixtures/sprites.sh` 快照） |
| 编程连字（`->` `!=` `===` `|>` …） | ✅ 等宽连字字体用的是 contextual alternates：每个字符留在自己的格子里，只是换成另一个字形、画进相邻格子。所以只对含两个以上相邻符号的“词”用 CoreText 整形，按格子换字形，结果缓存；160×50 满屏代码整帧重画中位数 0.31 ms。`font-feature = -calt` 关掉（Ghostty 同名项） |
| 搜索 scrollback（⌘F、⌘G/⌘⇧G、⌘E 搜选中文字，高亮所有匹配） | ✅ 用 libghostty-vt 的 search API |

## 6. 原生体验与性能

| 功能 | Libertty |
|---|---|
| 跟随显示刷新（最高 120Hz），空闲时暂停 | ✅ |
| 只重建脏行 | ✅ |
| 输入延迟：`--latency-trace` 实测，按键到上屏中位数 120Hz 下 8.5–10.6ms（原来 30ms）、60Hz 下 17–21ms（原来 44ms）；默认 `window-vsync = false`，全屏时自动打开同步 | ✅ |
| 拖动缩放时同步呈现，PTY 尺寸更新去抖 50ms | ✅ 修好了缩放卡顿：原来窗口缩放时每帧主线程卡约 900ms（display link 在 `presentsWithTransaction` 打开时还走 command buffer 的 present，drawable 一直不释放，`nextDrawable` 要等满 1 秒超时）。现在所有尺寸变化（窗口边缘、分隔条、分屏动画）都在 CA 事务里同步呈现，一帧只画一次，3 个 drawable，drawable 按 256px 分档复用，内容钉在左上角、不拉伸。`Libertty --resize-trace [--divider] [--splits N]` 实测 240 帧丢 0 帧，分隔条拖动每帧 2.6ms |
| 触控板按像素滚动 | ✅ 触控板跟手按点滚动（`scroll-smooth`，默认开）：整行交给 libghostty-vt 滚，余下的不到一行用 GPU 偏移，下方那一行用网格引用读出来补上；到顶/到底、有新输出跟到底部、改尺寸时回到行边界；鼠标点击和选择按偏移换算。快照测试半行偏移 |
| 减少动态效果开关 | ✅ token 已就位 |
| Secure Keyboard Entry | ✅ |
| Quick Terminal（下拉式终端） | ✅ 见 §1 |
| 基准测试：vtebench 吞吐、输入延迟 | ✅ 吞吐：上一轮 vtebench 12 项都第一，但那轮 Libertty 实际只留了约 500 行 scrollback、网格也比 Tern 小，成绩偏高，修好后还没重跑（`bench/RESULTS.md`）；输入延迟用外部测法（`bench/keylat.swift`）和 kitty、Ghostty、Terminal.app 比过一轮：出厂默认下 Libertty 中位数最低（20 ms，kitty 25、Ghostty 28–34、Terminal 40），但领先不到一帧，设置对齐的比较和更多轮次还没做 |
| **PTY 读线程改造**（照搬 Tern 的做法）：专用线程 + 非阻塞自旋读；数据不足 1 KiB 立刻交出，否则攒到 64 KiB 或 3 ms；读和解析分开，中间有 1 MiB 背压；从端开启 IUTF8 | ✅ 无窗口实测：200 MB 端到端从 112–128 MB/s 提升到 **303–345 MB/s**，快照渲染回归测试通过。大段粘贴（非阻塞写入遇到 EAGAIN 的分支）已验证：2 MB 粘贴进 raw 模式的程序一个字节不少，直连和经 liberttyd 都是约 0.25 s（`--paste-probe`，在 `tests/run.sh` 里）。⬜ 共享 poller（安静的 pane 让出读线程）还没做 |
| 拖分隔条：网格和 drawable 尺寸都没变时不重画；drawable 按 256px 分档。120Hz 下 2 个、4 个 pane 拖分隔条都是 240 帧丢 0 帧（原来分别丢 14、34 帧） | ✅ |
| NSAccessibility 文本接口，让 VoiceOver 能逐行朗读（Otty 已经做了） | ✅ 终端是只读文本区：按行 / 词 / 字读，光标即插入点，新输出会通知 VoiceOver（每秒最多 4 次） |
| pane 内容通用化：不只放终端，还能放文本、图片、网页、diff（Otty 和 Tern 都有） | ✅ 文档（Markdown 渲染、源码）既能开成标签，也能开成终端旁边的 pane：侧栏 ⌥ 单击或右键 Open Beside Terminal、⌥⌘ 单击路径、`libertty +open --split FILE[:LINE]`；分屏导航、缩放、⌘W、布局恢复都支持。图片（棋盘格透明底，文件变了自动刷新）、PDF、网页（开发服务器放在它的终端旁边：⌥⌘ 单击网址、Inspector 里点端口、`libertty +open --split http://localhost:3000`；页面标题当标签名，外链交给浏览器）、diff（`libertty +diff`、Inspector ▸ Show Changes：按文件分块、新旧行号、加删着色、代码高亮，再次打开就刷新；.diff/.patch 文件也这样显示）也都能放 |
| **Markdown 渲染**（Tern `markdown_rendered`）：在侧栏里单击 `.md` 就在标签页里打开渲染结果。支持 GFM：表格、任务列表、嵌套列表、代码块高亮（用终端主题的配色）、引用、图片、引用式链接、自动链接、原始 HTML（页面 JS 关闭）。样式取自 Tern 的 CSS 和设计 token；文件保存后自动刷新，阅读位置保持不变；支持 ⌘F、⌘+/⌘−，可以切换成看源码。`libertty +open FILE`、`libertty +render-markdown FILE` | ✅ |
| 源码文件查看：语法高亮 + 行号 | ✅ |
| 键盘移动分隔条（⌃⌘方向键）、单个 pane 最大化（⇧⌘↩） | ✅ |
| 侧栏文件树带 Git 状态颜色（修改橙、新增/未跟踪绿、删除红），提示符出现时刷新（命令改了子目录里的文件也能看到；根目录另有文件监听） | ✅ 借鉴 ELYTerminal：`git status --porcelain -z` 解析（GitCLI，Inspector 和 Show Changes 共用），异步跑、代数防乱序 |
| pane 画中画 | ✅ Window ▸ Picture in Picture / 右键：pane 实时显示在一个浮在所有 App 和桌面上的小窗里，原 pane 不动；直接画 pane 自己的帧（不多一份终端），点一下回到 pane，悬停显示标题和按钮，pane 关了它也关 |

## 9. 日常细节（对齐 Ghostty / Terminal.app / iTerm2）

| 功能 | Libertty |
|---|---|
| 滚动条：系统风格的覆盖式滚动条，滚动时出现、指针移到右边缘时变宽，可以拖动、点轨道翻页（`scrollbar = system/never`，Ghostty 同名项） | ✅ 数据用 libghostty-vt 的 scrollbar 状态和按行滚动 |
| 光标闪烁（`cursor-style-blink`，Ghostty 同名项：默认闪、程序可以用 DECSCUSR 或 DEC 12 改） | ✅ 打字时重新从亮开始；窗口不在前台时不闪 |
| 铃声（`bell-features = system,attention,title,border`，Ghostty 同名项） | ✅ 系统提示音、Dock 跳动、标签标题加 🔔（看过就消失）、pane 边缘闪一下 |
| 打字时隐藏鼠标指针（`mouse-hide-while-typing`） | ✅ |
| 复制时带上颜色（纯文本 + HTML，Ghostty 的 copy_to_clipboard:mixed） | ✅ 用 libghostty-vt 的 HTML 格式化输出 |
| 导出文本（File ▸ Export Text As…、Open Scrollback in Tab；`write_scrollback_file` / `write_selection_file`，Ghostty 同名动作） | ✅ |
| 复制上一条命令的输出（Edit 菜单、右键、命令面板；`copy_command_output`） | ✅ 按 OSC 133 的提示符标记找范围，zsh 和 bash 都验证过 |
| 同时输入到标签里所有 pane（Window ▸ Broadcast Input，iTerm2 的功能） | ✅ 每个 pane 按自己的终端模式编码按键；广播中的 pane 边框变橙色，窗口副标题提示 |
| Edit ▸ Emoji & Symbols（⌃⌘空格） | ✅ |
| 撤销关闭（Edit ▸ Undo Close Pane / Tab / Window，⌘Z；`undo-timeout`，Ghostty 同名项，默认 5 秒） | ✅ 关掉的 pane、标签、窗口在超时内保持运行，撤销后原样回来（程序没停、布局和比例不变）；超时后才真正结束会话。退出时等待撤销的会话一起结束 |
| 分屏里的文档 pane 和终端 pane 一样：失焦变暗、悬停出 ×、⌘F 搜索它、焦点和缩放都记得、恢复时按原位置 | ✅ |

## 8. 安装与更新

| 功能 | Libertty |
|---|---|
| Check for Updates（菜单、每天自动检查、`auto-update = check/download/off`，Ghostty 同名项） | ✅ 更新包用 Ed25519 签名，公钥内置在 App 里；大小、SHA-256、签名都对上才装。实测：篡改过的包（连 SHA-256 一起伪造）会被拒绝，真包装好后版本号正确、代码签名完好（`tests/update-test.sh`）。装完重启，程序在 liberttyd 里不中断，窗口原样恢复 |
| Homebrew cask（`brew install --cask ziwangprincex/libertty/libertty`，同时链接 `libertty` 命令） | ✅ `scripts/release.sh` 生成，`auto_updates true`；⬜ 还没发布（等你决定） |
| DMG 安装包 | ✅ `scripts/package.sh` |
| Developer ID 签名和公证 | — 不做（你说不管）；Homebrew 安装时去掉隔离标记，DMG 第一次打开需要右键 ▸ 打开 |

## 7. 配置与设置

| 功能 | Libertty |
|---|---|
| 配置文件 `~/.config/libertty/config`（尊重 `XDG_CONFIG_HOME`），Ghostty 式 `key = value` | ✅ 保存即生效（监听目录，编辑器原子替换也能收到），所有窗口实时更新 |
| 设置照 Ghostty：⌘, 直接打开配置文件；配置有错时弹 Configuration Errors 窗口；`libertty +set/+get/+show-config` 等命令行 | ✅（原来的自制设置窗口已删掉） |
| 11 套内置主题（Libertty Dark/Light、Catppuccin、Tokyo Night、Gruvbox、Dracula、Nord、One Dark、Solarized），可单独覆盖前景、背景、光标、选区、palette | ✅ |
| 字体（任意等宽字体，Nerd 图标自动回退到内置字体）、字号、光标样式 | ✅ |
| 背景透明度 + 毛玻璃，标题栏一起透明 | ✅ |
| 内边距、新窗口尺寸、未聚焦分屏变暗程度 | ✅ |
| Option 当 Alt（左、右或两边）、选中即复制、scrollback 行数、启动命令、起始目录 | ✅ |
| `libertty +validate-config` 检查配置，逐行报告问题 | ✅ |
| 自定义键位（keybind），Ghostty 语法和 action 名，`global:` 全局键位 | ✅ |
| 分屏 pane 悬停时右上角出现 ×，右键菜单（复制、粘贴、分屏、清屏、查找、关闭） | ✅ |
| 自定义主题文件（`~/.config/libertty/themes`，也能直接用 Ghostty 装的 463 套）、`theme = light:X,dark:Y` 跟随系统深浅色 | ✅ |

## 10. 借鉴 ELYTerminal / GoRex

| 功能 | 说明 | 状态 |
|---|---|---|
| Git 侧栏面板 | 暂存 / 取消暂存、丢弃（带确认，新目录用 `clean -fd`）、提交（失败保留提交信息并显示 git 的原话）、最近提交、点文件看 diff（暂存的 `--cached`、工作区、新文件 `--no-index` 对 /dev/null）。所有命令在**仓库根**下跑（porcelain 的路径永远相对根，pane 可能在子目录）；行和仓库根同时刷新，切 pane 的瞬间点按钮也不会作用到别的仓库；`--no-optional-locks` 不抢用户自己 git 命令的 index.lock | ✅ 借鉴 ELYTerminal：`GitPanel.swift` + `GitCLI`；`tests/fixtures/git-panel.txt` 用面板自己的按钮在子目录里暂存、提交，再让终端 `git log` 读回来 |
| UI 回归测试框架 | `libertty --ui-probe SCRIPT OUTDIR`：真实 App 开在屏幕外、全程不激活，真实 `NSEvent` 回放按键（大小写、`@ # % ~ "` 走 shift+原键、⌃C 带控制字符、Return 带 `\r`、方向键带功能键标志）和鼠标（`click:x,y` 或按标题/提示/占位文字 `click:Stage a.swift`，会打印点中了什么），每步截 PNG，`expect:` / `expect-not:` 断言各 pane 文本。已接进 `tests/run.sh` | ✅ 借鉴 ELN `examples/shot.rs`。窗口永远不是 key（不抢焦点），AppKit 会把第一下点击用来激活窗口，所以点击直接交给命中的视图（它自己的 mouseDown/跟踪/action）。弹模态框（alert、菜单）的点击会让脚本一起等 |
| 标签上的程序图标（Rex 的招牌外观） | 按前台进程组认出程序，标签上叠它的图标（Claude、vim、lazygit→"Git Changes"……聚焦 pane 的在前，超过 4 个显示 +N）；运行时或 wrapper 在前台时看它启动的子进程（tclaude = node → claude）或它跑的脚本名/所在包（不做子串匹配：`/Users/claude/x.js` 不是 Claude）；空闲 shell 不画，回到标签本身的小图标。内核调用在后台线程，同一进程组同一名字时复用结果 | ✅ 借鉴 GoRex `programs.go`，但**单色**：一排彩色方块在侧栏里读起来像装饰而不是信息 |
| pane 的活动圆点 | 程序正在输出时（最后输出 < 1.5s）pane 角上显示一个实心点——不需要任何协议支持，任何程序都有。淡入淡出各一次，不脉冲（GoRex："一直画帧的成本大于它表达的信息"）；每轮输出只开一个动画和一个定时器 | ✅ |
| 工具栏主机徽章 | 机器名小徽章，点开显示型号、芯片、内存、系统和 liberttyd（Rex 的 UI 元素，GoRex 复刻了） | ✅ |
| 慢窗口不拖累任何人 | 每个窗口一个发件箱 + 独立写线程（`LiberttyCore/Outbox.swift`）：会话只往队列里放、从不在锁里写 socket；落后超过 8 MB 的窗口跳过积压，之后收到一份当时的快照（新帧类型 `snapshot`，attach/create 时声明 `catchUp`），旧客户端则被断开重连。跳过期间程序的终端查询由 liberttyd 代答，不会让程序干等 | ✅ 借鉴 GoRex `attached.send`（有界队列 + 丢弃重连），加上 tmux 式追赶快照。`--slow-client-probe`：一个窗口不读时，洪流结束时间、打字延迟和单窗口时一样；改之前要多等 10 秒，打字卡 9 秒 |
| 关 pane 后的焦点 | 只有被关的 pane 有焦点时才移动焦点（后台 pane 退出不抢你的键盘），并且回到你之前用的 pane（每个 tab 一个最近使用列表），不是邻居 | ✅ 借鉴 GoRex `state.go` |
| 后台 tab 的动态 | 你不在的 tab：程序在输出时标题旁一个实心强调色小点；有东西结束（跑了 3 秒以上的命令）或响铃时一个空心圈，聚焦那个 pane 后消失。pane 自己的活动圆点不再因为 shell 回显你打的字而亮 | ✅ 借鉴 GoRex，去掉颜色（只用系统强调色） |
| 分屏细节 | 均分按每侧 pane 数加权（三个并排各三分之一，不是 50/25/25）；关掉被放大 pane 后面的 pane 不取消放大；只剩一个 tab 时不显示 ×；⌘9 提示标在最后一个 tab 上 | ✅ 借鉴 GoRex |
| GoRex 其余 GUI 候选 | 标签显示程序名 + 短目录（ssh 显示主机；shell 自己设的标题——"zsh"、"~/src"、"me@mac: ~/src"、文件夹名——不算程序的标题）；⌘P 跳到任意窗口任意 pane，含 quick terminal、文档 tab 和分屏里的文档，tab 起过的名字也能搜；侧栏 tab 内联重命名（双击 / ⇧⌘R，输入时其它 tab 照常更新，tab 增删或侧栏收起时保留已输入的名字）；分屏 pane 悬停名牌；"在原处重启 shell"（先起新 shell，起不来旧的不动；保留 pane 自己的目录）；分隔条悬停提示（移开、拖到尽头、窗口失焦都会熄）；布局由 liberttyd 按 Mac 分别保存（每台 Mac 一个 ID，按机器存，迁移助理拷不走），连到主机时取回那台主机上没有窗口在显示的会话和它们的窗口（后台线程，读不到就不覆盖主机上的那份；别的 Mac 自己的窗口和文档不会被带过来；`window-save-state = never` 时不取）；本地 liberttyd 断开提示；面板"无结果"行 | ✅ 借鉴 GoRex；`--layout-store-probe`、`gorex-gui` UI probe |

## 12. 终端自带功能与 workspace blocks（2026-10-19）

Tern 的三项终端功能，加上 11 个 workspace block（编号 11 的 AI 助手和 13 的云端机器/多人不做；全部是自己的代码或 MIT/OFL 开源件，没有用 Tern 的代码）。

| 功能 | 说明 | 状态 |
|---|---|---|
| Park pane（收起 pane） | 把分屏 pane 从布局里取下，会话照常运行（程序继续跑、输出继续收），之后从侧栏/面板放回原处 | ✅ `TerminalTab.Parked`、`park_surface` / `unpark_surface` |
| 窗口内 PiP（Float Pane） | 把 pane 缩小成窗口角上的一张卡片（镜像渲染，拖动换角、可展开/Put Away），会话仍在原布局里 | ✅ `FloatingPaneCard`、`float_surface` |
| 每窗口命名会话（Workspaces） | 一个窗口里几组名字与各自的 tab/分屏；切换、新建、重命名、关闭、⇧⌘1…9、命令面板；布局保存时也存工作区 | ✅ `switchWorkspace` 等，`workspaces` UI probe |
| 块的基础设施 | `libertty-block://NAME?参数` 地址、`DocumentView.Kind.block`、页面在 `blocks/NAME`（自带 CSP）、`block.call` ↔ `BlockService`、命令在任意终端结束后刷新、块也能读主题、`FileBlock` 统一处理文件读写（冲突不覆盖、原子写、跟随外部修改、⌘S/关闭时向页面要保存） | ✅ `Blocks/Block.swift`、`Blocks/FileBlock.swift`、`blocks/common/block.js` |
| 1. 编辑器 | CodeMirror 6，语种识别、主题、Vim 键位、查找；保存保留编码/CRLF/权限、外部修改检测、备份、`+open --wait`（git commit 的 EDITOR） | ✅ `Document/Editor.swift`、`frontend/editor/` → `vendor/codemirror` |
| 2. Git 客户端 | 变更（按块暂存/丢弃）、提交/amend、历史与图、每个提交的 diff、分支（切换/新建/删除）、fetch/pull/push、stash；冲突文件单独显示、用我方/对方；字面路径、UTF-8 文件名、重命名的两条路径 | ✅ `Blocks/GitBlock.swift`、`GitCLI` |
| 3. 浏览器块 | 地址栏（地址或搜索）、前进后退、加载进度、下载到 Downloads（重名不覆盖）、页面里的链接在块里开；`+browser` 自动化（读页面需 `browser-automation = true`，且 `+set` 不能打开它） | ✅ `Document/Browser.swift` |
| 4. 任务管理器 | 全部进程、CPU/内存、每个终端下的进程标出 pane、详情（命令行、目录、监听端口）、显示终端、打开目录、Quit/Force Quit（只限自己的进程，不碰 liberttyd），Profile… | ✅ `Blocks/TasksBlock.swift`、`libproc` |
| 5. 画布 | Excalidraw（MIT）：`.excalidraw` 文件、自动保存、跟随外部修改、冲突时选择保留哪份、导出 PNG/SVG、新画布 | ✅ `frontend/canvas/` → `blocks/canvas/lib`、`Blocks/FileBlock.swift` |
| 6. 性能分析 | 用 macOS 的 `sample` 录终端里的进程（可提前停止），报告转成 collapsed stacks 用 speedscope（MIT）显示，记录留在 Libertty 的 Profiles 里 | ✅ `Blocks/ProfilerBlock.swift`、`blocks/profile` |
| 7. 看板 | 以 Markdown 保存的 kanban（`## 列` + `- [ ] 卡片`），拖动/⌥方向键移动、勾选、标签、改名；`BOARD.md` 按仓库/目录打开，`*.board.md` 也认 | ✅ `blocks/board`、`Blocks/FileBlock.swift` |
| 8. SQLite | 表/视图、分页浏览、按列排序、结构、SQL 查询（多语句、限 1000 行、可停止）；默认只读（URI `mode=ro` + `sqlite3_stmt_readonly` 双保险），允许修改后才能改单元格 | ✅ `Blocks/SQLiteBlock.swift` |
| 9. 插件 | 配置目录 `plugins/` 里的 JavaScript，每个在自己的 JSContext + 自己线程（死循环只卡它自己）；API：命令、commandFinished 事件、通知、往终端打字、打开文件/网页、目录、屏幕文本、存储；默认关闭，打开才运行，保存即重载 | ✅ `Blocks/Plugins.swift`、`blocks/plugins` |
| 10. Notebook | `.ipynb` 按单元格编辑（Markdown 渲染经消毒器、代码 ⇧↩ 运行），内核用用户自己的 `jupyter server`（自动启动，token 只在本进程内），输出写回文件；关掉 tab 就停内核与服务器 | ✅ `Blocks/NotebookBlock.swift`、`blocks/notebook` |
| 11. 屏幕共享 | ScreenCaptureKit 抓一个显示器或一个窗口，按帧发给块显示（本机；远程共享走 liberttyd 的连接尚未做）；探测只允许 Libertty 自己的窗口 | ✅ `Blocks/ScreenShareBlock.swift` |

测试：`tests/run.sh` 里的 `tab-strip`、`park`、`float`、`workspaces`、`editor`、`git-block`、`tasks`、`canvas`、`profiler`、`board`、`sqlite`、`plugins`、`notebook`（没有 jupyter 时跳过）、`screen`、`browser`、`browser-automation`。
