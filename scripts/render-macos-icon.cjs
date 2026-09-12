#!/usr/bin/env node
// Render the existing vector artwork without flattening its transparent corners.
// Requires sharp (install outside the repo and provide its node_modules via NODE_PATH).
const path = require('node:path');
const fs = require('node:fs/promises');
const sharp = require('sharp');

async function main() {
  const directory = path.resolve(__dirname,
    '../packages/screen_recorder/macos/Runner/Assets.xcassets/AppIcon.appiconset');
  const source = await fs.readFile(path.join(directory, 'source.svg'));
  for (const size of [16, 32, 64, 128, 256, 512, 1024]) {
    const png = await sharp(source, { density: 288 })
      .resize(size, size).ensureAlpha().png().toBuffer();
    const { data, info } = await sharp(png).raw().toBuffer({ resolveWithObject: true });
    const corners = [0, size - 1, size * (size - 1), size * size - 1];
    // The rounded edge can cover a fraction of a corner pixel at 16px.
    const maxCornerAlpha = size === 16 ? 20 : 0;
    if (info.channels !== 4 || corners.some(pixel => data[pixel * 4 + 3] > maxCornerAlpha)) {
      throw new Error(`Icon ${size}: expected transparent corners`);
    }
    await fs.writeFile(path.join(directory, `app_icon_${size}.png`), png);
    console.log(`Rendered ${size}x${size} with transparent corners`);
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
