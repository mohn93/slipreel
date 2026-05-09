# Manual Testing Checklist

This checklist should be completed when testing Slipreel on each platform (macOS, Windows, Linux) to ensure feature parity and proper functionality.

## Pre-Testing Setup

### macOS
- [ ] Running macOS 12.3 or later
- [ ] Screen recording permission granted in System Preferences
- [ ] Audio recording permission granted (if testing audio)
- [ ] Multiple displays available (if testing multi-monitor)

### Windows
- [ ] Running Windows 10 Build 17134 (1803) or later
- [ ] DirectX 11 capable GPU
- [ ] Latest graphics drivers installed
- [ ] Multiple displays available (if testing multi-monitor)

### Linux
- [ ] PipeWire 0.3+ installed and running OR X11 display server
- [ ] xdg-desktop-portal installed and running (for Wayland)
- [ ] `pipewire --version` shows 0.3 or higher
- [ ] `systemctl --user status xdg-desktop-portal` shows active
- [ ] Multiple displays available (if testing multi-monitor)

---

## Core Functionality Tests

### Launch and Initialization
- [ ] App launches without errors
- [ ] No crash on startup
- [ ] Permission dialogs appear as expected (macOS/Wayland)
- [ ] Main window renders correctly
- [ ] UI is responsive

### Display/Screen Enumeration
- [ ] Screen list populates with available displays
- [ ] Screen names are descriptive and accurate
- [ ] Screen dimensions are correct
- [ ] Primary display is marked correctly
- [ ] Multi-monitor setups show all displays

**Platform Notes:**
- macOS: Should show all displays with accurate info
- Windows: Should show all displays with accurate info
- Linux (PipeWire): Should show displays (may require system picker)
- Linux (X11): Should show all displays with accurate info

### Window Enumeration
- [ ] Window list populates with open windows
- [ ] Window titles are accurate
- [ ] Window owner/app names are shown (macOS/Windows/X11)
- [ ] System/hidden windows are filtered appropriately
- [ ] Window list updates when windows open/close

**Platform Notes:**
- macOS: Full window enumeration with metadata
- Windows: Full window enumeration with metadata
- Linux (PipeWire): ⚠️ Window enumeration NOT available (security restriction)
- Linux (X11): Full window enumeration with metadata

---

## Recording Tests

### Display Recording
- [ ] Select a display from the list
- [ ] Click "Start Recording"
- [ ] Recording starts without errors
- [ ] Frame counter increments
- [ ] CPU usage is reasonable (check Activity Monitor/Task Manager)
- [ ] Memory usage is stable (no leaks)
- [ ] Click "Stop Recording"
- [ ] Output file path is returned
- [ ] Output file exists and is valid
- [ ] Output file is playable in video player

### Window Recording
- [ ] Select a window from the list
- [ ] Click "Start Recording"
- [ ] Recording starts without errors
- [ ] Only selected window is captured
- [ ] Window can be moved/resized during recording
- [ ] Click "Stop Recording"
- [ ] Output file is valid and playable

**Platform Notes:**
- Linux (PipeWire): ⚠️ Uses system picker instead of pre-selection

### Duration Test
- [ ] Record for at least 30 seconds
- [ ] Frame counter shows consistent progress
- [ ] No dropped frames or stuttering
- [ ] Memory usage remains stable
- [ ] Playback is smooth

### Sequential Recordings
- [ ] Complete a recording successfully
- [ ] Start a second recording immediately
- [ ] No errors or crashes
- [ ] Second recording completes successfully
- [ ] Start a third recording
- [ ] Third recording completes successfully
- [ ] No memory leaks between recordings

---

## Cursor Tracking Tests

### Cursor Visibility
- [ ] Enable cursor capture
- [ ] Start recording
- [ ] Move mouse around screen
- [ ] Cursor movements are visible in recording
- [ ] Cursor position is accurate
- [ ] Stop recording and playback

**Platform Notes:**
- macOS: ✅ Full cursor tracking
- Windows: ✅ Full cursor tracking
- Linux (PipeWire): ❌ Cursor NOT available
- Linux (X11): ✅ Full cursor tracking

### Click Detection
- [ ] Enable cursor capture
- [ ] Start recording
- [ ] Perform several left clicks
- [ ] Perform several right clicks
- [ ] Click indicators appear in recording (if implemented)
- [ ] Stop and verify playback

**Platform Notes:**
- Linux (PipeWire): ❌ Click detection NOT available

---

## Audio Capture Tests

### System Audio
- [ ] Enable audio capture
- [ ] Play audio (YouTube, music, etc.)
- [ ] Start recording
- [ ] Audio levels show activity
- [ ] Stop recording
- [ ] Playback video - audio is present and synchronized

### Microphone Audio
- [ ] Enable microphone capture
- [ ] Select microphone from device list
- [ ] Start recording
- [ ] Speak into microphone
- [ ] Audio levels show activity
- [ ] Stop recording
- [ ] Playback video - microphone audio is present

### No Audio
- [ ] Disable audio capture
- [ ] Start recording
- [ ] Stop recording
- [ ] Playback video - no audio track present

---

## Frame Effects Tests

### Zoom Effects
- [ ] Create a zoom region at start of video
- [ ] Zoom region appears on timeline
- [ ] Preview shows zoom applied
- [ ] Playback shows smooth zoom transition
- [ ] Create multiple zoom regions
- [ ] All zoom regions work correctly

### Window Framing
- [ ] Apply "None" frame template
- [ ] Video shows no decorations
- [ ] Apply "Rounded" frame template
- [ ] Video shows rounded corners
- [ ] Apply "Modern" frame template
- [ ] Video shows title bar decoration
- [ ] Apply "Minimal" frame template
- [ ] Video shows minimal border
- [ ] Custom frame colors work correctly

### Background Effects
- [ ] Apply solid color background
- [ ] Background color appears correctly
- [ ] Apply gradient background
- [ ] Gradient renders smoothly
- [ ] Apply blur background
- [ ] Background is properly blurred

---

## Export Tests

### 1080p 30fps Export
- [ ] Select "1080p 30fps" preset
- [ ] Click Export
- [ ] Export completes without errors
- [ ] Output file size is reasonable
- [ ] Playback quality is good
- [ ] Frame rate is consistent

### 1080p 60fps Export
- [ ] Select "1080p 60fps" preset
- [ ] Click Export
- [ ] Export completes without errors
- [ ] Playback is smooth at 60fps

### 4K 30fps Export
- [ ] Select "4K 30fps" preset
- [ ] Click Export
- [ ] Export completes without errors
- [ ] File size is larger (expected)
- [ ] Quality is excellent

### 4K 60fps Export
- [ ] Select "4K 60fps" preset
- [ ] Click Export
- [ ] Export completes without errors
- [ ] Large file size (expected)
- [ ] High quality maintained

### Web Optimized Export
- [ ] Select "Web Optimized" preset
- [ ] Click Export
- [ ] Export completes without errors
- [ ] File size is small
- [ ] Quality is acceptable for web
- [ ] Loads quickly in browser

---

## Performance Tests

### CPU Usage
- [ ] Monitor CPU during recording
- [ ] CPU usage is acceptable (< 30% on modern hardware)
- [ ] No CPU spikes or throttling
- [ ] Fans don't run excessively

### Memory Usage
- [ ] Monitor memory during recording
- [ ] Memory usage is stable
- [ ] No memory leaks over time
- [ ] Memory is released after stopping

### Frame Rate Consistency
- [ ] Record at 30 FPS
- [ ] Verify actual frame rate in output
- [ ] No dropped frames
- [ ] Record at 60 FPS
- [ ] Verify actual frame rate in output
- [ ] Consistent frame times

---

## Error Handling Tests

### Invalid Source Selection
- [ ] Attempt to record with no source selected
- [ ] Appropriate error message is shown
- [ ] App doesn't crash

### Permission Denied
- [ ] Revoke screen recording permission (macOS)
- [ ] Attempt to start recording
- [ ] Permission error is shown
- [ ] User is directed to settings

### Disk Space
- [ ] Fill disk to near capacity
- [ ] Attempt to record
- [ ] Disk space error is shown
- [ ] No corruption of existing files

### Network Drive (if applicable)
- [ ] Set output to network location
- [ ] Record video
- [ ] Verify successful save to network

---

## UI/UX Tests

### Timeline Interaction
- [ ] Timeline renders correctly
- [ ] Playhead can be dragged
- [ ] Zoom in/out on timeline works
- [ ] Timeline markers are visible
- [ ] Clicking on timeline seeks correctly

### Undo/Redo
- [ ] Perform several edits
- [ ] Click Undo
- [ ] Edit is reversed
- [ ] Click Redo
- [ ] Edit is reapplied
- [ ] Multiple undo/redo works correctly

### Keyboard Shortcuts
- [ ] Space bar plays/pauses
- [ ] Arrow keys seek frame-by-frame
- [ ] Cmd/Ctrl+Z undoes
- [ ] Cmd/Ctrl+Shift+Z redoes
- [ ] Other shortcuts work as expected

---

## Stress Tests

### Long Recording
- [ ] Record for 10+ minutes
- [ ] No crashes or errors
- [ ] Output file is valid
- [ ] Memory usage stays reasonable

### Large Resolution
- [ ] Record 4K display
- [ ] Recording completes successfully
- [ ] Performance is acceptable

### Rapid Start/Stop
- [ ] Start recording
- [ ] Immediately stop
- [ ] Repeat 10 times
- [ ] No crashes or errors
- [ ] No resource leaks

---

## Regression Tests

### Previously Fixed Bugs
- [ ] Check issue tracker for fixed bugs
- [ ] Test each fixed issue
- [ ] Verify issues don't reoccur
- [ ] Document any regressions

---

## Platform-Specific Tests

### macOS Only
- [ ] Test on Intel Mac
- [ ] Test on Apple Silicon Mac
- [ ] Hardware encoding works (macOS 13+)
- [ ] NSEvent cursor tracking works
- [ ] ScreenCaptureKit permission flow

### Windows Only
- [ ] Test on Windows 10
- [ ] Test on Windows 11
- [ ] Graphics Capture consent picker appears
- [ ] Low-level mouse hook for cursor works
- [ ] DirectX 11 capture works

### Linux Only - Wayland
- [ ] System picker appears for display capture
- [ ] System picker appears for window capture
- [ ] PipeWire capture works
- [ ] Audio capture works
- [ ] Cursor tracking NOT available (expected)

### Linux Only - X11
- [ ] Window enumeration works
- [ ] Display capture works
- [ ] Window capture works
- [ ] Cursor tracking works
- [ ] No permission dialogs (expected)

---

## Phase 9 Verification (macOS)

These checks confirm the live HW encode path and the export pipeline meet
their targets. Run on a representative Mac (Apple Silicon preferred).

### Recording (live HW encode)
- [ ] Start a 1-minute recording at 1080p60 of an active window
- [ ] Confirm CPU usage stays under 10% in Activity Monitor (avg)
- [ ] Confirm memory stays under 500 MB
- [ ] Stop recording — output `.mp4` exists at the path shown in the UI
- [ ] Sidecar `.meta.json` and `.cursor.json` exist next to the `.mp4`
- [ ] Log shows `[Recording] verdict: ... -> PASS`
- [ ] Open the recording in the editor — cursor overlay tracks playback

### Export (HW encode)
- [ ] Click Export, choose 1080p30 preset
- [ ] Export completes; output file plays in QuickTime
- [ ] Log shows `[Export] verdict: realtimeMultiple≥1.0 ✓ -> PASS`
- [ ] `outputCodec=h264_videotoolbox` in the summary line

### Legacy recording handling
- [ ] Open a recording made before Phase 9 (no `.meta.json` sidecar)
- [ ] No double-cursor in the editor preview (overlay correctly suppressed)
- [ ] Export still works (uses the same pipeline; cursor is already baked)

---

## Sign-Off

### Test Environment
- **Platform:** _______________
- **OS Version:** _______________
- **Hardware:** _______________
- **Date:** _______________
- **Tester:** _______________

### Results Summary
- **Total Tests:** _______________
- **Passed:** _______________
- **Failed:** _______________
- **Skipped (N/A):** _______________

### Issues Found
1. _______________________________________________
2. _______________________________________________
3. _______________________________________________

### Overall Assessment
- [ ] Ready for release
- [ ] Needs minor fixes
- [ ] Needs major fixes
- [ ] Not ready for release

### Notes
_________________________________________________
_________________________________________________
_________________________________________________
_________________________________________________

## Source Picker Redesign (2026-04-28)

- [ ] Picker open → first thumbnails visible within ~1.5s on a Mac with ~20 windows.
- [ ] Switch to Screens, see all physical displays with correct resolutions, "Main" badge on primary.
- [ ] Refresh re-captures (visually verify a stale thumbnail updates after scrolling content in the source).
- [ ] Select window → record → stop → playback shows what you recorded.
- [ ] Select screen → record → stop → playback covers full display.
- [ ] Toggle "Show all" — utility windows appear.
- [ ] First-launch permission flow: revoke Screen Recording in System Settings, re-launch, see CTA, grant, refresh works.

## Region Capture (2026-04-29)

- [ ] Region tab visible in segmented control with crop icon.
- [ ] Click Region tab on first launch → empty state with "Draw a region" button.
- [ ] Click "Draw a region" → app minimizes; transparent overlay appears across every connected display with the desktop dimmed.
- [ ] Click-drag → live `W × H` readout follows cursor; rect outlined in purple.
- [ ] Release → 8 resize handles appear at corners + edge midpoints; floating Start/Cancel toolbar appears at bottom-right of the rect.
- [ ] Drag a corner handle → rect resizes; toolbar follows.
- [ ] Drag an edge midpoint handle → resizes that axis only.
- [ ] Drag inside the rect → rect translates; toolbar follows.
- [ ] Drag past display edge → rect clips at the display boundary.
- [ ] Press Esc → overlay closes everywhere; app restores; Region tab still in empty state.
- [ ] Click Cancel → same as Esc.
- [ ] Click Start → overlay closes; app restores; Region tab now shows recap card with the chosen size and display name; Record button enabled.
- [ ] Click Record → recording captures only the chosen region at the rect's pixel size.
- [ ] Stop → playback shows exactly the region you drew (no scaling, correct aspect ratio).
- [ ] Switch to Windows tab → Region selection clears; switching back to Region tab shows empty state.
- [ ] Multi-display: drag rect on a secondary display, record, verify the secondary display's pixels are captured.
