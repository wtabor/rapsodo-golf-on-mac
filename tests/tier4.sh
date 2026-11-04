# shellcheck shell=bash
# The JavaScript in single quotes is for the page, not this shell:
# shellcheck disable=SC2016
# Tier 4: needs the MLM2PRO on USB (192.168.36.1 answers ping). Two ways in:
# - with tier 3 (scripts/test.sh 3 4): its app, started by the suite, is checked live
#   (discovery, connection, APIAuthenticate, then the alignment camera streams).
#   macOS only lets the app find the monitor (mDNS) when the terminal running the suite
#   has Local Network permission (iTerm, see README "Why iTerm").
# - alone, while you play (scripts/test.sh 4 next to an app started by play.sh): reads
#   that app's log for the same connection lines. Alignment needs tier 3's DevTools port.
# Real shots can't be automated: a checklist for a person is printed at the end.
# Never prints log lines verbatim (they carry the monitor's serial and account ids).
# Sourced by scripts/test.sh.

T4_DONE=0
MONITOR_IP=192.168.36.1
monitor_up() { ping -c 1 -t 2 "$MONITOR_IP" >/dev/null 2>&1; }

T4_DISCOVERED='\[MdnsScanner\] .* at 192\.168\.36\.1|V3ScanTCPDevices: [1-9][0-9]* device'
T4_CONNECTED='"msg":"Connected to the device"'
T4_AUTH='Name: APIAuthenticate RetVal: .*"Status":0'

# t4_connection LOG WAIT: discovery, connection and APIAuthenticate lines in LOG,
# waiting up to WAIT seconds for each (0 = just look).
t4_connection() {
  local log=$1 w=$2 hint=""
  [ "$w" = 0 ] || hint="; the terminal running this needs Local Network permission (iTerm)"
  if wait_for "$w" grep -q -E "$T4_DISCOVERED" "$log"; then
    pass "monitor discovered (mDNS / TCP scan)"
  else
    fail "monitor discovered (mDNS / TCP scan)" "no discovery line in the app log$hint"
    return 1
  fi
  if wait_for "$w" grep -q -F "$T4_CONNECTED" "$log"; then
    pass "app connected to the monitor"
  else
    fail "app connected to the monitor" "no 'Connected to the device' line"
    return 1
  fi
  # The first APIAuthenticate after launch can time out; the app's retry succeeds.
  if wait_for "$w" grep -q -E "$T4_AUTH" "$log"; then
    pass "APIAuthenticate succeeded (Status 0)"
  else
    fail "APIAuthenticate succeeded (Status 0)" "no successful APIAuthenticate reply in the app log"
    return 1
  fi
}

ffmpeg_running() { pgrep -f 'ffmpeg-static.ffmpeg\.exe' >/dev/null; }
mediamtx_running() { pgrep -f 'mediamtx.mediamtx\.exe' >/dev/null; }

# Alignment screen with both camera views (Fixes 5 and 6), driven through DevTools.
t4_alignment() {
  local name="alignment camera streams start (MediaMTX + both ffmpeg publishers)" mark out
  mark=$(log_lines)
  out="$(cdp eval '(async () => {
    const router = document.querySelector("#app")?.__vue_app__?.config.globalProperties.$router;
    if (!router) return "no router";
    await router.push("/alignment");
    for (let i = 0; i < 20; i++) {
      await new Promise(r => setTimeout(r, 500));
      // Its label is styled uppercase, and innerText returns the styled text.
      const b = document.querySelector("[data-testid=cal-footer-cta]");
      if (b && /^align now$/i.test(b.innerText.trim())) { b.click(); return "clicked Align Now"; }
    }
    return "no Align Now button (at " + router.currentRoute.value.path + ")";
  })()' 2>&1)" || true
  echo "        alignment: $out"
  local ok=0 s=$SECONDS
  while [ $((SECONDS - s)) -lt 60 ]; do
    if log_after "$mark" 'DEBUG: MediaMTX server ready' && log_after "$mark" 'DEBUG: ffmpeg \[alignment-shot\]' &&
      log_after "$mark" 'DEBUG: ffmpeg \[alignment-impact\]'; then
      ok=1
      break
    fi
    # "Alignment Couldn't Start" card: no point waiting.
    cdp eval '/Couldn.t Start/.test(document.body.innerText)' 2>/dev/null | grep -q true && break
    sleep 2
  done
  if [ "$ok" = 1 ]; then
    pass "$name" "$((SECONDS - s))s"
  else
    fail "$name" "after $((SECONDS - s))s; app log: $(tail -n +"$((mark + 1))" "$T3_LOG" | grep -c -E 'MediaMTX|mediamtx|stream-module|ffmpeg \[') stream lines"
    tail -n +"$((mark + 1))" "$T3_LOG" | grep -E 'MediaMTX|mediamtx (err|exited|error)|stream-module|ffmpeg \[alignment[^]]*\] (exited|spawn)' | head -15 | indent
  fi
  if [ "$ok" = 1 ]; then
    # Both live views decode at a real frame rate (~18-20 fps; Fix 6 regressions show ~1 fps).
    # The screen shows one camera at a time: Shot Vision, then the Impact Vision tab.
    sleep 5
    out="$(cdp eval '(async () => {
      const sleep = ms => new Promise(r => setTimeout(r, ms));
      const fps = async () => {
        const videos = [...document.querySelectorAll("video")];
        const before = videos.map(v => v.getVideoPlaybackQuality().totalVideoFrames);
        await sleep(5000);
        return videos.map((v, i) => ((v.getVideoPlaybackQuality().totalVideoFrames - before[i]) / 5).toFixed(1));
      };
      const views = await fps();
      const impact = document.querySelector("[data-testid=camera-tab-impact]");
      if (impact) {
        impact.click();
        await sleep(4000);
        views.push(...await fps());
      }
      return views.join(" ");
    })()' 2>&1)" || true
    out="${out//\"/}"
    local n=0 slow=0 f
    for f in $out; do
      n=$((n + 1))
      awk -v f="$f" 'BEGIN { exit !(f + 0 < 8) }' && slow=1
    done
    if [ "$n" -ge 2 ] && [ "$slow" = 0 ]; then
      pass "alignment live views play (Fix 6)" "fps per view: $out"
    else
      fail "alignment live views play (Fix 6)" "fps per view: ${out:-none} (want 2 views at 8+ fps)"
    fi
  fi
  # Leave the screen: everything it started must stop.
  cdp eval '(async () => { await document.querySelector("#app").__vue_app__.config.globalProperties.$router.push("/"); return true; })()' >/dev/null 2>&1 || true
  if wait_for 30 sh -c '! pgrep -f "ffmpeg-static.ffmpeg\.exe" >/dev/null && ! pgrep -f "mediamtx.mediamtx\.exe" >/dev/null'; then
    pass "alignment teardown (no ffmpeg or MediaMTX left)"
  else
    fail "alignment teardown (no ffmpeg or MediaMTX left)" "$(ffmpeg_running && echo 'ffmpeg ')$(mediamtx_running && echo 'MediaMTX ')still running 30 s after leaving the screen"
  fi
}

t4_live() {
  t4_connection "$T3_LOG" 120 && t4_alignment
}

t4_checklist() {
  cat <<'EOF'
   Manual checks (need a person and the monitor; not automated):
     [ ] Driving Range: hit a shot. Ball flight shows, numbers appear.
     [ ] Shot video and Impact video play after the shot (not blank, clock moves).
     [ ] A few more shots over ~10 minutes: the monitor stays connected.
     [ ] Close the Range: the app comes back and reconnects (green link icon).
EOF
}

tier4() {
  if [ "$T4_DONE" = 1 ]; then
    t4_checklist
    return
  fi
  if ! monitor_up; then
    skip "tier 4" "monitor not reachable at $MONITOR_IP (powered off, USB link down, or not plugged in)"
    t4_checklist
    return
  fi
  if pgrep -f "RapsodoGolf.exe --no-sandbox" >/dev/null && [ -f "$RGM_LOG" ]; then
    echo "   (reading the log of the app you started: $RGM_LOG)"
    t4_connection "$RGM_LOG" 0 || true
    skip "alignment camera streams" "needs the app started by tier 3 (scripts/test.sh 3 4) for its DevTools port"
  else
    skip "tier 4" "monitor is up but no app to check: run scripts/test.sh 3 4 (from iTerm), or start the app and run scripts/test.sh 4"
  fi
  t4_checklist
}
