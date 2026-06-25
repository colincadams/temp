// Assembles the web assets into ./www, which Capacitor copies into the native
// app (capacitor.config.json -> webDir). The same files are also served as-is
// from the repo root for the GitHub Pages web build, so nothing is duplicated
// in source control — www/ is generated and git-ignored.
import { cp, rm, mkdir } from "node:fs/promises";

const OUT = "www";
const ASSETS = ["index.html", "app.css", "manifest.webmanifest", "sw.js", "src", "icons"];

await rm(OUT, { recursive: true, force: true });
await mkdir(OUT, { recursive: true });
for (const asset of ASSETS) {
  await cp(asset, `${OUT}/${asset}`, { recursive: true });
}
console.log(`Copied ${ASSETS.length} web assets into ${OUT}/`);
