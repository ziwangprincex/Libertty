# Homebrew tap for Libertty

[Libertty](https://github.com/ziwangprincex/Libertty) is a fast native macOS terminal built on
libghostty-vt, with sessions that outlive the app and an editor, a Git client, a browser and
other blocks beside the terminal.

## Install

```sh
brew install --cask ziwangprincex/libertty/libertty
```

Apple silicon, macOS 14 or later. This puts Libertty in Applications and links the `libertty`
command into Homebrew's `bin`. The app is ad-hoc signed and not notarized; the cask clears the
quarantine flag, so it opens without the "Open Anyway" step.

## Updates

Libertty updates itself: Libertty ▸ Check for Updates…, or daily (`auto-update = check |
download | off` in its config). Each update is verified with an Ed25519 signature before it is
installed, and programs keep running in your sessions while Libertty restarts.

`brew upgrade` updates it too while it's older than the cask here, and leaves it alone once it
has updated itself.

## Uninstall

```sh
brew uninstall --cask libertty          # the app and the command
brew uninstall --cask --zap libertty    # also its config, data, caches and logs
```

Programs in your sessions run in Libertty Sessions (`liberttyd`), which quitting Libertty
leaves running. To end them before uninstalling, choose Libertty ▸ Quit and End Sessions (⌥⌘Q).

---

## 中文

```sh
brew install --cask ziwangprincex/libertty/libertty
```

需要 Apple silicon、macOS 14 或更高版本。安装后 Libertty 在"应用程序"里，`libertty` 命令链接到 Homebrew 的
`bin`。应用是临时签名、未经公证，cask 会去掉隔离标记，打开时不需要"仍要打开"。

Libertty 会自己更新（Libertty ▸ Check for Updates…，或每天自动检查），更新包都经过 Ed25519 签名校验，
更新时会话里的程序继续运行。应用版本比 cask 旧时，`brew upgrade` 也会更新它；它自己更新过之后，`brew upgrade`
就不再动它。卸载用 `brew uninstall --cask libertty`，加 `--zap`
连配置、数据、缓存和日志一起删除。退出 Libertty 后会话里的程序仍在 Libertty Sessions（`liberttyd`）里运行，卸载前想结束它们，
用 Libertty ▸ Quit and End Sessions（⌥⌘Q）。

The cask is written by `scripts/release.sh` in the Libertty repository, with each release.
