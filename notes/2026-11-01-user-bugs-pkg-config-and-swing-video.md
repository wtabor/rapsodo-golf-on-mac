# Two user reports: install stops at libzmq, no swing video in the Range (11/01/2026)

## 1. Install stops: "Could NOT find PkgConfig (missing: PKG_CONFIG_EXECUTABLE)"
A user's install stopped in `30-build-libzmq.sh` (screenshot: CMake error from
`builds/cmake/Modules/Findsodium.cmake:7`, called from `CMakeLists.txt:268`).

- Cause: libzmq 4.3.5's `Findsodium.cmake` starts with `find_package(PkgConfig
  REQUIRED)` on every non-MSVC build, before it looks at the `SODIUM_INCLUDE_DIRS` /
  `SODIUM_LIBRARIES` we pass in. pkg-config only supplies hints there. The owner's Mac
  has Homebrew's `pkgconf` (pulled in by something else), so it never failed here, and
  `00-prereqs.sh` doesn't install it.
- Reproduced: same sources and flags with Homebrew's bin dirs hidden from CMake
  (`CMAKE_IGNORE_PATH`, MinGW tools given by full path): "Could NOT find PkgConfig",
  "Configuring incomplete".
- Fix: 30 now edits that line to `find_package(PkgConfig)` (idempotent, next to the
  existing platform.hpp.in edit). Same hidden-pkg-config setup: configure completes,
  "Using libsodium for CURVE security", `ZMQ_HAVE_CURVE` defined, libzmq.dll builds and
  imports `libsodium-26.dll` (same export count as the current build). The real 30 run
  on the owner's Mac also builds. TetherKit's `FindLibUSB.cmake` uses
  `find_package(PkgConfig QUIET)` with a fallback, so it doesn't need pkg-config either.
- Also: `-Wno-dev -Wno-deprecated`, so libzmq's harmless CMake warnings (the yellow text
  in the screenshot) don't bury a real error.
- The user needs to run the install command again (their install never finished, so
  there is no Dock app to auto-update from).

## 2. "Swing video isn't working in range mode"
- The owner's own Range session on 10/28/2026 had two real shots. Player-prev.log shows
  the whole pipeline up to playback: `FileReady` (RIFF frames from the monitor),
  "SwingVideo processed by MLM2: …\swingVideo_avc.mp4", "Impact Video uploaded at path:
  C:\ProgramData\Rapsodo\SuperApp\files\…_ShotVideo.mp4", "VideoController SetVideoUrl
  …_ShotVideo.mp4". The files are valid (ffprobe: H.264 High, 480x640, 3 fps, 10 s).
- Unity's VideoPlayer on Windows plays through Media Foundation. Wine's MP4 source and
  H.264 decoder go through winegstreamer, and Gcenx's builds need GStreamer.framework
  installed for all users ([release notes, e.g. 9.0-rc3](https://github.com/Gcenx/macOS_Wine_builds/releases/tag/9.0-rc3)).
  Our `winegstreamer.so` links `@rpath/libgst*-1.0.0.dylib` (GStreamer 1.28, compatibility
  version 2802) with rpaths `@loader_path/` and
  `/Library/Frameworks/GStreamer.framework/Libraries`. Nothing installs it, and it isn't
  on the owner's Mac.
- Test: a small MinGW program (Media Foundation source reader, RGB32 output, like
  Unity) on the user's real `ShotVideo.mp4` under our Wine: `MFStartup` OK,
  `MFCreateSourceReaderFromURL` = `0xC00D36BB` (MF_E_UNEXPECTED). No frames.
- Fix (branch `gstreamer-video`, not on main yet): `scripts/46-install-gstreamer.sh`,
  run by install.sh, installs GStreamer's official universal runtime 1.28.8
  (`gstreamer-1.0-1.28.8-universal.pkg`, sha256 `d371ab04…`, from
  gstreamer.freedesktop.org; universal x86_64+arm64, libgstreamer compatibility 2809,
  includes libav, applemedia and isomp4; every component selected by default) with
  `sudo installer`. Skips when an x86_64 libgstreamer at >= 2802 is already there.
  Sandbox-tested (stub sudo/installer/curl): skip when present, replace an arm64-only
  copy, install when missing, no-op on the next run.
- Verified on the owner's Mac (11/01/2026, after his OK; 46 run from a terminal tab for
  his password): GStreamer 1.28.8 installed (x86_64+arm64, compatibility 2809, 257
  plugins). The same test now gives `MFCreateSourceReaderFromURL` = S_OK,
  `SetCurrentMediaType(RGB32)` = S_OK, **30/30 frames** of the user's real
  `ShotVideo.mp4`.
- The first use took 62 s: GStreamer scans every plugin once (under Rosetta) and caches
  the list in `~/.cache/gstreamer-1.0/registry.x86_64.bin`; later decodes take 1–2 s. That
  minute would land on the first swing video, so 46 now builds the list right after
  installing (`arch -x86_64 …/Commands/gst-inspect-1.0`), and also when GStreamer is
  already there but the list is missing (2.5 s here, with Rosetta's cache warm).
- Smoke test with GStreamer present, through play.sh: Driving Range up for 60 s, no
  video/Media Foundation errors (only the known localization exceptions), closed
  cleanly; Studios reached Courses in 38 s; the app quit with no false crash.
- **Not verified yet:** the swing video in the Range itself (needs the monitor and a
  shot).

## 3. Live test: swing video still blank ("video is blank")
With GStreamer installed and the monitor connected, real shots in the Range: the
Shot/Impact panel showed a pause button and 00:00 / 00:10 with no picture (playing, but
the clock never moved).

### First, wrong, fix: mfplat bind flags (dropped)
- Player.log's first line was `WindowsVideoMedia error 0x80070057 while reading`. A test
  program reading NV12 into D3D11 textures (DXGI device manager) got textures with bind
  flags 0, and `CreateShaderResourceView` on them returned the same 0x80070057. Wine's
  reader never passes `MF_SOURCE_READER_D3D11_BIND_FLAGS` to its output allocator
  (`mfreadwrite/reader.c`, `source_reader_create_sample_allocator_attributes`), and
  `InitializeSampleAllocatorEx` gives non-BGRA textures bind 0.
- A one-byte mfplat.dll patch (`patch_wine_mfplat.py`) made those textures shader-readable.
  The owner hit three more shots: still blank. The full Player.log entry, which the first
  grep had cut off, said where the error really came from (next section). Every one of
  the 1408 errors in the log from before that patch has the same context, so the patch
  never addressed it. Removed; mfplat.dll is back to stock.

### Real causes
- The full entry: `Context: Failed getting shared handle from IDXGIResource`, `Error
  details: Invalid parameter.`, repeated for every frame (3719 times in 20 minutes).
  UnityPlayer.dll (2022.3, disassembled): with the D3D11 renderer (`renderer == 2` sets
  the flag that picks it), WindowsVideoMedia decodes on its own D3D11 device, then for
  each frame calls `IDXGIResource::GetSharedHandle` and `OpenSharedResource` on the render
  device. A null handle is also an error.
- DXVK-macOS can't share textures: a test creating `MISC_SHARED` / `SHARED_KEYEDMUTEX`
  textures logs `Failed to create shared resource: VK_KHR_EXTERNAL_MEMORY_WIN32 not
  supported`, and `GetSharedHandle` returns 0x80070057 for every texture. So that path
  can't work here, whatever Media Foundation does.
- Unity only uses that path when `GetProcAddress(mfplat, "MFCreateDXGIDeviceManager")`
  and `"MFCreateVideoSampleAllocatorEx"` both succeed. It checks the stored pointers when
  setting up the source reader (no DXGI manager otherwise), when building its D3D frame
  queue (none otherwise, so the system-memory frame path runs), and in two optional D3D
  extras that are simply skipped. The system-memory path: `ConvertToContiguousBuffer`,
  `IMF2DBuffer::Lock2D` or `Lock`, stride from `MF_MT_DEFAULT_STRIDE` or
  `MFGetStrideForBitmapInfoHeader`, then Unity uploads the pixels itself.
- Second cause, in the same log: `First video frame not zero: 2 (0.666667s). Result may
  be out of sync.` (shot video, 3 fps) and `... 2 (0.050000s)` (swing video, 40 fps).
  Unity turns each sample time into a frame number (`time * fps + 0.5`) and drops the
  queued frame if it isn't the one it wants, so with every number off by two nothing is
  ever shown and the clock stays at 0. Both MP4s have B-frames and an edit list
  (`media time 8192` = two frames). Wine's default MP4 reader (winegstreamer, decodebin)
  returns already-decoded frames stamped with qtdemux's raw times, 0.667 s first.
  GStreamer's own FFmpeg (libavformat 61) applies the edit list (first pts 0, dts
  -0.667 s), and Wine's newer reader (mfsrcsnk + winedmo, which links those FFmpeg
  libraries) passes that through: first frame at 0, then 0.333, ... Selected by
  `HKCU\Software\Wine\MediaFoundation\DisableGstByteStreamHandler=1`.

### Fix
- `scripts/patch_unity_video.py`, run by 40 on every `games/<id>/<ver>/UnityPlayer.dll`:
  renames the one `MFCreateDXGIDeviceManager` string to `RGMNoDXGIDeviceManager` (same
  length), so the lookup fails. Refuses a DLL where the name isn't there exactly once or
  that imports Media Foundation statically (none of the three games do). Keeps `.orig`,
  replaces by rename (a running game keeps its mapped copy), `--revert`. On copies of
  both Unity builds (Range/Target Range, Studios): 25 bytes differ, re-run says "already
  patched", revert is byte-identical.
- `scripts/46-install-gstreamer.sh` sets the registry value (the new reader needs
  GStreamer.framework's FFmpeg libraries anyway).
- Kept from before: `launcher.c` sets
  `GST_PLUGIN_FEATURE_RANK=vtdec:NONE,vtdec_hw:NONE,avfassetsrc:NONE`. Wine's H.264
  decoder runs on GStreamer, whose VideoToolbox plugins link a second MoltenVK ("Class
  MVKBlockObserver is implemented in both"; seen when `vtdechw` picked the stream).

### Verified offline (11/01/2026, stock mfplat)
A MinGW program that reads the way Unity does (async `IMFSourceReaderCallback`,
DISABLE_DXVA=0, HARDWARE_TRANSFORMS=1, ADVANCED_VIDEO_PROCESSING=1, D3D11 bind flags 8,
XVP_DISABLE_FRC=1, no DXGI manager, Unity's stride lookup):
- Shot video from shot #3: 30/30 frames, times 0, 0.333 s, ... for NV12, RGB32 and ARGB32.
- Swing video (`swingVideo_avc.mp4`, H.264 1536x1440, 40 fps): 249/249, first at 0.
- Orientation: NV12 has stride +480 and is top-down; RGB32/ARGB32 have no
  `MF_MT_DEFAULT_STRIDE`, so Unity falls back to `MFGetStrideForBitmapInfoHeader` =
  -1920 (bottom-up), and Wine's RGB32 buffer is stored bottom-up (its first rows match
  the bottom of the picture by ffmpeg's luma). So the picture comes out right side up.
- With a DXGI manager (the path Unity no longer takes) the new reader sometimes lost the
  last 3 frames of the 3 fps video (decoder drain race, gone with tracing on). Never on
  the system-memory path.

**Not verified yet:** the video playing in the Range itself (needs a shot, or clicking
an earlier shot after restarting the game with the patched UnityPlayer.dll).
