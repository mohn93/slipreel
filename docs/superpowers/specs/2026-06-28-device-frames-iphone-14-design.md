# Add iPhone 14 family device frames (1170×2532 + siblings)

## Problem

Device recordings at **1170×2532** (iPhone 12/13/14 base, 12/13 Pro) have **no
matching device frame** in the catalog — it starts at iPhone 16 (1179×2556). With
"Perfect" matching there is no exact match, and the cover+bleed fit (PR #29) makes
a near-aspect frame look acceptable but the device shown is the wrong model. Add a
real frame whose native screen is 1170×2532.

## Decision

Add the **iPhone 14 family** (iPhone 14 / 14 Plus / 14 Pro / 14 Pro Max) from
Apple's `Bezel-iPhone-14.dmg`. iPhone 14 is **1170×2532** (notch) — an exact match
for the affected recordings — and the family also covers 1284×2778 (14 Plus) and
adds same-art alternatives for 1179×2556 (14 Pro) and 1290×2796 (14 Pro Max).

The addition is **additive**: existing devices' PNGs and manifest entries are left
unchanged. The new entries are appended to the end of the catalog so existing
auto-selections for already-shared resolutions are preserved.

## Source & generation

- `Bezel-iPhone-14.dmg` — `https://devimages-cdn.apple.com/design/resources/download/Bezel-iPhone-14.dmg`
  (public CDN, verified HTTP 200). Bundles all four iPhone 14 models, both
  orientations, all colors — same structure as the already-shipped DMGs.
- Generate via the existing, unit-tested extractor logic in `tool/device_frames/extract.py`
  (`screen_rect` flood-fill → `bezel` w/h, normalized `screenRect`, `screenCornerRadius`;
  `parse_filename`, `mount`, `slugify`). To avoid regenerating/clobbering the existing
  manifest and re-compressing the shipped 38MB of PNGs, run it **only against the
  iPhone 14 DMG into a staging dir** (a small scratch driver that imports these
  functions), then merge the result in.

## Catalog wiring

- Copy the 4 new device dirs into `packages/screen_recorder/assets/device_frames/`:
  `iphone-14/`, `iphone-14-plus/`, `iphone-14-pro/`, `iphone-14-pro-max/`.
- Append the 4 new entries to the **end** of
  `packages/screen_recorder/assets/device_frames/manifest.json`. Existing entries
  stay byte-for-byte identical. Rationale: `autoSelectDeviceFrame` /
  `perfectMatches` return the **first** catalog entry matching a resolution; several
  resolutions are already shared among existing entries (e.g. 1206×2622 among
  iphone-16-pro/17/17-pro), so order must not change. Appending keeps existing
  auto-selects; the new 1170×2532 has no prior match so iPhone 14 becomes its
  (only) auto-select.
- Add the 4 new asset dirs to `packages/screen_recorder/pubspec.yaml` (mirroring the
  existing per-device `assets/device_frames/<id>/` declarations).
- Add the `Bezel-iPhone-14.dmg` URL to `DMG_URLS` in `extract.py` so a future clean
  rebuild includes it (documentation of the source of truth).

## Tests

- `packages/slipreel_engine/test/rendering/device_frame_matcher_test.dart` (or a new
  test in the same dir): a 1170×2532 recording
  - `deviceMatchesRecording` is true for the `iphone-14` entry,
  - `autoSelectDeviceFrame(catalog, Size(1170,2532))` returns `iphone-14`,
  - `recordingFormFactor(Size(1170,2532)) == phone` and `deviceFrameCompatible` is
    true for `iphone-14`.
  Drive it with a small in-memory `DeviceFrameCatalog` (via
  `debugSetDeviceFrameCatalog` or `DeviceFrameCatalog.parse`) containing at least an
  iphone-16 (1179×2556) and the new iphone-14 (1170×2532) so the test also asserts
  1179×2556 still resolves to iphone-16 (order preserved), not iphone-14.
- A manifest sanity assertion: the real bundled manifest parses and contains the 4
  new ids, each with portrait+landscape assets whose files exist under
  `assets/device_frames/`.

## Verify

- `flutter analyze` clean; `slipreel_engine` + `screen_recorder` suites green.
- Rebuild the dev-signed Release, open the user's 1170×2532 recording → the iPhone 14
  frame auto-enables on a Perfect match and fills the cutout cleanly (combined with
  the cover+bleed fit), no white lines.

## Constraints / notes

- **License:** Apple Design Resources bezels — same class of art as the existing
  catalog, which shipped under Apple sign-off (PR #20). Proceeding on the assumption
  that sign-off covers additional same-kind assets.
- **Asset weight:** the iPhone 14 family across all colors/orientations adds an
  estimated ~10–15MB; report the exact PNG count/size after extraction. If it's too
  heavy, colors can be trimmed (the per-color swatch is a hardcoded dark `#1d1d1f`
  in the extractor regardless, so trimming colors costs little fidelity).
- Do NOT run `dart format` on existing files (pinned formatter reflows unrelated
  lines). Match style by hand.
