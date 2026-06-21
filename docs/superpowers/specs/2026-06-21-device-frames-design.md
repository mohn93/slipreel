# Device Frames (#9) — Design

- **Date:** 2026-06-21
- **Issue:** #9 — Device frames: render a device bezel around iPhone/iPad recordings (subproject)
- **Status:** Approved (design); implementation pending
- **Builds on:** merge `76829fd8` (device-recording editor handling + manual-zoom preview)

## 1. Goal

Render a realistic Apple device bezel around iPhone/iPad recordings in **both** the editor
preview (`PlaybackCanvas`) and export (`FrameCompositor`), with a Screen-Studio-style
inspector (enable toggle, "Adjust device size", Perfect/Flexible filter, per-model color
swatches). Preview must equal export.

## 2. Decisions (from brainstorming)

| Question | Decision |
| --- | --- |
| Fidelity | Realistic per-model PNG mockups (not a generic drawn bezel) |
| Art source | **Apple Design Resources** device bezels |
| Asset delivery | Fetch + extract programmatically (proven working this session) |
| License posture | Proceed now; **ship gated on Apple sign-off** — owner-accepted risk (see §9) |
| v1 catalog | iPhone 16 + 17 families + current iPads (Pro M5, Air M4, mini A17 Pro, iPad A16), **both** portrait & landscape |
| Inspector gate (v1) | Shown only for `isDeviceCapture` recordings |
| Auto-enable | On open of a device capture with no frame set, auto-select a Perfect match if one exists |

## 3. Proven feasibility (evidence captured this session)

- Apple bezel DMGs download from a **public CDN, no auth**
  (`https://devimages-cdn.apple.com/design/resources/download/Bezel-iPhone-16.dmg`, etc.).
- They mount headlessly with SLA auto-accept: `yes | hdiutil attach <dmg> -nobrowse -readonly`.
- Each DMG contains a `PNG/` tree — **one DMG = a device family** (e.g. iPhone 16 / 16 Plus /
  16 Pro / 16 Pro Max), per color, per orientation, named `<Device> - <Color> - <Orientation>.png`.
- PNGs have an **essentially binary alpha** (~0.3% antialiased edge pixels; **no** baked drop-shadow).
- The **screen is a transparent interior cutout**; isolating it via border flood-fill yields a
  bbox whose pixel size **equals the device's native screen resolution** (verified exact):

  | Bezel | Extracted screen cutout | Known native res |
  | --- | --- | --- |
  | iPhone 16 Pro | 1206×2622 @ norm L0.0533 T0.0250 R0.9467 B0.9750 | 1206×2622 ✅ |
  | iPhone 16 | 1179×2556 | 1179×2556 ✅ |
  | iPhone 16 Plus | 1290×2796 | 1290×2796 ✅ |
  | iPad Pro 11″ (M5) | 1668×2420 | ✅ |

- iPhone 16 family: 4 models × 4–5 colors × 2 orientations = 36 PNGs, 16 MB (portrait-only 8.3 MB).
- Tooling present on this machine: `python3` + PIL + numpy (11.3.0), `ffmpeg`, `hdiutil`, `sips`.

**Implications:** "Perfect match" detection is a trivial exact comparison (cutout == native res),
and compositing needs no manual corner-clipping/notch drawing — the opaque bezel ring does it.

## 4. Architecture & data flow

```
Apple bezel DMGs ──(offline extract script)──▶ assets/device_frames/**.png + manifest.json
                                                         │
                                            DeviceFrameCatalog (pure Dart, slipreel_engine)
                                                         │
  recording native res ──▶ matcher (Perfect/Flexible) ──▶ inspector picker
                                                         │
                        WindowFrame.deviceFrame* (persisted per project)
                                         │                          │
                             PlaybackCanvas (preview)       FrameCompositor (export)
                                         └──── shared compositing model ────┘
```

The catalog, matching, and sizing math live in **`slipreel_engine`** so preview and export
cannot drift — same rationale as the existing shared `ScenePassBuilder` / `FramePainter`.

Key existing files:

- `packages/slipreel_engine/lib/models/recording_metadata.dart` — `isDeviceCapture`
- `packages/slipreel_engine/lib/models/window_frame.dart` — per-project frame styling
- `packages/slipreel_engine/lib/rendering/output_canvas_resolver.dart` — canvas/letterbox fit
- `packages/slipreel_engine/lib/rendering/wallpaper.dart` — asset wallpaper load/cache pattern
- `packages/slipreel_engine/lib/export/frame_compositor.dart` — export compositor
- `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart` — preview compositor
- `packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart` — control pattern
- `packages/screen_recorder/pubspec.yaml` — asset declarations

## 5. Compositing model (the key simplification)

When a device frame is active, replace the current video-frame + `FramePainter` chrome with two
layers, **inside the existing zoom `Transform`**, over the wallpaper/padding:

1. **Video** — drawn to fill the bezel's screen sub-rect (manifest normalized `screenRect`
   × displayed bezel size).
2. **Bezel PNG** — drawn on top, filling the full bezel rect. Its opaque ring masks the video to
   rounded corners and overlays the dynamic island / camera automatically.

No manual corner-clipping or notch drawing. Existing window chrome (shadow/border/inset/rounded
corners) is **suppressed** while the frame is on. Optional synthetic drop-shadow under the bezel
for depth (Apple's art has none).

`OutputCanvasResolver` is generalized to fit a **content size** into the canvas — the *bezel* size
when framed, else the raw video size as today. Padding, wallpaper, blur, and the device-capture
manual zoom focal are unchanged.

Preview uses Flutter widgets (`Image.asset` bezel + `Positioned` video texture); export preloads
the bezel as a cached `ui.Image` (mirroring `_loadWallpaperPhoto`) and draws both through
`applyZoom()`. Device captures carry no cursor data, so no cursor layer.

### Known / accepted divergences

- **Preview smears the device bezel during zoom ramps** (scene-blur captures the entire
  `DeviceFrameComposition` subtree, including the bezel); export keeps the bezel crisp because
  `FrameCompositor._composeDeviceFrame` draws the bezel in a separate pass *after* the
  motion-blur step. This is an accepted preview-only divergence, identical in class to the
  drop-shadow smear on the standard chrome path. Revisit if runtime testing shows it's
  objectionable.

## 6. Data model

New flat fields on `WindowFrame` (consistent with `padding` / `wallpaperCategory` /
`backgroundBlur`; full `copyWith` / `toJson` / `fromJson`):

- `deviceFrameId: String?` — catalog entry id, e.g. `"iphone-16-pro"` (null = frame off)
- `deviceFrameColor: String?` — e.g. `"black-titanium"`
- `deviceFrameAdjustSize: bool = true` — the "Adjust device size" toggle

UI-only picker filter (Perfect/Flexible), default Perfect, not persisted. `deviceFrameId == null`
⇒ "Use device mockup" is off.

**Manifest** `assets/device_frames/manifest.json` (generated by the script), one entry per model:

```json
{ "id": "iphone-16-pro", "family": "iPhone 16 Pro", "kind": "phone",
  "screen": { "w": 1206, "h": 2622 },
  "colors": [
    { "id": "black-titanium", "name": "Black Titanium", "swatch": "#3a3a3c",
      "portrait":  { "asset": "device_frames/iphone-16-pro/black-titanium-portrait.png",
                     "bezel": { "w": 1350, "h": 2760 },
                     "screenRect": { "l": 0.0533, "t": 0.0250, "r": 0.9467, "b": 0.9750 } },
      "landscape": { "asset": "device_frames/iphone-16-pro/black-titanium-landscape.png",
                     "bezel": { "w": 2760, "h": 1350 },
                     "screenRect": { "l": 0.0250, "t": 0.0533, "r": 0.9750, "b": 0.9467 } } }
  ] }
```

`DeviceFrameCatalog` loads the manifest once (pure Dart) and is consumed by both compositors and
the inspector. `screen.{w,h}` is the native (portrait) resolution; orientation entries carry their
own bezel size + screenRect.

## 7. Asset pipeline (offline, macOS-only; run by a dev, not CI)

Python script `tool/device_frames/extract.py` (technique proven this session):

1. Download the configured Apple bezel DMGs (public CDN).
2. Mount with SLA auto-accept (`yes | hdiutil attach`).
3. Per PNG: parse `<Device> - <Color> - <Orientation>`; border flood-fill to isolate the interior
   transparent screen cutout; record bbox → native screen res + normalized `screenRect`;
   optionally `pngquant`-compress; copy to `assets/device_frames/<id>/<color>-<orientation>.png`.
4. Emit `manifest.json`; unmount.

Generated assets + manifest are committed. Re-run on additional DMGs to expand the catalog.
Declare `assets/device_frames/` in `packages/screen_recorder/pubspec.yaml`.

## 8. Sizing & matching semantics

- **Perfect** = entries whose native screen `{w,h}` exactly equals the recording resolution
  (exact, since cutout == native). **Flexible** = all entries of matching orientation/kind,
  scaled to fit.
- **Adjust device size ON** (default) = stretch the bezel's screen rect to the recording's aspect
  so the video fills the cutout edge-to-edge. **OFF** = keep the device's true proportions; fit the
  video into the cutout (cover).
- **Auto-enable**: opening a device-capture project with no frame set → if a Perfect match exists,
  auto-select it (default color) and turn the frame on; otherwise leave off.

## 9. Risks (documented, accepted)

- **License (primary):** Apple Design Resources License forbids exactly this use — verbatim:
  *"You may not embed the Apple Design Resources in any software programs or other products"* and
  *"used SOLELY FOR CREATING MOCK-UPS … FOR SOFTWARE PRODUCTS THAT RUN ONLY ON APPLE'S … OS"* and
  *"may not be … extracted, copied, modified, distributed, or repackaged."* Engineering proceeds,
  but **release is gated on the owner obtaining Apple sign-off.** This is an explicit prohibition,
  not a grey area — owner-accepted and owned decision.
- **Bundle size** ~50–80 MB; mitigate with `pngquant` and/or trimming rarely-used colors.
- **Trade dress / trademark** (device shape + model names) — same release gate as the license.
- Pipeline requires macOS + a manual run (not CI).

## 10. Testing

- **Pure-Dart unit:** manifest parse; Perfect/Flexible filter; `screenRect`→video-rect math;
  `OutputCanvasResolver` with bezel content; adjust-size on/off; auto-enable selection.
- **Golden:** preview widget + export compositor each composite a solid-color "video" into a
  fixture bezel → assert identical placement (preview == export).
- **Extraction:** screen-rect assertion on one checked-in fixture PNG.

## 11. Out of scope (v1)

- Framing desktop/browser recordings (only phone/tablet bezels exist).
- User-imported / custom frames.
- 3D/tilt device animation (tracked separately as #12).
- Older device models (script-addable later).
