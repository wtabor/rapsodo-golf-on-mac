# 11/10/2026 — Options for when Rosetta 2 goes (macOS 28, fall 2027)

A user saw macOS's "Support Ending for Intel-based Apps" warning for "Wine Staging".
It is shown for any Intel app since macOS 26.4. Harmless on macOS 27; Apple says
Intel-only apps won't launch on macOS 28, with a limited Rosetta kept for some older
games (how that subset is chosen isn't published).

Everything Windows-side we ship (patched libzmq, Go NETRESET patches, DXVK-macOS,
geolocation stub, display_fix) is PE code and doesn't care how Wine runs it. The Mac
side to re-check: Wine itself, Fix 13 (`patch_wine_topology.py`, sha-pinned to Gcenx
11.16's `win32u.so`), `rgm-appname.dylib` (built x86_64 to inject into Wine), and
GStreamer.framework (universal). TetherKit is already arm64.

## Options checked

| Option | Needs Rosetta? | Status 11/10/2026 | Verdict |
|---|---|---|---|
| ARM64 Wine + FEX ([MetalSharp-Wine](https://github.com/metalsharp/MetalSharp-Wine): Wine 11.20 Arm64/Arm64EC + FEX, open source) | No | Exists now, small project (31 stars), active | **Spike first.** Same Wine we use, so our patches mostly carry over |
| [CrossOver](https://www.codeweavers.com/) ARM64 preview (own FEX build) | No | Preview since 07/31/2026, target CrossOver 28 ([iThinkDiff](https://www.ithinkdiff.com/crossover-preview-native-arm64-support-rosetta-2/)) | Paid, closed packaging; can't ship it to users. Use as a reference |
| Gcenx Wine ([releases](https://github.com/Gcenx/macOS_Wine_builds/releases)) | Yes | 11.21 (10/31/2026) still `osx64` only | Switch if Gcenx ships arm64 |
| Apple Game Porting Toolkit 4 / D3DMetal ([AppleInsider](https://appleinsider.com/articles/26/06/17/apples-game-porting-toolkit-4-is-a-big-improvement-for-modern-game-coders)) | Yes (x86 Wine under Rosetta) | Beta, developer evaluation tool | Not better: same Rosetta dependency. Only helps if Apple's games-only Rosetta covers it, which is unconfirmed. Our D3D11 already works via DXVK |
| Windows 11 ARM VM (Parallels/UTM) | No | Not tried | Fallback. Unconfirmed: passing the monitor's RNDIS gadget (`2207:0019`) into the VM |

## Apple's own answer (checked 11/10/2026)
- An Apple engineer on the [developer forums](https://developer.apple.com/forums/thread/830692)
  says only that "x86_64 macOS games should continue to work as they do on macOS 26".
  The Wine/CrossOver part of that question went unanswered.
- [macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes),
  Gaming: `sudo game-test-tool enable` + restart previews the legacy-game mode; it
  "disables Rosetta", non-game processes may crash, and it exists only in beta
  releases (`game-test-tool` is absent on 27.0.1 here).
- For Windows games Apple offers nothing for players: GPTK is a tool for developers
  to port games to native Mac builds. Rapsodo would have to ship a Mac app.
- Test: on a macOS 28 beta (June 2027 or the next macOS 27 beta), enable
  `game-test-tool` and see whether Gcenx's x86_64 Wine still runs.

## Plan
1. Spike MetalSharp-Wine on macOS 27 now (it targets macOS 15+): app start,
   monitor connect + auth, Driving Range with DXVK, frame rate vs Rosetta.
2. If it fails, try the CrossOver ARM64 preview to see whether the gap is FEX itself.
3. VM only if both fail.
4. Tell users not to update to macOS 28 until one of these works.
