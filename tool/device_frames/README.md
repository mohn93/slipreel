# Device frame extraction

Generates `packages/screen_recorder/assets/device_frames/**` + `manifest.json`
from Apple Design Resources bezel DMGs.

## ⚠️ License gate
Apple Design Resources may **not** be embedded/redistributed in a product
without Apple's written permission (see the spec, §9). Do not ship the
generated assets until that sign-off is obtained.

## Run (macOS)
    python3 tool/device_frames/extract.py

Downloads the DMGs listed in `DMG_URLS`, mounts them (auto-accepting the
SLA), extracts each `<Device> - <Color> - <Orientation>.png`, computes the
screen cutout, and writes the assets + manifest.

## Test the extractor
    python3 tool/device_frames/test_extract.py
