# Final GTM readiness review — 9 September 2026

> Follow-up: the owner confirmed successful payment and activation. The six source findings have been repaired; see [GTM fixes and release status](2026-09-09-gtm-fixes.md). The assessment below is the original pre-fix review.

**Decision: hold the unconditional public-launch greenlight.** The technical foundation and published distribution are strong. The remaining work is targeted; a general rewrite or another indiscriminate testing cycle is not warranted. Close the customer-data and save-feedback issues below, attach final installed-app/payment evidence, and verify recovery/alert ownership before broad promotion. Marketing preparation can continue meanwhile.

This decision distinguishes demonstrated defects from missing evidence. The owner said testing was already completed; the exact build, hardware, and payment results were not supplied during this review. “Not verified here” does not mean “the owner has not tested it.”

## Scope and release identity

- Reviewed workspace: `19fb3bce3d5baece419f3e8ca600c2cb74dba843`.
- Current public app: **1.0.14 / build 1000014**, released from `4f7927e1bb7a4dc996e55be784ecda0bf6dd93bd`. There is no tracked app/engine diff between that tag and the reviewed HEAD.
- GitHub's [1.0.14 release pipeline](https://github.com/mohn93/slipreel/actions/runs/34342636410) and [reviewed-HEAD CI](https://github.com/mohn93/slipreel/actions/runs/34343501241) both returned success in this review.
- Read authentication, billing, entitlement refresh, native update configuration, export publication, project saving, crash recovery, captions/model delivery, telemetry/feedback, website acquisition/activation/download flows, deployment workflows, backup tooling, and previous hardening evidence. This was a risk-focused cross-system review, not a line-by-line audit of every renderer or native capture routine.
- The pre-existing Podfile.lock difference is only CocoaPods 1.16.2 → 1.17.0. It and the unrelated strategy/withdrawal documents were preserved. No application fixes, deployment, purchases, emails, or production account changes were made.

## Findings to resolve

### F1 — P2: The privacy disclosure contradicts shipped telemetry behavior

[privacy.html:50](/Users/mohn93/Desktop/side_projects/screenflow_studio/site/privacy.html:50) calls app telemetry anonymous and identified only by a device hash; line 60 says the app never transmits email. In [main.dart:772](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/lib/main.dart:772), a loaded entitlement changes analytics, diagnostics, and feedback identity to the account's `sub`. [feedback_service.dart:55](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/lib/feedback/feedback_service.dart:55) explicitly transmits the optional reply email to PostHog.

The disclosure mismatch is present on the live privacy page. Its raw HTML differs from the repository only because Cloudflare transforms the contact email and adds its decoding script; that is not source drift in the privacy claims.

**Impact:** a privacy-led product promises stronger anonymity than it implements. This is an observable product/disclosure mismatch, not a determination of jurisdiction-specific legal compliance.

**Close before public promotion:** describe anonymous pre-sign-in versus account-associated telemetry accurately, disclose optional feedback email and its processor, and make the Settings copy consistent. Alternatively change the implementation to meet the existing promise. Separately resolve the earlier operational review of historical analytics credential retention; this review did not inspect PostHog history.

### F2 — P2: Switching accounts can relabel queued telemetry as the next customer

[analytics_service.dart:87](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/lib/analytics/analytics_service.dart:87) treats the previous identity as an anonymous ID on every identify call. [posthog_sink.dart:75](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/lib/analytics/posthog_sink.dart:75) supplies one current identity to the entire batch at delivery time. The entitlement listener has no sign-out reset.

**Reproduced locally with mocked transport:** identify A, queue activity, identify B, flush. A's activity is sent with B's `distinct_id`; the identify payload also names A as `$anon_distinct_id`. This proves incorrect outgoing attribution. Whether PostHog merges or rejects that particular identity relationship was not tested against the service.

**Impact:** activity and potentially queued diagnostic/feedback data from a shared Mac can be attached to the wrong account, and the acquisition/retention funnel becomes unreliable.

**Close before public promotion:** capture identity per event, preserve it in the persistent queue, reset identity on sign-out, and only join a true anonymous session to its first authenticated account. Cover account A → sign-out → B, including offline queued feedback. Reproduction and output are retained in [the evidence directory](gtm-final-2026-09-09/telemetry_repro.dart).

### F3 — P2: Failed project autosaves have no local recovery feedback

[playback_screen.dart:1140](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/lib/ui/screens/playback_screen.dart:1140) ignores the future returned by `_projectStore.save`; disposal does the same at line 1162. [editor_project_store.dart](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine/lib/state/editor_project_store.dart) logs and rethrows write failures. These paths do not show an unsaved indicator or offer a retry.

**Trigger:** storage fills up, a recording's external volume disconnects, or the project directory becomes unwritable. The user can continue editing without knowing the newer state is not durable. Atomic rename protects the old saved state; it does not save the new edits when writing fails.

**Close before greenlighting data durability:** track pending/saved/failed state, catch the failure near the editor, retain dirty state for retry, and flush pending work through an awaited close/quit path. Verify with an injected write failure and a successful subsequent retry. This finding is established by source inspection; an actual disk-full or forced-quit experiment was not performed on the user's recordings.

### F4 — P2: Feedback says “sent” before delivery is known

[feedback_sheet.dart:58](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/lib/ui/feedback/feedback_sheet.dart:58) submits without awaiting and immediately shows success at line 65. The sink absorbs transport failures for retries and silently does nothing if unconfigured.

**Impact:** a launch customer can believe a blocking issue reached support when it is queued offline or was never accepted. A queue is useful, but the displayed state needs to be truthful.

**Close:** report “saved to send” once durable locally and “sent” only on acknowledgement; provide a support-email fallback. Verify the actual support recipient can see a test report from the release build. Existing receipt/notification evidence was not available here.

### F5 — P2: The offline telemetry limit does not bound the in-memory queue

[posthog_sink.dart:50](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/lib/analytics/posthog_sink.dart:50) appends without a limit and flushes the entire queue. `AnalyticsQueueStore.save` trims only the persisted representation to 500 events.

**Reproduced:** a store configured for 500 events leaves **1,001 events** in the live sink. Failed requests reschedule every five seconds. A persistent outage permits continued growth and increasingly large retry payloads; actual memory exhaustion was not induced.

**Close:** bound events/bytes in memory and on disk, limit batch size, and use bounded exponential retry backoff. Include shutdown handling so a failed final flush does not create another retry timer after disposal. This can be a near-term reliability fix for a controlled rollout; it should not remain the long-term outage behavior.

### F6 — P3: Homepage update promises and release wording need cleanup

[index.html:527](/Users/mohn93/Desktop/side_projects/screenflow_studio/site/index.html:527) advertises “Automatic updates,” while [AppDelegate.swift:9](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/macos/Runner/AppDelegate.swift:9) disables automatic checks and installations on startup. The manual-update policy is intentional to protect one-time-license coverage. Use “Check for updates in Settings.”

The live homepage also says “Developer-developer-signed” twice. Pricing still references “1.0.9 or later” for the trial, despite the public supported archive starting at 1.0.13. The historical trial statement is not necessarily false, but “the current release” would avoid needless confusion.

## Fresh verification

| Check | Result and limits |
|---|---|
| Website JavaScript | **43 passed**, no skips |
| Website lint | Clean; lint guard and deploy guard regressions passed |
| Release tooling | Appcast, build date, version tests passed; supported-archive policy **3 passed** |
| API typechecking | Passed, including maintenance scripts |
| Complete API suite | **102 passed across 24 files**, disposable local PostgreSQL; stopped afterward |
| Backup regression suite | **4 passed**, including a real custom-format dump/validation and retention on that disposable database |
| Desktop licensing/recovery/export entitlement selection | **99 passed** |
| Export engine directory | **250 passed**, including MP4/GIF, cancellation, source protection, audio, camera/composition paths; development environment binaries, not a fresh installed-release end-to-end test |
| New telemetry probes | **2 passed reproducing defects**; these are demonstrations, not fixes |
| Current npm advisory audit | **0 known vulnerabilities**, production and development dependencies; not an audit of all native/Flutter dependencies |
| Public API | `/ready` **200**; unauthenticated checkout **401**, no purchase created |
| Live browser | Homepage resolves download links to 1.0.14; pricing defaults to $69 one-time and switches to $9 monthly; anonymous downloads page finishes loading and lists only 1.0.14/1.0.13 |
| Public source comparison | Download-page and analytics JavaScript exactly match workspace SHA256 |
| CI/release | Actual published-release workflow and reviewed-HEAD CI successful |

Existing 1.0.14 artifact evidence was inspected and copied into [the durable evidence directory](gtm-final-2026-09-09/release-1.0.14-verification.json): public/GitHub/origin digest agreement, Sparkle signature, app/DMG signing, notarization, Gatekeeper, and universal app/helpers. It records SHA256 `53d6d58c57e7bb93901a4807bf2ecedace0e23c9dc2785a002047828b3cb4278`. These artifact inspections were performed earlier on the same date, not repeated or represented as newly performed here. The live feed and GitHub release identity were checked again.

Full older app/engine/native results remain in the earlier hardening report. Counts across reports overlap and must not be added into a unique-test total. Fresh temporary logs are under `/tmp/slipreel-final-audit`; key backend/advisory/reproduction evidence is copied alongside this report.

The generic web fetcher could not open the domain and a Python HTTP client received 403 responses. The normal browser and curl succeeded. Those tool-specific failures are not evidence that customers cannot load the website. Mobile layout, authenticated downloads, and a completed live checkout were not revalidated in the browser during this pass.

## Readiness across the business and product

| Area | Assessment |
|---|---|
| Capture/edit/export architecture | Strong automated foundation; safer staged output, stream-preserving recovery, project migrations, and recent native regressions. Native permissions/timing still require actual release hardware evidence. |
| Authentication and payments | Earlier severe findings have concrete repairs and passing regressions: verified-email ownership, no checkout-as-authentication, serialized seats, paid-price validation, webhook idempotency, reconciliation, reversal/grace policies. Final live journey remains an evidence gate. |
| Licensing and distribution | Signed tokens, bounded offline renewal, manual updates, supported archive, two-device handling. Public 1.0.14 distribution is healthy. Validate final activation/update/covered-version behavior with an installed app. |
| Data durability | Export protection is well covered; failed autosave visibility and final-close durability need closure. Test low disk and recovery on disposable recordings. |
| Operations | A local daily backup and prior restore drill exist. A server-loss recovery copy, signing-key recovery, application alert delivery, and a secure rollback rehearsal are not verified by this review. |
| Privacy/security operations | Current sensitive pages exclude analytics and tested credential scrubbing is present. Disclosure, account switching, historical retention review, and production alert ownership remain open. |
| Support | Guide, account/device management, changelog, and a public support address are available. Confirm inbox delivery, feedback visibility, a refund procedure, and an owner who can respond during launch. |
| Positioning and pricing | Clear local Mac-demo workflow, real feature demonstrations, three account-free exports, $69/$9 choices, two Macs, update window and 14-day online renewal disclosed. Scope is coherent for initial customers. No new competitor/pricing market research was performed. |
| Conversion and measurement | The visit/download/record/export instrumentation exists, but a click is not an install and entitlement activation is not necessarily a new purchase. Use Stripe's paid/refunded records as revenue truth. Do not trust cross-account funnel joins until F2 is fixed; verify events actually arrive. |
| Commercial readiness | Refund promise is visible. No dedicated terms/EULA page is present in the reviewed site tree. Tax/receipt settings and seller-policy review were not independently verified. Record an owner decision for intended sales markets; do not infer readiness from successful Stripe API calls alone. |
| Third-party assets | Native helper license/provenance documentation and music source/checksum records exist. This pass did not re-establish rights for every image, device frame, font, model, or asset. Keep that inventory review distinct from technical CI. |
| Maintainability | Meaningful multi-platform CI and release gating. Flutter uses moving `stable`, actions use version tags, and CocoaPods differs locally: pin toolchains for reproducibility before the next difficult release investigation. Not a demonstrated failure of 1.0.14. |

## Final greenlight checklist

1. **Close F1–F3**, with targeted regression evidence and an updated release when app code changes. Close F4 or make the email fallback and queued status truthful; clean up F6. Give F5 an explicit near-term owner if accepting it for a limited launch.
2. **Attach the owner's final-build acceptance evidence.** Use the current downloaded build: clean launch, permissions denied/granted, display/window/region capture, mic/system audio/camera sync, pause/resume/sleep, captions first download, save/reopen, MP4/GIF and cancel, crash recovery, and low-disk behavior. Cover Apple Silicon and Intel and the supported macOS endpoints, or explicitly narrow the launch support claim. Existing evidence can satisfy this—rerunning everything is unnecessary when build and coverage match.
3. **Complete the real customer journey.** Verify email → intended price/plan → payment/receipt → app activation → paid export; second-device and seat handling; cancellation and refund access behavior. Use controlled test-mode evidence for delayed webhooks/disputes rather than manufacturing a real card dispute. A real purchase/refund requires the owner's financial authorization and was not attempted here.
4. **Prove operational recovery and notification.** Restore an off-host backup to an isolated database, verify recovery of signing/configuration material and supported installers, and demonstrate delivery of readiness and backup-failure alerts to the responsible person. Set acceptable data-loss/recovery windows. A healthy host dashboard alone does not prove someone gets alerted.
5. **Verify the launch desk.** Confirm support/feedback reach the owner, paid/refund counts reconcile to Stripe, and the chosen commercial/privacy policies match the product. Document the historical analytics exposure review outcome separately.

After these are recorded, launch to a small initial cohort, watch successful first exports, paid activation failures, repeat use, refunds, and support load, then broaden promotion. The remaining issues are finite and actionable; the passing engineering work is substantial, but it cannot substitute for the last customer and operational checks.
