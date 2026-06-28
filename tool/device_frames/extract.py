"""Extract Apple Design Resources device bezels into Slipreel assets.

Pure extractor (`screen_rect`) is unit-tested. The download/mount/main
path requires macOS + network + accepting Apple's SLA and is run by a
developer (see README). Output: assets/device_frames/<id>/<color>-<orient>.png
plus assets/device_frames/manifest.json.

LICENSE: Apple Design Resources may not be embedded/redistributed in a
product without Apple's permission. Running this and shipping the output
is gated on Apple sign-off. See docs/superpowers/specs/2026-06-21-device-frames-design.md.
"""
import json
import os
import re
import subprocess
import sys
from PIL import Image, ImageDraw

# Apple bezel DMGs (public CDN). Extend as the catalog grows.
DMG_URLS = [
    "https://devimages-cdn.apple.com/design/resources/download/Bezel-iPhone-16.dmg",
    "https://devimages-cdn.apple.com/design/resources/download/Bezel-iPhone-17.dmg",
    "https://devimages-cdn.apple.com/design/resources/download/Bezel-iPhone-14.dmg",
    "https://devimages-cdn.apple.com/design/resources/download/Bezel-iPad-Pro-(M5).dmg",
    "https://devimages-cdn.apple.com/design/resources/download/Bezel-iPad-Air-(M4).dmg",
    "https://devimages-cdn.apple.com/design/resources/download/Bezel-iPad-mini-(A17-Pro).dmg",
    "https://devimages-cdn.apple.com/design/resources/download/Bezel-iPad-(A16).dmg",
]


def screen_rect(png_path):
    """Find the interior transparent screen cutout in a bezel PNG.

    Returns bezel size, screen bbox (px), and normalized screenRect.
    Algorithm: flood-fill transparent pixels from the border to mark the
    OUTSIDE; the remaining transparent region is the screen cutout.
    """
    im = Image.open(png_path).convert("RGBA")
    w, h = im.size
    alpha = im.split()[3]               # 0 = transparent, 255 = opaque
    work = alpha.copy()
    px = alpha.load()
    seeds = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1),
             (w // 2, 0), (w // 2, h - 1), (0, h // 2), (w - 1, h // 2)]
    for sx, sy in seeds:
        if px[sx, sy] == 0:
            ImageDraw.floodfill(work, (sx, sy), 200, thresh=0)
    wpx = work.load()
    xs0, ys0, xs1, ys1 = w, h, -1, -1
    for y in range(h):
        for x in range(w):
            if wpx[x, y] == 0:          # transparent and not reached -> screen
                if x < xs0:
                    xs0 = x
                if y < ys0:
                    ys0 = y
                if x > xs1:
                    xs1 = x
                if y > ys1:
                    ys1 = y
    if xs1 < 0:
        raise ValueError(f"no interior screen cutout in {png_path}")
    sw, sh = xs1 - xs0 + 1, ys1 - ys0 + 1

    # Screen corner radius: inset of the rounded cutout corner (median of the
    # four corners), normalized to bezel WIDTH. The video is clipped to this
    # radius so its square corners don't bleed through the transparent cutout.
    def first0_down(col):
        for y in range(ys0, ys1 + 1):
            if wpx[col, y] == 0:
                return y
        return ys0

    def first0_right(row):
        for x in range(xs0, xs1 + 1):
            if wpx[x, row] == 0:
                return x
        return xs0

    def last0_up(col):
        for y in range(ys1, ys0 - 1, -1):
            if wpx[col, y] == 0:
                return y
        return ys1

    def last0_left(row):
        for x in range(xs1, xs0 - 1, -1):
            if wpx[x, row] == 0:
                return x
        return xs1

    r_tl = ((first0_down(xs0) - ys0) + (first0_right(ys0) - xs0)) / 2
    r_tr = ((first0_down(xs1) - ys0) + (xs1 - last0_left(ys0))) / 2
    r_bl = ((ys1 - last0_up(xs0)) + (first0_right(ys1) - xs0)) / 2
    r_br = ((ys1 - last0_up(xs1)) + (xs1 - last0_left(ys1))) / 2
    radii = sorted([r_tl, r_tr, r_bl, r_br])
    radius = (radii[1] + radii[2]) / 2  # median of 4

    return {
        "bezel_w": w, "bezel_h": h,
        "screen": {"w": sw, "h": sh, "x": xs0, "y": ys0},
        "screenRect": {
            "l": xs0 / w, "t": ys0 / h, "r": (xs1 + 1) / w, "b": (ys1 + 1) / h,
        },
        "screenCornerRadius": round(radius / w, 5),
    }


def slugify(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def parse_filename(name):
    """`<Device> - <Color> - <Orientation>.png` -> (device, color, orient)."""
    base = name[:-4] if name.lower().endswith(".png") else name
    parts = [p.strip() for p in base.split(" - ")]
    if len(parts) != 3:
        return None
    device, color, orient = parts
    return device, color, orient.lower()


def mount(dmg_path):
    mnt = "/tmp/df_mnt_" + slugify(os.path.basename(dmg_path))
    subprocess.run(
        ["hdiutil", "attach", dmg_path, "-nobrowse", "-readonly", "-mountpoint", mnt],
        input=b"Y\n" * 50, check=True,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return mnt


def main():
    out_root = os.path.join("packages", "screen_recorder", "assets", "device_frames")
    os.makedirs(out_root, exist_ok=True)
    cache = "/tmp/df_dmgs"
    os.makedirs(cache, exist_ok=True)

    entries = {}  # id -> entry dict
    for url in DMG_URLS:
        dmg = os.path.join(cache, os.path.basename(url))
        if not os.path.exists(dmg):
            print(f"downloading {url}")
            subprocess.run(["curl", "-sL", "-o", dmg, url], check=True)
        mnt = mount(dmg)
        try:
            png_dir = os.path.join(mnt, "PNG")
            for dirpath, _dirs, files in os.walk(png_dir):
                for fn in files:
                    if not fn.lower().endswith(".png"):
                        continue
                    parsed = parse_filename(fn)
                    if parsed is None:
                        continue
                    device, color, orient = parsed
                    if orient not in ("portrait", "landscape"):
                        continue
                    src = os.path.join(dirpath, fn)
                    geom = screen_rect(src)
                    dev_id = slugify(device)
                    color_id = slugify(color)
                    dst_dir = os.path.join(out_root, dev_id)
                    os.makedirs(dst_dir, exist_ok=True)
                    dst_name = f"{color_id}-{orient}.png"
                    # Recompress (optional pngquant if present).
                    Image.open(src).convert("RGBA").save(os.path.join(dst_dir, dst_name))
                    asset = f"assets/device_frames/{dev_id}/{dst_name}"

                    entry = entries.setdefault(dev_id, {
                        "id": dev_id, "family": device,
                        "kind": "tablet" if "ipad" in dev_id else "phone",
                        "screen": None, "colors": {},
                    })
                    cv = entry["colors"].setdefault(
                        color_id, {"id": color_id, "name": color, "swatch": "#1d1d1f"})
                    cv[orient] = {
                        "asset": asset,
                        "bezel": {"w": geom["bezel_w"], "h": geom["bezel_h"]},
                        "screenRect": geom["screenRect"],
                        "screenCornerRadius": geom["screenCornerRadius"],
                    }
                    # Native portrait screen res defines the entry screen size.
                    if orient == "portrait":
                        entry["screen"] = {"w": geom["screen"]["w"], "h": geom["screen"]["h"]}
        finally:
            subprocess.run(["hdiutil", "detach", mnt, "-quiet"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Flatten colors dict -> list; drop incomplete variants/entries.
    manifest = {"entries": []}
    for entry in entries.values():
        if entry["screen"] is None:
            continue
        colors = [c for c in entry["colors"].values()
                  if "portrait" in c and "landscape" in c]
        if not colors:
            continue
        entry["colors"] = colors
        manifest["entries"].append(entry)

    with open(os.path.join(out_root, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"wrote {len(manifest['entries'])} device entries to {out_root}/manifest.json")


if __name__ == "__main__":
    sys.exit(main())
