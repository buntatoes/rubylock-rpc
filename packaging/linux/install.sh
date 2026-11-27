#!/usr/bin/env sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
APP_DIR="$PREFIX/share/rubylock-rpc"
BIN_DIR="$PREFIX/bin"
DESKTOP_DIR="$PREFIX/share/applications"
ICON_DIR="$PREFIX/share/icons/hicolor/256x256/apps"

mkdir -p "$APP_DIR/bin" "$APP_DIR/lib" "$APP_DIR/assets" "$BIN_DIR" "$DESKTOP_DIR" "$ICON_DIR"

cp -r "$SCRIPT_DIR/bin/"* "$APP_DIR/bin/"
cp -r "$SCRIPT_DIR/lib/"* "$APP_DIR/lib/"
cp -r "$SCRIPT_DIR/assets/"* "$APP_DIR/assets/"
cp "$SCRIPT_DIR/LICENSE" "$SCRIPT_DIR/README.md" "$APP_DIR/"
chmod +x "$APP_DIR/bin/rubylock-rpc"

if [ -f "$SCRIPT_DIR/rubylock-rpc" ]; then
    cp "$SCRIPT_DIR/rubylock-rpc" "$APP_DIR/rubylock-rpc"
    chmod +x "$APP_DIR/rubylock-rpc"
    ln -sf "$APP_DIR/rubylock-rpc" "$BIN_DIR/rubylock-rpc"
else
    ln -sf "$APP_DIR/bin/rubylock-rpc" "$BIN_DIR/rubylock-rpc"
fi

cp "$SCRIPT_DIR/assets/icon.png" "$ICON_DIR/rubylock-rpc.png"

sed "s|^Exec=.*|Exec=$BIN_DIR/rubylock-rpc|" \
    "$SCRIPT_DIR/packaging/linux/rubylock-rpc.desktop" > "$DESKTOP_DIR/rubylock-rpc.desktop"

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
fi

echo "Installed RubyLock RPC to $APP_DIR"
echo "Run with: $BIN_DIR/rubylock-rpc"
