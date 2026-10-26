#!/bin/bash
# magled uninstall — 卸载 MagSafe 3 LED 后台守护。
# 用法: sudo sh uninstall.sh
set -euo pipefail

if [ "$(id -u)" != "0" ]; then
    echo "需要管理员权限。请用: sudo sh uninstall.sh"
    exit 1
fi

# 卸载前先把 LED 交回系统控制（守护仍在，经 socket 下发 set 00；失败不阻塞卸载）
if [ -S /var/run/magled.sock ]; then
    if command -v nc >/dev/null 2>&1; then
        printf 'set 00\n' | nc -U /var/run/magled.sock >/dev/null 2>&1 || true
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import socket; s=socket.socket(socket.AF_UNIX); s.connect('/var/run/magled.sock'); s.send(b'set 00\n'); s.recv(64)" >/dev/null 2>&1 || true
    fi
    sleep 0.5
fi

launchctl bootout system/com.atstudio.magled 2>/dev/null || true
launchctl unload /Library/LaunchDaemons/com.atstudio.magled.plist 2>/dev/null || true
pkill -f /usr/local/lib/magled/magled-helper 2>/dev/null || true

rm -f /Library/LaunchDaemons/com.atstudio.magled.plist
rm -rf /usr/local/lib/magled
rm -f /var/run/magled.sock
rm -f /var/root/.magled_mode
rm -f /var/log/magled.log
rm -f /Applications/MagLED.app

echo "✅ magled 已卸载（后台守护已停止，LED 交回系统控制）。"
echo "   若还想彻底干净，删除 UserDefaults: defaults delete com.atstudio.magled"
