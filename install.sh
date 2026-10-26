#!/bin/bash
# magled install — 安装 MagSafe 3 LED 后台守护。
# 用法: sudo sh install.sh   （或在 MagLED 菜单里点"安装后台守护"）
set -euo pipefail

if [ "$(id -u)" != "0" ]; then
    echo "需要管理员权限。请用: sudo sh install.sh"
    echo "（或在 MagLED 菜单栏菜单里点 安装后台守护，按提示输密码即可）"
    exit 1
fi

SELF="$(cd "$(dirname "$0")" && pwd)"

# 1) 找到 helper 二进制：优先本目录，其次 App 包内
HELPER=""
for p in "$SELF/magled-helper" "$SELF/MagLED.app/Contents/Resources/magled-helper" "/Applications/MagLED.app/Contents/Resources/magled-helper"; do
    if [ -f "$p" ]; then HELPER="$p"; break; fi
done
if [ -z "$HELPER" ]; then
    echo "❌ 找不到 magled-helper 二进制（请把整个解压包放在一起）。"
    exit 1
fi

INSTALL_DIR=/usr/local/lib/magled

# 2) 幂等：守护已在运行、且二进制没有更新 → 跳过
#    （避免重复安装重启守护、让用户反复输密码；二进制有更新时才重装）
if [ -S /var/run/magled.sock ] && pgrep -f "$INSTALL_DIR/magled-helper" >/dev/null 2>&1; then
    if [ "$(md5 -q "$HELPER" 2>/dev/null || echo x)" = "$(md5 -q "$INSTALL_DIR/magled-helper" 2>/dev/null || echo y)" ]; then
        echo "✅ magled 后台守护已安装且在运行，无需重复安装。"
        exit 0
    fi
    echo "ℹ️ 检测到守护二进制已更新，重新安装…"
fi

# 2) 先停旧守护再拷贝——避免覆盖正在被执行的二进制
launchctl bootout system/com.atstudio.magled 2>/dev/null || true
pkill -f "$INSTALL_DIR/magled-helper" 2>/dev/null || true
for _ in 1 2 3 4 5 6; do
    pgrep -f "$INSTALL_DIR/magled-helper" >/dev/null 2>&1 || break
    sleep 0.5
done

# 3) 安装新二进制
mkdir -p "$INSTALL_DIR" /var/run
cp "$HELPER" "$INSTALL_DIR/magled-helper"
chmod 755 "$INSTALL_DIR/magled-helper"
codesign -f -s - "$INSTALL_DIR/magled-helper" 2>/dev/null || true

# 4) launchd daemon
PLIST=/Library/LaunchDaemons/com.atstudio.magled.plist
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.atstudio.magled</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/magled-helper</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/var/log/magled.log</string>
    <key>StandardErrorPath</key><string>/var/log/magled.log</string>
    <key>ProcessGroupName</key><string>magled</string>
</dict>
</plist>
EOF
launchctl bootstrap system "$PLIST" 2>/dev/null || launchctl load "$PLIST"

sleep 1
if [ -S /var/run/magled.sock ]; then
    echo "✅ magled 后台守护已安装并运行。"
    echo "   日志: /var/log/magled.log"
    echo "   现在可以用菜单栏 MagLED 或 'ledctl off' 关灯了。"
else
    echo "⚠️  守护已注册，但 socket 未出现，查看 /var/log/magled.log"
    exit 1
fi
