# Watching Rapsodo's app releases (10/30/2026)

Goal: learn about a new Rapsodo Golf PC app release, and whether it breaks this
project's fixes, before users' apps update themselves.

## How Rapsodo's app updates
- electron-updater, `provider: generic`. `resources/app-update.yml` says
  `https://storage.googleapis.com/super-app-clm-beta`, but main.js calls
  `setFeedURL({ provider: "generic", url: wse() })`, where `wse()` returns
  `updaterFeedURL: "https://storage.googleapis.com/super-app-clm-prod"` unless a channel
  is set (`updaterChannelURLs`: dev, test, stage).
- `latest.yml` there is public: `version`, `path` (the NSIS installer), `sha512`,
  `releaseDate`. On 10/30/2026: prod 1.0.0 (10/14/2026, the build installed here),
  test 0.6.0 (10/27/2026), dev 0.4.114 (10/27/2026), stage 0.5.0 (10/14/2026), beta
  0.0.197-0 (06/04/2026). Version numbers aren't comparable across channels.
- No webhook is possible (Rapsodo owns the bucket), so a daily poll it is.

## What was built
- `scripts/rapsodo-compat-check.py`: feed → download → sha512 → `7z x` the installer's
  `$PLUGINSDIR/app-64.7z` → the app → checks on copies of the stock files, using the same
  patch scripts 40 runs. Markdown report; exit 0 pass, 1 needs work, 2 couldn't run.
  Also `--installer`, `--app-dir` (an unpacked stock app) and `--feed-only`.
- `.github/workflows/rapsodo-app-watch.yml`: daily at 14:23 UTC and by hand. Skips a
  release that already has a `rapsodo-release` issue with its version + sha512 prefix in
  the title; otherwise runs the check and opens the issue (mentioning the owner). Never
  commits: a commit to main would make every user's play.sh download an update.
  GitHub turns scheduled workflows off in public repos after 60 days without
  repository activity
  ([docs](https://docs.github.com/actions/managing-workflow-runs/disabling-and-enabling-a-workflow)).

## Results
- Prod 1.0.0: every check passes; feed to report in ~12 s on the owner's Mac.
- A fake release (libzmq byte flipped, a second NETRESET site, `Pae = 2e3`, MediaMTX
  `v1.18.0`, `download game fin`): all 5 caught, exit 1. A junk installer: exit 2.
- Workflow steps run locally in order with a stand-in `gh`: first run opens
  "…1.0.0 (prod, sha512 yw1XMiureLhZ): every fix still applies"; a second run skips
  without downloading; dry run writes only the summary; the test channel opened
  "…0.6.0 (test, …): needs work" before the Fix 7 change below and "every fix still
  applies" after it; no 7-Zip, or a failing `gh issue list`, fails the job and opens no
  issue.

## Test 0.6.0 is the likely next release; Fix 7 now handles it
The first run failed Fix 7's game check: `patch_app_polls.py` looked for the literal
`Pae = 1e3, Bae = () => {`, and 0.6.0 has `due = 1e3, uM = 3, ...`. The minified names
changed and so did the code around them: when the game's `cmd /c` wrapper exits, 0.6.0
still closes the game at once (`game child exited`), and also logs whether the game is
still in the task list; the `tasklist` poll is now a fallback that needs `uM` = 3
consecutive misses (errors aren't counted). So a normal quit is still noticed at once,
and 60 s stays right. (A first reading of this said the opposite; the review caught it.)

`patch_app_polls.py` now finds the timer by structure: the `setInterval(…, <var>)` right
after the app's only "DEBUG: game is running" log, then that variable's one
`<var> = 1e3,` within the 20 KB before it. Tested on stock 1.0.0 and 0.6.0 (patch,
second run "already patched", `--revert` back to byte-identical stock) and on the
installed, already-patched 1.0.0 asar ("already patched"). With that, 0.6.0 passes
every check.

## Also found
- 40-apply-patches.sh keeps the first `libzmq.dll.orig` forever and swaps our rebuilt
  4.3.5 in without checking the stock DLL. If Rapsodo ships a different libzmq, 40 would
  replace it with ours, and games would be compared against the old hash. The watch
  flags that as a Fix 1 failure before users get the release; 40 itself is unchanged.
- The firewall module (`netsh advfirewall`, PowerShell `Get-NetFirewallRule`) is in
  1.0.0 too, and runs under Wine (`process.platform` is `win32`); not new in 0.6.0.
- Review fixes (10/30/2026): the check now also confirms the app's userData name
  (`super-app-clm`, so 47's MediaMTX folder) and its games path (`Rapsodo\SuperApp\games`,
  hardcoded in 40, 45 and play.sh); reads package.json from the asar index; clears a
  reused `--workdir`; accepts `$` in minified names; cleans up on SIGTERM; refuses `7za`
  (it can't read NSIS). The workflow fails, instead of re-checking, when listing issues
  fails.
- Not covered: game updates (they come through the signed-in app's game API), anything
  that needs Wine, the games or the monitor to show.
