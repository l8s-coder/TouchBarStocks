#!/bin/bash
set -euo pipefail
# This installer is opened only by an explicit click in the installed app.
app=/Applications/TouchBarStocks.app
label=local.penghuichai.TouchBarStocks.thermalhelper
state='/Library/Application Support/TouchBarStocksThermal'
binary="/Library/PrivilegedHelperTools/$label"
plist="/Library/LaunchDaemons/$label.plist"
if [ "${EUID}" -ne 0 ]; then
  printf '将安装仅用于本 App 的风扇温控服务。管理员密码只在本机输入。\n'
  exec /usr/bin/sudo /bin/bash "$app/Contents/Resources/InstallThermalService.command" "$@"
fi
if [ "${1:-}" = "--uninstall" ]; then
  /bin/launchctl bootout "system/$label" 2>/dev/null || true
  if [ -f "$state/manual-control" ]; then
    /bin/launchctl bootstrap system "$plist" 2>/dev/null || true
    printf '未确认恢复系统控制，保留服务以继续恢复。请先在 App 点击恢复系统自动。\n'; exit 1
  fi
  /bin/rm -f "$binary" "$plist" "$state/client-hash"
  /bin/rmdir "$state" 2>/dev/null || true
  printf '温控服务已卸载。\n'; exit 0
fi
/usr/bin/codesign --verify --deep --strict "$app"
client_hash=$(/usr/bin/codesign -dv --verbose=4 "$app" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')
[[ "$client_hash" =~ ^[0-9a-fA-F]{40}$ ]] || { printf '无法读取 App 签名\n'; exit 1; }
/bin/launchctl bootout "system/$label" 2>/dev/null || true
if [ -f "$state/manual-control" ]; then
  /bin/launchctl bootstrap system "$plist" 2>/dev/null || true
  printf '旧服务尚未确认恢复系统控制，已中止更新。请在 App 中恢复自动后重试。\n'; exit 1
fi
# Do not follow user-created symlinks at privileged destinations.
for path in "$state" "$binary" "$plist"; do
  [ ! -L "$path" ] || { printf '拒绝符号链接路径: %s\n' "$path"; exit 1; }
done
if [ -d "$state" ]; then
  [ "$(/usr/bin/stat -f '%u' "$state")" = 0 ] || { printf '状态目录必须属于 root\n'; exit 1; }
fi
/usr/bin/install -d -o root -g wheel -m 700 "$state"
/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
/usr/bin/install -o root -g wheel -m 755 "$app/Contents/Helpers/ThermalHelper" "$binary"
printf '%s\n' "$client_hash" > "$state/client-hash"
/usr/sbin/chown root:wheel "$state/client-hash"
/bin/chmod 600 "$state/client-hash"
/bin/cat > "$plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>local.penghuichai.TouchBarStocks.thermalhelper</string>
<key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/local.penghuichai.TouchBarStocks.thermalhelper</string></array>
<key>MachServices</key><dict><key>local.penghuichai.TouchBarStocks.thermalhelper</key><true/></dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>5</integer>
</dict></plist>
PLIST
/usr/sbin/chown root:wheel "$plist"
/bin/chmod 644 "$plist"
/usr/bin/plutil -lint "$plist"
/bin/launchctl bootstrap system "$plist"
printf '温控服务已安装。回到 App，点击“启用温度曲线”才会开始控制。\n'
