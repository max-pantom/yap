// Serves the launch film at http://127.0.0.1:3010 and saves exported files into ./out (PUT /out/<name>).
import { createServer } from "node:http";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { join, extname, basename, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const types = { ".html": "text/html", ".woff2": "font/woff2", ".mp4": "video/mp4", ".png": "image/png", ".json": "application/json", ".wav": "audio/wav" };

const port = Number(process.env.PORT) || 3010;

createServer(async (req, res) => {
  const path = decodeURIComponent(new URL(req.url, "http://x").pathname);
  if (req.method === "PUT") {
    const name = basename(path);
    // Films and posters go to out/; the sound editor saves the soundtrack and its settings to audio/.
    const ok = (path.startsWith("/out/") && /\.(mp4|png)$/.test(name)) || ["/audio/mix.wav", "/audio/mix-settings.json"].includes(path);
    if (!ok) { res.writeHead(400).end(); return; }
    const dir = path.startsWith("/out/") ? "out" : "audio";
    const chunks = [];
    for await (const c of req) chunks.push(c);
    await mkdir(join(root, dir), { recursive: true });
    const data = Buffer.concat(chunks);
    await writeFile(join(root, dir, name), data);
    console.log(`saved ${dir}/${name} (${data.length} bytes)`);
    res.writeHead(201).end(`saved ${data.length} bytes`);
    return;
  }
  const file = join(root, path === "/" ? "launch.html" : path === "/sound" ? "sound.html" : path);
  if (!file.startsWith(root)) { res.writeHead(403).end(); return; }
  try {
    const body = await readFile(file);
    res.writeHead(200, { "content-type": types[extname(file)] || "application/octet-stream", "cache-control": "no-store" }).end(body);
  } catch { res.writeHead(404).end(); }
}).listen(port, "127.0.0.1", () => console.log(`launch film at http://127.0.0.1:${port}`));
