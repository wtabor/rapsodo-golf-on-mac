# Game FPS benchmark: DXVK + MoltenVK is the bottleneck (11/20/2026)

Base M4 MacBook Air (8-core GPU, 16 GB), Dell 1920x1080@60 as game display.
Target Range v1.16.0 started directly with wine (no app), map screen with the
"Network access required" modal up, `DXVK_ASYNC=1`, `DXVK_HUD=fps,frametimes,gpuload,drawcalls,submissions`.
Game auto-detected "Recommended Quality: Low" (Player.log; D3D reports "NVIDIA GeForce 6800").
GPU busy read from `ioreg -c IOAccelerator` "Device Utilization %": 96–100% in every run.

| Resolution (-screen-width/height) | frame time | ~fps |
|---|---|---|
| 960x540   | 39–46 ms  | 23 |
| 1280x720  | 54–63 ms  | 17 |
| 1920x1080 | 91–108 ms | 10 |

~4000 draw calls, 71 render passes, 104 barriers per frame.

No effect at 720p (all 54–65 ms): `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0`,
`MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=1`, dxvk.conf `d3d11.relaxedBarriers=True` +
`d3d11.cachedDynamicResources="a"`.

Gotcha: `-screen-width/-screen-height` are saved by Unity to
`HKCU\Software\Rapsodo\Practice_TargetRange`; the last run (1920x1080) restored it.

Conclusion: GPU-bound inside the D3D11 -> Vulkan -> Metal translation, not settings.
Only a different translator (D3DMetal from Apple's GPTK, or DXMT) can change this;
DXMT previously failed to load with Gcenx's winemac.so (see Fix 3). Not tried yet.
Not measured: real gameplay without the modal (it may blur the scene), the app's
chosen quality level. Disk had 5.6 GB free (swap headroom; earlier sessions used 9.4 GB swap).

## CrossOver 26.3.0 (trial) — D3DMetal and DXMT (same day)
Bottle `rgm-bench` (win10_64). Target Range cloned in (`cp -cR`, already-patched DLLs) to
`C:\Games\TargetRange`. Needs `C:\ProgramData\Rapsodo\SuperApp\app.db` (+ dwapp.db, images,
local) cloned too, or the game's gRPC calls fail "Unauthenticated" and it sits on the
loading screen. Backend per launch: `CX_GRAPHICS_BACKEND=d3dmetal|dxmt|dxvk`.
FPS from Apple's Metal HUD (`MTL_HUD_ENABLED=1`). Same map screen + network modal.

- **D3DMetal 3.0:** loading screen 60 fps (GPU 2.8–5.4 ms), but the game exits ~25 s in,
  as the course scene loads (`EXCEPTION_ACCESS_VIOLATION` in the game process, no Unity
  crash report). Not investigated further.
- **DXMT v0.72:** works. 1920x1080 fullscreen on the Dell (`-monitor 2 -screen-fullscreen 1`):
  39 fps avg (frames 16.7/33.3 ms alternating = judder at 60 Hz), "Composited" (not direct).
  1470x956 window on the laptop: 51 fps. D3D reports "Apple M4". ~4x DXVK.

## Wired in: games under CrossOver + DXMT (opt-in, branch feat/dxmt-games)
`RGM_GAME_RUNTIME=crossover` (env.local.sh). The app stays on Gcenx Wine 11.16; only the
Unity games move. Design and why:
- Wine 11.16 ignores IFEO `Debugger` (tested with hostname.exe), so the game exe itself is
  swapped: `49-game-runtime.sh` keeps the real one as `<Game>.exe.rgm-unity` and puts
  `rgm-game-runner.exe` (`game_runner.c`, marker `RGM-GAME-RUNNER-STUB`) in its place.
  The app's launch (`"C:\...\<Game>.exe" -language=en`) and its tasklist check (exe name)
  see the stand-in. A non-stub exe found later (game update) becomes the new `.rgm-unity`.
  Off → every `.rgm-unity` is moved back.
- Hand-off through files in `C:\ProgramData\rgm-game-runner\` (`<pid>.req` / `.started` /
  `.exit`); the stand-in touches `.req` every second; `game-runner.sh` (started by play.sh
  with the app's pid) closes the game when that goes stale >15 s and stops everything when
  the app exits. Stand-in shows an error box if nobody picks the request up in 20 s.
- Unity finds `<Game>_Data` from the exe's own name, so the real exe runs from a mirror in
  the bottle, `C:\rgm-games\<id>\<ver>\`: symlinks to every game file + a clone of the exe.
- Bottle `rapsodo-games`: `C:\ProgramData\Rapsodo` is a symlink to the app prefix's (app.db
  = user + game settings; the game's gRPC calls fail "Unauthenticated" without it). Each
  game's Unity registry key is copied over once (marker files in
  `C:\rgm-games\.settings-copied\`), so games open on the same monitor/size.
- Tests: hand-off verified without the app (1080p on the Dell, DXMT 39 fps, Player.log
  "Renderer: Apple M4"); app-side close → game closed in ~18 s; game exit → stand-in exits
  in ~2 s, files cleaned; switching off/on restores/re-swaps all 4 exes. Tier 3 adapted
  (`T3_GAME_PAT`, bottle Player.log and registry, runner started next to the test app).
- Open: two Wine servers share app.db (the app's and the game's). Wine mirrors file locks
  to Unix locks, so it should be safe; not verified under load. Real shots, swing video
  under CrossOver's own GStreamer, and Studios/Wedge Matrix/Driving Range in play: untested.
- Unrelated, found by tier 1: `patch_app_window.py`'s "no maximize" edit no longer matches
  the installed app (it now calls `Ce.maximize()`); the Rapsodo app updated since Fix 12.
