#!/usr/bin/env bash
# Create the double-click app: /Applications/Rapsodo Golf (Mac Port).app ($RGM_APP_BUNDLE)
#   Contents/MacOS/open-in-iterm  entry point: runs scripts/play.sh in iTerm
#   Contents/MacOS/launch         native launcher play.sh execs to start Wine
#   Contents/Resources/AppIcon.icns  built from the installed app's own icon
set -euo pipefail
. "$(dirname "$0")/env.sh"

A="$RGM_APP_BUNDLE"
mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources"
cat > "$A/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Rapsodo Golf (Mac Port)</string>
<key>CFBundleDisplayName</key><string>Rapsodo Golf</string>
<key>CFBundleIdentifier</key><string>local.rapsodogolf-wine</string>
<key>CFBundleExecutable</key><string>open-in-iterm</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.sports-games</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSAppleEventsUsageDescription</key><string>Opens iTerm to start the USB link and Rapsodo Golf.</string>
<key>NSLocalNetworkUsageDescription</key><string>Rapsodo Golf finds and talks to your launch monitor over its USB-C network link.</string>
<key>NSBonjourServices</key><array><string>_RapsodoDevice._tcp</string></array>
</dict></plist>
EOF

rm -f "$A/Contents/MacOS/launch"
clang -O2 -Wall -o "$A/Contents/MacOS/launch" "$RGM_REPO/scripts/launcher.c" \
  -DRGM_WINE="\"$RGM_WINE_BIN/wine\"" -DRGM_PREFIX="\"$RGM_PREFIX\"" \
  -DRGM_APP_DIR="\"$RGM_APP_DIR\"" -DRGM_LOG="\"$RGM_LOG\""

# Entry point. Wine started straight from Finder gets no Local Network access
# (macOS never prompts), so hand off to iTerm, which has it, and run play.sh there.
# The first open asks once to let this app control iTerm.
cat > "$A/Contents/MacOS/open-in-iterm" <<'EOF'
#!/bin/bash
play='__PLAY__'
if ! /usr/bin/osascript \
  -e "tell application \"iTerm\" to create window with default profile command \"$play\"" \
  -e 'tell application "iTerm" to activate' >/dev/null 2>&1; then
  /usr/bin/osascript -e 'display alert "Rapsodo Golf" message "Could not open iTerm. In System Settings → Privacy & Security → Automation, turn on iTerm under bash (or Rapsodo Golf), then open the app again." as critical' >/dev/null
  exit 1
fi
EOF
sed -i '' "s|__PLAY__|$RGM_REPO/scripts/play.sh|" "$A/Contents/MacOS/open-in-iterm"
chmod +x "$A/Contents/MacOS/open-in-iterm"

# Icon: the app's own dist/icon.png (256 px, extracted from app.asar at build time,
# never committed) on a rounded macOS tile.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if python3 -I - "$RGM_APP_DIR/resources/app.asar" "$tmp/src.png" <<'EOF'
import json, struct, sys
d = open(sys.argv[1], "rb").read()
pickle_size = struct.unpack("<I", d[4:8])[0]
header = json.loads(d[16:16 + struct.unpack("<I", d[12:16])[0]])
entry = header["files"]["dist"]["files"]["icon.png"]
start = 8 + pickle_size + int(entry["offset"])
open(sys.argv[2], "wb").write(d[start:start + entry["size"]])
EOF
then
  swift "$RGM_REPO/scripts/make_icon.swift" "$tmp/src.png" "$tmp/master.png"
  set_dir="$tmp/AppIcon.iconset"
  mkdir -p "$set_dir"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$tmp/master.png" --out "$set_dir/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$tmp/master.png" --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$set_dir" -o "$A/Contents/Resources/AppIcon.icns"
else
  echo "warning: couldn't extract the app icon; launcher will use the generic icon" >&2
fi

# Ad-hoc sign so macOS keeps a stable identity for its permission prompts.
codesign --force --sign - "$A" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed" >&2
# Make Finder and the Dock pick up the new icon.
touch "$A"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$A" >/dev/null 2>&1 || true
echo "Launcher: $A"
for old in "$RGM_USER_HOME/Applications/Rapsodo Golf (Wine).app" "/Applications/Rapsodo Golf (Wine).app"; do
  if [ "$old" != "$A" ] && [ -d "$old" ]; then
    echo "note: an older copy is still at $old; you can drag it to the Trash"
  fi
done
