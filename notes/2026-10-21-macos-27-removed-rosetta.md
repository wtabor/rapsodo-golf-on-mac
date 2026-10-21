# 10/21/2026 — macOS 27.0.1 update removed Rosetta 2; the app stopped opening

## Symptom
After updating to macOS 27.0.1 (build 26A434), opening
`/Applications/Rapsodo Golf (Mac Port).app` did nothing visible.

## Cause
Rosetta 2 was gone: `arch -x86_64 /usr/bin/true` → `Bad CPU type in executable`,
`pkgutil --pkgs` lists no Rosetta package, and `/Library/Apple/usr/libexec/oah/`
holds only `RosettaLinux`. Gcenx's Wine is x86_64, so every Wine binary failed;
`RapsodoGolf-heal.log` showed `wine: Bad CPU type in executable`.

The update also reset the Automation permission for iTerm: the launcher's
AppleScript to iTerm hung on a fresh prompt. And `~/Library/Application
Support/com.apple.TCC/TCC.db` can no longer be read from a normal shell.

## Fix
- `softwareupdate --install-rosetta --agree-to-license` (the owner ran it), then allow
  the Automation prompt again.
- `play.sh` now checks Rosetta first and keeps its iTerm window open with that
  command if it's missing; the launcher's alert names the right Automation entry
  (`bash` → iTerm).

## Note
macOS 27 still runs Intel apps; general Rosetta support ends with macOS 28 (see
`notes/2026-10-19-next-steps.md`, "Rosetta deadline").
