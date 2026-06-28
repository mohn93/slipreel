# Add iPhone 14 Family Device Frames — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add iPhone 14 / 14 Plus / 14 Pro / 14 Pro Max device frames so 1170×2532 (and sibling) recordings get a real perfect-match bezel.

**Architecture:** Generate PNGs + geometry from Apple's `Bezel-iPhone-14.dmg` using the existing extractor logic, **additively** (existing assets/manifest untouched), append 4 entries to the end of the catalog, wire pubspec, and add matcher tests.

**Tech Stack:** Python 3 + Pillow (extractor), Dart/Flutter (catalog + tests), macOS `hdiutil`/`curl`.

## Global Constraints

- Additive only: existing device PNGs and `manifest.json` entries must remain unchanged; append new entries to the END of `entries`.
- New entry order (appended): `iphone-14`, `iphone-14-plus`, `iphone-14-pro`, `iphone-14-pro-max`.
- `kind` = `phone`; `swatch` = `#1d1d1f` (extractor default); ids via `slugify(device)`.
- Apple ADR art — same class as the existing sign-off (PR #20).
- Do NOT run `dart format` on existing files; match style by hand.
- Verify with `flutter analyze` + `flutter test` (per package); no `dart format`.

---

### Task 1: Extract & stage the iPhone 14 family assets and append the manifest

**Files:**
- Create: `packages/screen_recorder/assets/device_frames/iphone-14/`, `iphone-14-plus/`, `iphone-14-pro/`, `iphone-14-pro-max/` (PNGs)
- Modify: `packages/screen_recorder/assets/device_frames/manifest.json` (append 4 entries)
- Scratch: `<scratchpad>/extract_iphone14.py` (driver, not committed)

**Interfaces:**
- Consumes: `tool/device_frames/extract.py` functions `screen_rect`, `parse_filename`, `mount`, `slugify`.
- Produces: 4 manifest entries with shape `{id, family, kind, screen:{w,h}, colors:[{id,name,swatch,portrait,landscape}]}` where each orientation = `{asset, bezel:{w,h}, screenRect:{l,t,r,b}, screenCornerRadius}`. `iphone-14` has `screen:{w:1170,h:2532}`.

- [ ] **Step 1: Install Pillow (extractor dependency)**

Run: `python3 -m pip install --user Pillow 2>&1 | tail -2 && python3 -c "from PIL import Image, ImageDraw; print('PIL ok')"`
Expected: `PIL ok`. (If `pip` is blocked, use `python3 -m pip install --break-system-packages Pillow` or a venv.)

- [ ] **Step 2: Write the scratch extraction driver**

Create `<scratchpad>/extract_iphone14.py` (use the real scratchpad path):

```python
import json, os, subprocess, sys
REPO = "/Users/mohn93/Desktop/side_projects/screenflow_studio"
os.chdir(REPO)
sys.path.insert(0, os.path.join(REPO, "tool", "device_frames"))
from extract import screen_rect, parse_filename, mount, slugify  # reuse tested logic
from PIL import Image

URL = "https://devimages-cdn.apple.com/design/resources/download/Bezel-iPhone-14.dmg"
out_root = "packages/screen_recorder/assets/device_frames"
cache = "/tmp/df_dmgs"; os.makedirs(cache, exist_ok=True)
dmg = os.path.join(cache, os.path.basename(URL))
if not os.path.exists(dmg):
    print("downloading", URL)
    subprocess.run(["curl", "-sL", "-o", dmg, URL], check=True)

mnt = mount(dmg)
entries = {}
try:
    for dirpath, _dirs, files in os.walk(os.path.join(mnt, "PNG")):
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
            dev_id = slugify(device); color_id = slugify(color)
            dst_dir = os.path.join(out_root, dev_id); os.makedirs(dst_dir, exist_ok=True)
            dst_name = f"{color_id}-{orient}.png"
            Image.open(src).convert("RGBA").save(os.path.join(dst_dir, dst_name))
            asset = f"assets/device_frames/{dev_id}/{dst_name}"
            entry = entries.setdefault(dev_id, {
                "id": dev_id, "family": device, "kind": "phone",
                "screen": None, "colors": {}})
            cv = entry["colors"].setdefault(
                color_id, {"id": color_id, "name": color, "swatch": "#1d1d1f"})
            cv[orient] = {
                "asset": asset,
                "bezel": {"w": geom["bezel_w"], "h": geom["bezel_h"]},
                "screenRect": geom["screenRect"],
                "screenCornerRadius": geom["screenCornerRadius"],
            }
            if orient == "portrait":
                entry["screen"] = {"w": geom["screen"]["w"], "h": geom["screen"]["h"]}
finally:
    subprocess.run(["hdiutil", "detach", mnt, "-quiet"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

# Flatten + drop incomplete variants/entries (mirrors extract.main()).
new_entries = []
for e in entries.values():
    if e["screen"] is None:
        continue
    cols = [c for c in e["colors"].values() if "portrait" in c and "landscape" in c]
    if not cols:
        continue
    e["colors"] = cols
    new_entries.append(e)

man_path = os.path.join(out_root, "manifest.json")
man = json.load(open(man_path))
existing_ids = {e["id"] for e in man["entries"]}
for e in sorted(new_entries, key=lambda x: x["id"]):
    if e["id"] in existing_ids:
        print("SKIP existing", e["id"]); continue
    man["entries"].append(e)
    print("ADDED", e["id"], e["screen"], "colors:", len(e["colors"]))
with open(man_path, "w") as f:
    json.dump(man, f, indent=2)
print("total entries:", len(man["entries"]))
```

- [ ] **Step 3: Run the driver**

Run: `python3 <scratchpad>/extract_iphone14.py`
Expected: lines `ADDED iphone-14 {'w': 1170, 'h': 2532} colors: N`, plus `iphone-14-plus`, `iphone-14-pro`, `iphone-14-pro-max`; `total entries: 18`. (The DMG download is a few hundred MB on first run.)

- [ ] **Step 4: Verify the manifest diff is purely additive + geometry is sane**

Run:
```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git diff --stat packages/screen_recorder/assets/device_frames/manifest.json
python3 - <<'PY'
import json
m=json.load(open("packages/screen_recorder/assets/device_frames/manifest.json"))
for e in m["entries"]:
    if e["id"].startswith("iphone-14"):
        s=e["screen"]; p=e["colors"][0]["portrait"]; r=p["screenRect"]; b=p["bezel"]
        cw=(r["r"]-r["l"])*b["w"]; ch=(r["b"]-r["t"])*b["h"]
        print(e["id"], f"screen={s['w']}x{s['h']}", f"cutoutPx={cw:.0f}x{ch:.0f}",
              "aspect_ok=", abs((cw/ch)-(s['w']/s['h']))<0.01)
PY
git diff packages/screen_recorder/assets/device_frames/manifest.json | grep -E '^[-+]' | grep -v '^[-+][-+]' | grep '^-' | head
```
Expected: `iphone-14` shows `screen=1170x2532`; all four `aspect_ok= True`; the last command (lines REMOVED from manifest) prints **nothing** (purely additive). If removals appear, the json re-dump reformatted existing entries — STOP and instead splice the 4 new entry objects as text before the final `]` so existing bytes are untouched.

- [ ] **Step 5: Confirm new PNGs exist and are referenced**

Run:
```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
ls packages/screen_recorder/assets/device_frames/ | grep iphone-14
du -sh packages/screen_recorder/assets/device_frames/iphone-14*
python3 - <<'PY'
import json, os
m=json.load(open("packages/screen_recorder/assets/device_frames/manifest.json"))
missing=[]
for e in m["entries"]:
    if not e["id"].startswith("iphone-14"): continue
    for c in e["colors"]:
        for o in ("portrait","landscape"):
            p="packages/screen_recorder/assets/device_frames/"+c[o]["asset"].split("assets/device_frames/")[1] if False else "packages/screen_recorder/"+c[o]["asset"]
            if not os.path.exists(p): missing.append(p)
print("missing:", missing)
PY
```
Expected: 4 `iphone-14*` dirs listed; `missing: []`. Note the total size (for the report).

- [ ] **Step 6: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder/assets/device_frames/iphone-14 \
        packages/screen_recorder/assets/device_frames/iphone-14-plus \
        packages/screen_recorder/assets/device_frames/iphone-14-pro \
        packages/screen_recorder/assets/device_frames/iphone-14-pro-max \
        packages/screen_recorder/assets/device_frames/manifest.json
git commit -m "feat(device-frame): add iPhone 14 family bezel assets (1170x2532 + siblings)"
```

---

### Task 2: Wire pubspec asset declarations and the extractor URL

**Files:**
- Modify: `packages/screen_recorder/pubspec.yaml` (after line `- assets/device_frames/iphone-air/`, before the ipad entries)
- Modify: `tool/device_frames/extract.py` (`DMG_URLS`)

**Interfaces:** none.

- [ ] **Step 1: Add the 4 asset dirs to pubspec.yaml**

In `packages/screen_recorder/pubspec.yaml`, insert after the `- assets/device_frames/iphone-air/` line:
```yaml
    - assets/device_frames/iphone-14/
    - assets/device_frames/iphone-14-plus/
    - assets/device_frames/iphone-14-pro/
    - assets/device_frames/iphone-14-pro-max/
```

- [ ] **Step 2: Add the DMG URL to the extractor (documents the source)**

In `tool/device_frames/extract.py`, add to the `DMG_URLS` list (after the `Bezel-iPhone-17.dmg` line):
```python
    "https://devimages-cdn.apple.com/design/resources/download/Bezel-iPhone-14.dmg",
```

- [ ] **Step 3: Verify pub get resolves the new assets**

Run: `cd packages/screen_recorder && flutter pub get 2>&1 | tail -2`
Expected: `Got dependencies!` (no asset-path errors).

- [ ] **Step 4: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/screen_recorder/pubspec.yaml tool/device_frames/extract.py
git commit -m "feat(device-frame): declare iPhone 14 assets in pubspec; add DMG url to extractor"
```

---

### Task 3: Matcher tests for the iPhone 14 family

**Files:**
- Modify: `packages/slipreel_engine/test/rendering/device_frame_matcher_test.dart`

**Interfaces:**
- Consumes: `DeviceFrameCatalog.parse`, `autoSelectDeviceFrame`, `deviceMatchesRecording`, `perfectMatches`, `recordingFormFactor`, `deviceFrameCompatible` from `package:slipreel_engine/...`.

- [ ] **Step 1: Add the failing test**

Append to `packages/slipreel_engine/test/rendering/device_frame_matcher_test.dart` (inside `void main()`), using a small in-memory catalog with an iphone-16 (1179×2556) BEFORE iphone-14 (1170×2532) to prove append-order preserves existing auto-selects:

```dart
  group('iPhone 14 family (1170x2532)', () {
    final catalog = DeviceFrameCatalog.parse('''
{"entries":[
  {"id":"iphone-16","family":"iPhone 16","kind":"phone",
   "screen":{"w":1179,"h":2556},
   "colors":[{"id":"black","name":"Black","swatch":"#1d1d1f",
     "portrait":{"asset":"a","bezel":{"w":1359,"h":2736},
       "screenRect":{"l":0.06,"t":0.03,"r":0.94,"b":0.97},"screenCornerRadius":0.15},
     "landscape":{"asset":"b","bezel":{"w":2736,"h":1359},
       "screenRect":{"l":0.03,"t":0.06,"r":0.97,"b":0.94},"screenCornerRadius":0.07}}]},
  {"id":"iphone-14","family":"iPhone 14","kind":"phone",
   "screen":{"w":1170,"h":2532},
   "colors":[{"id":"blue","name":"Blue","swatch":"#1d1d1f",
     "portrait":{"asset":"c","bezel":{"w":1350,"h":2760},
       "screenRect":{"l":0.05,"t":0.03,"r":0.95,"b":0.97},"screenCornerRadius":0.15},
     "landscape":{"asset":"d","bezel":{"w":2760,"h":1350},
       "screenRect":{"l":0.03,"t":0.05,"r":0.97,"b":0.95},"screenCornerRadius":0.07}}]}
]}''');

    test('1170x2532 perfect-matches and auto-selects iphone-14', () {
      const rec = Size(1170, 2532);
      final iphone14 = catalog.entryById('iphone-14')!;
      expect(deviceMatchesRecording(iphone14, rec), isTrue);
      expect(perfectMatches(catalog, rec).map((e) => e.id), ['iphone-14']);
      expect(autoSelectDeviceFrame(catalog, rec)?.id, 'iphone-14');
    });

    test('1170x2532 is a phone form factor, compatible with iphone-14', () {
      const rec = Size(1170, 2532);
      expect(recordingFormFactor(rec), RecordingFormFactor.phone);
      expect(deviceFrameCompatible(catalog.entryById('iphone-14')!, rec), isTrue);
    });

    test('appending iphone-14 does not steal 1179x2556 from iphone-16', () {
      // Shared-resolution guard: the earlier catalog entry still wins.
      expect(autoSelectDeviceFrame(catalog, const Size(1179, 2556))?.id, 'iphone-16');
    });
  });
```

- [ ] **Step 2: Run the test to verify it FAILS before the import/symbols are present**

Run: `cd packages/slipreel_engine && flutter test test/rendering/device_frame_matcher_test.dart 2>&1 | tail -15`
Expected: FAILS only if a needed symbol/import is missing. If the file already imports the matcher + `device_frame.dart` and `RecordingFormFactor`, the test will instead PASS immediately (the production code already supports this) — that is acceptable: this is a data-addition feature, so a green matcher test against an in-memory catalog confirms the contract. If it fails to COMPILE (missing import for `DeviceFrameCatalog`/`Size`), add the imports `package:flutter/painting.dart` (Size) and `package:slipreel_engine/models/device_frame.dart`, then continue.

- [ ] **Step 3: Ensure imports are present**

Confirm the test file imports (add any missing):
```dart
import 'package:flutter/painting.dart';
import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/rendering/device_frame_matcher.dart';
```

- [ ] **Step 4: Run the test to verify it PASSES**

Run: `cd packages/slipreel_engine && flutter test test/rendering/device_frame_matcher_test.dart 2>&1 | tail -6`
Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/slipreel_engine/test/rendering/device_frame_matcher_test.dart
git commit -m "test(device-frame): iphone-14 perfect-match + append-order guard"
```

---

### Task 4: Full verification

**Files:** none (verification only).

- [ ] **Step 1: Real bundled-manifest parse sanity (uses the shipped manifest)**

Run:
```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
python3 - <<'PY'
import json
m=json.load(open("packages/screen_recorder/assets/device_frames/manifest.json"))
ids=[e["id"] for e in m["entries"]]
need=["iphone-14","iphone-14-plus","iphone-14-pro","iphone-14-pro-max"]
assert all(n in ids for n in need), ids
# iphone-14 must be exactly 1170x2532
e=[x for x in m["entries"] if x["id"]=="iphone-14"][0]
assert e["screen"]=={"w":1170,"h":2532}, e["screen"]
print("manifest OK; entries:", len(ids))
PY
```
Expected: `manifest OK; entries: 18`.

- [ ] **Step 2: Analyze + engine + recorder suites**

Run:
```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine && flutter test 2>&1 | tail -3
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder && flutter analyze 2>&1 | tail -2 && flutter test 2>&1 | tail -3
```
Expected: both suites `All tests passed!`; analyze `No issues found!`.

- [ ] **Step 3: Build, sign, run; visually verify the 1170×2532 recording**

Run:
```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder
osascript -e 'quit app "Slipreel"' 2>/dev/null; flutter build macos --release 2>&1 | tail -2
IDENT=CE7C4468C650F29F8EBC819F378B49133F820954
APP=build/macos/Build/Products/Release/Slipreel.app
ENT=macos/Runner/Release.entitlements
find "$APP/Contents/Frameworks" \( -name "*.dylib" -o -name "*.framework" \) -print | while read -r i; do codesign --force --timestamp=none --options runtime -s "$IDENT" "$i" >/dev/null 2>&1; done
codesign --force --timestamp=none --options runtime --entitlements "$ENT" -s "$IDENT" "$APP" >/dev/null 2>&1
codesign --verify --deep --strict "$APP" && open "$APP"
```
Expected: app launches; opening the user's 1170×2532 recording (`/Users/mohn93/Documents/recording_1782642016408.mp4`) auto-enables an **iPhone 14** frame (Perfect match) that fills the cutout with no white lines. User confirms visually.

- [ ] **Step 4: Commit any incidental fixes (only if Step 2 required edits)**

```bash
git add -A && git commit -m "fix(device-frame): test/analyze fixes for iPhone 14 addition"
```

---

## Self-Review

**Spec coverage:**
- Source DMG + additive extraction → Task 1. ✓
- Append entries at end, order preserved → Task 1 Steps 3-4 + Task 3 append-order test. ✓
- Copy dirs + manifest → Task 1. ✓
- pubspec decls + extractor URL → Task 2. ✓
- Matcher tests (perfect match, auto-select, form factor, order guard) → Task 3. ✓
- Manifest/asset sanity → Task 1 Step 5 + Task 4 Step 1. ✓
- Verify analyze/suites/visual → Task 4. ✓
- License note, asset-weight report → Task 1 Step 5 (size), spec notes. ✓

**Placeholder scan:** No TBD/TODO; the scratch driver + test code are complete. `<scratchpad>` is the session scratchpad path, substituted at run time. ✓

**Type consistency:** Entry shape matches `DeviceFrameEntry.fromJson` / `DeviceFrameColorVariant.fromJson` (id/family/kind/screen{w,h}/colors[{id,name,swatch,portrait,landscape}], each orient {asset,bezel{w,h},screenRect{l,t,r,b},screenCornerRadius}). Matcher symbols match `device_frame_matcher.dart`. ✓
