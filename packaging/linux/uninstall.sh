#!/usr/bin/env sh
# SPDX-License-Identifier: GPL-3.0-only
# RubyLock RPC Linux Uninstaller (zenity / kdialog / terminal fallback)
set -eu

PREFIX="${PREFIX:-$HOME/.local}"
SILENT=0
FORCE_GUI=0

while [ $# -gt 0 ]; do
    case "$1" in
        --silent|-y|--yes)
            SILENT=1
            ;;
        --gui)
            FORCE_GUI=1
            ;;
        --prefix)
            shift
            if [ $# -eq 0 ]; then
                echo "Error: --prefix requires a directory argument" >&2
                exit 1
            fi
            PREFIX="$1"
            ;;
        --prefix=*)
            PREFIX="${1#*=}"
            ;;
        -h|--help)
            cat <<'EOF'
RubyLock RPC Linux Uninstaller
Usage: ./uninstall.sh [OPTIONS]

Options:
  --silent, -y, --yes  Uninstall non-interactively without prompts
  --gui                Force graphical dialogs (requires zenity or kdialog)
  --prefix DIR         Install prefix (default: ~/.local)
  -h, --help           Show this help message
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
    shift
done

APP_DIR="$PREFIX/share/rubylock-rpc"
BIN_DIR="$PREFIX/bin"
DESKTOP_DIR="$PREFIX/share/applications"
ICON_DIR="$PREFIX/share/icons/hicolor/256x256/apps"

GUI_TOOL=""
if [ "$SILENT" -eq 0 ]; then
    if [ "$FORCE_GUI" -eq 1 ] || [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
        if command -v zenity >/dev/null 2>&1; then
            GUI_TOOL="zenity"
        elif command -v kdialog >/dev/null 2>&1; then
            GUI_TOOL="kdialog"
        fi
    fi
fi

if [ "$SILENT" -eq 0 ]; then
    prompt_msg="Uninstall RubyLock RPC from:\n$APP_DIR\n\nThis will remove application files, the rubylock-rpc command, desktop launcher, and icon."
    case "$GUI_TOOL" in
        zenity)
            if ! zenity --question --title="Uninstall RubyLock RPC" --text="$prompt_msg" \
                --ok-label="Uninstall" --cancel-label="Cancel"; then
                exit 0
            fi
            ;;
        kdialog)
            if ! kdialog --title "Uninstall RubyLock RPC" --yesno "$prompt_msg"; then
                exit 0
            fi
            ;;
        *)
            if [ -t 0 ]; then
                printf "Uninstall RubyLock RPC from %s? [y/N] " "$APP_DIR"
                read -r answer || answer=""
                case "$answer" in
                    [yY]|[yY][eE][sS]) ;;
                    *) echo "Cancelled."; exit 0 ;;
                esac
            fi
            ;;
    esac
fi

rm -f "$BIN_DIR/rubylock-rpc"
rm -f "$DESKTOP_DIR/rubylock-rpc.desktop"
rm -f "$ICON_DIR/rubylock-rpc.png"
rm -rf "$APP_DIR"

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
fi

echo "Uninstalled RubyLock RPC from $PREFIX"

case "$GUI_TOOL" in
    zenity)
        zenity --info --title="Uninstall RubyLock RPC" --text="RubyLock RPC has been uninstalled." >/dev/null 2>&1 || true
        ;;
    kdialog)
        kdialog --title "Uninstall RubyLock RPC" --msgbox "RubyLock RPC has been uninstalled." >/dev/null 2>&1 || true
        ;;
esac
