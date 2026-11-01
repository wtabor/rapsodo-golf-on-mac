# App and games show as "wine" in Force Quit and the Dock (11/01/2026)

The owner's screenshot of Force Quit Applications listed the running game as "wine".
The Dock and Command-Tab show the same.

## Why
- Every Wine process runs the same executable,
  `Wine Staging.app/Contents/Resources/wine/lib/wine/x86_64-unix/wine`, with no bundle
  around it (`lsappinfo list`: `bundleID=[ NULL ]`, bundle path = that executable). macOS
  names such an app after its executable.
- Wine's Mac driver has no setting for this; it only reads `CFBundleName` from the main
  bundle for its Hide/Quit menu items (wine-11.16 `dlls/winemac.drv/cocoa_app.m`).

## Tried
- `lsappinfo setinfo -app <ASN> name=...` (also `LSDisplayName=`, `DisplayName=`) on a
  running Wine process: exits quietly, nothing changes. LaunchServices lets an app rename
  only itself.

## Fix
- `scripts/appname.c`, built by 50-make-launcher.sh into
  `Rapsodo Golf on Mac.app/Contents/MacOS/rgm-appname.dylib` (x86_64 + arm64, ad-hoc
  signed on its own so the bundle's signature still verifies). The launcher sets
  `DYLD_INSERT_LIBRARIES` to it when the file exists. Every Wine process the app starts
  inherits it, games included.
- In each process it waits for `NSApplicationDidFinishLaunchingNotification` (Wine's
  Mac driver finishes launching through NSApplication), then sets the LaunchServices
  display name with the private calls Chromium uses for its helper processes
  (`_LSGetCurrentApplicationASN`, `_LSSetApplicationInformationItem`, `_kLSDisplayNameKey`,
  looked up at run time). The name comes from argv[0], which Wine has rewritten to the
  Windows program (`C:\...\DrivingRange.exe`): RapsodoGolf.exe → "Rapsodo Golf",
  DrivingRange.exe → "Driving Range", Practice_TargetRange.exe → "Target Range",
  RapsodoStudiosGolf_development.exe → "Rapsodo Studios", anything else → its file name
  without ".exe". Processes that never start Cocoa (wineserver, services) are untouched.

## Verified (11/01/2026)
- Test windows under Wine (a 1x1 window off-screen): `NSRunningApplication.localizedName`
  "Driving Range" / "offwin", also when started through `cmd /d /s /c`, which is how the
  app starts games.
- The real app from the bundle (iTerm, play.sh): window process "Rapsodo Golf", connected
  to the monitor and ran `APIAuthenticate` as usual. The real Driving Range with the library
  loaded: "Driving Range", Direct3D 11 up, closed cleanly.
- The bundle's ad-hoc signature verifies (`codesign -v`). The first build, without signing
  the library on its own, printed "warning: ad-hoc codesign failed".

## Not covered
- The bold app name in the menu bar still says "wine" (AppKit sets it at launch from the
  process name). The games usually run full screen, where it's hidden.
- Force Quit's icon for the games is still the generic one; the Dock icon already came from
  the exe (Wine sets it).
- Not looked at in the Force Quit window itself (no screen access); it lists apps by the
  same LaunchServices name.
