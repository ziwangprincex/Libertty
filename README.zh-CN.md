<p align="center"><img src="assets/icon/png/libertty-256.png" width="128" alt="Libertty logo"></p>

# Libertty

[English](README.md) | 简体中文

Libertty 是一个 macOS 终端模拟器。VT 解析和终端状态由
[libghostty-vt](https://github.com/ghostty-org/ghostty) 负责，应用本身用 Swift 和 AppKit
编写，渲染器基于 Metal 和 CoreText 自行实现。Shell 会话运行在独立的守护进程
`liberttyd` 中，应用退出后会话继续运行。除终端外，窗口中还可以打开文档和工具面板
（"块"）：编辑器、Git 客户端、浏览器、任务管理器等。

## 状态

- 版本 0.2.0。需要 macOS 14 或更高版本；构建脚本产出 Apple silicon（arm64）二进制。
- 未经过 Apple 公证。更新包改用 Ed25519 签名校验（见[更新与发布](#更新与发布)）。
- 已在 [GitHub Releases](https://github.com/ziwangprincex/Libertty/releases) 发布（DMG 和 zip）。暂无 Homebrew cask。
- 已知缺口：屏幕共享只能在本机查看，不能传到远程主机；陷入死循环的插件会一直占用它自己的线程，直到 Libertty 重启；Notebook 不渲染交互组件（ipywidgets）。

## 安装

1. 从[最新版本](https://github.com/ziwangprincex/Libertty/releases/latest)下载 `Libertty-版本号.dmg`，打开后把 Libertty 拖到"应用程序"文件夹。
2. 应用未经公证，第一次打开会被 macOS 拦下。先打开一次，然后在"系统设置 ▸ 隐私与安全性"中点"仍要打开"；或者在打开前运行 `xattr -dr com.apple.quarantine /Applications/Libertty.app`。
3. 可选：在 Libertty 的 shell 里可以直接使用 `libertty` 命令。要在其他地方使用，建一个链接：`ln -s /Applications/Libertty.app/Contents/Resources/bin/libertty ~/.local/bin/libertty`。

不需要安装 Xcode 或 Command Line Tools。Git 客户端、Git 面板和文件树的 Git 标记需要 `git`：可以来自 Command Line Tools（`xcode-select --install`），也可以是其他安装，例如 Homebrew 的。没有 git 时，这些功能会提示 git 未安装，Libertty 的其他部分照常使用。

会话里的程序需要的隐私权限（摄像头、麦克风、文件与文件夹、完全磁盘访问）归会话守护进程 Libertty Sessions 所有，macOS 也以它的名义询问。要让程序拥有完全磁盘访问权限，在"系统设置 ▸ 隐私与安全性 ▸ 完全磁盘访问权限"里添加 `/Applications/Libertty.app/Contents/MacOS/liberttyd`（在文件对话框里按 ⌘⇧G 可以直接输入路径）。Libertty 是临时签名，更新后 macOS 可能会再问一次。

## 功能

### 终端

- 通过 Metal 和字形图集渲染。制表符、Powerline 和盲文字符按单元格网格绘制。支持 kitty 图像协议，包括 tmux 的 Unicode 占位符。默认启用编程连字（`font-feature = -calt` 可关闭）。
- `TERM=xterm-ghostty`，附带对应的 terminfo。从 Libertty 的 shell 里执行 `ssh` 时发送 `TERM=xterm-256color`，`ssh-env = false` 可关闭此行为。
- zsh 和 bash 的 shell 集成（提示符标记、工作目录、命令耗时与退出码）。
- 支持 OSC 8 超链接、OSC 9 / OSC 777 通知、OSC 9;4 进度、OSC 52 剪贴板（默认禁止读取）和 OSC 7501 程序状态。
- ⌘-点击可打开 URL，以及带行号和列号的文件路径（`src/a.swift:42:7`）。
- 长时间运行的命令结束时发送通知（`notify-on-command-finish`），提供通知收件箱；Dock 图标上的角标显示等待输入的程序数量。
- 程序状态（OSC 7501：工作中、等你处理、完成、失败）：每种状态是否显示在标签上、是否发通知、是否计入 Dock 角标、是否播放声音，都可以分别设置（`program-status-indicator`、`-notify`、`-dock-badge`、`-sound`）。

### 窗口、标签页与面板

- 标签页可放在侧栏或窗口顶部（`tab-bar = sidebar | top`）；支持分屏；面板标题栏可选（`pane-headers = never | split | always`）。
- 收起面板（Park）：把面板移出布局，其中的程序继续运行，之后可以放回。
- 浮动面板（Float）：把面板以卡片形式显示在窗口一角。
- 程序一启动就失败（`abnormal-command-exit-runtime` 毫秒内以非 0 状态退出，默认 250）时，pane 保留并显示错误，按任意键关闭。`wait-after-command = true` 让所有程序退出后都保留 pane；`libertty +split --keep-open` 只保留这一个。
- 移动 pane：从分屏移到新标签、移进另一个标签的分屏，或者移到新窗口；把标签移到新窗口。把标签拖出所有窗口会开成一个新窗口，拖到另一个窗口的标签列表上就移过去（窗口菜单、命令面板、右键菜单；`move_surface_to_new_tab`、`move_surface_to_tab:N`、`move_surface_to_new_window`、`move_tab_to_new_window`）。
- 工作区（Workspaces）：同一窗口内的多组命名标签页（⌘⇧1…9）。
- 命令面板（⌘⇧P）、跳转到面板（⌘P）、标签页总览（⌘⇧\\）、Quick Terminal、画中画、广播输入；关闭面板、标签页或窗口可撤销（`undo-timeout`）。

### 会话（liberttyd）

Shell 运行在 `liberttyd` 中，由 Libertty 按需启动。应用退出、崩溃或更新时程序继续运行；下次启动恢复窗口、标签页、分屏、屏幕内容和回滚缓冲区。关闭面板或窗口会结束其中的程序；⌥⌘Q 结束全部会话。新版本的 liberttyd 会接管正在运行的旧进程，期间不结束会话。`session-persistence = false` 时 shell 改为在应用内运行。

### 远程主机

文件 ▸ 连接到主机…（⇧⌘K，或 `libertty +connect HOST`）打开一个窗口，其中的面板通过系统的 `ssh`（`~/.ssh/config`、密钥、agent、跳板机）运行在另一台机器上。主机端会安装自己的 liberttyd（位于 `~/.libertty`，不需要 root），因此断线后程序继续运行。支持的主机：macOS（Apple silicon）和 Linux（x86_64、aarch64）。

### 网页访问

`web-access = local | network` 把本机的面板提供给浏览器：显示面板的屏幕内容，并通过与键盘相同的按键编码器输入。每个页面都需要链接中的密钥。`local` 只监听本机；`network` 在局域网上使用明文 HTTP。`web-access-input = false` 时只读。

### 文档与块

文件和工具可以在标签页中打开，也可以作为面板显示在终端旁边。

| 项目 | 说明 |
|---|---|
| 文档 | Markdown（渲染后显示）、带语法高亮的源文件、图片、PDF、网页、`git diff` 输出 |
| 编辑器 | CodeMirror 6；保留文件的编码和换行符；检测外部修改；Vim 键位（`editor-keymap = vim`）；`libertty +open --wait` 可用作 `$EDITOR` |
| Git | 按文件或代码块暂存、取消暂存、丢弃；提交与 amend；带分支图的历史；分支；fetch、pull、push；stash；冲突时选用我方或对方版本 |
| 浏览器 | 地址栏，支持搜索（`browser-search`）；下载到 ~/Downloads；`libertty +browser` 命令；读取或操作页面需要在配置文件中设置 `browser-automation = true` |
| 任务管理器 | 全部进程及其 CPU、内存占用；按所属终端分组；命令行、目录、监听端口；可对当前用户自己的进程执行退出和强制退出 |
| 画布 | Excalidraw 绘图，保存为 `.excalidraw` 文件，自动保存，可导出 PNG 或 SVG |
| 性能分析 | 用 macOS 的 `sample` 录制进程，用 speedscope 显示结果 |
| 看板 | 以 Markdown（`## 列`、`- [ ] 卡片`）保存在 `BOARD.md` 或 `*.board.md` 中的看板 |
| SQLite | 表和视图、分页浏览、排序、表结构、SQL 查询；默认只读，允许修改后才能写入 |
| 插件 | `~/.config/libertty/plugins/` 中的 JavaScript；默认禁用，启用后才运行；每个插件在独立的 JavaScriptCore 上下文和线程中运行 |
| Notebook | `.ipynb` 文件；代码在用户自己的 `jupyter server` 内核中运行（`jupyter =` 指定路径）；输出写回文件 |
| 屏幕 | 通过 ScreenCaptureKit 显示本机的一个显示器或一个窗口（需要"屏幕录制"权限） |

基于文件的块（画布、看板、Notebook）采用原子写入；文件在别处被修改后，未经确认不会覆盖；没有未保存的修改时会自动载入外部改动。

### 编程 Agent

- `libertty +agent-setup` 给 Claude Code 的配置（`$CLAUDE_CONFIG_DIR`，没有就是 `~/.claude`；`--claude-dir` 指定其他目录）加上 hook，并安装一个介绍 Libertty 命令行的 skill。它会先列出要改的内容并询问，`--remove` 可以撤掉。之后在 Libertty 里运行 Claude Code，标签上会显示它在工作、等你处理（需要批准）还是已完成；它会知道自己在哪个 pane，并按任务给会话起名（`agent-session-names = false` 关闭起名）。在其他终端里这些 hook 什么都不做。
- `libertty +status STATE`：任何脚本都能向终端报告程序状态（OSC 7501）。
- `libertty +rename-session [ID] NAME`：给会话起名，标签和 `+list-sessions` 都会显示这个名字。

## 环境要求与构建

- macOS 14+、Swift 6（Command Line Tools 即可）、Zig 0.16（`brew install zig@0.16`）。
- Node.js 和 npm 仅在重新构建内置网页时需要；构建产物已在仓库中。

```sh
git submodule update --init vendor/ghostty   # 固定版本的 Ghostty 源码
scripts/build-libghostty-vt.sh   # 首次构建，或更新 vendor/ghostty 之后
scripts/bundle.sh                # 生成 build/Libertty.app（debug）；`scripts/bundle.sh release` 生成优化版本
open build/Libertty.app
```

其他构建脚本：

| 脚本 | 产物 |
|---|---|
| `scripts/build-editor.sh` | 由 `frontend/editor/` 生成 `vendor/codemirror/` |
| `scripts/build-canvas.sh` | 由 `frontend/canvas/` 生成 `blocks/canvas/lib/` |
| `scripts/build-speedscope.sh` | `blocks/profile/lib/`（speedscope 发布版） |
| `scripts/build-linux-liberttyd.sh` | 供 Linux 主机使用的静态 liberttyd（依赖见脚本开头） |
| `scripts/gen-keymap.py` | 由 Ghostty 的按键表生成 `Sources/Libertty/Input/KeyMap.swift` |

## 配置

配置文件为 `~/.config/libertty/config`，格式与 Ghostty 相同（`key = value`、`keybind = cmd+d=new_split:right`、`theme = light:X,dark:Y`、`config-file = ...`）。Libertty ▸ 设置…（⌘,）打开该文件，保存后立即生效；配置错误会在 Configuration Errors 窗口中列出。可直接使用 Ghostty 的主题文件，来源包括 `~/.config/libertty/themes` 和已安装的 Ghostty.app。

```sh
libertty +set theme="Tokyo Night" font-size=14
libertty +get theme
libertty +show-config --changes        # 另有 --default、--docs
libertty +validate-config
libertty +list-themes ; libertty +list-fonts ; libertty +list-keybinds ; libertty +list-actions
```

`libertty +set` 不能修改 `browser-automation`，该项只能通过编辑配置文件设置。

## 命令行

在 Libertty 的 shell 中，`libertty` 已在 `PATH` 里。`libertty +help` 列出全部命令。

```sh
libertty +action new_split:right                 # 在运行中的应用里执行一个动作
libertty +new-window --cwd ~/src -e htop
libertty +open [--split] [--edit] [--wait] FILE[:LINE]
libertty +diff [git diff 参数]
libertty +browser open URL ; libertty +browser text

libertty +list-sessions [--json]
libertty +new-session --cwd ~/src -e make watch
libertty +capture ID [--scrollback] [--ansi | --html]
libertty +send ID 'make test\n'
libertty +wait ID --until exit|prompt|idle=MS [--timeout S]
libertty +events [--filter KIND,...]
libertty +attach ID [--window] ; libertty +kill-session ID
libertty +split [ID] [--down] [--ratio 30] [--no-focus] [-e COMMAND]   # 在会话 ID 的 pane 旁边开一个新 pane，输出新会话的 ID
libertty +move-pane [ID] --new-tab | --tab N | --new-window
```

会话相关命令支持 `--host HOST`。`$LIBERTTY_SESSION` 是当前面板的会话 ID。

## 测试与诊断

`tests/run.sh [release]` 运行无界面测试套件，使用独立的 liberttyd、配置目录和数据目录，不打开可见窗口，也不抢占焦点。覆盖范围包括渲染快照（输出到 `build/test-output/`）、解析、配置、链接、选区、shell 集成、会话、粘贴、吞吐量，以及窗口功能和每个块的 UI 脚本（`tests/fixtures/*.txt`，由 `Libertty --ui-probe SCRIPT OUTDIR` 执行）。找不到 `jupyter server` 时跳过 Notebook 测试（`LIBERTTY_TEST_JUPYTER` 可指定路径）。`tests/update-test.sh` 离线检查更新流程。

```sh
# 不开窗口，把命令的最终屏幕输出为 PNG
build/Libertty.app/Contents/MacOS/Libertty --snapshot out.png --cols 90 --rows 15 -- sh tests/fixtures/showcase.sh
Libertty --latency-trace [--count N]             # 按键到屏幕的延迟
Libertty --resize-trace [--divider] [--splits N] # 调整窗口大小时每一步的主线程耗时
Libertty --session-bench FILE [--mb N] [--persist]
Libertty --git-probe                             # 在当前目录下 Libertty 会使用哪个 git
```

与其他终端的对比基准位于 `bench/`（`bench/RESULTS.md`）。

## 更新与发布

- 通过 Libertty ▸ 检查更新…、每日自动检查（`auto-update = check | download | off`）或 `libertty +update [--check]` 更新。更新包是一个 zip，其 Ed25519 签名必须与应用内置的公钥（`scripts/update-public-key.txt`）匹配。安装时替换应用包并重新启动，会话在 liberttyd 中继续运行。
- `scripts/release.sh VERSION` 根据 `docs/CHANGELOG.md` 中对应版本的段落，在 `build/release/VERSION` 中生成 zip、DMG、`appcast.json` 和 Homebrew cask；加 `--publish` 则上传到 `scripts/release.conf` 中配置的仓库和 tap。签名私钥从 `~/.config/libertty-release/update.key`（或 `$LIBERTTY_UPDATE_KEY`）读取，不在仓库中。

## 目录结构

| 路径 | 内容 |
|---|---|
| `Sources/Libertty/` | 应用：`App`（入口、命令行、探测）、`UI`、`Terminal`、`Renderer`、`Document`、`Blocks`、`Config`、`Remote`、`Web`、`Input`、`Design`、`Util` |
| `Sources/LiberttyCore/` | 应用与守护进程共用：PTY 读取、通信协议、守护进程服务端、远程 PTY |
| `Sources/liberttyd/` | 会话守护进程入口 |
| `Sources/CPty/` | C 辅助代码：`openpty` 与进程创建、Unix socket、libproc 查询 |
| `Sources/CGhosttyVt/` | libghostty-vt 头文件的模块映射 |
| `blocks/` | 块的页面（HTML、CSS、JavaScript）；`blocks/*/lib/` 存放打包好的第三方构建产物 |
| `frontend/` | 内置网页的 npm 源码（`editor`、`canvas`） |
| `vendor/` | Ghostty（固定版本的检出）、构建好的 CodeMirror、Geist 字体 |
| `Resources/` | 随应用发布的文件：shell 集成、terminfo、远程 liberttyd 二进制、第三方声明 |
| `assets/icon/` | 应用图标、各尺寸 PNG、favicon、SVG 及其生成脚本 |
| `scripts/` | 构建、打包和发布脚本 |
| `tests/` | 测试套件及测试数据 |
| `bench/` | 吞吐量与延迟基准；旧的测试数据在 `bench/results-archive/` |
| `docs/` | `CHANGELOG.md`、`roadmap.md` |
| `tools/` | `winshot`（按进程 ID 截取单个窗口） |

## 第三方组件

libghostty-vt（MIT）、带 Nerd Fonts 符号的 JetBrains Mono（OFL-1.1）、Geist（OFL-1.1）、CodeMirror 6（MIT）、Excalidraw 与 React（MIT；Excalidraw 的字体为 OFL-1.1 和 MIT）、speedscope（MIT；Source Code Pro 为 OFL-1.1）。完整声明见 `Resources/THIRD-PARTY-NOTICES.txt`；每个打包产物另附 `LICENSES.txt`。
