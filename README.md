<div align="center">
  <img src="assets/icon.png" alt="RubyLock RPC" width="120" />

  # RubyLock RPC

  Zero-dependency Ruby Discord Rich Presence client for **Deadlock**. Automatically shows your hero, match mode, elapsed match timer, and game phase on your Discord profile on **Windows (`.exe` installer)** and **Linux**, licensed under **GPL-3.0**.

  <p>
    <a href="https://github.com/buntatoes/rubylock-rpc/releases/latest"><img src="https://img.shields.io/badge/release-v1.1.0-blue" alt="Latest Release" /></a>
    <a href="https://github.com/buntatoes/rubylock-rpc/releases"><img src="https://img.shields.io/github/downloads/buntatoes/rubylock-rpc/total?color=brightgreen&label=downloads" alt="Downloads" /></a>
    <a href="https://github.com/buntatoes/rubylock-rpc/actions/workflows/ci.yml"><img src="https://github.com/buntatoes/rubylock-rpc/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI" /></a>
    <a href="#installation--packaging"><img src="https://img.shields.io/badge/language-Ruby%203.2%2B-CC342D?logo=ruby&logoColor=white" alt="Ruby 3.2+" /></a>
    <a href="#installation--packaging"><img src="https://img.shields.io/badge/platform-Windows%20%7C%20Linux-blue" alt="Platform: Windows | Linux" /></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue" alt="License: GPL-3.0" /></a>
  </p>

</div>

## Preview

<div align="center">
  <img src="assets/demo.gif" alt="RubyLock RPC showing Deadlock hero portrait, match mode, and game phase updating live on a Discord profile card" />
</div>

## Features

- **100% Pure Ruby Core (Zero External Gems)**: Runs on standard Ruby (`3.2+` / `3.4+`) using only the Ruby standard library (`json`, `net/http`, `socket`, `win32/registry`, `zlib`).
- **Windows `.exe` Installer with Desktop Shortcut**: `RubyLock-RPC-Setup-v1.1.0-win64.exe` installs `rubylock-rpc.exe` and the Ruby runtime files to `%LOCALAPPDATA%\RubyLock-RPC`, registers Windows Add/Remove Programs uninstall support, and creates **"RubyLock RPC"** shortcuts on your Desktop and Start Menu so double-clicking launches Deadlock with `-condebug` and Discord Rich Presence.
- **Linux Package**: `rubylock-rpc-linux-x86_64.tar.gz` includes a native ELF wrapper, XDG desktop entry, icon installation, and `install.sh` installer for `~/.local`.
- **Live Discord Rich Presence**: Displays your current hero, match mode (`Standard Match`, `Ranked Match`, `Street Brawl`, `Bot Match`, `Training Range`, `Hero Labs`), match elapsed timer, party headcount in the Hideout, and game phase.
- **Five Hero Portrait Styles**: Supports `"normal"`, `"gloat"`, `"critical"`, `"icon"`, and `"fullbody"` portraits via the community [Deadlock API](https://deadlock-api.com), with an offline hero fallback table.
- **VAC-Safe Log Tailing**: Reads Deadlock's `-condebug` console log (`game/citadel/console.log`) and never reads game memory, modifies game files, or intercepts network traffic.
- **Cross-Platform Discord IPC**: Connects automatically to each user's local Discord client via Windows Named Pipes (`\\.\pipe\discord-ipc-0..9`) or Linux UNIX Domain Sockets (native, Flatpak, Snap, and Vesktop) — no personal Discord IDs are ever stored. Optionally supports a custom `discord_app_id` override in `config.toml`.

## Installation & Packaging

Requires [Ruby 3.2+](https://www.ruby-lang.org/) (tested on Ruby 3.4).

### Windows (`.exe` Installer)

1. Download `RubyLock-RPC-Setup-v1.1.0-win64.exe` from the [Releases](../../releases) page (or build it from source with `ruby scripts/package.rb --exe`).
2. Run `RubyLock-RPC-Setup-v1.1.0-win64.exe` to install to `%LOCALAPPDATA%\RubyLock-RPC` and create the **"RubyLock RPC"** Desktop shortcut.
3. Double-click the **"RubyLock RPC"** shortcut on your Desktop to launch Deadlock with Discord Rich Presence automatically.
4. To uninstall later, use Windows **Installed Apps / Add or Remove Programs** (or run the setup executable with `--uninstall`).

### Linux (`.tar.gz` / XDG Desktop Installer)

1. Download `rubylock-rpc-linux-x86_64.tar.gz` from the [Releases](../../releases) page (or build it from source with `ruby scripts/package.rb --linux`).
2. Extract and install to `~/.local` (creates `~/.local/bin/rubylock-rpc`, `~/.local/share/applications/rubylock-rpc.desktop`, and installs the app icon):

```bash
tar -xzf rubylock-rpc-linux-x86_64.tar.gz
cd rubylock-rpc-linux-x86_64
./install.sh
rubylock-rpc
```

### Building Packages from Source

```bash
git clone https://github.com/buntatoes/rubylock-rpc.git
cd rubylock-rpc

# Build both dist/RubyLock-RPC-Setup-v1.1.0-win64.exe and dist/rubylock-rpc-linux-x86_64.tar.gz:
ruby scripts/package.rb
```

## Launching Deadlock

Rich Presence reads Deadlock's console log file (`game/citadel/console.log`), which requires the `-condebug` launch option:

1. **Use the Desktop / App Shortcut**: Launch **RubyLock RPC** from your Desktop or application menu. It starts Discord Rich Presence and launches Deadlock via Steam with `-condebug`, then closes automatically when you exit Deadlock.
2. **Use Steam Launch Options**: In Steam, right-click **Deadlock -> Properties -> Launch Options** and set:
   ```sh
   rubylock-rpc --launch-with-command -- %command%
   ```
3. **Launch both manually**: Add `-condebug` to Deadlock's Steam Launch Options and run `rubylock-rpc --no-launch`.

## CLI Flags

| Flag | Description |
|------|-------------|
| `--no-launch` | Skip launching Deadlock on startup, even if `launch_game_on_start` is enabled in `config.toml`. |
| `--no-shortcut` | Skip shortcut prompt handling. |
| `--launch-with-command -- <command>` | Launch the game by running `<command>` with `-condebug` appended (for Steam `%command%`). |
| `--generate-config` | Write a fresh `config.toml` with all default settings and exit. |
| `-v`, `--version` | Print version and exit. |
| `-h`, `--help` | Show CLI usage help. |

## Running Tests

```bash
ruby -Ilib:test test/test_rubylock_rpc.rb
```

## License & Attribution

- **Author**: [Buntato](https://github.com/buntatoes)
- **License**: **GNU General Public License v3.0 ([GPL-3.0](LICENSE))**
- **Upstream Notice**: RubyLock RPC is a Ruby reimplementation based on the original GPL-3.0 Rust project [HeyTariq/deadlock-rpc](https://github.com/HeyTariq/deadlock-rpc).

## Disclaimer

Not affiliated with, endorsed by, or connected to Valve Corporation. **Deadlock**, all hero names, images, and related assets are the property of **Valve Corporation**. Hero images displayed in Discord are sourced from the community-maintained [Deadlock API](https://deadlock-api.com) and remain the property of Valve. This project does not distribute or claim ownership of any Valve assets.
