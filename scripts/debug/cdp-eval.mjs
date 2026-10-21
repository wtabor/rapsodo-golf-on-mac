// Usage: node scripts/debug/cdp-eval.mjs '<js expression>'  — evaluates in the app's renderer page.
const expr = process.argv[2];
const targets = await (await fetch("http://127.0.0.1:9222/json")).json();
const page = targets.find((t) => t.type === "page");
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
ws.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression: expr, awaitPromise: true, returnByValue: true } }));
ws.addEventListener("message", (m) => {
  const msg = JSON.parse(m.data);
  if (msg.id !== 1) return;
  const r = msg.result;
  console.log(JSON.stringify(r.exceptionDetails ?? r.result.value ?? r.result, null, 1).slice(0, 6000));
  ws.close();
  process.exit(0);
});
setTimeout(() => { console.log("timeout"); process.exit(1); }, 20000);
