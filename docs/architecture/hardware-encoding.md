# Hardware Encoding Architecture

## Overview

Slipreel uses a hybrid encoding approach:
- **Phase 4**: FFmpeg software encoding (current)
- **Phase 9**: VideoToolbox hardware encoding (future)

## Current Implementation (FFmpeg)

### Advantages
- Complete pipeline (video + audio + muxing)
- Cross-platform (works everywhere FFmpeg is installed)
- Well-tested and reliable
- Supports all codecs and formats

### Disadvantages
- CPU-intensive
- Slower than hardware encoding
- Higher power consumption

## Future Implementation (VideoToolbox)

### Architecture

```
┌─────────────┐
│   Frames    │
│  (BGRA)     │
└──────┬──────┘
       │
       v
┌─────────────────┐
│ CVPixelBuffer   │
│  Conversion     │
└──────┬──────────┘
       │
       v
┌──────────────────┐
│  VideoToolbox    │
│  VTCompression   │
│    Session       │
└──────┬───────────┘
       │
       v
┌──────────────────┐
│   H.264 NAL      │
│     Units        │
└──────┬───────────┘
       │
       v
┌──────────────────┐
│   AVAssetWriter  │
│   (MP4 Muxing)   │
└──────┬───────────┘
       │
       v
┌──────────────────┐
│   Final MP4      │
└──────────────────┘
```

### Implementation Plan

**Phase 9 Tasks:**
1. Implement CVPixelBuffer conversion from BGRA
2. Set up VTCompressionSession output callback
3. Collect NAL units into buffer
4. Use AVAssetWriter for MP4 muxing
5. Integrate audio track from AudioCaptureManager
6. Add fallback to FFmpeg if VideoToolbox unavailable

### Benefits
- 5-10x faster encoding
- Lower CPU usage (~20% vs ~80%)
- Better battery life on laptops
- Real-time encoding possible

### Challenges
- macOS only (need Windows Media Foundation, Linux VAAPI)
- More complex error handling
- NAL unit parsing required
- Audio/video sync more critical

## Decision: Keep FFmpeg for Phase 4

**Reasons:**
1. Complete implementation in 1 task vs 6 tasks for VideoToolbox
2. Cross-platform from the start
3. User testing can start sooner
4. Hardware encoding can be added later without breaking API

**Migration Path:**
- VideoEncoder API stays the same
- Add `useHardwareEncoding: bool` parameter
- Detect VideoToolbox availability at runtime
- Fall back to FFmpeg if hardware unavailable
