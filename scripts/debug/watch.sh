#!/bin/bash
# Watch the game's monitor link: print state changes and gaps in received messages.
# Usage: scripts/debug/watch.sh [seconds]. Exits on heartbeat_timeout or after $1 seconds (default 900).
. "$(dirname "$0")/../env.sh"
D="$RGM_PREFIX/drive_c/users/$(id -un)/AppData/LocalLow/Rapsodo/DrivingRange"
P="$D/Player.log"; R="$D/log/rdc.log"
end=$(( $(date +%s) + ${1:-900} ))
start_r=1
seen=0
while [ "$(date +%s)" -lt "$end" ]; do
  n=$(grep -c -E 'ConnectionPhase|Entering state : (Armed|SessionStarted)|heartbeat_timeout|EventName: (DeviceArmed|DeviceDisarmed|ShotMetrics|Shot)' "$P" 2>/dev/null)
  if [ "$n" -gt "$seen" ]; then
    grep -E 'ConnectionPhase|Entering state : (Armed|SessionStarted)|heartbeat_timeout|EventName: (DeviceArmed|DeviceDisarmed|ShotMetrics|Shot)' "$P" | tail -n $((n - seen)) | cut -c1-140
    seen=$n
  fi
  last=$(tail -n +"$start_r" "$R" | grep 'Received message' | tail -1 | cut -c13-24)
  if [ -n "$last" ]; then
    now=$(date +%s); lt=$(date -j -f '%H:%M:%S' "${last%.*}" +%s 2>/dev/null)
    gap=$(( now - lt ))
    [ "$gap" -gt 5 ] && echo "$(date +%T) GAP ${gap}s since last monitor message at $last"
  fi
  grep -q heartbeat_timeout "$P" && { echo "$(date +%T) heartbeat_timeout seen; stopping"; exit 0; }
  sleep 3
done
echo "$(date +%T) watch window ended"
