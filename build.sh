#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="$repo_dir/src"
mkdir -p "$repo_dir/dist"
build_dir="$(mktemp -d /tmp/touchbar-stocks-build.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
app="$build_dir/TouchBarStocks.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
xcrun clang -c "$source_dir/TouchBarBridge.m" -o "$build_dir/bridge.o" -fobjc-arc
xcrun clang -c "$source_dir/ThermalBridge.m" -o "$build_dir/thermal.o" -fobjc-arc
xcrun clang -c "$source_dir/ThermalAuthorization.m" -o "$build_dir/auth.o" -fobjc-arc
xcrun clang "$source_dir/ThermalAuthorizationTests.m" "$build_dir/auth.o" -o "$build_dir/auth-tests" -fobjc-arc -framework Foundation -framework Security
codesign --force --sign - "$build_dir/auth-tests"
"$build_dir/auth-tests"
xcrun swiftc "$source_dir/ThermalHelper.swift" "$source_dir/ThermalControl.swift" "$build_dir/thermal.o" "$build_dir/auth.o" -import-objc-header "$source_dir/ThermalHelperBridge.h" -o "$app/Contents/Helpers/ThermalHelper" -framework Foundation -framework IOKit -framework Security -O
xcrun swiftc "$source_dir/main.swift" "$source_dir/MenuBarFolder.swift" "$source_dir/MenuIdleCountdown.swift" "$source_dir/ThermalControl.swift" "$source_dir/ThermalPanel.swift" "$build_dir/bridge.o" "$build_dir/thermal.o" -import-objc-header "$source_dir/Bridge.h" -o "$app/Contents/MacOS/TouchBarStocks" -framework AppKit -framework IOKit -O
install -m 755 "$source_dir/InstallThermalService.command" "$app/Contents/Resources/InstallThermalService.command"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TouchBarStocks</string>
<key>CFBundleIdentifier</key><string>local.penghuichai.TouchBarStocks</string>
<key>CFBundleName</key><string>TouchBarStocks</string>
<key>CFBundleDisplayName</key><string>自选股与菜单栏</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.0</string>
<key>CFBundleVersion</key><string>6</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xattr -cr "$app"
codesign --force --sign - "$app/Contents/Helpers/ThermalHelper"
codesign --force --sign - "$app"
"$app/Contents/MacOS/TouchBarStocks" --self-test
codesign --verify --deep --strict "$app"
ditto --norsrc -c -k --keepParent "$app" "$repo_dir/dist/TouchBarStocks-1.3.0.zip"
destination="${1:-$repo_dir/build}"
mkdir -p "$destination"
if [ -e "$destination/TouchBarStocks.app" ]; then
  printf 'App already exists; ZIP updated, existing app preserved: %s\n' "$destination/TouchBarStocks.app"
else
  ditto --norsrc --noextattr "$app" "$destination/TouchBarStocks.app"
  codesign --verify --deep --strict "$destination/TouchBarStocks.app"
  printf 'Built: %s\n' "$destination/TouchBarStocks.app"
fi
