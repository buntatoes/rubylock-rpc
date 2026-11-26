<div align="center">
  <img src="assets/icon.png" alt="Deadlock RPC" width="120" />

  # Deadlock Rich Presence for Discord (Ruby Edition)

  Show your Deadlock hero, match mode, and game phase on your Discord profile automatically. Free, open-source, zero-dependency Ruby edition for **Windows (`.exe` installer)** and **Linux**, licensed under **GPL-3.0**.

  Forked from and based on the original Rust project by **[HeyTariq/deadlock-rpc](https://github.com/HeyTariq/deadlock-rpc)**.

  [![Latest Release](https://img.shields.io/github/v/release/buntatoes/deadlock-rpc-ruby?label=release)](https://github.com/buntatoes/deadlock-rpc-ruby/releases/latest)
  [![CI](https://img.shields.io/github/actions/workflow/status/buntatoes/deadlock-rpc-ruby/ci.yml?branch=main&label=CI)](https://github.com/buntatoes/deadlock-rpc-ruby/actions/workflows/ci.yml)
  [![Ruby](https://img.shields.io/badge/language-Ruby%203.2%2B-CC342D?logo=ruby&logoColor=white)](#installation--packaging)
  [![Platform](https://img.shields.io/badge/platform-Windows%20(.exe)%20%7C%20Linux-blue)](#installation--packaging)
  [![License: GPL v3](https://img.shields.io/github/license/buntatoes/deadlock-rpc-ruby)](LICENSE)

</div>

## Preview

<div align="center">
  <img src="assets/demo.gif" alt="Deadlock Discord Rich Presence showing hero portrait, match mode, and game phase updating live on a Discord profile card" />
</div>

## Features

- **100% Pure Ruby Core (Zero External Gems)**: Runs on standard Ruby (`3.2+` / `3.4+`) using only the Ruby standard library (`json`, `net/http`, `socket`, `win32/registry`, `open3`, `zlib`).
- **Windows `.exe` Installer with Desktop Shortcut**: `DeadlockRPC-Ruby-Setup-v1.0.1-win64.exe` installs `deadlock-rpc.exe` and the Ruby runtime files to `%LOCALAPPDATA%\DeadlockRPC-Ruby`, registers Windows Add/Remove Programs uninstall support, and automatically creates a **"Deadlock RPC"** shortcut on your Desktop and Start Menu so double-clicking it launches Deadlock with `-condebug` and Discord Rich Presence.
- **Linux Package**: `deadlock-rpc-linux-x86_64.tar.gz` includes an XDG desktop entry and `install.sh` installer for `~/.local`.
- **Live Discord Rich Presence**: Automatically displays your current hero, match mode (`Standard Match`, `Ranked Match`, `Street Brawl`, `Bot Match`, `Training Range`, `Hero Labs`), match elapsed timer, party headcount in the Hideout, and game phase.
- **Five Hero Portrait Styles**: Supports `"normal"`, `"gloat"`, `"critical"`, `"icon"`, and `"fullbody"` portraits via the community [Deadlock API](https://deadlock-api.com), with a 45-hero offline fallback table.
- **VAC-Safe Log Tailing**: Uses Deadlock's `-condebug` launch option (`game/citadel/console.log`) and never reads game memory, modifies game files, or intercepts network traffic.
- **Cross-Platform Discord IPC**: Native Windows Named Pipe (`\\.\pipe\discord-ipc-0..9`) and Linux UNIX Domain Socket (`$XDG_RUNTIME_DIR/discord-ipc-0..9`) client.
- **Drop-In `config.toml` Compatibility**: Uses the exact same `config.toml` schema (`config_version = 4`) as upstream `deadlock-rpc`.

## Installation & Packaging

Requires [Ruby 3.2+](https://www.ruby-lang.org/) (tested on Ruby 3.4).

### Windows (`.exe` Installer)

1. Download `DeadlockRPC-Ruby-Setup-v1.0.1-win64.exe` from the [Releases](../../releases) page (or build it from source with `ruby scripts/package.rb --exe`).
2. Run `DeadlockRPC-Ruby-Setup-v1.0.1-win64.exe` to install to `%LOCALAPPDATA%\DeadlockRPC-Ruby` and create the **"Deadlock RPC"** Desktop shortcut.
3. Double-click the **"Deadlock RPC"** shortcut on your Desktop to launch Deadlock with Discord Rich Presence automatically.
4. To uninstall later, use Windows **Installed Apps / Add or Remove Programs** (or run the setup executable with `--uninstall`).

### Linux (`.tar.gz` / XDG Desktop Installer)

1. Download `deadlock-rpc-linux-x86_64.tar.gz` from the [Releases](../../releases) page (or build it from source with `ruby scripts/package.rb --linux`).
2. Extract and install to `~/.local` (creates `~/.local/bin/deadlock-rpc` and `~/.local/share/applications/deadlock-rpc.desktop`):

```bash
tar -xzf deadlock-rpc-linux-x86_64.tar.gz
cd deadlock-rpc-linux-x86_64
./install.sh
deadlock-rpc
```

### Building Packages from Source

```bash
git clone https://github.com/buntatoes/deadlock-rpc-ruby.git
cd deadlock-rpc-ruby

# Build both dist/DeadlockRPC-Ruby-Setup-v1.0.1-win64.exe and dist/deadlock-rpc-linux-x86_64.tar.gz:
ruby scripts/package.rb
```

## Launching Deadlock

Rich Presence reads Deadlock's console log file (`game/citadel/console.log`), which requires the `-condebug` launch option:

1. **Use the Desktop Shortcut (Recommended on Windows)**: Double-click **"Deadlock RPC"** on your Desktop. It starts Discord Rich Presence and launches Deadlock via Steam with `-condebug`, then closes automatically when you exit Deadlock.
2. **Use Steam Launch Options**: In Steam, right-click **Deadlock -> Properties -> Launch Options** and set:
   ```sh
   deadlock-rpc --launch-with-command -- %command%
   ```
3. **Launch both manually**: Add `-condebug` to Deadlock's Steam Launch Options and run `deadlock-rpc --no-launch`.

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
ruby -Ilib:test test/test_deadlock_rpc.rb
```

## Credits & License

- **Original Creator**: [HeyTariq](https://github.com/HeyTariq) — [HeyTariq/deadlock-rpc](https://github.com/HeyTariq/deadlock-rpc)
- **Ruby Port**: [Buntato](https://github.com/buntatoes)
- **License**: Licensed under the **GNU General Public License v3.0 ([GPL-3.0](LICENSE))**.

## Disclaimer

Not affiliated with, endorsed by, or connected to Valve Corporation. **Deadlock**, all hero names, images, and related assets are the property of **Valve Corporation**. Hero images displayed in Discord are sourced from the community-maintained [Deadlock API](https://deadlock-api.com) and remain the property of Valve. This project does not distribute or claim ownership of any Valve assets.
