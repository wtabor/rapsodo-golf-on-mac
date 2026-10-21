// Usage: node scripts/debug/cdp-shot.mjs out.png  — screenshot of the app's renderer page.
import { writeFileSync } from "node:fs";
const targets = await (await fetch("http://127.0.0.1:9222/json")).json();
const ws = new WebSocket(targets.find((t) => t.type === "page").webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
ws.send(JSON.stringify({ id: 1, method: "Page.captureScreenshot", params: { format: "png" } }));
ws.addEventListener("message", (m) => {
  const msg = JSON.parse(m.data);
  if (msg.id !== 1) return;
  writeFileSync(process.argv[2], Buffer.from(msg.result.data, "base64"));
  process.exit(0);
});
setTimeout(() => process.exit(1), 20000);
