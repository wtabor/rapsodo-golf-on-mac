#!/usr/bin/env bash
# GStreamer, for video in the games (the Driving Range's swing video, for one).
# Gcenx's Wine needs GStreamer.framework installed for all users: its
# winegstreamer.so loads it from /Library/Frameworks/GStreamer.framework/Libraries.
# Without it, Media Foundation can't even open an MP4 (MFCreateSourceReaderFromURL
# fails with MF_E_UNEXPECTED), so Unity's VideoPlayer shows nothing. This installs
# GStreamer's official universal runtime package (sha256-checked) with macOS's
# installer, which asks for your password once. Skipped when a GStreamer new enough
# for this Wine, with an Intel (x86_64) slice, is already there. Idempotent.
set -euo pipefail
. "$(dirname "$0")/env.sh"

GST_VERSION=1.28.8
GST_PKG=gstreamer-1.0-$GST_VERSION-universal.pkg
GST_URL=https://gstreamer.freedesktop.org/data/pkg/osx/$GST_VERSION/$GST_PKG
GST_SHA256=d371ab04a7632713626836c2fc234e863cc98484c74c473eba99b0fbd9b3a3fe
FRAMEWORK="${RGM_GST_FRAMEWORK:-/Library/Frameworks/GStreamer.framework}"
LIB="$FRAMEWORK/Libraries/libgstreamer-1.0.0.dylib"
# Our Wine's winegstreamer.so was linked against GStreamer 1.28 and needs at least
# this dylib compatibility version.
NEED=2802

# The installed libgstreamer's version as a dylib "current version" (2809 = 1.28.8),
# or nothing when it's missing or has no x86_64 slice (Wine runs under Rosetta).
installed_version() {
  [ -f "$LIB" ] && lipo -archs "$LIB" 2>/dev/null | grep -qw x86_64 || return 0
  otool -L "$LIB" 2>/dev/null |
    awk 'NR == 2 { for (i = 1; i < NF; i++) if ($i == "current") { split($(i + 2), v, "."); print v[1] } }'
}

# GStreamer scans all its plugins the first time it's used and caches the list in
# ~/.cache/gstreamer-1.0/registry.x86_64.bin. Under Rosetta that first scan took
# about a minute, which would land on the first swing video in a game (the game may
# give up waiting). Do it here instead, as the user, in Intel mode like Wine.
warm_up() {
  [ -f "$HOME/.cache/gstreamer-1.0/registry.x86_64.bin" ] && return 0
  echo "Preparing GStreamer's plugin list (once; can take a minute)..."
  arch -x86_64 "$FRAMEWORK/Commands/gst-inspect-1.0" >/dev/null 2>&1 ||
    echo "warning: couldn't prepare GStreamer's plugin list; the first video may take a minute" >&2
}

# Wine has two MP4 readers. The default (GStreamer's demuxer) ignores an MP4's edit
# list, so a video with B-frames starts at frame 2 (0.67 s into the Range's 3 fps shot
# video), and Unity drops every frame whose number isn't the one it asked for. Wine's
# newer reader (winedmo, built on the FFmpeg libraries inside GStreamer.framework)
# gets the times right.
WINEPREFIX="$RGM_PREFIX" WINEDEBUG=-all "$RGM_WINE_BIN/wine" reg add \
  'HKCU\Software\Wine\MediaFoundation' /v DisableGstByteStreamHandler /t REG_DWORD /d 1 /f >/dev/null &&
  echo "Wine's FFmpeg-based MP4 reader enabled" ||
  echo "warning: couldn't switch Wine's MP4 reader; game videos may stay blank" >&2

v="$(installed_version)"
if [ -n "$v" ] && [ "$v" -ge "$NEED" ]; then
  echo "GStreamer already installed ($FRAMEWORK, version $v)"
  warm_up
  exit 0
fi

dir="$RGM_BUILD/gstreamer"
mkdir -p "$dir"
if ! echo "$GST_SHA256  $dir/$GST_PKG" | shasum -a 256 -c - >/dev/null 2>&1; then
  curl -fL --progress-bar -o "$dir/$GST_PKG.part" "$GST_URL"
  mv -f "$dir/$GST_PKG.part" "$dir/$GST_PKG"
fi
echo "$GST_SHA256  $dir/$GST_PKG" | shasum -a 256 -c -

# Say why the password prompt appears, also when the installer's output goes to a
# log (auto-update).
msg="Installing GStreamer $GST_VERSION (video playback in the games). macOS asks for your password."
{ echo "$msg" >/dev/tty; } 2>/dev/null || echo "$msg" >&2
sudo installer -pkg "$dir/$GST_PKG" -target /

v="$(installed_version)"
if [ -z "$v" ] || [ "$v" -lt "$NEED" ]; then
  echo "error: GStreamer didn't install into $FRAMEWORK" >&2
  exit 1
fi
rm -f "$dir/$GST_PKG"
echo "GStreamer $GST_VERSION installed ($FRAMEWORK, version $v)"
warm_up
