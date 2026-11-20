#!/bin/bash
# Builds ClaudeTerminal.app from the release binary + AppIcon.icns,
# then installs it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=ClaudeTerminal.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeTerminal "$APP/Contents/MacOS/"
cp AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>en</string>
    <key>CFBundleExecutable</key>             <string>ClaudeTerminal</string>
    <key>CFBundleIdentifier</key>             <string>io.github.nickoh-821.claudeterminal</string>
    <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
    <key>CFBundleName</key>                   <string>ClaudeTerminal</string>
    <key>CFBundleDisplayName</key>            <string>ClaudeTerminal</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>0.1.0</string>
    <key>CFBundleVersion</key>                <string>1</string>
    <key>CFBundleIconFile</key>               <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>         <string>13.0</string>
    <key>NSHighResolutionCapable</key>        <true/>
    <key>NSPrincipalClass</key>               <string>NSApplication</string>
</dict>
</plist>
EOF

# Prefer the self-signed "ClaudeTerminal Signing" cert: a stable identity
# means TCC file-access grants survive rebuilds.
# Ad-hoc (-) changes the code hash every build, so macOS re-asks each time.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "ClaudeTerminal Signing"; then
  codesign --force -s "ClaudeTerminal Signing" "$APP"
else
  echo "warning: 'ClaudeTerminal Signing' cert not found — ad-hoc signing (permissions will reset on rebuild)"
  codesign --force -s - "$APP"
fi
rm -rf /Applications/ClaudeTerminal.app
cp -R "$APP" /Applications/
echo "Installed: /Applications/ClaudeTerminal.app"
