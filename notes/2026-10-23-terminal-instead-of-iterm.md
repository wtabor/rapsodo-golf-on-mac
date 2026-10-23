# 10/23/2026 — Launching from Terminal.app instead of iTerm: mDNS blocked

## Question
Is iTerm required, or does Apple's Terminal work as the app that lends Local
Network permission to Wine?

## Test
- Rapsodo app closed, USB link running, monitor on.
- `osascript -e 'tell application "Terminal" to do script ".../scripts/play.sh"'`
- `play.sh` ran normally: fixes checked, `Monitor link up: 192.168.36.12`, app
  started (`RapsodoGolf.exe` child of the Terminal session).

## Result
The app never found the monitor. `~/Library/Logs/RapsodoGolf-Wine.log`, every scan:

    [v3api] [warning] V3ScanTCPDevices: mDNS scan did not start (101)
    Error: 13999 undefined: Could not start the mDNS scan

Same symptom as launching Wine from Finder. No Local Network prompt appeared for
Terminal. Whether Terminal is listed (and off) under System Settings → Privacy &
Security → Local Network wasn't checked.

## Conclusion
Keep iTerm as the launcher. Terminal could still work if it's listed in Local
Network and switched on; untested.
