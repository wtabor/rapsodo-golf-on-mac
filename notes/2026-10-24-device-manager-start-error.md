# "The device manager could not start" (10/24/2026)

A user on an M2 MacBook Pro reported: "device manager could not start: no port
could be bound, or its bootstrap failed. Check device manager log." Their log
isn't available; this note records what was ruled out here.

## How the app starts the device manager (app.asar, 1.0.0)

- `server.start(resources/libs/grpc-env.yaml)` spawns
  `libs/windows/deviceManagerServer.exe` with `DEVICE_MANAGER_CONTROL=1` and
  `DEVICE_MANAGER_PREFERRED_PORT=0`. The server prints a control line with the
  port it bound; a gRPC resolver (`rapsodo-dm:///device-manager`) points the
  clients at `127.0.0.1:<that port>`. No client hardcodes 8080.
- The full error is `DeviceManagerStartError.FAILED` plus "It exited with code N
  before binding a port, check the device manager log": the server process died
  during bootstrap. Its stderr is inherited, so the "device manager log" is
  `~/Library/Logs/RapsodoGolf-Wine.log` (the launcher truncates it on each start).
- If the database is locked by another device manager (`filelock: ...`), the app
  retries for a while, then fails the same way. The app's own error box says
  "Close any other Rapsodo Golf window and restart the app."

## Tests

- **Port 8080 taken** (`nc -lk 127.0.0.1 8080`): the server bound
  `127.0.0.1:58165` instead and the app worked. Not the cause.
- **Main process killed, leftovers running** (renderer, crashpad survived): the
  relaunch still started the device manager. Not reproduced here, but leftovers
  are real after a crash.
- Same Rapsodo build as the update feed (`latest.yml` 1.0.0, released
  10/14/2026), so the user has the same binaries.

## Change

`play.sh` now runs `wineserver -k` on the prefix before launching (only when the
app isn't already running), so a crashed session can't leave a device manager
holding the database. The 8080/9090 warning added earlier the same day was wrong
and is removed.

Then, on request, `play.sh` also retries: it starts the app in the background,
watches the log for `DEBUG: start device manager` (ok) or `device manager server
start failed`, and on failure saves the log as `RapsodoGolf-Wine-failed.log`,
runs `wineserver -k`, and relaunches, up to 3 tries. Tested with a stub launcher
(fail, fail, ok → started; fail ×3 → error naming the log). Injecting a fake line
into the real log doesn't work: the launcher's fd isn't O_APPEND, so Wine
overwrites it.

## Open

The user's actual exit code is unknown. If it recurs, get their
`RapsodoGolf-Wine.log` and look for the `deviceManagerServer` JSON lines before
the failure.
