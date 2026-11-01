// Minimal Chrome DevTools Protocol client for scripts/test.sh (tiers 3 and 4). The app
// must have been started with --remote-debugging-port (launcher.c does that when
// RGM_REMOTE_DEBUGGING_PORT is set). Needs Node 22+ (built-in fetch and WebSocket).
//
// Usage: node cdp.mjs [--port N] [--timeout S] COMMAND ...
//   wait                  wait for the app's page; print its URL
//   eval EXPR             evaluate EXPR in the page (promises awaited); print the value as JSON
//   call FN [ARG...]      evaluate (FN)(ARG...) with the string ARGs passed as JSON
//                         (no shell or JS quoting trouble with Windows paths)
//   close                 ask the page to close its window (window.close()), don't wait
// Exit status: 0 ok, 1 exception or timeout (message on stderr), 2 usage.
const args = process.argv.slice(2);
let port = 9222;
let timeout = 30;
while (args[0]?.startsWith("--")) {
  const opt = args.shift();
  if (opt === "--port") port = Number(args.shift());
  else if (opt === "--timeout") timeout = Number(args.shift());
  else usage();
}
const cmd = args.shift();
if (!["wait", "eval", "call", "close"].includes(cmd)) usage();
if (typeof WebSocket === "undefined") die("this Node has no built-in WebSocket (Node 22 or newer needed)");
setTimeout(() => die(`timeout after ${timeout}s`), timeout * 1000).unref?.();

function usage() {
  console.error("usage: node cdp.mjs [--port N] [--timeout S] wait|eval EXPR|call FN [ARG...]|close");
  process.exit(2);
}
function die(msg) {
  console.error(`cdp: ${msg}`);
  process.exit(1);
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// The app's page (not a DevTools or service-worker target).
async function page() {
  for (;;) {
    try {
      const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
      const p = targets.find((t) => t.type === "page" && !t.url.startsWith("devtools:") && t.webSocketDebuggerUrl);
      if (p) return p;
    } catch {
      // not listening yet
    }
    await sleep(1000);
  }
}

async function evaluate(expression) {
  const p = await page();
  const ws = new WebSocket(p.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", () => reject(new Error("WebSocket error")), { once: true });
  });
  const reply = new Promise((resolve) => {
    ws.addEventListener("message", (m) => {
      const msg = JSON.parse(m.data);
      if (msg.id === 1) resolve(msg);
    });
  });
  ws.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression, awaitPromise: true, returnByValue: true } }));
  const msg = await reply;
  ws.close();
  if (msg.error) die(msg.error.message);
  const r = msg.result;
  if (r.exceptionDetails) die(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
  return r.result.value;
}

if (cmd === "wait") {
  console.log((await page()).url);
} else if (cmd === "eval") {
  console.log(JSON.stringify(await evaluate(args[0] ?? "undefined")));
} else if (cmd === "call") {
  const fn = args.shift() ?? usage();
  console.log(JSON.stringify(await evaluate(`(${fn})(${args.map((a) => JSON.stringify(a)).join(",")})`)));
} else if (cmd === "close") {
  const p = await page();
  const ws = new WebSocket(p.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener("open", r, { once: true }));
  ws.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression: "setTimeout(() => window.close(), 100); true" } }));
  await sleep(500);
  ws.close();
  console.log("close requested");
}
process.exit(0);
