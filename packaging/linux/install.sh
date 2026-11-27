#!/usr/bin/env sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
APP_DIR="$PREFIX/share/deadlock-rpc"
BIN_DIR="$PREFIX/bin"
DESKTOP_DIR="$PREFIX/share/applications"
ICON_DIR="$PREFIX/share/icons/hicolor/256x256/apps"

mkdir -p "$APP_DIR/bin" "$APP_DIR/lib" "$APP_DIR/assets" "$BIN_DIR" "$DESKTOP_DIR" "$ICON_DIR"

cp -r "$SCRIPT_DIR/bin/"* "$APP_DIR/bin/"
cp -r "$SCRIPT_DIR/lib/"* "$APP_DIR/lib/"
cp -r "$SCRIPT_DIR/assets/"* "$APP_DIR/assets/"
cp "$SCRIPT_DIR/LICENSE" "$SCRIPT_DIR/README.md" "$APP_DIR/"
chmod +x "$APP_DIR/bin/deadlock-rpc"

if [ -f "$SCRIPT_DIR/deadlock-rpc" ]; then
    cp "$SCRIPT_DIR/deadlock-rpc" "$APP_DIR/deadlock-rpc"
    chmod +x "$APP_DIR/deadlock-rpc"
    ln -sf "$APP_DIR/deadlock-rpc" "$BIN_DIR/deadlock-rpc"
else
    ln -sf "$APP_DIR/bin/deadlock-rpc" "$BIN_DIR/deadlock-rpc"
fi

cp "$SCRIPT_DIR/assets/icon.png" "$ICON_DIR/deadlock-rpc.png"

sed "s|^Exec=.*|Exec=$BIN_DIR/deadlock-rpc|" \
    "$SCRIPT_DIR/packaging/linux/deadlock-rpc.desktop" > "$DESKTOP_DIR/deadlock-rpc.desktop"

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
fi

echo "Installed Deadlock RPC (Ruby Edition) to $APP_DIR"
echo "Run with: $BIN_DIR/deadlock-rpc"
