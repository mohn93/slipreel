# Whole-repo review — Slipreel (2026-06-24)

Parallel 13-subsystem code review with adversarial verification of every finding (26 agents, ~2.75M tokens).

| Raw | Confirmed | Rejected (false +ve) | Critical | Major | Minor | Nit |
|---|---|---|---|---|---|---|
| 55 | 49 | 6 | 1 | 6 | 32 | 10 |

## Confirmed findings (49)

### [CRITICAL] Non-positive playbackSpeed from a loaded .editor.json hangs the export in an infinite atempo loop (OOM crash)

- **Subsystem:** slipreel_engine — export / encode / ffmpeg
- **Category:** bug · **Confidence:** high
- **Location:** `packages/slipreel_engine/lib/export/n_slice_filter_graph.dart:278-279 (audio), 241-248 (video); root: ffmpeg_filters.dart:12-25 atempoChain`

**What:** A ClipSlice with playbackSpeed <= 0 reaches the filter-graph builder and detonates two ways. (1) Audio: _audioChainFor calls speedAtempo(speed) whenever playbackSpeed != 1.0; speedAtempo -> atempoChain(0.0) enters `while (s < 0.5) { factors.add(0.5); s /= 0.5; }`, but 0.0 / 0.5 == 0.0, so the loop never terminates and grows `factors` without bound -> OutOfMemory, taking the whole app down (losing any unsaved editor state). A negative speed has the same non-terminating behavior plus emits a nonsensical `atempo=-1.0`. (2) Video: _videoChainFor computes `(s.effectiveLength.inMicroseconds / s.playbackSpeed).round()`; with speed 0 that is Infinity.round(), which throws UnsupportedError. The UI clamps speed to [0.25, 24.0] in EditorProjectController.setSliceSpeed, but ClipSlice's constructor and ClipSlice.fromJson (state/clip_slice.dart:193-195) do NOT clamp, and the value is loaded from the on-disk `<videoPath>.editor.json` sidecar via EditorProjectState.fromJson -> Timeline.fromJson -> ClipSlice.fromJson (timeline.dart:228). A truncated/half-written/hand-edited sidecar with `playbackSpeed: 0` (or negative) therefore crashes every export attempt for that recording. Tellingly, _slicedOutputSeconds (export_pipeline.dart:536) already guards `if (c.playbackSpeed <= 0) continue;`, proving the value is known to reach this layer un-sanitized.

**Suggested fix:** Sanitize playbackSpeed at the trust boundary: clamp in ClipSlice's constructor (e.g. `playbackSpeed = (playbackSpeed.isFinite && playbackSpeed > 0) ? playbackSpeed.clamp(0.25, 24.0) : 1.0`) so neither the filter graph nor editedLength can ever see <= 0 / NaN / Infinity. Defensively, also guard atempoChain to bail when `speed <= 0 || !speed.isFinite` and treat speed<=0 as 1.0 in _videoChainFor/_audioChainFor.

<details><summary>Verifier reasoning</summary>

Confirmed by reading the code and reproducing the runtime behavior. ClipSlice's constructor (clip_slice.dart:23-45) clamps gains and trim bounds but NEVER clamps playbackSpeed, and ClipSlice.fromJson (193-195) takes the raw on-disk double verbatim; Timeline.fromJson loads each clip via ClipSlice.fromJson (timeline.dart:228), so a sidecar value flows straight through. In the graph builder, _videoChainFor divides by playbackSpeed directly (n_slice_filter_graph.dart:248) — not via editedLength, whose `<=0` guard at clip_slice.dart:83 therefore does NOT protect this path — and _audioChainFor calls speedAtempo for any playbackSpeed != 1.0 (279). I reproduced all three failure modes in Dart: atempoChain(0.0) grows `factors` without bound (the while-loop body leaves s==0.0 forever → OOM), atempoChain(-1.0) diverges to -Infinity (never terminates), and (1000000/0.0).round() throws `UnsupportedError: Infinity or NaN toInt`. The only `playbackSpeed <= 0` guard anywhere in the export path is _slicedOutputSeconds (export_pipeline.dart:536), used solely for the progress denominator — confirming the maintainers know the value reaches this layer un-sanitized while the actual filter-graph builder remains unguarded. Reachability caveat: the UI clamps to [0.25,24.0] in setSliceSpeed (editor_project_controller.dart:328), so this is NOT reachable through normal operation — it needs a truncated/half-written/hand-edited .editor.json. Given the app has crash-recovery machinery (mid-save truncation is plausible) and the consequence is a whole-app OOM crash losing unsaved editor state, with a trivial one-line boundary-clamp fix, critical is justified.
</details>

---

### [MAJOR] CaptionRenderer.paint allocates a TextPainter every frame and never disposes it (per-frame native leak on the export + preview hot path)

- **Subsystem:** slipreel_engine — rendering / compositing / zoom / blur
- **Category:** resource-leak · **Confidence:** high
- **Location:** `packages/slipreel_engine/lib/rendering/caption_renderer.dart:48-84`

**What:** CaptionRenderer.paint constructs a `TextPainter(...)..layout(...)` on every invocation and never calls `.dispose()`. A TextPainter owns a native `ui.Paragraph` (a Skia/Impeller handle); the Flutter framework requires disposing it. This `paint` is the shared caption renderer for BOTH the live preview (caption_overlay.dart:41) and export (frame_compositor.dart:448 and :712). On export it runs once per output frame for the entire video — e.g. a 2-minute 60fps export with captions enabled creates ~7200 undisposed TextPainters, each retaining a native paragraph until GC happens to run. During a long export this is sustained native-memory pressure on the raster path (and it also leaks every preview frame while a caption is on screen). grep confirms there is no `TextPainter` `.dispose()` anywhere in the repo.

**Suggested fix:** Dispose the TextPainter before returning: wrap the layout/paint in `try { ... tp.paint(...); } finally { tp.dispose(); }`. (Equivalently, hoist a single reusable TextPainter that is re-laid-out per frame and disposed when the renderer/owner tears down, but the local try/finally is the minimal, safe fix and preserves the stateless API.)

<details><summary>Verifier reasoning</summary>

Confirmed by reading caption_renderer.dart:48-84. `CaptionRenderer.paint` constructs `final tp = TextPainter(...)..layout(...)`, paints it at line 84, and returns with no `tp.dispose()`. A TextPainter owns a native ui.Paragraph and Flutter requires disposal. Repo-wide grep found zero TextPainter `.dispose()` calls in slipreel_engine. This static method is the shared caption renderer for both export (frame_compositor.dart:448 inside the per-output-frame compose loop, and :712) and live preview (caption_overlay.dart:41), so it allocates one undisposed TextPainter per frame whenever captions are enabled and a caption is on screen. On a long export this is real sustained native/raster memory pressure. The local try/finally dispose suggested is the correct minimal fix. I trim 'major' only slightly in spirit (paragraphs are GC-finalized so it is pressure/soft-leak not an unbounded hard leak, and it only fires with captions enabled), but it is a genuine resource defect on a hot path so I keep adjustedSeverity at major.
</details>

---

### [MAJOR] Caption extraction leaks a temp directory (WAV + whisper JSON) on every generation run

- **Subsystem:** slipreel_engine — effects / captions / audio / utils
- **Category:** resource-leak · **Confidence:** high
- **Location:** `packages/slipreel_engine/lib/captions/caption_audio_extractor.dart:108-119`

**What:** CaptionAudioExtractor.extract creates a brand-new system-temp directory per call (Directory.systemTemp.createTempSync('slipreel_caption_')) and writes a 16 kHz mono WAV into it. Nothing ever deletes this directory or its contents. CaptionTranscriber then writes 'caption_transcript.json' next to that WAV (caption_transcriber.dart:74-75, base = dirname(audioPath)/caption_transcript), which is also never removed. The production wiring (captions_tab.dart:26 -> extractor.extract(video, source)) never passes outPath, so the temp branch is always taken, and CaptionGenerationController.generate (caption_generation_controller.dart:85-99) never cleans up the returned WAV path. Every time the user clicks 'Generate' in the Captions tab, a new slipreel_caption_<rand>/ folder is left behind. For a 5-minute recording the WAV alone is ~10 MB (16000 Hz * 2 bytes * 300 s). On macOS /var/folders temp is not promptly reclaimed, so repeated caption generation grows disk usage without bound.

**Suggested fix:** Track the created temp directory and delete it after transcription completes (or fails). E.g. have extract() return both the WAV path and its temp dir, and in CaptionGenerationController.generate wrap the transcribe step in try/finally that does `Directory(p.dirname(audio)).deleteSync(recursive: true)`. Alternatively register the temp dir for cleanup via addTearDown-style bookkeeping in the extractor and expose a dispose().

<details><summary>Verifier reasoning</summary>

Confirmed by reading the full chain. caption_audio_extractor.dart:108-112 creates a fresh `Directory.systemTemp.createTempSync('slipreel_caption_')` whenever `outPath` is null and writes caption_audio.wav into it; nothing in extract() deletes it. The production wiring at captions_tab.dart:26 (`extractAudio: (video, source) => extractor.extract(video, source)`) passes no outPath, so the temp branch is ALWAYS taken in prod. caption_generation_controller.dart generate() (lines 85-106) transcribes the returned `audio` path but never deletes the dir. caption_transcriber.dart:74-75 defaults outBase to `dirname(audioPath)/caption_transcript` and whisper writes `$base.json` (line 96) into that same temp dir, also never removed. A repo-wide grep for deleteSync/delete(recursive on caption temp paths found zero cleanup in non-test code (only whisper_model_store and gif_export_pipeline delete unrelated files). So every 'Generate'/'Regenerate' click leaks a temp dir with a WAV (~10MB for 5 min at 16kHz mono 16-bit) plus the JSON. Severity major is reasonable: unbounded disk growth on a repeatable user action, /var/folders not promptly reclaimed.
</details>

---

### [MAJOR] Fatal recording error during pause/resume is silently overwritten back to paused/recording (and restarts a dead-session timer)

- **Subsystem:** screen_recorder — state / controllers (recording, permissions, recovery)
- **Category:** concurrency · **Confidence:** high
- **Location:** `packages/screen_recorder/lib/state/recording_state.dart:569-597, 599-627`

**What:** pauseRecording() and resumeRecording() check status BEFORE their `await ScreenRecorderPlatform.instance.pause/resumeRecording()` and then write `state` unconditionally AFTER the await with no re-check. _handleError() (triggered by recordingErrorStream or any thrown failure) is NOT routed through the same _transition queue and runs synchronously. Sequence: (1) user pauses → op awaits the native pause; (2) native capture dies → recordingErrorStream fires → _handleError sets status=error, nulls _durationTimer/_startTime, cancels subscriptions; (3) the pause op resumes past its await and does `state = copyWith(status: paused, duration: elapsed)`, clobbering the error state. The UI then shows 'Paused'/'Recording' over a dead native session instead of surfacing the error, and the Stop/Resume affordance acts on nothing. In the resume case it is worse: line 590 creates a brand-new periodic _durationTimer on a session _handleError just tore down, so a leaked timer keeps ticking the duration on an errored recording with no owner to cancel it (dispose/_handleError already ran).

**Suggested fix:** After each `await` in the transition body, re-check the precondition before mutating state, e.g. in resume: `if (!mounted || state.status != RecordingStatus.paused) return;` immediately after the await (and likewise guard pause). Better, route stopRecording AND _handleError through _enqueueTransition too so error/stop and pause/resume are strictly serialized, and have the transition ops bail if the controller entered the error state while awaiting.

<details><summary>Verifier reasoning</summary>

Confirmed in recording_state.dart. pauseRecording() (569-582) checks status==recording before the `await ScreenRecorderPlatform.instance.pauseRecording()` then unconditionally does `state = copyWith(status: paused, duration: elapsed)` with no re-check after the await. resumeRecording() (584-597) is the same pattern and, worse, unconditionally creates a NEW `_durationTimer = Timer.periodic(...)` at line 590 and sets status=recording. _handleError() (599-627) is NOT routed through _enqueueTransition; it is synchronous, fired by the recordingErrorStream listener (275: `if (state.isRecording) _handleError(message)`), and it sets status=error, cancels subscriptions, and nulls _durationTimer/_startTime (621-623). If native capture dies during the pause/resume await, _handleError runs, then the transition continuation resumes and overwrites state back to paused/recording — clobbering the error so the UI shows a live status over a dead session. In the resume case the freshly-created _durationTimer (590) survives _handleError's teardown and keeps ticking with no owner to cancel it (dispose/_handleError already ran), a genuine leak. The native-error test only covers an error during steady recording, not during a pause/resume await, so this is uncovered. Real, material concurrency defect.
</details>

---

### [MAJOR] main() has no top-level error guard; a shader/asset load failure during init silently yields a blank window with no diagnostics

- **Subsystem:** screen_recorder — services / platform / main / onboarding / debug
- **Category:** bug · **Confidence:** high
- **Location:** `packages/screen_recorder/lib/main.dart:66-213 (esp. 94-95)`

**What:** The whole startup sequence in main() runs ~8 sequential awaits before runApp(), with NO try/catch around them and NO runZonedGuarded / FlutterError.onError / ErrorWidget.builder anywhere in the entry point (verified: grep for all four returns nothing in main.dart/main_dev.dart). Most store loads catch internally, but the two shader pre-loads on lines 94-95 do NOT fully swallow failures: CursorOverlayPainter.ensureMotionBlurProgramLoaded() (slipreel_engine/lib/rendering/cursor_overlay_painter.dart:86) catches the FIRST asset path but re-throws if the second/fallback path 'shaders/motion_blur.frag' also fails; SceneMotionBlurShader.ensureLoaded() follows the same pattern. If the bundled shader asset is ever missing or unloadable in a packaged release, the exception propagates out of the await in main(), runApp() is never reached, and the user sees a permanent blank/white NSWindow with zero error UI or logging of the fatal cause. getApplicationSupportDirectory() (lines 110/125/141/149) is likewise unguarded. This is exactly the 'breaks silently with no feedback' failure mode that is worst in a DIRECT-distributed app where you can't hotfix quickly.

**Suggested fix:** Wrap the body of main() in runZonedGuarded (or at minimum a try/catch around the init block) and set ErrorWidget.builder, so a fatal init error is logged via AppLogger and shows a minimal 'failed to start' surface instead of a blank window. Additionally make ensureMotionBlurProgramLoaded()/ensureLoaded() degrade gracefully (log + leave the multi-stamp fallback path) rather than rethrowing, since the painter already has a polygon/multi-stamp fallback and a missing motion-blur shader should never be fatal to app launch.

<details><summary>Verifier reasoning</summary>

Confirmed accurate. main() (main.dart:66-213) runs ~8 sequential awaits before runApp() with no try/catch, and a grep for runZonedGuarded/FlutterError.onError/ErrorWidget.builder/PlatformDispatcher.instance.onError across the whole screen_recorder lib returns nothing; main_dev.dart just delegates to app.main() with no guard either. The two awaited shader pre-loads (lines 94-95) only partially swallow failures: CursorOverlayPainter.ensureMotionBlurProgramLoaded() (cursor_overlay_painter.dart:86-101) and SceneMotionBlurShader.ensureLoaded() (scene_motion_blur.dart:35-52) both catch the package-prefixed asset path but RETHROW if the bare fallback path also fails. So if the bundled shader asset is ever missing/unloadable in a packaged release, the exception escapes the await, runApp() is never reached, and the user gets a blank NSWindow with zero logging or error UI. getApplicationSupportDirectory() calls are likewise unguarded. The realistic trigger is a packaging regression rather than everyday use, but the silent-blank-window outcome is exactly the worst failure mode for a DIRECT-distributed app you can't hotfix. Major is defensible.
</details>

---

### [MAJOR] Recents thumbnail extractor invokes bare 'ffmpeg' instead of Ffmpeg.resolve() — silently fails in the packaged app

- **Subsystem:** cross-cutting: architecture, build/CI, config, entitlements, dead code
- **Category:** bug · **Confidence:** high
- **Location:** `packages/screen_recorder/lib/ui/screens/recents/recording_thumbnail_service.dart:199`

**What:** _decodeFrameBgra spawns `Process.run('ffmpeg', args, stdoutEncoding: null)` with a bare binary name. The app's own FfmpegResolver docstring (ffmpeg_resolver.dart:73-76) explicitly warns that 'A packaged/sandboxed macOS app has a minimal PATH, so invoking a bare ffprobe/ffmpeg fails even when ffmpeg resolves from a well-known location.' Every other ffmpeg call site in the codebase (frame_extractor_provider.dart, caption_audio_extractor.dart, waveform_extractor.dart, ffmpeg_encoder.dart, ffmpeg_probe.dart) correctly routes through Ffmpeg.resolve(); this is the single outlier. In the shipped .app (which has a minimal PATH and resolves ffmpeg only via the /opt/homebrew or /usr/local well-known paths), Process.run('ffmpeg') throws ProcessException, so `out.length < frameSize` is never reached — recents thumbnails silently never render. It works in dev only because the developer's shell PATH includes Homebrew.

**Suggested fix:** Replace `Process.run('ffmpeg', args, ...)` with `Process.run(Ffmpeg.resolve(), args, ...)` (import slipreel_engine's Ffmpeg facade), and wrap in a try/catch that returns null on FfmpegNotFoundException so a missing binary degrades gracefully instead of throwing on the recents screen.

<details><summary>Verifier reasoning</summary>

Confirmed at recording_thumbnail_service.dart:199: `Process.run('ffmpeg', args, stdoutEncoding: null)` uses a bare binary name. This is the single outlier: the resolver doc (ffmpeg_resolver.dart:74-76) explicitly states a packaged/sandboxed macOS app has a minimal PATH so bare invocation fails, and every sibling call site routes through Ffmpeg.resolve()/resolveProbe() (frame_extractor_provider.dart:57, ffmpeg_probe.dart:73/157, plus caption/waveform/encoder). Notably the SAME file's _defaultProbeDuration (line 141) correctly goes through ffmpegProbe→resolveProbe, so duration probing works but the frame-decode for the PNG does not. In a packaged app the bare call throws ProcessException, which propagates through _defaultGenerate→thumbFor; the FutureBuilder in recording_card.dart:98 catches `snap.hasError` and shows _Placeholder(), so it degrades to a blank placeholder rather than crashing — meaning recents thumbnails silently never render in the shipped app while working in dev (developer PATH has Homebrew). Real defect, correctly located. I keep it at major (it's a clear correctness/packaging bug and the only ffmpeg call site that violates the established pattern), though the impact is a missing thumbnail visual with graceful fallback, not a crash or data loss.
</details>

---

### [MAJOR] Hardened Runtime is not enabled anywhere in the Xcode project — a direct-distribution build cannot be notarized

- **Subsystem:** cross-cutting: architecture, build/CI, config, entitlements, dead code
- **Category:** security · **Confidence:** high
- **Location:** `packages/screen_recorder/macos/Runner.xcodeproj/project.pbxproj:720-737 (Release config) / whole file`

**What:** The app ships DIRECT outside the Mac App Store, which requires Apple notarization, and notarization HARD-REQUIRES the Hardened Runtime to be enabled (ENABLE_HARDENED_RUNTIME = YES) and a Developer ID signing identity. `grep ENABLE_HARDENED_RUNTIME project.pbxproj` returns 0 matches (absent in every config), and CODE_SIGN_IDENTITY is '-' (ad-hoc) with CODE_SIGN_STYLE = Automatic and an empty PROVISIONING_PROFILE_SPECIFIER. An ad-hoc-signed, non-hardened build is Gatekeeper-blocked on any machine other than the one that built it ('app is damaged / cannot be opened'). This matches the memory note that the current Release artifact is only 'ad-hoc-signed'. Because App Sandbox is intentionally disabled (Release.entitlements line 5-6 `com.apple.security.app-sandbox = false`, consistent with Debug — that part is fine and intentional for ffmpeg/keystroke), the entitlements are otherwise sane, but without Hardened Runtime the release is undistributable. Also note the Release entitlements correctly omit the Debug-only `com.apple.security.cs.allow-jit` and `network.server` keys, which is correct.

**Suggested fix:** For the release pipeline (the still-pending DMG/sign/notarize work), add ENABLE_HARDENED_RUNTIME = YES to the Release build config, set a Developer ID Application signing identity, and re-sign+notarize. Keep Hardened Runtime compatible with the disabled sandbox; add any required cs.* exception entitlements (e.g. allow-unsigned-executable-memory only if a dependency needs it). Do NOT ship the ad-hoc identity.

<details><summary>Verifier reasoning</summary>

Confirmed. `grep -c ENABLE_HARDENED_RUNTIME project.pbxproj` returns 0 — the key is absent from every build config including the Release block (lines 724-737), which has CODE_SIGN_ENTITLEMENTS=Runner/Release.entitlements, CODE_SIGN_STYLE=Automatic, PROVISIONING_PROFILE_SPECIFIER="", and CODE_SIGN_IDENTITY="-" (ad-hoc) elsewhere. Apple notarization (required for direct-distribution outside the Mac App Store) hard-requires Hardened Runtime + a Developer ID identity, so the current ad-hoc, non-hardened Release is undistributable/Gatekeeper-blocked off the build machine, matching the memory note that the Release artifact is only 'ad-hoc-signed'. Release.entitlements correctly disables app-sandbox (intentional for ffmpeg/keystroke) and omits the Debug-only allow-jit/network.server keys, so the entitlements assessment in the finding is accurate. The factual claims all check out. Severity: this is real but is pending-release-pipeline work (the DMG/sign/notarize task per memory is explicitly not done yet), so it is more accurately a known-incomplete release task than a regression in shipped behavior; I keep major given it blocks distributability.
</details>

---

### [MINOR] Enter-ramp settle target ignores CursorPostProcess (despike / end-freeze), diverging from the visible cursor sprite the camera is supposed to track

- **Subsystem:** slipreel_engine — rendering / compositing / zoom / blur
- **Category:** correctness · **Confidence:** high
- **Location:** `packages/slipreel_engine/lib/rendering/scene_pass_builder.dart:204-210`

**What:** For a followCursor zoom, `enterCursorTarget` (the point the enter pan aims at, i.e. where the cursor will be when the zoom completes) is sampled with the RAW lookup `cursorAt(cursorRecording, enterEnd)`. But the visible cursor sprite and `cursorForFocal` are produced by `CursorMotionController` via `cursorAtFiltered(..., postProcess)` (cursor_motion_controller.dart:184), which applies despike and end-freeze. When CursorPostProcess is active and the enter-ramp end lands on a despiked sample or past the end-freeze cap, the camera pans to a raw point that differs from where the despiked/frozen sprite actually settles. The whole point of the enter-pan settle target (per the surrounding comment and ZoomFocalController docs) is for the camera and the on-screen cursor to agree; here they can disagree. It is position-pure so play==scrub==export stay consistent with each other, but all three are consistently aimed at the wrong (unfiltered) spot relative to the rendered sprite.

**Suggested fix:** Sample the settle target through the same filtered lookup the sprite uses: `cursorAtFiltered(cursorRecording, enterEnd, cursorPostProcess)` (and apply the same cursorDelay shift the motion controller applies) so the enter pan lands exactly where the rendered cursor will be.

<details><summary>Verifier reasoning</summary>

Confirmed the asymmetry: scene_pass_builder.dart:204 samples the enter settle target with the RAW `cursorAt(cursorRecording, enterEnd)`, whereas the visible sprite path in cursor_motion_controller.dart:184 uses `cursorAtFiltered(cursorRecording, queryPosition, postProcess)` (despike + end-freeze, cursor_geometry.dart:44-136) and also shifts by cursorDelay. So when CursorPostProcess is active and the enter-ramp end lands on a despiked sample or past the end-freeze cap, the camera's captured enter target (zoom_focal_controller.dart:592-594, then clampFocalToBounds) differs from where the filtered sprite actually settles, contradicting the stated goal that camera and cursor agree. The defect is real and the suggested fix (cursorAtFiltered + cursorDelay shift) is correct. Materiality is low though: the divergence only occurs with despike/end-freeze on AND the ramp-end on an affected sample, despike caps deviation to a few px, the target is only the enter-pan aim point that the spring smoothly resumes from, and it stays position-pure (play==scrub==export). Minor, not major.
</details>

---

### [MINOR] GIF progress denominator uses full-source duration, never the edited (trimmed/sped) length

- **Subsystem:** slipreel_engine — export / encode / ffmpeg
- **Category:** correctness · **Confidence:** high
- **Location:** `packages/slipreel_engine/lib/export/gif_export_pipeline.dart:146, 435-443, 236-237, 340-342`

**What:** GifExportPipeline._expectedFrames is computed from probed.durationSec / nb_frames (the FULL source), but the GIF filter_complex applies the same per-slice `trim`+`setpts`+`concat` as the MP4 path, so ffmpeg only emits the EDITED frame count. For a trimmed or sped-up project the progress bar advances against the wrong denominator: a project trimmed to half its length reaches only ~50% and then the export jumps to done, and a 2x slice undershoots similarly. The MP4 pipeline already fixed exactly this (the 'm9' change in export_pipeline.dart uses _slicedOutputSeconds via expectedOutputFrames); the GIF path was not updated to match.

**Suggested fix:** Mirror the MP4 path: compute the sliced output seconds from slicedState.timeline.clips (Σ effectiveLength/playbackSpeed) and derive expectedFrames from that, falling back to source duration only when no usable edited length exists.

<details><summary>Verifier reasoning</summary>

Confirmed. GifExportPipeline._expectedFrames (gif_export_pipeline.dart:435-443) computes the progress denominator only from probed.durationSec / probed.nbFrames — the FULL source — while the GIF filter graph is built by the SAME buildExportFilterGraph on slicedState (line 139, audioStreams:[]), which emits per-slice trim=trimStart:trimEnd + setpts + concat (confirmed via grep: the only edited-length symbols present are _ensureSlices/slicedState; no outputDurationSec/_slicedOutputSeconds/expectedOutputFrames usage exists in this file). The decoder feeds all source frames and the filter graph trims them inside ffmpeg, and pass2Frames is only incremented for frames ffmpeg actually accepts (the StdinClosed `continue` at 219/326 precedes the increment), so pass2Frames tracks the EDITED count against a SOURCE-count denominator. For a trimmed or sped-up project the bar advances against the wrong total (a half-length trim reaches ~50% then jumps to done). The MP4 path already fixed exactly this via expectedOutputFrames(outputDurationSec=...) (export_pipeline.dart:292-298, the documented 'm9' change); the GIF path was not updated. Impact is purely a cosmetic progress-bar inaccuracy — no output corruption — so minor is correct.
</details>

---

### [MINOR] GIF pass-1 failure can orphan the decoder/encoder ffmpeg processes

- **Subsystem:** slipreel_engine — export / encode / ffmpeg
- **Category:** resource-leak · **Confidence:** high
- **Location:** `packages/slipreel_engine/lib/export/gif_export_pipeline.dart:251-255 (pass1 exit check) and 398-409 (outer catch)`

**What:** If pass-1 palettegen exits non-zero, line 254 throws. The outer `catch (_)` (398) only deletes the partial output and rethrows; it never kills `_activeProc` (proc1) or `_activeDecoder` (decoder1). In the normal exit path decoder1's stream has already ended (so its process is gone) and proc1 has exited (we just read its exitCode), so today this rarely leaks. But the catch is the generic failure funnel for the whole run(): an exception thrown from compose(), from `proc1.stdin.flush()` for a non-pipe reason, or a cancellation mid pass-1 (line 205 throws ExportCancelledException) lands here with proc1/decoder1 potentially still alive, and nothing in the catch or the `finally` (410-423, which only deletes the palette dir) kills them. The MP4 pipeline, by contrast, explicitly kills decoder+encoder on every failure path.

**Suggested fix:** In the outer catch (and/or the outer finally), call `_activeProc?.kill(ProcessSignal.sigkill); _activeDecoder?.kill();` so any failure path reaps both subprocesses, matching ExportPipeline's teardown.

<details><summary>Verifier reasoning</summary>

Confirmed. The GIF pipeline only kills its subprocesses on cancellation (gif_export_pipeline.dart:99-102, wired to cancelToken.whenCancelled). The outer catch (398-409) just deletes partial output, translates cancel, and rethrows; the outer finally (410-423) only deletes the palette dir — neither calls _activeProc?.kill() or _activeDecoder?.kill(). I traced a non-cancel failure (e.g. compositor1.compose() throwing at line 214): the inner finally (240-249) disposes the compositor and closes proc1.stdin (so the palettegen ffmpeg will likely EOF and exit on its own), but the abandoned decoder generator is the real leak — FfmpegDecoder.frames() is an async* whose `finally` (ffmpeg_decoder.dart:110-113) only stops a stopwatch and does NOT kill _process; cancelling the generator cancels the stdout subscription but leaves the ffmpeg decode subprocess alive, blocked once its stdout pipe fills. So a compose/decode failure orphans the decoder ffmpeg, exactly as claimed, whereas ExportPipeline kills decoder+encoder on every failure path (export_pipeline.dart:398-399). It is a genuine resource leak, but only on non-cancel failure paths (the common cancellation case IS handled) and the orphan is reaped at app exit, so minor is appropriate.
</details>

---

### [MINOR] VideoToolbox capability probe caches a transient failure for the whole process lifetime

- **Subsystem:** slipreel_engine — export / encode / ffmpeg
- **Category:** correctness · **Confidence:** high
- **Location:** `packages/slipreel_engine/lib/export/ffmpeg_encoder.dart:186-217`

**What:** _videotoolboxCanEncode caches its result in a process-static (`_videotoolboxUsable`) and the catch block treats ANY failure to spawn the probe (ffmpeg momentarily missing, OS transiently refusing to spawn under memory pressure, EINTR) as `ok = false` and caches it permanently. After one such transient miss, every subsequent export in that app session silently falls back to libx264 software encoding — markedly slower and higher CPU — with no path to recover without restarting the app. ffmpeg-binary resolution elsewhere deliberately avoids caching failures (FfmpegResolver._cached holds only successes) for exactly this reason; the VT probe does the opposite.

**Suggested fix:** Only cache a definitive result: cache `true` always, but on the catch path (probe could not even run) return false WITHOUT writing the cache, so the next export re-probes. Optionally distinguish 'probe ran and VT rejected' (cacheable false) from 'probe could not spawn' (non-cacheable).

<details><summary>Verifier reasoning</summary>

Confirmed. _videotoolboxCanEncode (ffmpeg_encoder.dart:196-217) caches into the process-static _videotoolboxUsable, and the catch block (210-216) sets `ok = false` for ANY spawn failure — ffmpeg vanished between resolve() and probe, OS refusing to spawn under memory pressure, EINTR — then unconditionally writes `_videotoolboxUsable = ok` and returns. A single transient spawn miss is thus cached as a permanent 'no hardware', forcing every subsequent export in the session onto libx264 software encoding with no recovery short of restarting the app. This is the opposite of FfmpegResolver, which deliberately never caches a failed lookup (ffmpeg_resolver.dart:38-40 comment 'A failed lookup is never cached so resolve re-scans... ffmpeg may be installed mid-session'), so the asymmetry the finding draws is accurate. The defect (caching a non-definitive 'could-not-probe' result) is real independent of how often the probe transiently fails; the proper fix is to cache only definitive results and return false without caching on the catch path. Trigger is genuinely rare, so minor is correct.
</details>

---

### [MINOR] splitSlice duplicates fadeIn/fadeOut onto BOTH halves, injecting spurious fades at the cut seam

- **Subsystem:** slipreel_engine — models / state / timeline / editor
- **Category:** correctness · **Confidence:** high
- **Location:** `packages/slipreel_engine/lib/state/editor_project_controller.dart:451-458`

**What:** When a slice is cut in two, both halves are produced with `parent.copyWith(...)`, which carries the parent's fadeIn AND fadeOut onto each half. So the LEFT half keeps the parent's fadeOut (now applied at the brand-new internal seam) and the RIGHT half keeps the parent's fadeIn (applied at the internal seam too). If the user had set, say, a 500ms fade-out on the clip, after splitting in the middle the audio/visual will now also fade out at the cut point and fade back in right after — a dip the user never asked for. mergeSeam does the right thing (left.fadeIn + right.fadeOut), so split and merge are asymmetric. The dip appears identically in preview and export (so not a divergence), but it is still wrong content.

**Suggested fix:** On split, give the interior edges zero fade: left should keep parent.fadeIn but get fadeOut: Duration.zero; right should keep parent.fadeOut but get fadeIn: Duration.zero. e.g. `left = parent.copyWith(cutEnd: sourcePosition, trimEnd: sourcePosition, fadeOut: Duration.zero)` and `right = parent.copyWith(cutStart: sourcePosition, trimStart: sourcePosition, fadeIn: Duration.zero)`.

<details><summary>Verifier reasoning</summary>

Confirmed. Fades are slice-local in the export filter graph: n_slice_filter_graph.dart applies `fade=t=in:st=0:d=fadeIn` at every slice's start and `fade=t=out:st=effectiveOut-fadeOut:d=fadeOut` at every slice's end, independently per slice, for both video (lines 250-260) and audio (lines 291-301). splitSlice (editor_project_controller.dart:451-458) builds both halves with bare `parent.copyWith(cutEnd/trimEnd...)` and `parent.copyWith(cutStart/trimStart...)`, so left inherits parent.fadeOut (now applied at the new interior seam) and right inherits parent.fadeIn (applied right after the seam). mergeSeam (lines 544-551) is correctly edge-only (`fadeIn: left.fadeIn, fadeOut: right.fadeOut`), proving the split/merge asymmetry. So a user-set fade-out produces a spurious dip-and-rise at the cut point. It only manifests when fades are non-default (both default to Duration.zero), so minor is the right severity; preview and export agree (not a divergence), but the content is wrong.
</details>

---

### [MINOR] MotionTuningController.activePreset returns null for a JSON-loaded tuning that equals a shipped preset

- **Subsystem:** slipreel_engine — models / state / timeline / editor
- **Category:** correctness · **Confidence:** high
- **Location:** `packages/slipreel_engine/lib/state/motion_tuning_controller.dart:50-55`

**What:** activePreset detects the current preset with `identical(state, p.tuning)`. That only works after usePreset() (which assigns the exact const preset instance). The class is explicitly documented to also be seeded via `replace(MotionTuning.fromJson(...))` at app startup from a sidecar. MotionTuning has no `operator ==`/`hashCode` (it uses identity), so a freshly-decoded tuning is never identical to MotionTuning.defaults/snappy/cinematic even when every field matches. Result: after a sidecar reload, the inspector's preset picker shows no preset highlighted even though the values are exactly 'Default'/'Snappy'/'Cinematic'. Reproduces every cold start that loads a saved-as-a-preset tuning.

**Suggested fix:** Compare by value: add value `operator ==`/`hashCode` to MotionTuning and use `state == p.tuning` here. (MotionTuning lives in rendering/, but the bug surfaces through this in-scope accessor.)

<details><summary>Verifier reasoning</summary>

Confirmed. activePreset (motion_tuning_controller.dart:50-55) detects the preset via `identical(state, p.tuning)`, which only holds after usePreset() assigns the exact const instance. replace() (line 43) sets an arbitrary instance, and the class docstring explicitly states it is seeded via a JSON-loaded sidecar at startup. I verified motion_tuning.dart: the MotionTuning class (line 19) defines no `operator ==`/`hashCode` and is not Equatable/freezed, so it uses identity equality. A freshly-decoded MotionTuning that field-for-field equals defaults/snappy/cinematic is therefore never `identical` to the const presets, so activePreset returns null and the inspector picker shows nothing highlighted after a sidecar reload. Reproduces on every cold start that loads a saved-as-a-preset tuning. Minor is appropriate (UI-only, no data effect).
</details>

---

### [MINOR] ZoomRegion.fromJson accepts non-positive duration in release builds (assert is stripped)

- **Subsystem:** slipreel_engine — models / state / timeline / editor
- **Category:** correctness · **Confidence:** medium
- **Location:** `packages/slipreel_engine/lib/models/zoom_region.dart:113, 255-256, 292`

**What:** The only guard against a zero/negative `duration` is `assert(duration > Duration.zero)`, which is compiled out of release/profile builds (the app ships release). ZoomRegion.fromJson reads `durationMicros` with no clamp, so a corrupt or hand-edited `.editor.json` with `durationMicros: 0` (or negative) constructs a degenerate region in production. getProgress() is accidentally safe (`x/0` → Infinity/NaN, then `.clamp(0,1)` yields 1.0 in Dart), but the zero-length region still flows into ramp/overlap math in the rendering engine and into AutoZoomDetector._dropOverlaps comparisons with an undefined visual result. CaptionSegment/CameraRegion have the same assert-only stance, but ZoomRegion is the one whose duration feeds per-frame ramp division.

**Suggested fix:** Clamp in fromJson to a minimum positive duration (e.g. `max(micros('durationMicros'), const Duration(microseconds: 1))`) so corrupt sidecars can't produce a zero/negative-length region in release builds; or have the loader drop regions whose decoded duration is <= 0.

<details><summary>Verifier reasoning</summary>

Partly confirmed; core premise real, downstream impact overstated. The constructor's only `duration` guard is `assert(duration > Duration.zero)` (zoom_region.dart:113), which is stripped in release/profile, and fromJson (line 291) reads `duration: micros('durationMicros')` with NO clamp — notably enterDuration/exitDuration/followDuration all get explicit `.isNegative` guards in the constructor while `duration` does not. ZoomRegion.fromJson IS reachable from project load (Timeline.fromJson -> editor_project_state.dart), so a corrupt/hand-edited `.editor.json` with `durationMicros: 0` or negative does construct a degenerate region in a release build — that part is real and the defensive fix is warranted. However the claimed 'undefined visual result' downstream is milder than described: the ramp-division consumers _exitRampWindow/_enterRampWindow (zoom_focal_controller.dart:814,839) explicitly guard `if (regionUs <= 0) return null`; ZoomTransformer does not divide by duration; getProgress is accidentally safe; and _dropOverlaps just does start+duration arithmetic with no NaN/crash. AutoZoomDetector._buildRegion itself guards `duration <= Duration.zero` (line 90), so only a corrupt sidecar (not the detector) can produce this. Net: a real, defensive, low-end-minor robustness gap (invalid model object violating the documented invariant), not a crash/NaN bug.
</details>

---

### [MINOR] EditorProjectState.copyWith(captionSource:) on a recording with no caption track silently creates an empty caption track

- **Subsystem:** slipreel_engine — models / state / timeline / editor
- **Category:** correctness · **Confidence:** high
- **Location:** `packages/slipreel_engine/lib/state/editor_project_state.dart:241-258`

**What:** When only `captionSource` is provided (e.g. EditorProjectController.setCaptionSource) and the timeline has no caption tracks yet, the branch builds a brand-new CaptionTrack with empty segments and that source. So setting the 'transcribe from' source before any captions exist materializes an empty caption track in the project (and persists it). It also means `state.captionSource` flips from null to a value with zero captions, which can confuse UI that keys 'captions exist' off the track's presence. Contained (no data loss), but it writes state the user didn't intend.

**Suggested fix:** When `captionSegments == null` and the track list is empty, skip creating a track for a source-only change (no captions to attach a source to), or gate setCaptionSource so it only writes when a caption track already exists.

<details><summary>Verifier reasoning</summary>

Confirmed. In EditorProjectState.copyWith (editor_project_state.dart:241-258) the branch fires when `captionSegments != null || captionSource != null`. When only captionSource is supplied and `t.captionTracks` is empty, it constructs a brand-new `CaptionTrack(segments: captionSegments ?? const <CaptionSegment>[], source: captionSource ?? CaptionAudioSource.mixed)` — i.e. an empty-segment caption track with the chosen source. So setting the transcribe-from source before any captions exist materializes (and would persist, since captionTracks is serialized via timeline.toJson) an empty caption track, and flips captionSource from null to a value with zero captions, which can mislead UI that keys 'captions exist' off track presence. Contained, no data loss, writes unintended state — minor is correct.
</details>

---

### [MINOR] AccumulationCursorPainter renders a translucent cursor during the first exposure window of the recording

- **Subsystem:** slipreel_engine — effects / captions / audio / utils
- **Category:** correctness · **Confidence:** medium
- **Location:** `packages/slipreel_engine/lib/effects/accumulation_cursor_painter.dart:186-296`

**What:** alphaPerStamp is fixed at 1.0/sampleCount on the assumption that all sampleCount stamps are drawn (a stationary cursor then sums to alpha 1.0 exactly, which the comment at 178-186 explicitly relies on). But the per-stamp loop skips any stamp whose sub-frame time t = position - i*dtMicros is < 0 (line 291 `if (t < 0) continue;`) and any stamp where cursorAtFiltered returns null for times before the first recorded sample (line 297). For output frames within ~exposureMs of t=0 (and before the first cursor sample), fewer than sampleCount stamps are drawn, so a stationary cursor accumulates to validStamps/sampleCount < 1.0 and renders visibly translucent for the first frames of the recording. The dropped-stamp count is never compensated into alphaPerStamp.

**Suggested fix:** Either count the stamps that will actually be drawn first and use alphaPerStamp = 1.0/drawnCount, or clamp t to >= 0 (and to the first sample time) instead of skipping, so the integration still sums to 1.0 at the recording start.

<details><summary>Verifier reasoning</summary>

The core mechanism is real but the evidence is partly wrong. alphaPerStamp is fixed at 1.0/sampleCount (line 186) and the `if (t < 0) continue;` guard (line 291) drops trailing stamps without recompensing alpha, so a stationary cursor at the very start of the timeline accumulates to drawnStamps/sampleCount < 1.0 and renders translucent, fading in as `position` grows past the exposure window. However the finding has two inaccuracies: (1) it uses the painter's 40ms default, but production preview AND export pass exposureMs = 150.0 * intensity (frame_compositor.dart:1044; PlaybackCanvas hard-codes accumulation), so the affected region is the first ~150ms and ONLY when cursor blur intensity is non-zero (zero blur -> exposure 0 -> dtMicros 0 -> all stamps at t=position, no skip, sharp full-alpha). (2) The claim that `cursorAtFiltered` returns null for times before the first recorded sample is FALSE: cursorAt -> getPositionAt returns `after` (the first sample) when `before` is null (cursor_recording.dart:72), never null for a non-empty recording, and paint() already early-returns when positions is empty (line 143). So only the `t<0` guard actually drops stamps. Net: a genuine but transient, conditional, purely-cosmetic fade-in confined to the opening exposure window; minor is appropriate (arguably nit).
</details>

---

### [MINOR] parseWhisperJson accepts zero-/negative-duration segments that silently never render

- **Subsystem:** slipreel_engine — effects / captions / audio / utils
- **Category:** correctness · **Confidence:** medium
- **Location:** `packages/slipreel_engine/lib/captions/caption_transcriber.dart:30-39`

**What:** The parser keeps any segment with non-null from/to and non-empty text, but never checks toMs >= fromMs. whisper.cpp occasionally emits segments whose 'to' equals 'from' (zero duration) or, rarely, is earlier. Such a segment becomes a CaptionSegment with endMicros <= startMicros. CaptionSegment.isActiveAtMicros uses the half-open interval `t >= startMicros && t < endMicros`, which is empty when end <= start, so the caption is counted in CaptionDone(count) and listed in the editor but never appears on the video, and a reversed pair could also confuse downstream sorting/rendering.

**Suggested fix:** After computing fromMs/toMs, skip or repair degenerate spans: `if (toMs <= fromMs) continue;` (or clamp toMs = fromMs + minVisibleMs). This keeps the reported count consistent with what actually renders.

<details><summary>Verifier reasoning</summary>

Confirmed structurally. parseWhisperJson (caption_transcriber.dart:30-39) keeps any segment with non-null from/to and non-empty text, with no `toMs > fromMs` guard, producing a CaptionSegment with endMicros <= startMicros when whisper emits a zero/negative span. CaptionSegment.isActiveAtMicros is half-open `t >= startMicros && t < endMicros` (caption_segment.dart:35), which is the empty set when end <= start, so caption_renderer.activeCaptionAt (a linear first-match scan) never returns it and it never paints. Meanwhile CaptionDone(segments.length) counts it and replaceCaptionSegments (editor_project_controller.dart:246) stores it verbatim with no validation, so it appears in the editor's segment list -> count/list vs render inconsistency is real. The 'reversed pair confuses downstream sorting/rendering' sub-claim is overstated: activeCaptionAt is order-independent and there is no sort that a reversed pair would corrupt. Contingent on whisper.cpp actually emitting to <= from, which is uncommon, so minor (low-frequency, cosmetic/consistency rather than a crash or wrong-frame bug).
</details>

---

### [MINOR] DisplayLatencyProbe.dispose() races its own async poll → ValueNotifier value set after dispose

- **Subsystem:** screen_recorder — state / controllers (recording, permissions, recovery)
- **Category:** concurrency · **Confidence:** high
- **Location:** `packages/screen_recorder/lib/state/display_latency_probe.dart:42-61`

**What:** pollOnce() is async and awaits a method-channel call, then writes `_latency.value = _smoother.value`. dispose() cancels the timer and immediately disposes `_latency`. If dispose() runs while a poll is mid-await (the channel call is in flight; window is real at a 125ms interval), the poll completes after dispose and assigns to a disposed ValueNotifier, which throws/asserts ('A ValueNotifier was used after being disposed'). Because pollOnce errors are not caught at the call site (only the channel invoke is wrapped), this surfaces as an unhandled exception when the editor preview is torn down right after a latency poll fires.

**Suggested fix:** Track a disposed flag and bail before writing: set `_disposed = true` in dispose() and guard `if (_disposed) return;` after the await in pollOnce() before `_latency.value = ...`. (Cancelling the timer alone does not stop an already-dispatched async poll.)

<details><summary>Verifier reasoning</summary>

Confirmed in display_latency_probe.dart. pollOnce() (42-55) awaits `_channel.invokeMethod(...)` then writes `_latency.value = _smoother.value` at line 54. dispose() (57-61) cancels the timer and immediately calls `_latency.dispose()`. There is no disposed flag. If dispose() runs while a poll is mid-await (real window at the 125ms interval, e.g. editor preview torn down right after a poll fires), the poll resumes after dispose and assigns to a disposed ValueNotifier, which asserts/throws 'A ValueNotifier was used after being disposed'. The future returned by pollOnce is created fire-and-forget by `Timer.periodic(interval, (_) => pollOnce())` (line 36) and is not awaited or error-handled, so the throw surfaces as an unhandled async exception. Cancelling the timer does not stop an already-dispatched poll. The suggested _disposed guard after the await is the correct fix. Real but minor.
</details>

---

### [MINOR] RecoveryService.recover() appends to history with an unguarded await after creating the recovered file; a failure orphans the recovered clip and leaves the marker

- **Subsystem:** screen_recorder — state / controllers (recording, permissions, recovery)
- **Category:** correctness · **Confidence:** high
- **Location:** `packages/screen_recorder/lib/state/recovery_service.dart:136-148`

**What:** Every other step in recover() is wrapped in try/catch and degrades gracefully, but `await history.append(...)` (136) is not. If the prefs/history write throws, the exception propagates out of recover() AFTER the `.recovered.mp4` was written but BEFORE the cleanup block (145-147) that deletes the partial, the NDJSON, and removes the marker. Result: the recovered file exists on disk, the original partial + marker also remain, and on the next cold launch the same partial is re-offered for recovery — re-running recover() overwrites `.recovered.mp4` (ffmpeg `-y`) and tries to append again, so a flaky history write can produce repeated recovery prompts / duplicate history entries once it finally succeeds.

**Suggested fix:** Wrap the history append in try/catch (log + continue) so cleanup still runs and the marker is removed even if the history write fails, matching the controller's own 'never block a recording on a prefs write' policy used in stopRecording().

<details><summary>Verifier reasoning</summary>

Confirmed in recovery_service.dart. recover() wraps the ffmpeg re-mux (63-81), the ffprobe (85-99), the cursor-sidecar restore (102-115), and the .meta.json write (118-133) each in try/catch that logs and degrades. In contrast `await history.append(RecordingHistoryEntry(...))` (136-142) is bare, and it sits BEFORE the cleanup block `_safeDelete(partial)` / `_safeDelete(...cursorNdjsonPath)` / `markerStore.remove(candidate.marker.id)` (145-147). If the prefs/history write throws, the exception propagates out of recover() after the `.recovered.mp4` was already written (ffmpeg ran with `-y`) but before cleanup, so the partial + marker remain and the same partial is re-offered on the next cold launch; re-running recover() overwrites `.recovered.mp4` and re-appends, risking duplicate history entries once the flaky write finally succeeds. This contradicts the 'never block on a prefs write' policy the controller itself follows in stopRecording() (490-500), which wraps the identical append in try/catch. Real correctness defect; minor.
</details>

---

### [MINOR] stopRecording() mutates _durationTimer/_startTime outside the pause/resume serialization queue, racing an in-flight pause/resume

- **Subsystem:** screen_recorder — state / controllers (recording, permissions, recovery)
- **Category:** concurrency · **Confidence:** high
- **Location:** `packages/screen_recorder/lib/state/recording_state.dart:401-421, 559-597`

**What:** pause/resume are serialized via _enqueueTransition, but stopRecording() is not. A user can pause (op awaiting the native pause) and then hit Stop (separate hotkey/UI path through RecordingActionRouter.stop()) before the pause op completes. stopRecording immediately cancels _durationTimer, reads/nulls _startTime, cancels the cursor/keystroke/error subscriptions, and calls _videoEncoder.stop(), while the still-pending pause op will, on resume, set `state = paused` (clobbering the `processing`/`completed` state stop set) and rely on _startTime it already nulled. The two methods interleave shared mutable fields (_durationTimer, _startTime, subscriptions) with no mutual exclusion, so the final status and the duration readout become order-dependent and can land on a stale 'paused' over a session that was actually stopped.

**Suggested fix:** Route stopRecording through _enqueueTransition as well (or share a single lock) so stop cannot interleave with an in-flight pause/resume, and have the pause/resume bodies re-check status after their await before writing state.

<details><summary>Verifier reasoning</summary>

Confirmed. stopRecording() (401-552) is NOT wrapped in _enqueueTransition; it directly cancels _durationTimer, reads/nulls _startTime (406-411), cancels the cursor/keystroke/error subscriptions (413-418), and awaits _videoEncoder.stop() (420). pauseRecording()/resumeRecording() run inside _enqueueTransition (569/584) and write `state` only after their native await; the queue (559-567) serializes pause vs resume but NOT stop vs pause/resume. RecordingActionRouter.stop() (160-167) calls stopRecording() directly while pauseOrResume() (169-177) goes through the queue, so a user can pause (op awaiting native pause; status still `recording`) then hit Stop via a separate hotkey/UI path. stopRecording's guard is `state.isRecording` which includes paused (isRecording => recording||paused, 70-71), so it proceeds, sets status=processing, and tears down shared fields, while the still-pending pause op's continuation later sets `state = copyWith(status: paused)` clobbering the processing/completed state and relying on a _startTime stop already nulled. The two methods interleave _durationTimer/_startTime/subscriptions with no mutual exclusion, making the final status and duration order-dependent. Real concurrency defect; severity minor-to-major. Keeping minor since it requires a deliberate stop-during-pause-await and the worst case is a stale status rather than data loss.
</details>

---

### [MINOR] PermissionsController.request() lacks the try/catch that refreshAll() has; a method-channel throw propagates to UI callers

- **Subsystem:** screen_recorder — services / platform / main / onboarding / debug
- **Category:** bug · **Confidence:** high
- **Location:** `packages/screen_recorder/lib/state/permissions_controller.dart:56-76`

**What:** refreshAll() wraps its platform calls in try/catch and keeps the last-good snapshot on failure, but request() makes the same kind of platform/method-channel calls (requestScreenRecordingPermission, requestMicrophonePermission, requestAccessibilityPermission + getAccessibilityPermission, requestCameraPermission) with no error handling at all. If any of those throws a PlatformException (channel not wired, OS prompt machinery fails), the exception propagates straight out to the caller (onboarding permissions_page.dart:72 and settings_screen). This controller is constructed and refreshed in main() init, so its robustness is part of the startup/permissions path. The inconsistency means the deliberately-defensive refreshAll coexists with a request() that can throw uncaught.

**Suggested fix:** Mirror refreshAll(): wrap request()'s platform calls in try/catch, log via AppLogger.permissions, and on failure return a sane status (e.g. the current state[kind] or PermissionStatus.denied) instead of letting the exception escape into widget callbacks.

<details><summary>Verifier reasoning</summary>

Confirmed. PermissionsController.request() (permissions_controller.dart:56-76) makes the same kind of platform/method-channel calls as refreshAll() but, unlike refreshAll() (lines 37-54, which try/catch + log + keep last-good state), has no error handling, so a PlatformException propagates to callers. Verified the three callers: permissions_page.dart:72 and settings_screen.dart:201 invoke it as a fire-and-forget onGrant callback (return value not awaited, no catchError) so a throw becomes an unhandled async/framework error with no user feedback; recording_action_router.dart:136 awaits it inside _ensureCameraForDevice with no try/catch around the request call, so a throw propagates up the camera-gating flow. The inconsistency between the deliberately-defensive refreshAll and a throwing request is real and the suggested fix (mirror refreshAll) is sound. Impact is modest (these channels rarely throw and the UI callers don't synchronously crash), so minor is the right ceiling.
</details>

---

### [MINOR] Zoom/Camera pill drag divides by contentWidth without a zero guard (Infinity → .round() throws)

- **Subsystem:** screen_recorder — timeline / transport / zoom / canvas widgets
- **Category:** bug · **Confidence:** medium
- **Location:** `packages/screen_recorder/lib/ui/widgets/timeline/zoom_lane.dart:428-430 (and camera_lane.dart 341-343)`

**What:** In `_ZoomPillState._update` (and the identical `_CameraPillState._update`), `final scale = widget.duration.inMicroseconds / widget.contentWidth;` then `(_dxAccum * scale).round()`. `contentWidth` is threaded down as `cw = contentWidth(viewport, scale) = viewport * scale`, which is 0 whenever the timeline viewport width is 0 (first layout pass / a collapsed editor pane). If a drag-update is delivered while contentWidth is 0, `scale` becomes Infinity and `(_dxAccum * Infinity).round()` throws `UnsupportedError: Infinity or NaN toInt`, killing the gesture frame. The xToTime helper in timeline_constants.dart guards `pps <= 0` for this exact reason, but these two drag handlers do not.

**Suggested fix:** Early-return or treat as no-op when `widget.contentWidth <= 0` at the top of `_update` (e.g. `if (widget.contentWidth <= 0) return;`), mirroring the `pps <= 0` guard in `xToTime`.

<details><summary>Verifier reasoning</summary>

Confirmed in the code: `_ZoomPillState._update` (zoom_lane.dart:427-429) does `_dxAccum += dxDelta; final scale = widget.duration.inMicroseconds / widget.contentWidth; final deltaUs = (_dxAccum * scale).round();` and `_CameraPillState._update` (camera_lane.dart:339-342) is identical. `contentWidth` is an `int / double` division, so when `widget.contentWidth == 0` it yields `double.infinity`, and `(_dxAccum * infinity).round()` throws `UnsupportedError: Infinity or NaN toInt` for any non-zero `_dxAccum` (true after the first accumulated delta). `cw` is threaded from `_timeAxisContentWidth(width, scale) = contentWidth(max(0,width-2*inset), scale) = viewport*scale`, which is 0 when the LayoutBuilder constraint width is 0. The sibling `xToTime` does guard `pps <= 0` (timeline_constants.dart:58) and `_update` has no analogous guard, so the defensive gap is genuinely present in both files exactly as described. Materiality is low, though: a drag can only START if the pill is laid out with grabbable extent, which requires non-zero content width, so the only trigger is an active pill drag racing a relayout to exactly width 0 (e.g. editor pane collapsing mid-gesture) — a narrow, unlikely sequence. Real latent crash, low reachability.
</details>

---

### [MINOR] EditorTimeline schedules a post-frame callback on every 60Hz playhead tick

- **Subsystem:** screen_recorder — timeline / transport / zoom / canvas widgets
- **Category:** perf · **Confidence:** high
- **Location:** `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart:812-818`

**What:** `_onPositionTick` is the `widget.position` ValueListenable listener; it fires on every per-vsync playhead update (~60Hz during playback). Each invocation calls `WidgetsBinding.instance.addPostFrameCallback(...)` to run `_maybeAutoFollow`. That schedules a new one-shot callback every frame for the whole duration of playback. While each callback does fire exactly once (so there is no unbounded accumulation), it allocates a closure + queues a callback 60×/s purely to read the position that is already available synchronously, and `_maybeAutoFollow` early-returns immediately when `timelineScale == 1.0` (the common case). This is wasted per-frame work on the hot playback path the ValueListenable refactor was specifically meant to keep cheap.

**Suggested fix:** Short-circuit before scheduling: `if (!widget.isPlaying || widget.timelineScale == 1.0 || _userOverrodeScroll) return;` at the top of `_onPositionTick`, so the post-frame callback is only queued when auto-follow can actually do something.

<details><summary>Verifier reasoning</summary>

Confirmed exactly as described. `widget.position.addListener(_onPositionTick)` (line 618) registers the per-vsync ValueListenable listener, and `_onPositionTick` (812-818) unconditionally allocates a closure and calls `WidgetsBinding.instance.addPostFrameCallback(...)` on every notification, while `_maybeAutoFollow` (1124) early-returns at `if (!widget.isPlaying) return; if (widget.timelineScale == 1.0) return;` (1125-1126) — the common no-zoom case. During playback at timelineScale 1.0 this queues ~60 one-shot callbacks/sec purely to read a value already available synchronously, on the exact hot path the ValueListenable refactor (commented at 807-811) was meant to keep cheap. No unbounded accumulation (each fires once), so impact is modest, but it is genuinely wasted per-frame work and the suggested short-circuit (`if (!widget.isPlaying || widget.timelineScale == 1.0 || _userOverrodeScroll) return;` before scheduling) is correct. Real but minor perf issue.
</details>

---

### [MINOR] RecoveryModal calls setState after await with no mounted guard — crashes if dialog closed mid-recovery

- **Subsystem:** screen_recorder — inspector / export-dialog / command-palette / camera / alerts widgets
- **Category:** concurrency · **Confidence:** high
- **Location:** `packages/screen_recorder/lib/ui/widgets/recovery_modal.dart:36-59`

**What:** _recover() and _discard() are async, await widget.onRecover(c)/widget.onDiscard(c), then call setState() unconditionally with no `if (!mounted) return;` guard. The AlertDialog's 'Close' FilledButton (lines 114-117) calls Navigator.of(context).maybePop() and is ALWAYS enabled, so the user can dismiss the recovery dialog while a recover/discard is still running. Recovery is an ffmpeg `-c copy` re-mux (RecoveryService) that can take seconds. When the awaited future completes after the modal is popped, setState() runs on a disposed State → 'setState() called after dispose()' exception, crashing the frame. This is on the cold-launch crash-recovery path, so it surfaces right when the app is already in a fragile post-crash state. The sibling method _discardAll() (line 67) DOES guard with `if (mounted)` before touching Navigator, and scene_blur_overlay.dart / command_palette.dart consistently use `if (!mounted) return;`, so this is an inconsistency, not an intentional omission.

**Suggested fix:** Add `if (!mounted) return;` immediately after each `await` and before the following setState in both _recover (including the catch block) and _discard, matching the existing pattern in _discardAll and the rest of the codebase.

<details><summary>Verifier reasoning</summary>

Confirmed against recovery_modal.dart. _recover() (lines 36-50) awaits widget.onRecover(c) then calls setState() in both the success and catch branches with no `if (!mounted) return;` guard; _discard() (lines 52-59) does the same after `await widget.onDiscard(c)`. The 'Close' FilledButton (lines 114-117) is unconditionally enabled and calls Navigator.of(context).maybePop(), so the user can pop the dialog while a recover/discard future is still in flight. The sibling _discardAll() (lines 61-68) DOES guard with `if (mounted)` before Navigator, proving the pattern is known and this is an inconsistency. onRecover ultimately drives RecoveryService's ffmpeg `-c copy` re-mux which can take seconds, so the race window is real, and a setState-after-dispose throws a FlutterError. I downgrade from major to minor because triggering it requires deliberately racing the Close button against a multi-second operation (narrow window), the impact is a caught/logged framework exception on a transient modal rather than data loss or a persistent crash, and the recovery work itself still completes; the fix (add `if (!mounted) return;` after each await) is trivial and correct.
</details>

---

### [MINOR] Recents thumbnails never refresh after an edit — Image.file serves the stale cached PNG

- **Subsystem:** screen_recorder — screens / bar / theme UI
- **Category:** correctness · **Confidence:** high
- **Location:** `packages/screen_recorder/lib/ui/screens/recents/recording_card.dart:99-105`

**What:** RecordingThumbnailService is explicitly designed to regenerate the thumbnail when `<videoPath>.editor.json` is newer than the cached PNG (see _isStale), writing the new PNG to the SAME path `<videoPath>.thumb.png`. RecordingCard renders that file with `Image.file(snap.data!.pngFile, gaplessPlayback: true)`. Flutter's default FileImage keys the image cache on (path, scale) only — it does not look at file contents or mtime. So when a user edits a recording (changes zoom/crop/frame), returns to Recents and the service correctly regenerates the PNG in place, `Image.file` still paints the OLD decoded bytes from imageCache. `gaplessPlayback: true` further guarantees the previous frame stays on screen. The thumbnail silently lies about the recording's current look until the app is restarted (or the cache is evicted under memory pressure). _refresh() clears the in-memory memo and the service memo, but nothing evicts Flutter's image cache, so the regeneration work is wasted.

**Suggested fix:** Bust Flutter's image cache when the file is regenerated. Either evict before painting (e.g. in the service after writing: `await FileImage(thumb).evict()`), or key the widget's image on the file mtime so a new mtime forces a reload — e.g. `Image(image: ResizeImage(FileImage(file)), key: ValueKey(file.lastModifiedSync()))`, or pass the mtime into a custom ImageProvider's `obtainKey`. Returning the resolved mtime in RecordingThumbnail and using it as the Image key is the cleanest.

<details><summary>Verifier reasoning</summary>

Confirmed. recording_thumbnail_service.dart:101 always writes the regenerated PNG to the SAME deterministic path File('${entry.videoPath}.thumb.png'), and _isStale (112-120) regenerates when editor.json is newer. RecordingThumbnail.pngFile is therefore the same File path across regenerations. recording_card.dart:99-104 renders it via Image.file(snap.data!.pngFile, gaplessPlayback: true). Flutter's FileImage keys ImageCache on (path, scale) only — it ignores mtime/contents — so after an in-place regeneration the OLD decoded bytes are served. A grep over packages/screen_recorder/lib confirms zero evict/imageCache/FileImage-mtime-key/unique-filename handling anywhere near thumbnails. The bug is in fact worse than reported: recents_screen.dart:82-86 _open() pushes PlaybackScreen with no .then(_refresh), so returning from the editor doesn't even rebuild the _futures memo — the same Future and same cached image persist. The in-file comment at recents_screen.dart:62-67 documents the intent to avoid stale thumbnails by clearing the memos, but that work is wasted because it never busts Flutter's image cache. Real user-visible defect: edited recordings show a stale thumbnail until app restart. I downgrade to minor because it is purely cosmetic (Recents preview), does not touch the export/output path, and self-heals on restart.
</details>

---

### [MINOR] debugPlaybackController is set in build() but never cleared on dispose — use-after-dispose for ext.slipreel.* VM hooks

- **Subsystem:** screen_recorder — screens / bar / theme UI
- **Category:** concurrency · **Confidence:** high
- **Location:** `packages/screen_recorder/lib/ui/screens/playback_screen.dart:2049-2052`

**What:** The playback screen publishes its VideoPlayerController into the top-level `debugPlaybackController` global inside build() (guarded by assert, so debug/profile only). dispose() never resets it to null. After the user pops the editor, the global still references the now-disposed controller. The VM-service extensions in main.dart (ext.slipreel.play/pause/seek/state) call `debugPlaybackController?.play()/.pause()/.seekTo()` on it — a use-after-dispose that throws inside the disposed controller. The project's memory notes say agent-driven debugging relies on these hooks (ext.slipreel.* / debugPlaybackController), so a debugging session that pokes playback after the editor closed will hit a disposed-object error instead of a clean no-op. Release builds are unaffected (assert-only).

**Suggested fix:** In dispose(), clear the global when this screen owned it: `assert(() { if (identical(debugPlaybackController, _controller)) debugPlaybackController = null; return true; }());` placed before `_controller.dispose()`.

<details><summary>Verifier reasoning</summary>

Confirmed, though the described failure mechanism is partly overstated. playback_screen.dart:87 declares top-level global VideoPlayerController? debugPlaybackController; build() assigns it _controller at line 2050 inside an assert (debug/profile only); dispose() (1022-1054) disposes _controller at line 1050 but never nulls the global. Inspecting the locked video_player 2.10.1 source: play() (589) executes `value = value.copyWith(isPlaying: true)` BEFORE any disposed check, and the ValueNotifier value= setter calls notifyListeners() on change, which after super.dispose() (579) trips _debugAssertNotDisposed() and throws 'A VideoPlayerController was used after being disposed.' pause() (605) throws likewise only when transitioning isPlaying true→false. So ext.slipreel.play (main.dart:248), and pause in the playing case, do hit a use-after-dispose error on the stale global. However the finding overstates seekTo and playbackState: seekTo() (683) and _playbackStateJson() (main.dart:289 guards via isInitialized) both early-return on a disposed/uninitialized controller — they are clean no-ops, not throws. Net: a real use-after-dispose for the play (and conditionally pause) hook, debug/profile-only, affecting only agent-driven debugging after the editor closes. Severity minor as the finding itself classifies.
</details>

---

### [MINOR] Live-recording lifecycle Tasks are not main-actor-isolated, so pause/resume (main thread) and start/stop (background Task) race on shared writer/encoder state

- **Subsystem:** screen_recorder_macos (Swift) — capture / writer / encode
- **Category:** concurrency · **Confidence:** medium
- **Location:** `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift:768, 1202-1278, 1329-1355`

**What:** ScreenRecorderMacosPlugin is a plain NSObject (not @MainActor). `handle(_:result:)` is invoked by Flutter on the main thread, but `startLiveRecording` and `stopLiveRecording` do their work inside a bare `Task { ... }` (line 768, line 1203). A bare Task started from a non-isolated method does NOT inherit the main actor — it runs on the cooperative thread pool. Inside those Tasks the plugin mutates non-Sendable instance refs: `self.liveWriter`, `self.liveEncoder`, `self.captureManager`, `self.cameraManager`, `self.cursorTracker`, `self.perfSampler`, `self.liveCaptureWidth/Height` (e.g. lines 956-961, 1267-1281). Meanwhile `pauseRecording`/`resumeRecording` run DIRECTLY on the main thread (no Task) and read `liveWriter`/`cameraManager` (lines 1330, 1340, 1345, 1353), and `writer.stop`'s completion runs on AVFoundation's thread and reads `self.liveCaptureWidth/Height` and `cameraManager`-derived state (lines 1294-1306). The Pause/Resume global hotkeys (Cmd+Shift+P) can fire while a slow start (SCStream spin-up / device AVCaptureSession.startRunning, which the code itself documents as blocking) or a slow stop (finishWriting) is still in flight in the background Task, producing a genuine data race on these references and on `firstVideoFrameAt` ordering. Manifests as intermittent: a pause that no-ops or hits a half-constructed writer, a crash on a torn-down object, or a stop reading stale capture dimensions written by a subsequent start.

**Suggested fix:** Make the plugin's recording control single-threaded. Simplest: annotate the lifecycle entry points (or the whole plugin) `@MainActor` and use `Task { @MainActor in ... }` for `startLiveRecording`/`stopLiveRecording` so all instance-var mutations and the pause/resume reads happen on the main actor; do the genuinely blocking work (SCStream startCapture, AVCaptureSession.start, finishWriting) via `await` off-actor while keeping the state assignments on the actor. Alternatively funnel every access to `liveWriter`/`liveEncoder`/`captureManager`/`cameraManager`/`liveCaptureWidth/Height` through one dedicated serial DispatchQueue.

<details><summary>Verifier reasoning</summary>

The factual premises hold: the class is a plain `public class ScreenRecorderMacosPlugin: NSObject, FlutterPlugin` with no @MainActor (line 9); `startLiveRecording`/`stopLiveRecording` do their work inside a bare `Task { }` (lines 768, 1203) which runs on the cooperative thread pool, NOT the main actor (the comment at line 1027 even wrongly claims it 'inherits the main actor'); and `pauseRecording`/`resumeRecording` execute inline on the calling main thread (lines 1329-1355), reading `self.liveWriter`/`self.cameraManager` while the start/stop Task writes `self.liveWriter`, `self.liveEncoder`, `self.cameraManager`, `self.liveCaptureWidth/Height` (lines 956-961, 1267-1281). So there genuinely is unsynchronized concurrent access to the plugin's optional reference-typed lifecycle properties from two threads — a real data race under Swift's model (ARC retain/release around a concurrent optional-reference read/write is not race-free even though aligned pointer loads are atomic on arm64). HOWEVER the severity is overstated. The objects those references point at are robustly serialized: LiveRecordingWriter funnels every method (start/appendVideo/appendAudio/stop/pause/resume) through a private serial `writerQueue.sync`, with idempotent guards (`guard isStarted, writerActive, !isPaused`), so a pause landing during a stop is internally safe and ordering-independent. The 'half-constructed writer' scenario is not real: `writer.start()` completes synchronously before `self.liveWriter = writer` is assigned (line 815 vs 956), so a non-nil `liveWriter` always points at a fully-built writer. The 'stop reading stale dims from a subsequent start' scenario is also implausible because the Dart `canStartRecording` guard plus early `liveWriter=nil` in stop prevent legitimate start/stop interleave. The genuine, residual hazard is just the racy bare-optional-reference access (low-probability ARC over-release / TSan finding) when Cmd+Shift+P fires during the brief SCStream spin-up or finishWriting window. The suggested @MainActor + `Task { @MainActor in }` fix is correct. Real defect, but minor not major.
</details>

---

### [MINOR] Window capture sizes the framebuffer with NSScreen.main's backing scale even when the window is on a different (mixed-DPI) display

- **Subsystem:** screen_recorder_macos (Swift) — capture / writer / encode
- **Category:** correctness · **Confidence:** high
- **Location:** `packages/screen_recorder_macos/macos/Classes/ScreenCaptureManager.swift:129-130, 197-199`

**What:** Both `captureDimensions(sourceId:isWindow:)` (used to size the encoder + writer) and `startCapture` (used to set `config.width/height`) compute window pixel dimensions as `window.frame.{width,height} * NSScreen.main?.backingScaleFactor`. The scale is taken from the MAIN screen unconditionally, not from the display the target window actually lives on. On a multi-monitor setup mixing a 2x (Retina) and 1x (external) display, a window on the non-main display is captured at the wrong resolution: e.g. a window on a 1x external while the built-in Retina is main is allocated a 2x-sized buffer and SCStream scales the 1x content up to fill it (soft/upscaled), or the inverse halves the captured detail. Because the encoder, writer, and the cursor-transform's pixels-per-point are all derived from the same (wrong-but-consistent) dimensions, there is no crash or dimension mismatch — the artifact is a blurry / mis-scaled window recording, and the recorded resolution differs from what the user expects for that monitor.

**Suggested fix:** Resolve the window's host display and use ITS backingScaleFactor: find the NSScreen whose `frame` contains `window.frame` (or use `window.frame` center) and read that screen's backingScaleFactor, falling back to NSScreen.main only if none matches — mirroring the region path's NSScreen lookup at lines 179-182.

<details><summary>Verifier reasoning</summary>

Confirmed exactly as described. `captureDimensions(sourceId:isWindow:)` computes window pixel size as `Int(window.frame.width * scale)` with `let scale = NSScreen.main?.backingScaleFactor ?? 1.0` (lines 129-130), and `startCapture`'s window branch does the identical `NSScreen.main`-based scaling for `config.width/height` (lines 197-199). The scale is taken from the MAIN screen unconditionally, never from the display the target window actually occupies. The region path right above (lines 179-182) deliberately resolves the matching NSScreen by `NSScreenNumber == region.displayId` and uses ITS backingScaleFactor, proving the codebase knows the correct pattern and the window path is an inconsistent omission. On a mixed-DPI multi-monitor setup, a window on a non-main display is allocated a buffer sized with the wrong scale; because `config.scalesToFit = true` (line 230), SCStream rescales the content to fill it, so the result is a soft/upscaled or detail-reduced recording at an unexpected resolution rather than a crash or dimension mismatch (encoder, writer and cursor pixels-per-point all derive from the same consistent-but-wrong dims). Genuine correctness bug, correctly located; minor because it only manifests on mixed-DPI multi-monitor window capture and degrades quality rather than breaking the recording.
</details>

---

### [MINOR] DeviceCaptureManager.stop() clears callback closures and the `stopped` flag from a non-capture thread while captureOutput reads them on videoQueue

- **Subsystem:** screen_recorder_macos (Swift) — capture / writer / encode
- **Category:** concurrency · **Confidence:** high
- **Location:** `packages/screen_recorder_macos/macos/Classes/DeviceCaptureManager.swift:156-170, 172-184`

**What:** `stop()` runs on the plugin's Task/main context and writes `onVideoFrame = nil`, `onAudioSample = nil`, `onDisconnect = nil`, and sets `stopped = true` directly (lines 157, 164-166). Concurrently, `captureOutput` runs on `videoQueue`/`audioQueue` and READS those same closure properties (`onVideoFrame?(...)`, line 180; `onAudioSample?(...)`, line 183) plus mutates `videoFrameCount`/`loggedFirstVideoFrame`. The `videoQueue.sync {}` / `audioQueue.sync {}` drains at the end of stop() only flush an in-flight callback that has already started; they do not synchronize the property writes that happen BEFORE the drain with the property reads on the capture queue. This is a data race on the optional-closure storage. The window is small, but a device that is still delivering frames at stop time can read a torn closure reference. (`stopped` is likewise read/written without synchronization.)

**Suggested fix:** Clear the callbacks and set `stopped` INSIDE a `videoQueue.sync { ... }` (and audioQueue) block, or guard all access to these closures/flags with the capture queues. Reading/writing `onVideoFrame` etc. on the same queue that delivers frames removes the race; the existing trailing `.sync {}` then also guarantees no later callback fires.

<details><summary>Verifier reasoning</summary>

Confirmed. `stop()` (lines 156-170) executes on the plugin's Task/main context and writes `onVideoFrame = nil`, `onAudioSample = nil`, `onDisconnect = nil` and `stopped = true` directly, NOT inside a videoQueue/audioQueue block. Concurrently `captureOutput` (lines 172-184) reads those same optional-closure properties (`onVideoFrame?(sampleBuffer)`, `onAudioSample?(sampleBuffer)`) and mutates `videoFrameCount`/`loggedFirstVideoFrame` on videoQueue/audioQueue. The trailing `videoQueue.sync {}` / `audioQueue.sync {}` only block until an already-started in-flight callback drains; they do not order the property WRITES (which precede the drain) against concurrent READS on the capture queue. So a device still delivering frames at stop time can read torn optional-closure storage, and `stopped` is a plain Bool touched from both threads — a genuine data race on the closure refs and the flag. The plugin nils these same callbacks before calling stop() (stopLiveRecording lines 1230-1232, tearDown lines 1151-1153), but those writes are themselves off-queue, so they don't remove the race. The in-code comment at lines 161-163 calls the nil-ing 'defense-in-depth' — tacitly conceding it isn't real synchronization. Real low-severity race; the fix (clear callbacks/flag inside videoQueue.sync/audioQueue.sync) is correct.
</details>

---

### [MINOR] ScreenCaptureManager mutable session state is shared between the SCStreamDelegate background queue and start/stop Tasks without synchronization

- **Subsystem:** screen_recorder_macos (Swift) — capture / writer / encode
- **Category:** concurrency · **Confidence:** high
- **Location:** `packages/screen_recorder_macos/macos/Classes/ScreenCaptureManager.swift:12-16, 256, 260-271, 282-285`

**What:** `isCapturing`, `stream`, `streamOutput`, `contentFilter`, `streamConfiguration`, and the `onError`/`onFrameReceived` closures are plain stored properties with no isolation. `startCapture`/`stopCapture` mutate them from the plugin's background Task, while the SCStreamDelegate callback `stream(_:didStopWithError:)` writes `isCapturing = false` and invokes `onError?` (lines 283-284) on ScreenCaptureKit's own delegate queue. If the system tears the stream down (display unplugged, permission revoked) at the same moment the user stops, `isCapturing` and the `onError` closure are read/written from two threads concurrently. No crash is guaranteed, but `isCapturing` can be observed inconsistently (e.g. a stale `true` that blocks the next `startCapture` with `.alreadyCapturing`, or a spurious error emit during an intentional stop because `onError` is read before the plugin nils it).

**Suggested fix:** Serialize all access to the capture session state (the SCStream, the flags, and the callbacks) through a single private serial DispatchQueue, or make ScreenCaptureManager an actor. At minimum guard `isCapturing` and the `onError` invocation in `didStopWithError` with the same queue used by start/stop.

<details><summary>Verifier reasoning</summary>

Confirmed. `isCapturing`, `stream`, `streamOutput`, `contentFilter`, `streamConfiguration`, and the `onError`/`onFrameReceived` closures are plain stored properties with no isolation (lines 12-20). The SCStreamDelegate callback `stream(_:didStopWithError:)` writes `isCapturing = false` and invokes `onError?(error)` on ScreenCaptureKit's own delegate queue (lines 282-285), while `startCapture` sets `isCapturing = true` (line 256) and `stopCapture` sets `isCapturing = false` plus nils stream/output/filter/config (lines 260-271) from the plugin's background Task. Nothing serializes these two threads. If the system tears the stream down (display unplugged, permission revoked) at the same instant the user stops, `isCapturing` and `onError` are read/written concurrently — a real data race that can leave `isCapturing` observed inconsistently (a stale `true` blocking the next `startCapture` with `.alreadyCapturing`) or fire a spurious `onError` during an intentional stop. The plugin sets `captureManager.onError = nil` before `stopCapture()` (lines 1206, 1146) to suppress the intentional-stop emit, but that write is itself off-queue and racy against the delegate's `onError` read, so the suppression is best-effort, not race-free. Correctly located and described low-severity concurrency defect; serializing the session state through one private serial queue (or making the class an actor) is the right fix.
</details>

---

### [MINOR] PerfSampler reports near-zero CPU% because TASK_THREAD_TIMES_INFO excludes live threads

- **Subsystem:** screen_recorder_macos (Swift) — audio / cursor / keystroke / region / sidecar
- **Category:** correctness · **Confidence:** high
- **Location:** `packages/screen_recorder_macos/macos/Classes/PerfSampler.swift:81-93 (currentCpuTimes), consumed at 63-79 (takeSample)`

**What:** The per-second CPU% sampling reads cumulative process CPU time via task_info(TASK_THREAD_TIMES_INFO). On macOS that flavor returns the accumulated user/system time of TERMINATED threads ONLY; time spent by threads that are still alive is NOT included. A screen recorder's capture/encode/audio threads are long-lived and only terminate when the recording stops, so during the recording the per-second delta (user-lastTotalUserTime)+(system-lastTotalSystemTime) stays ~0. The cpuPctAvg/cpuPctP95 values flow all the way to Flutter (recording_state.dart reads perfStats.cpuPctAvg/P95) and are shown to the user, so they will read implausibly low (often ~0%), making the perf readout misleading. This is diagnostics-only (does not affect the recording or export).

**Suggested fix:** Sample live CPU by enumerating threads: call task_threads(mach_task_self_, &threads, &count), then for each thread thread_info(thread, THREAD_BASIC_INFO, ...) and sum (user_time+system_time) for threads whose flags don't include TH_FLAGS_IDLE; remember to vm_deallocate the thread list. Alternatively combine TASK_THREAD_TIMES_INFO (terminated) with the summed live-thread times. Convert the summed seconds delta over wall time to a percentage as today.

<details><summary>Verifier reasoning</summary>

Confirmed in PerfSampler.swift:81-93: currentCpuTimes() reads task_info(mach_task_self_, TASK_THREAD_TIMES_INFO,...) and takeSample() (63-79) computes the per-second delta of that cumulative user+system time. On macOS/Mach, TASK_THREAD_TIMES_INFO accounts for CPU time of TERMINATED threads only; live-thread CPU is obtained by summing thread_info(THREAD_BASIC_INFO) over task_threads(), or by combining with TASK_BASIC_INFO totals. A recorder's capture/encode/audio threads are long-lived and only terminate at stop(), so during recording the delta stays ~0 and cpuPctAvg/cpuPctP95 read implausibly low — directly contradicting the class doc's claim 'CPU% (across all threads)'. The reviewer slightly overstates the consumer impact: the values are not rendered in a user-facing widget; they are logged via AppLogger and feed RecordingPerfSummary.cpuOk (a PASS/FAIL gate against maxCpuPctAvg=10.0). That actually means a perpetually-near-zero CPU reading would make the CPU verdict almost always falsely PASS regardless of real load. Diagnostics-only, does not affect recording/export. Real defect; minor is appropriate.
</details>

---

### [MINOR] CursorTracker emits unconditional print() diagnostics on the per-frame path in Release builds

- **Subsystem:** screen_recorder_macos (Swift) — audio / cursor / keystroke / region / sidecar
- **Category:** perf · **Confidence:** high
- **Location:** `packages/screen_recorder_macos/macos/Classes/CursorTracker.swift:222-225, 380-393`

**What:** detectCursorStateName() and startTracking() call Swift print(...) that is not gated by #if DEBUG and is compiled into Release builds (no print-stripping is configured in the podspec). The first 60 classifier samples print a multi-field line each (`[CursorState] sample #...`), and after that EVERY cursor-type transition prints `[CursorState] changed → ...` for the entire recording. detectCursorStateName runs from the main-thread 60Hz position timer (throttled to ~10Hz for classification), so a shipped build spams stdout during every recording and pays string-formatting cost on the cursor hot path. This is console noise + minor main-thread overhead, not a correctness issue.

**Suggested fix:** Wrap these in `#if DEBUG ... #endif`, or route through the project's gated logger (the plugin already uses a `Self.vlog(...)` verbose-logging helper for `[CursorTransform]`). At minimum drop the unbounded `changed →` transition log in Release.

<details><summary>Verifier reasoning</summary>

Confirmed: CursorTracker.swift:222-225 has a bare print("[CursorState] init...") in startTracking, and detectCursorStateName (380-393) prints '[CursorState] sample #N ...' for the first 60 classifier samples then '[CursorState] changed → ...' on EVERY cursor-type transition for the whole recording. None are wrapped in #if DEBUG, and the podspec (screen_recorder_macos.podspec) configures no print-stripping, so these compile into Release. detectCursorStateName runs from the main-runloop 60Hz position timer, throttled to ~10Hz for classification, so a shipped build spams stdout and pays string-formatting on the cursor path during every recording. The project already has the idiomatic fix: ScreenRecorderMacosPlugin.swift:146-153 defines a gated vlog() helper (#if DEBUG + SLIPREEL_VERBOSE_LOGGING) used for the '[CursorTransform]' logs the reviewer cites. Console noise + minor main-thread overhead, not correctness. Real, minor.
</details>

---

### [MINOR] SourcePickerOverlay.appIcon matches running apps by localizedName, picking the wrong icon for duplicate/empty names

- **Subsystem:** screen_recorder_macos (Swift) — audio / cursor / keystroke / region / sidecar
- **Category:** correctness · **Confidence:** high
- **Location:** `packages/screen_recorder_macos/macos/Classes/SourcePickerOverlay.swift:136-139 (appIcon), 124-128 (call site)`

**What:** The window-picker resolves each target's app icon by `NSWorkspace.shared.runningApplications.first { $0.localizedName == ownerName }`. ownerName comes from SCWindow.owningApplication?.applicationName. Matching on a human-readable name is fragile: two running apps can share a localizedName (e.g. multiple helper processes, or two apps both named the generic owner), and the SCWindow owner name can differ from NSRunningApplication.localizedName, so `.first` may attach the wrong app's icon or none. The result is a cosmetically wrong/blank icon over a window thumbnail in the picker — contained UI glitch, not a wrong recording target (selection is by window id).

**Suggested fix:** Carry the owner bundle identifier into PickerTarget (RawWindow already has ownerBundleId) and resolve via `runningApplications.first { $0.bundleIdentifier == ownerBundleId }`, falling back to NSWorkspace.shared.icon(forFile: app.bundleURL?.path) so a non-running owner still yields an icon.

<details><summary>Verifier reasoning</summary>

Confirmed: SourcePickerOverlay.swift:136-139 resolves the per-window app icon via NSWorkspace.shared.runningApplications.first { $0.localizedName == ownerName }, where ownerName originates from SCWindow.owningApplication?.applicationName (SourceCatalog.rawWindow, line 68). Matching on a human-readable localizedName is fragile: names can collide across helper processes and the SCWindow applicationName need not equal NSRunningApplication.localizedName, so .first can attach the wrong icon or none. SourceCatalog already captures a stable ownerBundleId in RawWindow (line 10/69), but it is NOT projected into the dictionaries (applyStrictFilter/projectAll emit only ownerName) nor carried into PickerTarget (struct in SourcePickerView.swift:5-10 has id/title/icon/localFrame, no bundle id), so the stable key the suggested fix wants is unavailable downstream. Impact is purely cosmetic — selection is by window id (line 124 id: id), so the recording target is correct; only the thumbnail's icon can be wrong/blank. Real but cosmetic; minor is acceptable (borderline nit).
</details>

---

### [MINOR] video_sync patch: lastPresentedItemTime read/written across threads without synchronization (torn CMTime read)

- **Subsystem:** platform interface + macos Dart + vendored video_player
- **Category:** concurrency · **Confidence:** medium
- **Location:** `packages/video_player_avfoundation/darwin/video_player_avfoundation/Sources/video_player_avfoundation/FVPTextureBasedVideoPlayer.m:34, 153, 223-232`

**What:** self.lastPresentedItemTime is WRITTEN in copyPixelBuffer (line 153), which the Flutter engine calls on the raster/display thread, and is READ in displayLatencyMicros (line 224) whose caller is the slipreel/video_sync FlutterMethodChannel handler in FVPVideoPlayerPlugin.m — FlutterMethodChannel handlers run on the platform (main) thread. CMTime is a 24-byte struct (value:int64, timescale:int32, flags, epoch), and `@property(nonatomic, assign)` provides no atomicity, so a concurrent read can observe a torn struct (e.g. a new .value paired with an old .timescale), producing a garbage latency for that sample. It does not crash and the Dart-side EMA smoother + non-negative clamp absorbs single-sample spikes, so user impact is limited to an occasional bad latency reading that gets smoothed away; the preview cursor never reads a torn value directly.

**Suggested fix:** Guard both access sites with a tiny lock or use an os_unfair_lock / @synchronized around the read and write of lastPresentedItemTime, or store the value as a single atomic int64 of micros computed at write time (compute clock-vs-presented delta inside copyPixelBuffer and publish one int64) so the cross-thread read is naturally atomic.

<details><summary>Verifier reasoning</summary>

Confirmed: lastPresentedItemTime is declared `@property(nonatomic, assign) CMTime` (line 34), a 24-byte struct with no atomicity. It is written in copyPixelBuffer (line 153) and read in displayLatencyMicros (line 224). copyPixelBuffer is the FlutterTexture protocol method invoked by the Flutter engine on the raster/display thread, while displayLatencyMicros is invoked synchronously from the slipreel/video_sync FlutterMethodChannel handler (FVPVideoPlayerPlugin.m line 75), which runs on the platform/main thread. So the two access sites genuinely run on different threads with no lock, making a torn multi-word read possible (technically UB). The reviewer's own impact assessment is accurate and limiting: the Dart-side DisplayLatencySmoother EMA plus the non-negative clamp (FVPTextureBasedVideoPlayer.m line 231, smoother line 21) absorb a single garbage sample, the value is preview-only, and torn reads on aligned int64 fields are rare in practice on arm64/x86_64. Real but genuinely minor.
</details>

---

### [MINOR] video_sync patch: slipreel/video_sync method-call handler creates a retain cycle and is never torn down on engine detach

- **Subsystem:** platform interface + macos Dart + vendored video_player
- **Category:** resource-leak · **Confidence:** high
- **Location:** `packages/video_player_avfoundation/darwin/video_player_avfoundation/Sources/video_player_avfoundation/FVPVideoPlayerPlugin.m:66-83, 109-120`

**What:** The patch registers a FlutterMethodChannel, retains it on the plugin via `instance.slipreelSyncChannel` (strong property, line 48/83), and installs a method-call handler block that captures `instance` strongly (it dereferences `instance->_playersByIdentifier` and calls `[(FVPTextureBasedVideoPlayer *)player displayLatencyMicros]`). That forms a cycle: instance -> slipreelSyncChannel (strong) -> handler block -> instance. detachFromEngineForRegistrar: (line 109) tears down the players and the pigeon API (`SetUpFVPAVFoundationVideoPlayerApi(messenger, nil)`) but never clears slipreelSyncChannel nor its handler. On engine teardown the plugin instance therefore leaks, and the `slipreel/video_sync` handler stays installed on the (now detached) messenger. This matters for this app because it is multi-window desktop and uses hot restart during development; each engine detach leaks one plugin + its players dictionary.

**Suggested fix:** Capture `__weak typeof(instance) weakInstance = instance;` in the handler block (mirroring the existing weakSelf pattern used in configurePlayer), and in detachFromEngineForRegistrar: call `[self.slipreelSyncChannel setMethodCallHandler:nil]; self.slipreelSyncChannel = nil;` to break the cycle and unregister the side channel.

<details><summary>Verifier reasoning</summary>

Confirmed by direct reading. The handler block (FVPVideoPlayerPlugin.m lines 69-82) captures `instance` strongly via `instance->_playersByIdentifier[playerId]`; the channel is retained on a strong property `slipreelSyncChannel` (line 48) and assigned `instance.slipreelSyncChannel = syncChannel` (line 83). That is a real retain cycle: instance -> slipreelSyncChannel -> handler block -> instance. detachFromEngineForRegistrar: (lines 109-120) disposes players and calls SetUpFVPAVFoundationVideoPlayerApi(messenger, nil) but never touches slipreelSyncChannel or its handler, so on engine detach the plugin instance and its players dictionary leak and the stale handler stays installed. The configurePlayer code right below uses the __weak weakSelf pattern, confirming the fix idiom is already known in this file. The desktop multi-window + hot-restart context makes the leak repeatable during development, though in production the engine is rarely torn down. Real, low impact, minor.
</details>

---

### [MINOR] SystemAudioConfig.fromJson throws on unknown/missing mode (no orElse fallback)

- **Subsystem:** platform interface + macos Dart + vendored video_player
- **Category:** correctness · **Confidence:** medium
- **Location:** `packages/screen_recorder_platform_interface/lib/src/models/system_audio_config.dart:20`

**What:** SystemAudioConfig.fromJson resolves the enum with `SystemAudioMode.values.byName(json['mode'] as String)`, which throws ArgumentError if 'mode' is absent or not exactly 'allApps'/'selectedApps'. This factory deserializes the native result of showSystemAudioMenu (and persisted settings). A contract drift on the native side (renamed/extra mode) or a corrupt persisted value throws inside the await for showSystemAudioMenu rather than degrading. Every other enum in this package (RecordingSource, AudioDeviceType, PixelFormat, CursorState, PermissionStatus) uses a firstWhere(orElse:) / default fallback, so this is the lone enum that hard-fails on unknown input.

**Suggested fix:** Use a non-throwing lookup with a sensible default, e.g. `mode: SystemAudioMode.values.firstWhere((e) => e.name == json['mode'], orElse: () => SystemAudioMode.allApps),` to match the rest of the package's defensive enum decoding.

<details><summary>Verifier reasoning</summary>

Confirmed: system_audio_config.dart line 20 uses `SystemAudioMode.values.byName(json['mode'] as String)`, and byName throws ArgumentError when the name is absent or unmatched. This is genuinely the lone enum in the package that hard-fails on unknown input — recording_settings.dart line 52 (RecordingSource) and audio_device_info.dart line 28 (AudioDeviceType) both use firstWhere(orElse:), and other enums fall back too. The decode path runs on the native showSystemAudioMenu result and on persisted settings, so a corrupt persisted 'mode' value or a native rename would throw inside the await rather than degrading. The throw is somewhat contained (the menu result is a one-shot Future, not a long-lived stream, so it would surface as a caught/failed call rather than killing capture), and contract drift is the app authoring both ends, lowering likelihood. Still a real defensive-consistency gap worth a one-line fix; minor is appropriate.
</details>

---

### [MINOR] The application package's pubspec.lock is gitignored — release/CI builds are not reproducible

- **Subsystem:** cross-cutting: architecture, build/CI, config, entitlements, dead code
- **Category:** maintainability · **Confidence:** high
- **Location:** `.gitignore:33`

**What:** Line 33 `pubspec.lock` ignores ALL lockfiles repo-wide, including the deployable application package (packages/screen_recorder). `git ls-files '*pubspec.lock'` returns zero tracked lockfiles. Dart/Flutter's official guidance is that APPLICATIONS (not libraries) must commit pubspec.lock so every build resolves identical dependency versions. Every package here uses floating caret constraints (flutter_riverpod: ^2.5.1, video_player: ^2.9.2, package_info_plus: ^8.0.0, etc.), and per project memory CI tracks the LATEST Flutter SDK rather than a pin. With no committed lockfile, `melos bootstrap` on CI and on a release machine can silently resolve newer transitive versions than were tested. For an app whose hard invariant is preview==export frame-for-frame, an unpinned transitive bump (e.g. in video_player, a rendering/path dep) is exactly the kind of change that can introduce a regression that nobody can reproduce later because the resolved graph is gone.

**Suggested fix:** Stop ignoring the application lockfile: scope the ignore to library packages only, or add `!packages/screen_recorder/pubspec.lock` to un-ignore it, then commit it. Keep ignoring it for the pure-library packages (engine/platform_interface) per convention. This makes CI and release builds reproducible.

<details><summary>Verifier reasoning</summary>

.gitignore line 33 `pubspec.lock` under a `# Dependencies` header ignores all lockfiles repo-wide; `git check-ignore packages/screen_recorder/pubspec.lock` => IGNORED and `git ls-files '*pubspec.lock'` => empty (zero tracked lockfiles). packages/screen_recorder is a deployable Flutter application (has lib/main.dart, a `flutter:`/uses-material-design section, version 1.0.0+1) and uses floating caret constraints (video_player ^2.9.2, flutter_riverpod ^2.5.1, package_info_plus, etc.). Dart's official guidance is that applications (not libraries) should commit pubspec.lock for reproducible builds. The finding is accurate. One caveat that slightly tempers it: CI uses `channel: stable` (unpinned SDK) per the workflow, so committing the lockfile alone wouldn't fully freeze the resolved graph against a `pub upgrade`, but it is still the standard, correct fix for reproducibility. No active runtime bug, so this is a maintainability/reproducibility concern; I downgrade from major to minor.
</details>

---

### [MINOR] slipreel_engine ('zero Flutter widget-tree imports') contains StatelessWidget UI and its boundary test does not enforce the invariant

- **Subsystem:** cross-cutting: architecture, build/CI, config, entitlements, dead code
- **Category:** maintainability · **Confidence:** high
- **Location:** `packages/slipreel_engine/lib/rendering/keystroke_overlay.dart:1, 17, 178`

**What:** The engine package's pubspec description and the architecture test engine_layer_boundary_test.dart (lines 8-12) both state the engine 'cannot drag the editor's Flutter widget tree along' so it can run as a headless CLI/cloud exporter. But keystroke_overlay.dart imports `package:flutter/material.dart` (line 1) and defines `class KeystrokeOverlay extends StatelessWidget` (line 17) and `class KeystrokeKeycap extends StatelessWidget` (line 178) — real widget-tree code living inside the supposedly headless engine. The boundary test only forbids `import 'package:screen_recorder/*'`; it never checks for material/widgets/cupertino imports, so the documented invariant is unenforced and has already drifted. (deterministic_focal_track.dart:5 also imports `package:flutter/widgets.dart` just for `Size`, which is available from `dart:ui` and shouldn't pull widgets.dart.) Separately, the headless claim is further contradicted by engine code using rootBundle (frame_compositor.dart:570, device_frame.dart:159), SharedPreferences, and path_provider — all of which need a live Flutter platform binding — so 'cloud worker / CLI without the app shell' is currently not achievable. No runtime bug today (the app shell hosts the widget), but the stated architecture boundary is false and untested.

**Suggested fix:** Move KeystrokeOverlay/KeystrokeKeycap (and any other StatelessWidget) into packages/screen_recorder (the shell), leaving only the data models in the engine. Extend engine_layer_boundary_test.dart to also fail on imports of package:flutter/material.dart, package:flutter/widgets.dart, and package:flutter/cupertino.dart so the invariant is actually enforced. Change deterministic_focal_track.dart to `import 'dart:ui' show Offset, Size;`. If true headless portability is a real goal, also abstract rootBundle/SharedPreferences/path_provider behind injectable interfaces; otherwise soften the pubspec/test docstrings to match reality.

<details><summary>Verifier reasoning</summary>

Confirmed on every factual point. The engine pubspec description literally claims 'Has zero Flutter widget-tree imports so it can drive headless CLI exports, cloud worker compositions, or third-party plugin SDKs', yet keystroke_overlay.dart:1 imports `package:flutter/material.dart` and defines `class KeystrokeOverlay extends StatelessWidget` (line 17) and `class KeystrokeKeycap extends StatelessWidget` (line 178) — genuine widget-tree code inside the supposedly headless package. deterministic_focal_track.dart:5 imports `package:flutter/widgets.dart show Size` (Size is reachable from dart:ui). The boundary test engine_layer_boundary_test.dart only regex-matches `package:screen_recorder/` imports and never checks for flutter material/widgets/cupertino, so the stated 'zero widget-tree imports' invariant is both false and unenforced. The reviewer's secondary note about rootBundle (frame_compositor.dart:570/599, device_frame.dart:159), SharedPreferences (recording_history.dart), and path_provider (curve_library/export_settings/telemetry stores) is also accurate — those need a live Flutter binding and undermine the broader 'cloud worker / CLI' claim, though strictly they are platform plugins, not widget-tree imports. No runtime bug today (the app shell hosts the widget); this is architecture doc-drift plus a test-coverage gap. Minor is correct.
</details>

---

### [MINOR] CI never builds the macOS app — signing, entitlement, native-compile, and bundling regressions are invisible

- **Subsystem:** cross-cutting: architecture, build/CI, config, entitlements, dead code
- **Category:** maintainability · **Confidence:** high
- **Location:** `.github/workflows/test-all-platforms.yml:10-24`

**What:** The only macOS CI job runs `flutter analyze` + `melos run test`; it never runs `flutter build macos` or `xcodebuild`. So the entire native layer (the Swift ScreenCaptureKit recorder in screen_recorder_macos, the vendored/patched video_player_avfoundation, the Podfile/CocoaPods integration, the entitlements, and Info.plist substitutions) is never compiled or linked in CI. A broken entitlement, a Swift compile error, a Pod resolution failure, or a missing usage-description string would pass CI and only surface when a human runs the build locally. Given that release config (hardened runtime/signing, see other finding) and native capture are the highest-risk, least-unit-testable parts of this product, the absence of even a compile/build smoke is a meaningful coverage gap. (The melos comments correctly explain why native packages are excluded from unit tests — but unit-test exclusion is not a substitute for a build step.)

**Suggested fix:** Add a `flutter build macos --debug --no-codesign` (or a `xcodebuild build` of the Runner scheme) step to the macOS job so native Swift, the Podfile, entitlements, and Info.plist substitutions are compile-checked on every PR. Memory confirms `flutter build macos` works on the pinned SDK, so this is low-cost insurance for the riskiest layer.

<details><summary>Verifier reasoning</summary>

Confirmed. .github/workflows/test-all-platforms.yml is the only workflow; its macOS job (analyze-and-test) runs flutter --version, brew install ffmpeg, melos bootstrap, `melos run analyze`, and `melos run test` — no `flutter build macos` or `xcodebuild`. `grep -rn 'flutter build|xcodebuild' .github/` returns nothing. So the native Swift ScreenCaptureKit recorder, the vendored video_player_avfoundation, the Podfile/CocoaPods integration, the entitlements, and Info.plist substitutions are never compiled/linked in CI; a Swift compile error, broken entitlement, Pod resolution failure, or missing usage-description string would pass CI and only surface on a local build. Given native capture + release signing are the highest-risk, least-unit-testable parts, this is a genuine coverage gap. It is a missing-coverage/maintainability issue, not an active defect, so minor is the right severity. The reviewer's note that melos correctly excludes native packages from unit tests (and that exclusion is not a substitute for a build step) matches the workflow comments.
</details>

---

### [NIT] DeterministicFocalTrack never samples the region's exact end focal, so focalAt near endTime returns a stale (≤16 ms old) focal for scene-blur

- **Subsystem:** slipreel_engine — rendering / compositing / zoom / blur
- **Category:** correctness · **Confidence:** high
- **Location:** `packages/slipreel_engine/lib/rendering/deterministic_focal_track.dart:112-140`

**What:** The replay loop is `for (var us = startUs; us < endUs; us += _stepMicros)`. Because the upper bound is exclusive and the region length is generally not a multiple of 16 ms, the final fixed-step sample sits strictly before `endUs`. The exit ramp drives the focal to the video centre exactly at `endTime`, but that terminal focal is never added to `_samples`. `focalAt(t)` clamps any `t >= maxRel` to `_samples[lastIdx]` (the last grid point before endTime), so for the last fraction of a region the scene-blur sampler reads a focal that is up to 16 ms / one ramp-step stale instead of the true near-centre focal. This biases the scene-blur pan vector right at zoom-out completion — precisely the boundary where the box-shadow/zoom-ramp smear artifacts have historically shown up.

**Suggested fix:** After the loop, append one final sample at the clamped region end (e.g. evaluate the builder at `Duration(microseconds: endUs)` or at `endUs - 1`) and have focalAt interpolate to it, so the trajectory covers the full [startTime, endTime] the renderer paints.

<details><summary>Verifier reasoning</summary>

Confirmed at deterministic_focal_track.dart:112 the build loop is `for (var us = startUs; us < endUs; us += _stepMicros)` (exclusive upper bound), so the final grid sample sits up to 16 ms before endUs and the exact terminal focal at endTime (driven toward center by the exit ramp) is never added to `_samples`. focalAt (lines 172-174) clamps any `rel >= maxRel = lastIdx*_stepMicros` to `_samples[lastIdx]`, so for the last <16 ms of a region the scene-blur consumers (frame_compositor.dart:867, scene_blur_overlay.dart:511) read a focal up to one ramp-step stale instead of interpolating to the true near-center end focal. So the coverage gap and the resulting tiny bias at zoom-out completion are real. But the impact is bounded to a single 16 ms step at the very tail where the eased focal is already flattening toward center, on a subtle blur-pan signal — negligible in practice. nit, not minor.
</details>

---

### [NIT] CursorOverlayPainter.velocityPxPerSec is a dead parameter that still forces repaints

- **Subsystem:** slipreel_engine — rendering / compositing / zoom / blur
- **Category:** maintainability · **Confidence:** high
- **Location:** `packages/slipreel_engine/lib/rendering/cursor_overlay_painter.dart:44-72, 560`

**What:** `velocityPxPerSec` is declared, defaulted, and compared in `shouldRepaint`, but it is never read inside `paint()` — the motion-blur trail is derived entirely from `cursorRecording` lookups (`_trailVectorForBlur`). The field is therefore dead for rendering yet participates in `shouldRepaint`, so a caller that passes the live per-frame velocity (playback_canvas.dart:971) can trigger extra repaints that produce identical output. Harmless to correctness today only because `position` already changes every frame; it is a latent maintenance/perf trap and misleading API surface.

**Suggested fix:** Remove the `velocityPxPerSec` field (and its shouldRepaint clause and constructor arg), or actually consume it in the trail computation if a velocity-driven path was intended. Update the playback_canvas.dart call site accordingly.

<details><summary>Verifier reasoning</summary>

Confirmed by grep on the actual file (packages/slipreel_engine/lib/rendering/cursor_overlay_painter.dart — the finding's path is right; the misleading screen_recorder path in the file's line-1 comment is stale). `velocityPxPerSec` appears only at line 44 (field), line 72 (constructor default), and line 560 (shouldRepaint comparison). It is never read inside paint() or _trailVectorForBlur — the motion-blur trail is derived entirely from cursorRecording lookups (cursorAt). The call site (playback_canvas.dart:980) passes `combinedCursorVelocity = scenePass.filteredCursorVelocity` (playback_canvas.dart:890), which changes every frame, so the field is dead-for-render yet still participates in shouldRepaint and could trigger repaints that produce identical output. As the finding states, it is harmless to correctness today because position/screenPos already change per frame, making it a maintainability/latent-perf and API-clarity issue. Correctly classified as a nit.
</details>

---

### [NIT] Sub-millisecond audio leading-gap is silently dropped, leaving export audio early vs. preview

- **Subsystem:** slipreel_engine — export / encode / ffmpeg
- **Category:** correctness · **Confidence:** high
- **Location:** `packages/slipreel_engine/lib/export/n_slice_filter_graph.dart:209-219 (delayMs rounding); also audio_streams.dart:60-61`

**What:** The per-track A/V re-sync delay is converted to whole milliseconds (`delayMs = (delayMicros / 1000).round()`) and only emitted when `delayMs > 0`. A genuine gap of, e.g., 400us (system audio that started 0.0004s after video) is computed as a real 400us shift but rounds to 0ms, so no `adelay` is emitted and the exported audio is up to ~0.5ms earlier than the in-sync preview (AVFoundation honors the true sub-ms gap). This is a quantization of the very A/V-sync compensation the file exists to provide. It is minor in magnitude but is a real preview!=export divergence and is locked in by a test ('a sub-millisecond gap rounds to 0 -> no adelay'). ffmpeg's adelay only accepts integer milliseconds, so the residual is unavoidable with adelay alone, but rounding to nearest (rather than down) at least halves the worst case.

**Suggested fix:** Accept that <0.5ms is below adelay's resolution (document it), or for higher fidelity use `aresample=async=1` / an `atrim`-based shift instead of adelay so sub-ms gaps are preserved. At minimum keep the round-to-nearest already present. Low priority unless lip-sync at this scale matters.

<details><summary>Verifier reasoning</summary>

The code is exactly as described: n_slice_filter_graph.dart:209 `final delayMs = (delayMicros / 1000).round();` and line 210 `if (delayMicros > 0 && delayMs > 0)`, so a genuine 400us gap (delayMicros=400, >0) yields delayMs=0 and emits no adelay; the test at n_slice_filter_graph_audio_offset_test.dart:151-159 locks this in. So it is a real, intentional quantization of the A/V-resync compensation this file provides. However, the residual is bounded at <500us — sub-frame at any realistic frame rate (a 60fps frame is 16,667us; 120fps is 8,333us), so it cannot shift audio by even one frame relative to video and is inaudible for lip-sync. It is also an inherent limit of ffmpeg's adelay (integer milliseconds only), and the code already uses round-to-nearest, which is the optimal mitigation with adelay alone. The finding itself concedes it is 'minor in magnitude', 'unavoidable with adelay alone', and 'low priority'. Given the sub-perceptual, hardware-limited, already-optimally-rounded nature, I downgrade minor → nit.
</details>

---

### [NIT] UndoRedoController.redo() bypasses maxSize trimming

- **Subsystem:** slipreel_engine — models / state / timeline / editor
- **Category:** resource-leak · **Confidence:** high
- **Location:** `packages/slipreel_engine/lib/state/undo_redo_controller.dart:64-73`

**What:** push() enforces maxSize by trimming the undo stack from the front, but redo() does a bare `_undoStack.add(stateToRedo)` with no trim. Net size is bounded by the number of prior undos, so this cannot grow past maxSize indefinitely; however, if push() trims an entry while a redo path still exists, the bookkeeping is inconsistent (the oldest reachable-via-redo state may have been dropped from the undo side). In practice push() also clears the redo stack, so the window is narrow — hence nit, not a leak.

**Suggested fix:** Apply the same trimming after redo's add, or document that net stack size is bounded by undo depth and leave as-is. Low priority.

<details><summary>Verifier reasoning</summary>

Confirmed as described, and the reviewer's own nit framing is right. redo() (undo_redo_controller.dart:64-73) does a bare `_undoStack.add(stateToRedo)` with no maxSize trim, whereas push() trims from the front (lines 40-42). But net undoStack size genuinely cannot exceed maxSize: push() is the only operation that increases the total state count and the only one that trims, and it trims to maxSize; undo/redo merely move one item between the two stacks without changing the total. So any item redo replays was previously in undoStack (already <= maxSize), and the redoStack length is bounded by what undo popped. There is no unbounded growth / leak — only a cosmetic bookkeeping asymmetry in the narrow window the reviewer notes. resource-leak is the wrong category; this is effectively benign, so nit (bordering on none).
</details>

---

### [NIT] SleepObserver.pausedBySleep can latch true when the auto-pause no-ops, causing a spurious on-wake modal

- **Subsystem:** screen_recorder — state / controllers (recording, permissions, recovery)
- **Category:** correctness · **Confidence:** medium
- **Location:** `packages/screen_recorder/lib/state/sleep_observer.dart:47-61`

**What:** On 'willSleep' the observer sets `pausedBySleep = true` and then fire-and-forgets `_router.pauseOrResume()` without confirming a pause actually occurred. The flag is only cleared by _stateSub on a transition OUT of paused (38-44). If the recording never actually enters `paused` (e.g. a concurrent stop already flipped status to processing/completed between the status read at line 51 and the router acting, or pauseRecording's queued op early-returns), the flag stays latched true. The subsequent 'didWake' (57) then fires onWake?.call() and shows the wake/resume modal even though nothing was paused by sleep, confusing the user (and potentially prompting them to 'resume' a recording that already stopped).

**Suggested fix:** Only set pausedBySleep after confirming the pause landed (await the router/controller and check `state.status == paused`), or set it inside _stateSub when the transition INTO paused is observed with a sleep cause. At minimum, reset pausedBySleep=false on didWake after consuming it and verify status==paused before calling onWake.

<details><summary>Verifier reasoning</summary>

Confirmed in sleep_observer.dart. The willSleep branch (50-56) sets `pausedBySleep = true` then fire-and-forgets `_router.pauseOrResume()` with no confirmation a pause landed. The flag is cleared ONLY by _stateSub on a transition OUT of paused (38-44: requires prev==paused && next!=paused); didWake (57-59) does NOT reset it. So if the recording never actually enters paused — e.g. a concurrent stop flips status between the synchronous read at line 51 and the queued pauseRecording op running (pauseRecording early-returns because `state.status != recording`, which is plausible given finding 4's stop-vs-pause interleaving) — the flag stays latched true and the subsequent didWake spuriously fires onWake?.call(), showing the wake/resume modal over a session that was not paused by sleep. The defect is real, but the trigger is a narrow race (a stop landing in a small window during auto-pause), and the user-visible consequence is a single spurious modal whose resume action would no-op on an already-stopped session. Downgrading to nit given the narrow trigger and low impact; the suggested fix (reset on didWake / verify status==paused) is sound.
</details>

---

### [NIT] TipsStore.markSeen performs a non-atomic read-modify-write on SharedPreferences

- **Subsystem:** screen_recorder — services / platform / main / onboarding / debug
- **Category:** concurrency · **Confidence:** high
- **Location:** `packages/screen_recorder/lib/onboarding/tips_store.dart:12-17`

**What:** markSeen() reads the current string list, adds the id, and writes the whole list back. If two markSeen() calls for different tip ids run concurrently (e.g. a tip dismissal racing with the ext.slipreel.resetOnboarding hook's clearAll(), or two TipAnchors marked back-to-back), both read the same baseline before either writes, and the second write clobbers the first's id — a tip can re-appear after a restart. In normal use TipsController.tryClaim() serializes visible tips so the window is small, but the store offers no ordering guarantee on its own and the debug reset path can interleave with an in-flight markSeen.

**Suggested fix:** Serialize mutations through a single-entry Future queue (chain each markSeen/clearAll onto the previous via a stored _pending future), or re-read inside a lock just before writing, so concurrent updates compose instead of clobbering.

<details><summary>Verifier reasoning</summary>

The code matches: TipsStore.markSeen (tips_store.dart:12-17) is a non-atomic read-modify-write on SharedPreferences with no ordering guarantee, so concurrent writers can clobber each other. However the impact is very low. TipsController.markSeen (tips_controller.dart:40-45) guards with `if (_seen.add(id.name))` so a given id is written at most once, and tryClaim() serializes visible tips so only one is active at a time — meaning two different ids being marked truly concurrently essentially never happens in normal use. The only genuine interleave is the debug-only ext.slipreel.resetOnboarding hook calling clearAll() racing an in-flight markSeen(), a developer-only path. The defect is technically real but the meaningful race is debug-gated and the worst outcome is one tip re-appearing once after restart, so this is below minor.
</details>

---

### [NIT] AppAlerts overlay is re-attached on every MyApp.build() via a post-frame callback

- **Subsystem:** screen_recorder — services / platform / main / onboarding / debug
- **Category:** perf · **Confidence:** high
- **Location:** `packages/screen_recorder/lib/main.dart:452-462`

**What:** build() unconditionally schedules a post-frame callback that calls AppAlerts.attach(...) on every rebuild. MyApp is a ConsumerStatefulWidget that watches appPaletteControllerProvider, so every theme change (and any other rebuild) tears down and recreates the alerts OverlayEntry. AppAlertsController.attach() is idempotent (it does _entry?.remove() then overlay.insert(), verified at app_alerts_controller.dart:55-63), so this is not a leak, but it is needless OverlayEntry churn on a frequently-rebuilt widget and momentarily removes/reinserts the live alert stack overlay on each rebuild.

**Suggested fix:** Attach once after first frame (e.g. a bool _alertsAttached guard, or do it from initState/_initRecordingSurfaces) and re-attach only on hot-restart, rather than on every build().

<details><summary>Verifier reasoning</summary>

Accurate. MyApp.build() (main.dart:454-462) unconditionally schedules addPostFrameCallback -> AppAlerts.attach on every rebuild, and MyApp watches appPaletteControllerProvider (line 449), so every theme change (and any rebuild) re-attaches. AppAlertsController.attach() (app_alerts_controller.dart:55-64) is idempotent — it does _entry?.remove(), _disposeAllTimers(), stack.value = const [], then overlay.insert() — so there is no leak, confirming it is not worse than a nit on the perf axis. Worth noting the reviewer slightly understated it: attach() also clears the live stack and cancels all timers, so re-attaching while alerts are visible would wipe them and their auto-dismiss timers, a minor correctness wrinkle on top of the OverlayEntry churn. Still nit-level overall given alerts during a theme switch are rare; the suggested one-time-attach guard is the right fix.
</details>

---

### [NIT] Keystroke lane visibility test uses inclusive bounds on both sides, double-counting slice seams

- **Subsystem:** screen_recorder — timeline / transport / zoom / canvas widgets
- **Category:** correctness · **Confidence:** high
- **Location:** `packages/screen_recorder/lib/ui/widgets/timeline/keystroke_timeline_lane.dart:159-166`

**What:** `_isVisible` returns true when `sourceTime >= c.trimStart && sourceTime <= c.trimEnd` for any slice. Both ends are inclusive, so a keystroke whose source timestamp lands exactly on a shared cut boundary (slice[i].trimEnd == slice[i+1].trimStart) matches two slices. It only affects a boolean OR (so the bar still shows, correctly), but the inclusive/inclusive convention diverges from `sourceToEdited` in edited_time.dart, which treats the range as `< trimStart` (excluded) / `<= trimEnd` (included) — i.e. half-open on the low side. The mismatch is harmless today but is the kind of off-by-one that bites if this predicate is later reused for exclusive layout math.

**Suggested fix:** Align the half-open convention with sourceToEdited (e.g. `sourceTime >= c.trimStart && sourceTime < c.trimEnd`, plus an explicit `== lastTrimEnd` case) so boundary keystrokes map to exactly one slice.

<details><summary>Verifier reasoning</summary>

Confirmed and accurately characterized as a harmless nit. `_isVisible` (keystroke_timeline_lane.dart:159-166) uses inclusive/inclusive bounds `sourceTime >= c.trimStart && sourceTime <= c.trimEnd`, so a keystroke landing exactly on a shared seam (slice[i].trimEnd == slice[i+1].trimStart) matches two slices, whereas `sourceToEdited` (edited_time.dart:42-57) uses a half-open scan (`< trimStart` excluded, `<= trimEnd` returns at the earlier slice). The convention diverges as stated. The mismatch is fully harmless today because `_isVisible`'s only call site is a boolean filter guard `if (!_isVisible(...)) continue;` (line 69) — double-matching a seam still yields true (the bar correctly shows) and is never used in layout/offset math. It is purely a latent off-by-one convention inconsistency, correctly rated a nit.
</details>

---

### [NIT] Export dialog leaves Format/Frame-rate pickers editable in shareable-link mode, violating the enforced 1080p/60 MP4 invariant

- **Subsystem:** screen_recorder — inspector / export-dialog / command-palette / camera / alerts widgets
- **Category:** correctness · **Confidence:** high
- **Location:** `packages/screen_recorder/lib/ui/widgets/export_dialog/export_dialog.dart:182-232`

**What:** _onDestinationChanged() deliberately forces format=mp4, resolution=1080p, frameRate=60 when switching to ExportDestination.shareableLink, with a comment explaining shareable links are 'always 1080p/60' hosted video, and _buildFooterRow() shows 'Shareable links are always exported as 1080p video at 60fps.' BUT _buildTopRow() (FormatPicker + FrameRatePicker) is rendered UNCONDITIONALLY and stays fully interactive in shareable-link mode — only the mid row swaps to the ShareableLinkPanel. So after selecting Shareable link, the user can tap FormatPicker → GIF (which runs _onFormatChanged and snaps fps to 10) or change the frame rate, ending up with destination=shareableLink + format=gif/odd-fps. _onExport() pops these settings verbatim, and the consumer (playback_screen.dart ~line 1840) routes them straight into ShareableLinkPublisher() with NO re-normalization (confirmed: no shareableLink format/resolution coercion after the dialog returns). The hosted-video share then gets a GIF or non-60fps payload that contradicts the UI's promise and the backend's expectation, potentially breaking the share or producing a broken hosted asset.

**Suggested fix:** When _isShareableLink is true, hide or disable the Format and Frame-rate pickers (e.g. wrap _buildTopRow in IgnorePointer + dimmed, or skip it and show a locked '1080p · 60fps · MP4' summary), OR re-normalize settings to mp4/1080p/60 inside _onExport() before popping when destination == shareableLink, so the popped ExportSettings can never disagree with the stated invariant.

<details><summary>Verifier reasoning</summary>

The UI mechanic is confirmed: _buildTopRow() (FormatPicker + FrameRatePicker) is rendered unconditionally at line 195 and stays interactive in shareable mode — only _buildMidRow() swaps to ShareableLinkPanel. _onDestinationChanged normalizes to mp4/1080p/60 only at the transition (lines 143-153); nothing prevents a subsequent FormatPicker→GIF tap (_onFormatChanged sets format=gif and snaps fps to 10) while destination stays shareableLink, and _onExport() (line 173) pops settings verbatim. The export_dialog_test 'lock' tests only cover the transition and never tap a picker after entering shareable mode, so the gap is genuinely unguarded/untested, and the footer text 'always 1080p video at 60fps' can disagree with the popped settings. HOWEVER the finding's stated impact is false: the consumer ShareableLinkPublisher (destination_handlers.dart:190-228) is an explicit documented STUB with NO backend — resolveOutputPath just builds a temp path from the file extension and deliver() writes a `file://` URL to the clipboard ('local file for now — hosted upload coming soon'). There is no upload, no backend format/resolution expectation, and no hosted asset to corrupt; the actual encode still produces a valid file in whatever format the user chose (ext follows settings.format at playback_screen.dart:1844). So nothing 'breaks the share' or 'produces a broken hosted asset' in the current codebase — the only real defect is a cosmetic UI inconsistency (live pickers vs a stale 'always 1080p/60' footer promise). Because the consumer is a no-op stub and the export itself is correct, I downgrade major to nit.
</details>

---

### [NIT] video_sync patch: displayLatencyMicros uses unbounded int64 multiply that can overflow for high-timescale assets

- **Subsystem:** platform interface + macos Dart + vendored video_player
- **Category:** correctness · **Confidence:** high
- **Location:** `packages/video_player_avfoundation/darwin/video_player_avfoundation/Sources/video_player_avfoundation/FVPTextureBasedVideoPlayer.m:228-229`

**What:** displayLatencyMicros converts CMTime to micros with `presented.value * 1000000 / presented.timescale` (and the same for clock). The multiply happens before the divide on raw CMTimeValue (int64). For assets with a large timescale (some capture/ProRes pipelines use timescales up to 1e9), presented.value grows proportionally, so `value * 1000000` can overflow int64 for long playheads (e.g. timescale 1e9 overflows near ~2.5 hours of media time). On overflow the latency becomes a garbage/negative value; the negative case is clamped to 0 (line 231) but a positive-wrapped value would feed a bogus large latency into the smoother. For typical minutes-long screen recordings with timescale 600/90000 this is unreachable, hence minor.

**Suggested fix:** Use CoreMedia's conversion to avoid manual overflow: `int64_t presentedUs = (int64_t)llround(CMTimeGetSeconds(presented) * 1e6);` and likewise for clock, then subtract and clamp. CMTimeGetSeconds handles the scaling in double space and avoids the int64 intermediate overflow.

<details><summary>Verifier reasoning</summary>

The code at lines 228-229 does `presented.value * 1000000 / presented.timescale` with the multiply before the divide on raw int64 CMTimeValue, so for a very large timescale (e.g. 1e9) the intermediate `value * 1000000` can overflow int64 at long playheads. That is arithmetically true. However it is essentially unreachable for this app: AVPlayer playback of file-based recordings uses normal timescales (600/90000), guarded by timescale==0 checks (line 227) and CMTIME_IS_VALID (line 226), and the same multiply-first idiom is used by the upstream FVPCMTimeToMillis (FVPVideoPlayer.m line 216) at the millis scale. A wrapped-positive result would feed the smoother but get EMA-averaged out, and the negative case is clamped. Given it cannot trigger with the assets this code actually plays and the only consequence is a transient smoothed-away preview-cursor blip, I am downgrading from minor to nit: a latent robustness improvement, not a material defect.
</details>

---

## Rejected by verifier — not real / not material (6)

- **Pinch smoothing ticker can leak one stale-dt frame across back-to-back gestures** — `packages/screen_recorder/lib/ui/widgets/timeline/editor_timeline.dart`
  - _The described stale-dt frame does not actually manifest. `onScaleStart` (line 1417) resets `_pinchReleasing = false`, `_pinchHasScaled = false`, and crucially sets BOTH `_renderScale = widget.timelineScale` (1428) and `_rawTargetScale = widget.timelineScale` (1429) to the same value, but does not stop the still-active release ticker nor reset `_lastPinchElapsed` — so far matching the report. However, in `_onPinchTick` (1165) with the new gesture's state, `target = _rawTargetScale ?? _renderScale` equals `_renderScale`, so `newRender == _renderScale`, `delta ≈ 0`, and `settled` is true; with `_pinchReleasing == false` the tick hits the early-return `if (!_pinchReleasing && settled) return;` (1187) BEFORE calling `onPinchScale`. So every tick between onScaleStart and the first real pinch frame is a no-op regardless of the stale `_lastPinchElapsed` baseline. Then the first pinch frame sets `_lastPinchElapsed = Duration.zero` (1529) and stop/start the ticker (1531-1532) before any non-trivial smoothing runs. There is no window where a large stale dt actually feeds a scale application, so the claimed timing glitch is not reachable._

- **CutOverlay maps tap x to edited time without clamping to content bounds** — `packages/screen_recorder/lib/ui/widgets/timeline/cut_overlay.dart`
  - _The factual half is correct: `_editedTimeAt` (cut_overlay.dart:57-60) converts x→edited time with no clamp, unlike `_seekFromTimelineViewportX` and TimeRuler. But the claimed consequence — 'cut-decision math runs on an out-of-range timestamp' causing a defect — does not hold. The overlay is `Positioned.fill` inside the same Stack box as ClipLane, sized to content width, so the translucent GestureDetector only receives taps within the lane box (the `Clip.none` affects only the painted scissors glyph, not hit-testing); the `totalEditedDuration` field is passed but never even used. More decisively, the consumer is fully guarded: `onCommitCut → _attemptSplit → decideCut` produces a time that is handed to `controller.splitAtPlayhead` (editor_project_controller.dart:472), which maps to source time and only splits when `sourcePosition > s.trimStart && sourcePosition < s.trimEnd` (strict, exclusive) for some slice — an out-of-range time satisfies this for no slice and returns false (no split, no crash, no bad mutation). `resolveSnap` on an out-of-range input is also harmless nearest-candidate math. So even if x were somehow out of range, the result is a benign no-op. The unclamped conversion is a cosmetic inconsistency, not a material defect._

- **Concurrent _openPanel flows can desync window mode (panel route shown while window morphed back to bar)** — `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart`
  - _The structural observation is accurate (recording_bar_screen.dart:140-146 _openPanel has no re-entrancy guard and unconditionally calls showBar() after its push resolves), but the described concrete failure is not reachable. The two callers are mutually exclusive in time: _onGearTap (279-290) only runs when the gear is visible, and the gear lives in _buildBar() which renders solely in WindowMode.bar/panel (build() 297-309); during recording the window is in WindowMode.pill (RecordingPill has only onStop/onPauseOrResume, no gear), so the user cannot open a gear panel while a recording is in flight. The completion listener (74-86) fires _openPanel(PlaybackScreen) only on the recording→completed edge, i.e. when leaving pill mode, at which point no gear-opened panel can be open. Crucially, the most plausible nested path — RecentsScreen opening a recording — does NOT go through _openPanel: recents_screen.dart:82-86 _open() pushes PlaybackScreen directly onto the same Navigator and never calls showBar/showPanel, so the inner pop leaves window mode untouched and only the outer _openPanel (Recents) restores the bar. No reachable code path produces two stacked _openPanel tails both calling showBar(). This is a latent code smell, not a material defect._

- **Thumbnail decode slices output to history-recorded dimensions, not the frame's actual size** — `packages/screen_recorder/lib/ui/screens/recents/recording_thumbnail_service.dart`
  - _The code reads as described (recording_thumbnail_service.dart:201 frameSize = w*h*4 from entry.widthPx/heightPx (153); _decodeFrameBgra args 190-198 decode -f rawvideo -pix_fmt bgra with no scale filter; guard uses < at 202 then sublist(0, frameSize) at 203), but there is no reachable path to the dangerous mismatch in this codebase. The decode reads the ORIGINAL source MP4 at entry.videoPath, and the history dimensions are produced from the native side's ACTUAL encoded dimensions (recording_state.dart:473-475 'Prefer the actual capture dimensions returned by the native side', written into both the metadata sidecar and RecordingHistoryEntry at 491-497). ffmpeg's rawvideo bgra output uses the codec's coded resolution = exactly those dimensions, so out.length == w*h*4 in normal operation — no scale filter is needed for alignment. The finding's mismatch scenarios don't occur here: device frames are applied in the editor/compositor, not baked into the source at record time; the app records unrotated ScreenCaptureKit frames, not orientation-rotated media that ffmpeg would auto-swap; and history rows aren't rewritten out-of-band. The only residual edge is a legacy entry with widthPx/heightPx defaulting to 0 (recording_history.dart:36-37), which yields frameSize 0 and an empty-but-non-null decode — a different, downstream failure, and the service backfill prefers meta dims anyway. This is a defensive-coding gap (use == not <, or add -vf scale), not a material defect manifesting in practice._

- **RegionToolbarPosition can place the toolbar partly outside a short, wide selection** — `packages/screen_recorder_macos/macos/Classes/RegionToolbarPosition.swift`
  - _The constants check out (RegionSelectorView: toolbarSize=(140,36), toolbarGap=8; RegionSelectorState.minSize=50) and the fallback branch (RegionToolbarPosition.swift:17-21) does set y = rect.maxY - 36 - 8 = maxY-44 with no clamp to rect.minY. But the asserted user-visible glitch is not reachable: by the reviewer's own arithmetic the toolbar only spills for rect.height < 44, and a selection only reaches a toolbar-showing state at height >= 50. showsToolbar (RegionSelectorView:129-134) is true only in .selected/.resizing/.moving, and .drawing → .selected requires clipped.height >= minSize=50 (handleFromDrawing:166). At height=50 the toolbar [maxY-44, maxY-8] sits fully inside [maxY-50, maxY], so its top never crosses rect.minY. Additionally the inside-rect fallback only triggers when there is room neither below nor above the rect on the whole display — a rare edge condition. The only conceivable path to height<44 is a live resize intermediate while simultaneously pinned to both top and bottom screen edges, an extremely contrived combination, and the reviewer themselves concede 'at any rect.height < 44 it does not [fit]... at the 50pt minimum it actually fits.' The missing y >= rect.minY clamp is a legitimate latent robustness gap (would matter if minSize were lowered), but no reachable cosmetic bug exists under current constraints. Marking not a real defect; at most a nit-level defensive improvement._

- **Live cursor/keystroke stream parsing throws (killing the stream) if a non-int numeric ever arrives for timestampMicros** — `packages/screen_recorder_platform_interface/lib/src/models/cursor_position.dart`
  - _The cast `json['timestampMicros'] as int` exists at cursor_position.dart line 39 and keystroke_event.dart line 87, and the sibling x/y fields do use the more defensive `(json['x'] as num).toDouble()`, so the stylistic inconsistency is real. But there is no actual defect today: the native sender emits Int64 (ScreenRecorderMacosPlugin.swift lines 1855 and 1909), the streams use plain EventChannel with the StandardMethodCodec (method_channel lines 10/22), and that codec round-trips a Swift Int64 to a Dart int deterministically — a double can never arrive on this wire without a deliberate contract change. The reviewer explicitly concedes it is 'latent, not active.' An adversarial verifier should not mark a latent style-consistency suggestion that cannot fire against the real code as a real defect. The suggested change is a reasonable hardening nit but not a current bug, so isReal=false with severity none._

