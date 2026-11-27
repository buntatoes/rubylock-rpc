#!/usr/bin/env sh
# SPDX-License-Identifier: GPL-3.0-only
# RubyLock RPC Linux Installer & Setup GUI (zenity / kdialog / terminal fallback)
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
SILENT=0
FORCE_GUI=0
UNINSTALL_MODE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --silent|-y|--yes)
            SILENT=1
            ;;
        --gui)
            FORCE_GUI=1
            ;;
        --uninstall)
            UNINSTALL_MODE=1
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
RubyLock RPC Linux Installer
Usage: ./install.sh [OPTIONS]

Options:
  --silent, -y, --yes  Install non-interactively without GUI prompts
  --gui                Force graphical dialogs (requires zenity or kdialog)
  --uninstall          Uninstall RubyLock RPC instead of installing
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

gui_confirm() {
    title="$1"
    text="$2"
    case "$GUI_TOOL" in
        zenity)
            zenity --question --title="$title" --text="$text" --ok-label="Install" --cancel-label="Cancel"
            return $?
            ;;
        kdialog)
            kdialog --title "$title" --yesno "$text"
            return $?
            ;;
        *)
            return 0
            ;;
    esac
}

gui_info() {
    title="$1"
    text="$2"
    case "$GUI_TOOL" in
        zenity)
            zenity --info --title="$title" --text="$text" >/dev/null 2>&1 || true
            ;;
        kdialog)
            kdialog --title "$title" --msgbox "$text" >/dev/null 2>&1 || true
            ;;
    esac
}

run_uninstaller() {
    uninst=""
    if [ -f "$SCRIPT_DIR/uninstall.sh" ]; then
        uninst="$SCRIPT_DIR/uninstall.sh"
    elif [ -f "$SCRIPT_DIR/packaging/linux/uninstall.sh" ]; then
        uninst="$SCRIPT_DIR/packaging/linux/uninstall.sh"
    elif [ -f "$APP_DIR/uninstall.sh" ]; then
        uninst="$APP_DIR/uninstall.sh"
    fi

    if [ -n "$uninst" ]; then
        if [ "$SILENT" -eq 1 ]; then
            exec sh "$uninst" --prefix "$PREFIX" --silent
        elif [ "$FORCE_GUI" -eq 1 ]; then
            exec sh "$uninst" --prefix "$PREFIX" --gui
        else
            exec sh "$uninst" --prefix "$PREFIX"
        fi
    else
        echo "Uninstaller script not found." >&2
        exit 1
    fi
}

if [ "$UNINSTALL_MODE" -eq 1 ]; then
    run_uninstaller
fi

if [ -n "$GUI_TOOL" ]; then
    if [ -d "$APP_DIR" ]; then
        choice=""
        case "$GUI_TOOL" in
            zenity)
                choice="$(zenity --list --radiolist \
                    --title="RubyLock RPC Setup" \
                    --text="RubyLock RPC is already installed in:\n$APP_DIR\n\nChoose an action:" \
                    --column="" --column="Action" --column="Description" \
                    TRUE "install" "Update or reinstall RubyLock RPC" \
                    FALSE "uninstall" "Uninstall RubyLock RPC and remove shortcuts" \
                    --hide-column=2 --width=460 --height=260 2>/dev/null || true)"
                ;;
            kdialog)
                choice="$(kdialog --title "RubyLock RPC Setup" \
                    --menu "RubyLock RPC is already installed in $APP_DIR. Choose an action:" \
                    install "Update or reinstall RubyLock RPC" \
                    uninstall "Uninstall RubyLock RPC and remove shortcuts" 2>/dev/null || true)"
                ;;
        esac

        case "$choice" in
            install)
                ;;
            uninstall)
                run_uninstaller
                ;;
            *)
                exit 0
                ;;
        esac
    else
        if ! gui_confirm "RubyLock RPC Setup" \
            "Install RubyLock RPC to:\n$APP_DIR\n\nThis will install:\n• rubylock-rpc command ($BIN_DIR/rubylock-rpc)\n• Application launcher entry and icon\n• Uninstaller (rubylock-rpc --uninstall)"; then
            exit 0
        fi
    fi
fi

mkdir -p "$APP_DIR/bin" "$APP_DIR/lib" "$APP_DIR/assets" "$BIN_DIR" "$DESKTOP_DIR" "$ICON_DIR"

cp -r "$SCRIPT_DIR/bin/"* "$APP_DIR/bin/"
cp -r "$SCRIPT_DIR/lib/"* "$APP_DIR/lib/"
cp -r "$SCRIPT_DIR/assets/"* "$APP_DIR/assets/"
cp "$SCRIPT_DIR/LICENSE" "$SCRIPT_DIR/README.md" "$APP_DIR/"
chmod +x "$APP_DIR/bin/rubylock-rpc"

if [ -f "$SCRIPT_DIR/uninstall.sh" ]; then
    cp "$SCRIPT_DIR/uninstall.sh" "$APP_DIR/uninstall.sh"
    chmod +x "$APP_DIR/uninstall.sh"
elif [ -f "$SCRIPT_DIR/packaging/linux/uninstall.sh" ]; then
    cp "$SCRIPT_DIR/packaging/linux/uninstall.sh" "$APP_DIR/uninstall.sh"
    chmod +x "$APP_DIR/uninstall.sh"
fi

if [ -f "$SCRIPT_DIR/rubylock-rpc" ]; then
    cp "$SCRIPT_DIR/rubylock-rpc" "$APP_DIR/rubylock-rpc"
    chmod +x "$APP_DIR/rubylock-rpc"
    ln -sf "$APP_DIR/rubylock-rpc" "$BIN_DIR/rubylock-rpc"
else
    ln -sf "$APP_DIR/bin/rubylock-rpc" "$BIN_DIR/rubylock-rpc"
fi

cp "$SCRIPT_DIR/assets/icon.png" "$ICON_DIR/rubylock-rpc.png"

sed -e "s|^Exec=rubylock-rpc\$|Exec=$BIN_DIR/rubylock-rpc|" \
    -e "s|^Exec=rubylock-rpc --uninstall\$|Exec=$BIN_DIR/rubylock-rpc --uninstall|" \
    "$SCRIPT_DIR/packaging/linux/rubylock-rpc.desktop" > "$DESKTOP_DIR/rubylock-rpc.desktop"

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
fi

echo "Installed RubyLock RPC to $APP_DIR"
echo "Run with: $BIN_DIR/rubylock-rpc"

gui_info "RubyLock RPC Setup" \
    "Installation complete!\n\nLaunch \"RubyLock RPC\" from your application menu or run:\n$BIN_DIR/rubylock-rpc"
