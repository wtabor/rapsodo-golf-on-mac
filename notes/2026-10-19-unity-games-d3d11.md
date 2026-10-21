# 10/19/2026 — Unity games: "Failed to initialize player" (DirectX 11)

## Symptom
Starting Driving Range from the app showed a Unity error dialog:
"Failed to initialize player … Make sure you have DirectX 11 installed …
InitializeEngineGraphics failed". The app log then repeats
`DEBUG: game is running DrivingRange.exe`.

- Game: `C:\ProgramData\Rapsodo\SuperApp\games\driving-range\v1.15.1\DrivingRange.exe`
  (Unity 6000.2.11f1), launched by the app as `DrivingRange.exe -language=en`.
- Game log: `C:\users\<you>\AppData\LocalLow\Rapsodo\DrivingRange\Player.log`.

## Root cause
`Player.log`: D3D12 is rejected by the game's own filter (needs FL 12.1), then
`d3d11: failed to create device and context (80004005)` twice.

`WINEDEBUG=+d3d11,+dxgi,warn+d3d`: Unity asks for FL 11_1/11_0/10_1/10_0, and
wined3d (OpenGL, macOS caps at GL 4.1) fails in
`wined3d_device_init: Failed to create command stream` → `E_FAIL`.

## Tried
| Attempt | Result |
|---|---|
| `-force-glcore` | "not built from editor, shaders will not be available" — the build has D3D11/D3D12 shaders only |
| `-force-vulkan` | same |
| wined3d `renderer=vulkan` (registry) | same E_FAIL |
| wined3d `csmt=0` | same "Failed to create command stream" |
| DXMT v0.80 (Metal) | not attempted: its `winemetal.so` `dlsym`s `macdrv_functions` / `macdrv_view_create_metal_view`; Gcenx 11.16 `winemac.so` exports only 2 symbols, so it can't make a Metal view. Needs a CrossOver-source or custom Wine build |
| **DXVK-macOS 1.10.3 (async repack) + MoltenVK** | **works**: `D3D_FEATURE_LEVEL_11_0` on Apple M4; Rapsodo Range loading screen renders |

## Fix
`scripts/45-install-dxvk.sh`:
- downloads `dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz` from
  https://github.com/Gcenx/DXVK-macOS (sha256 pinned) into `build/dxvk/`;
- copies x64 `d3d11.dll` and `d3d10core.dll` into the prefix's `system32`;
- sets `HKCU\Software\Wine\AppDefaults\<Game>.exe\DllOverrides` d3d11/d3d10core =
  `native,builtin` for `DrivingRange.exe` and every `games/*/*/<Name>_Data` found
  (today: also `Practice_TargetRange.exe`, `RapsodoStudiosGolf_development.exe`).
  Everything else (Electron) keeps Wine's builtin d3d11.
- DXVK logs `Adapter is not a DXVK adapter` (the repack has no `dxgi.dll`; Wine's
  dxgi is used). Harmless.

Re-run after a Rapsodo update, a Wine prefix `wineboot --update`, or when the app
downloads a new game.

## Not yet verified
- A full session in Driving Range with shots from the MLM2PRO.
- Practice_TargetRange / RapsodoStudiosGolf games.
- Tested by launching the exe directly, not from the app's Play button.
