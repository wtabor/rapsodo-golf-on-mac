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
- **Not verified yet:** the decode test with GStreamer present (blocked here: it would
  run the downloaded GStreamer code; needs the owner's OK or the system install), and
  the swing video in the Range itself (needs the monitor and a shot).
