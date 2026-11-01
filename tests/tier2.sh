# shellcheck shell=bash
# Tier 2: Wine, no monitor, no app. Small Windows programs (tests/wine/*.c, built with
# MinGW) run under the installed Wine and prefix, next to a running app if there is
# one. Nothing in the prefix is changed: the programs only read, and MediaMTX runs
# with its own config on loopback ports. Sourced by scripts/test.sh.

# Link flags per test program (tests/wine/<name>.c).
win_test_flags() {
  case "$1" in
    unityvp) echo "-municode -lmfplat -lmfreadwrite -lmfuuid -ld3d11 -lole32 -luuid" ;;
    mfsrc) echo "-municode -lmfplat -lmfuuid -lole32" ;;
    d3d11check) echo "-ld3d11 -ldxgi -luuid" ;;
    udpioctl) echo "-lws2_32" ;;
    winctl) echo "-municode" ;;
    *) echo "" ;;
  esac
}

# Build tests/wine/*.c into $WORK/bin (once per run). Reports one line.
build_win_tests() {
  local log=$1 src name bad="" n=0
  mkdir -p "$WORK/bin"
  [ -z "${WIN_TESTS_BUILT:-}" ] || return 0
  : >"$log"
  for src in "$TESTS"/wine/*.c; do
    name="$(basename "$src" .c)"
    n=$((n + 1))
    # shellcheck disable=SC2046  # flags are separate words
    "$MINGW" -O2 -Wall -o "$WORK/bin/$name.exe" "$src" $(win_test_flags "$name") >>"$log" 2>&1 || bad="$bad $name"
  done
  WIN_TESTS_BUILT=1
  if [ -z "$bad" ]; then
    pass "tests/wine programs compile" "$n programs"
  else
    fail "tests/wine programs compile" "failed:$bad"
    show "$log"
  fi
}

# Is HKCU\Software\Wine\MediaFoundation\DisableGstByteStreamHandler=1 set? Read from
# the prefix's user.reg directly (no Wine, no change).
gst_handler_disabled() {
  awk '/^\[/ { s = ($0 ~ /^\[Software\\\\Wine\\\\MediaFoundation\]/) } s && /^"DisableGstByteStreamHandler"=dword:0*1$/ { f = 1 } END { exit !f }' \
    "$RGM_PREFIX/user.reg" 2>/dev/null
}

# t2_prog NAME TIMEOUT EXE [ARGS...]: run one program; PASS on exit 0.
t2_prog() {
  local name=$1 t=$2 exe=$3 log rc=0
  shift 3
  log="$WORK/t2-$(basename "$exe" .exe)-$RANDOM.log"
  (cd "$WORK/bin" && wine_run "$t" "$exe" "$@") >"$log" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then
    pass "$name" "$(grep -E '^(info|adapter):' "$log" | head -2 | tr -d "\r" | tr "\n" " " | sed "s/ $//")"
    [ -z "$RGM_TEST_VERBOSE" ] || show "$log"
  else
    [ "$rc" = 142 ] && echo "timed out after ${t}s" >>"$log"
    fail "$name" "exit status $rc"
    show "$log"
  fi
}

t2_mediamtx() {
  local name="MediaMTX opens its UDP listeners (Fix 5, 47 + NETRESET patch)" dir="$WORK/mtx" rc=0
  if [ ! -f "$MTX_EXE" ]; then skip "$name" "not installed (47-install-mediamtx.sh)"; return; fi
  mkdir -p "$dir"
  # Loopback only, odd ports, and only RTSP (UDP) and WebRTC (ICE/UDP): the two kinds of
  # UDP listener the unpatched exe can't open ("wsaioctl: winapi error #10045").
  cat >"$dir/mediamtx.yml" <<'EOF'
logLevel: info
api: no
metrics: no
pprof: no
playback: no
rtmp: no
hls: no
srt: no
rtsp: yes
rtspTransports: [udp, tcp]
rtspAddress: 127.0.0.1:18554
rtpAddress: 127.0.0.1:18000
rtcpAddress: 127.0.0.1:18001
webrtc: yes
webrtcAddress: 127.0.0.1:18889
webrtcLocalUDPAddress: 127.0.0.1:18189
webrtcLocalTCPAddress: ''
EOF
  (cd "$dir" && wine_run 8 "$MTX_EXE" mediamtx.yml) >"$dir/out.log" 2>&1 || rc=$?
  # Still running when the 8 s timeout stops it (142) is the good outcome.
  if [ "$rc" = 142 ] && grep -q '(UDP/RTP)' "$dir/out.log" && grep -q '(ICE/UDP)' "$dir/out.log" &&
    ! grep -q ' ERR ' "$dir/out.log"; then
    pass "$name"
    [ -z "$RGM_TEST_VERBOSE" ] || show "$dir/out.log"
  else
    fail "$name" "exit status $rc (142 = still running, expected)"
    show "$dir/out.log"
  fi
}

# Media Foundation reads the way Unity's VideoPlayer does after patch_unity_video.py
# (system memory, async reader; unityvp.exe NOD3D=1). Synthetic videos only: never
# use real swing videos here (they're personal).
t2_video() {
  local fx="$WORK/video" why=""
  have ffmpeg || why="ffmpeg not installed (brew install ffmpeg)"
  [ -d /Library/Frameworks/GStreamer.framework ] || why="GStreamer.framework missing (46-install-gstreamer.sh)"
  if [ -n "$why" ]; then skip "Media Foundation video reads" "$why"; return; fi
  mkdir -p "$fx"
  local enc="-c:v libx264 -pix_fmt yuv420p"
  # easy: no B-frames, no edit list. shot: like the Range's shot video (H.264 High,
  # B-frames, so the MP4 has an edit list and the first frame's pts is 2 frames in),
  # 480x640 at 3 fps. swing: like the swing video, 1536x1440 at 40 fps, 2 s.
  # shellcheck disable=SC2086
  if ! { ffmpeg -v error -y -f lavfi -i testsrc2=size=480x640:rate=3 -t 10 $enc -profile:v baseline "$fx/easy.mp4" &&
    ffmpeg -v error -y -f lavfi -i testsrc2=size=480x640:rate=3 -t 10 $enc -profile:v high -bf 2 -g 30 "$fx/shot.mp4" &&
    ffmpeg -v error -y -f lavfi -i testsrc2=size=1536x1440:rate=40 -t 2 $enc -profile:v high -bf 3 "$fx/swing.mp4"; } >"$fx/ffmpeg.log" 2>&1; then
    fail "make synthetic test videos" "ffmpeg failed"
    show "$fx/ffmpeg.log"
    return
  fi
  # The hard case needs an edit list with a start offset; check ffmpeg still makes one.
  local elst
  elst="$(python3 -I -c '
import struct, sys
d = open(sys.argv[1], "rb").read()
i = d.find(b"elst")
if i < 0:
    print(0)
else:
    v = d[i + 4]
    print(struct.unpack(">q" if v == 1 else ">i", d[i + 20 : i + 28] if v == 1 else d[i + 16 : i + 20])[0])
' "$fx/shot.mp4" 2>/dev/null)"
  if [ "${elst:-0}" -gt 0 ] 2>/dev/null; then
    pass "synthetic videos (B-frame MP4 has an edit list)" "media time $elst"
  else
    skip "synthetic videos (B-frame MP4 has an edit list)" "this ffmpeg wrote none; the first-frame-time checks prove less"
  fi
  local strict=0
  if gst_handler_disabled; then
    strict=1
  fi
  t2_read "Media Foundation: no-B-frame video, all frames from 0 (Unity system-memory path)" easy.mp4 30 1 ""
  t2_read "Media Foundation: B-frame shot video 480x640 3 fps, all frames from 0" shot.mp4 30 "$strict" ""
  t2_read "Media Foundation: same, RGB32 output" shot.mp4 30 "$strict" rgb32
  t2_read "Media Foundation: B-frame swing video 1536x1440 40 fps, all frames from 0" swing.mp4 80 "$strict" ""
  # The MP4 source itself (before any decoder): first sample time 0 when the edit list is applied.
  local log="$fx/mfsrc.log" rc=0 first
  (cd "$fx" && wine_run 60 "$WORK/bin/mfsrc.exe" shot.mp4) >"$log" 2>&1 || rc=$?
  first="$(summary_field "$log" first_time)"
  t2_judge "Media Foundation: MP4 source applies the edit list (first sample time 0)" "$strict" \
    "$([ "$rc" = 0 ] && [ "$first" = 0 ] && echo ok)" "exit $rc, first sample time ${first:-none}" "$log"
}

# t2_read NAME FILE FRAMES STRICT OUT
t2_read() {
  local name=$1 file=$2 want=$3 strict=$4 out=$5 log rc=0 frames first nonblank
  log="$WORK/video/${file%.mp4}-${out:-nv12}.log"
  (cd "$WORK/video" && NOD3D=1 OUT="$out" wine_run 100 "$WORK/bin/unityvp.exe" "$file") >"$log" 2>&1 || rc=$?
  frames="$(summary_field "$log" frames)"
  first="$(summary_field "$log" first_ts)"
  nonblank="$(summary_field "$log" nonblank)"
  t2_judge "$name" "$strict" \
    "$([ "$rc" = 0 ] && [ "$frames" = "$want" ] && [ "$first" = 0 ] && [ "$nonblank" = "$want" ] && echo ok)" \
    "exit $rc, frames ${frames:-none}/$want, first time ${first:-none}, with a picture ${nonblank:-none}" "$log"
}

# t2_judge NAME STRICT OK DETAIL LOG: without DisableGstByteStreamHandler=1 (branch
# game-video-fix sets it), a wrong first-frame time is Wine's known default, so SKIP.
t2_judge() {
  local name=$1 strict=$2 ok=$3 detail=$4 log=$5
  if [ -n "$ok" ]; then
    pass "$name" "$detail"
    [ -z "$RGM_TEST_VERBOSE" ] || show "$log"
  elif [ "$strict" = 1 ]; then
    fail "$name" "$detail"
    show "$log"
  else
    skip "$name" "$detail; expected without HKCU\\Software\\Wine\\MediaFoundation\\DisableGstByteStreamHandler=1"
  fi
}

tier2() {
  local why=""
  [ -x "$RGM_WINE_BIN/wine" ] || why="Wine not installed ($RGM_WINE_BIN/wine)"
  [ -n "$why" ] || [ -f "$RGM_PREFIX/system.reg" ] || why="no Wine prefix ($RGM_PREFIX)"
  [ -n "$why" ] || arch -x86_64 /usr/bin/true 2>/dev/null || why="Rosetta 2 not installed"
  [ -n "$why" ] || have "$MINGW" || why="no $MINGW (brew install mingw-w64)"
  if [ -n "$why" ]; then
    skip "tier 2" "$why"
    return
  fi
  build_win_tests "$WORK/compile.log"
  if [ ! -f "$WORK/bin/udpioctl.exe" ]; then return; fi
  # The first Wine program can take a while if no Wine server is running yet.
  t2_prog "Wine accepts SIO_UDP_CONNRESET (what the Fix 2 patch relies on)" 60 udpioctl.exe
  t2_prog "D3D11 device through DXVK (Fix 3)" 60 d3d11check.exe
  if [ ! -f "$WORK/bin/GeolocationPlugin.dll" ]; then
    "$MINGW" -shared -O2 -s -o "$WORK/bin/GeolocationPlugin.dll" "$RGM_REPO/scripts/geolocation_stub.c" >/dev/null 2>&1
  fi
  RGM_GEO_LAT=12.345678 RGM_GEO_LON=-45.678901 RGM_GEO_ALT=100.5 \
    t2_prog "geolocation stub: Allowed + position from RGM_GEO_* (Fix 4)" 30 geocheck.exe GeolocationPlugin.dll 12.345678 -45.678901 100.5
  # Without the variables (env.sh exports them, so drop them in a subshell): no fix.
  (
    unset RGM_GEO_LAT RGM_GEO_LON RGM_GEO_ALT
    t2_prog "geolocation stub: no position without RGM_GEO_*" 30 geocheck.exe GeolocationPlugin.dll unset
  )
  if [ -f "$RGM_LIBS_DIR/libzmq.dll" ]; then
    t2_prog "patched libzmq: sockets, loopback, CURVE (Fix 1)" 30 zmqcheck.exe "$(winpath "$RGM_LIBS_DIR")"
  else
    skip "patched libzmq: sockets, loopback, CURVE (Fix 1)" "app not installed"
  fi
  t2_mediamtx
  if [ -f "$WORK/bin/rgm-display-fix.exe" ] || "$MINGW" -municode -O2 -s -o "$WORK/bin/rgm-display-fix.exe" \
    "$RGM_REPO/scripts/display_fix.c" -luser32 -ladvapi32 -lntdll >/dev/null 2>&1; then
    local log="$WORK/display.log" rc=0
    (cd "$WORK/bin" && wine_run 30 rgm-display-fix.exe show) >"$log" 2>&1 || rc=$?
    if [ "$rc" = 0 ] && grep -q ' primary' "$log" && ! grep -q WinDisc "$log"; then
      pass "display fix: Wine sees a primary monitor (Fix 9, rgm-display-fix.exe show)"
      [ -z "$RGM_TEST_VERBOSE" ] || show "$log"
    else
      fail "display fix: Wine sees a primary monitor (Fix 9, rgm-display-fix.exe show)" "exit $rc"
      show "$log"
    fi
  fi
  t2_video
}
