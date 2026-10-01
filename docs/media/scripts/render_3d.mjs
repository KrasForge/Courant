#!/usr/bin/env node
// Headless renders of docs/media/3d/*.glb into docs/media/images/.
//
//   cd docs/media/scripts && npm install && node render_3d.mjs
//
// Needs Playwright with a Chromium build (PLAYWRIGHT_BROWSERS_PATH or the
// default cache). Serves this directory on a local port so the import map
// can load three.js from node_modules.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const media = path.resolve(here, '..');
const require = createRequire(import.meta.url);
let chromium;
try { ({ chromium } = require('playwright')); } catch { ({ chromium } = require('/opt/node22/lib/node_modules/playwright')); }

const VIEWS = [
  // [output, model, azimuth, elevation, zoom, w, h]
  ['stack_hero.png', '3d/courant_stack.glb', -32, 30, 1.25, 1800, 1100],
  ['stack_side.png', '3d/courant_stack.glb', -78, 8, 1.35, 1800, 900],
  ['mainboard_3d.png', '3d/courant_mainboard.glb', -20, 48, 1.3, 1800, 1150],
  ['panel_3d.png', '3d/courant_panel.glb', -18, 42, 1.3, 1800, 1150],
];

const types = { '.html': 'text/html', '.js': 'text/javascript', '.glb': 'model/gltf-binary', '.png': 'image/png' };
const server = http.createServer((req, res) => {
  const url = decodeURIComponent(req.url.split('?')[0]);
  const file = url.startsWith('/media/') ? path.join(media, url.slice(7)) : path.join(here, url);
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream' });
    res.end(data);
  });
}).listen(0);
const port = server.address().port;

const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
for (const [out, model, az, el, zoom, w, h] of VIEWS) {
  const page = await browser.newPage({ viewport: { width: w, height: h } });
  page.on('console', (m) => { if (m.type() === 'error') console.error(m.text()); });
  await page.goto(`http://127.0.0.1:${port}/viewer.html?model=/media/${model}&az=${az}&el=${el}&zoom=${zoom}&w=${w}&h=${h}`);
  await page.waitForFunction(() => document.title === 'ready', null, { timeout: 180000 });
  const file = path.join(media, 'images', out);
  await page.locator('canvas').screenshot({ path: file, omitBackground: true });
  console.log('wrote', out);
  await page.close();
}
await browser.close();
server.close();
