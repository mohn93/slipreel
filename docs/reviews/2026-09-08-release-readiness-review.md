**Slipreel release-readiness review — 8–9 September 2026**

**Recommendation: hold the public launch until the P1 findings below are fixed.** The landing page and signed download are in good shape, and the existing automated suites pass. However, targeted checks uncovered account-access and recording-data-loss defects that those suites do not cover.

Reviewed the working tree, including the export-dialog changes now in commit `48f190cb`, and the public website/API and downloadable **1.0.12 / build 1000012**. The published appcast dates that binary to 7 September. Findings against current source are not a claim that every compiled code path in the published binary was reverse-engineered. No product fixes or production changes were made during this review.

**Verified coverage**

| Area | Result |
|---|---|
| Flutter app suite | 1,060 passed; 14 skipped |
| Rendering/editor engine suite | 1,545 passed; 2 skipped |
| Platform interface | 77 passed |
| macOS Dart plugin/channel suite | 18 passed |
| Backend | 92 passed against a fresh, disposable local Postgres database |
| Website JavaScript | 27 passed |
| Native Swift | 60 passed: first-frame timing, cursor/region geometry, and writer stop without frames |
| Static analysis | App and engine clean; backend TypeScript typecheck passed |
| Release/site scripts | Site lint, lint guards, deploy guards, appcast, version derivation, and build-date tests passed |
| Actual bundled ffmpeg | 17 MP4/GIF fixture checks passed using ffmpeg from the public DMG |
| Targeted regression probes | Two failing data-preservation tests; additional backend defects reproduced with real routes/DB and mocked Stripe |
| Public URLs | 55 current page, asset, and download URLs returned 200 |
| Live browser | Desktop homepage; 390px mobile homepage/pricing; checkout empty-email validation; signed-out account → login |
| Download | 148,255,719 bytes, matching the appcast; DMG checksum valid; deep app signature valid; notarization staple valid; Gatekeeper accepted as Notarized Developer ID |
| Update/auth keys | Sparkle signature cryptographically verifies against the bundled public key; API entitlement public key matches checked-in app key |
| Architecture | App, ffmpeg, ffprobe, and whisper-cli include x86_64 and arm64; app minimum OS is 13.0 |
| Dependency/security spot check | Production npm audit: one moderate dependency, zero high/critical. No current tracked matches for the private-key/live-secret patterns checked |

The initial backend test attempt lacked TEST_DATABASE_URL; it was rerun successfully on an isolated database. Native tests initially hit a stale generated CocoaPods project; regenerating it resolved the compile failure, and all 60 selected tests passed. Seven live HTML files differ from disk; the inspected homepage difference is Cloudflare email obfuscation, not an undisclosed price change. All inspected deployed application JavaScript files matched the checkout.

**Release blockers — P1**

**1. A checkout using somebody else's email can authenticate the purchaser as that existing customer.**

The unauthenticated [checkout route](/Users/mohn93/Desktop/side_projects/screenflow_studio/server/src/routes/billing.ts:21) reuses a Stripe customer based solely on the posted email. [session-from-checkout](/Users/mohn93/Desktop/side_projects/screenflow_studio/server/src/routes/auth.ts:27) then grants a full application session for that customer after payment, without proving control of the email address. Paying with one's own card is not proof of ownership of the pre-existing account.

Local reproduction: seeded an existing customer, submitted checkout for their email without a cookie, simulated completion of that new checkout, and received their user ID and a session that opened their billing portal. Stripe was mocked; the database and application handlers were real. No real customer was accessed. Impact includes account/device management and access to the victim's billing portal, subject to the portal's configured features.

Fix: require verified sign-in before attaching a checkout to an existing account. For new accounts, establish email ownership before granting account-management access. Bind completion to a server-side purchase flow; the desktop state nonce alone does not establish account identity.

**2. Exporting to the original recording's path can delete the recording.**

The save path reaches the encoder without a source/destination identity guard. When ffmpeg rejects the same input/output path, [export cleanup deletes outputPath](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/slipreel_engine/lib/export/export_pipeline.dart:672), which is the original source. This reproduced on a disposable fixture copy: ffmpeg reported “same as Input #1”; the original copy no longer existed afterward.

Fix: reject destinations matching any source media, including resolved symlinks/file identity. Encode into a unique sibling temporary file, validate it, and replace the selected destination only after successful finalization. Cleanup must delete only files owned by that export attempt. This also preserves a previous successful export when a replacement attempt fails or is canceled.

**3. Crash recovery silently discards an audio track and deletes the original.**

[RecoveryService](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/lib/state/recovery_service.dart:65) remuxes without explicit stream mapping. A recording with microphone and system-audio tracks recovers with only one audio stream. The [successful recovery path](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/lib/state/recovery_service.dart:144) then deletes the original. A synthetic fragmented MP4 with two audio streams reproduced `audioTracks=1; originalExists=false`.

Fix: explicitly preserve the intended video and all audio streams, verify recovered stream counts, and retain the original until recovery has been validated. The recovery metadata also does not preserve camera linkage or device-capture identity; expand that recovery contract before describing it as complete project recovery.

**4. Authentication pages load analytics while credentials remain in URLs and links.**

[Analytics initialization](/Users/mohn93/Desktop/side_projects/screenflow_studio/site/assets/js/analytics.js:74) enables automatic pageviews and permits session replay. Login and success pages load it while carrying `token` or `session_id` in the URL; neither page removes those values before analytics starts. App-return links additionally contain entitlement/refresh credentials. The deployed PostHog SDK constructs `$current_url` from the current location and defaults personal-data masking off; this site does not configure a scrubber. Masking typed inputs does not protect URLs or generated link attributes.

Fix: exclude login/success/activation pages from analytics and replay, remove consumed credentials from the address bar, and explicitly scrub credential query parameters and callback links everywhere. Review analytics retention/access for any previously collected credentials. This finding is based on deployed source/configuration; production analytics records were not accessed. PostHog documents the relevant [capture and before_send controls](https://posthog.com/docs/libraries/js/config).

**5. Successful payment can return a free token before the entitlement webhook arrives.**

[Checkout completion](/Users/mohn93/Desktop/side_projects/screenflow_studio/site/assets/js/flow.js:43) immediately activates a device after obtaining a web session. Users already exist from checkout creation, so authentication can succeed before the entitlement row exists. The token endpoint then correctly resolves that incomplete state as free. Reproduced a complete/paid checkout followed by activation receiving `plan: free`. There is no fulfillment wait/retry in this flow; the app refreshes at launch rather than immediately retrying this pending purchase.

Fix: make fulfillment idempotent and reconcile it before reporting activation ready; otherwise return a distinct pending state and poll with a bounded retry and useful recovery UI. Do not consume an activation opportunity and tell a paying user to buy again. Stripe explicitly warns that [webhook event order is not guaranteed](https://docs.stripe.com/webhooks).

**6. An unpaid one-time checkout grants a permanent entitlement.**

The [payment-mode webhook branch](/Users/mohn93/Desktop/side_projects/screenflow_studio/server/src/billing/entitlements.ts:66) grants access without checking `payment_status`. A `checkout.session.completed` event with `payment_status: unpaid` reproduced an active one-time entitlement. Delayed-notification payment methods can complete checkout before funds succeed; applicability in production depends on which payment methods are enabled, which was not inspected.

Fix: verify payment status and product/price, fulfill delayed payments on successful settlement, and handle later failure. Add idempotency at the purchase/payment level so supporting both completed and async-success events cannot extend the update window twice. See Stripe's [fulfillment guidance](https://docs.stripe.com/checkout/fulfillment).

**Other actionable findings — P2**

**7. Out-of-order subscription events can restore canceled access or remove valid access.** [Subscription upsert](/Users/mohn93/Desktop/side_projects/screenflow_studio/server/src/billing/entitlements.ts:135) unconditionally overwrites current state using the incoming event. Processing a newer cancellation and then an older active update restored export in the local database. Event-ID deduplication does not solve ordering. Reconcile against the current Stripe subscription, or implement safe version/order handling and reconciliation tests.

**8. Refunds and terminal nonpayment do not reliably revoke access.** The [webhook switch](/Users/mohn93/Desktop/side_projects/screenflow_studio/server/src/billing/entitlements.ts:83) acknowledges and ignores refund/dispute events; a full refund left the one-time license active in the reproduction. Separately, [unpaid maps to grace](/Users/mohn93/Desktop/side_projects/screenflow_studio/server/src/billing/entitlements.ts:12), and [entitlement resolution](/Users/mohn93/Desktop/side_projects/screenflow_studio/server/src/billing/effective_entitlement.ts:24) does not bound grace by time. An unpaid subscription with an expired period still granted export. Implement explicit refund/reversal policy and a finite grace window; keep a payment ledger so renewals and partial refunds are handled correctly. Allow for the documented offline token lifetime when evaluating revocation latency.

**9. Concurrent activation bypasses the two-device limit.** [Device registration](/Users/mohn93/Desktop/side_projects/screenflow_studio/server/src/auth/devices.ts:41) counts seats and inserts separately. With a warmed pool, eight concurrent registrations for one test account all succeeded, leaving eight seats for a limit of two. Serialize registration per user inside a transaction, including duplicate-fingerprint handling.

**10. Canceling checkout loses the desktop activation context.** [Billing config](/Users/mohn93/Desktop/side_projects/screenflow_studio/server/src/billing/config.ts:46) always returns cancellations to bare `/pricing`. The original `device`, `device_name`, `state`, and selected plan are lost. A user who cancels to change plan and then pays completes a website-only purchase rather than returning to the waiting app. Preserve a server-bound flow reference across cancel/retry. The [website-only success message](/Users/mohn93/Desktop/side_projects/screenflow_studio/site/assets/js/page-success.js:40) also says export is unlocked when no Mac was activated; replace it with explicit install/sign-in steps.

**11. GIF limits and estimates use source duration instead of edited duration.** The dialog receives the raw probed duration, and the [60-second check](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/lib/ui/screens/playback_screen.dart:2237) uses the same value. A five-minute recording trimmed to a ten-second selection is rejected as a GIF, while size/time estimates remain based on the longer recording. Use the edited timeline duration after cuts and speed changes for both display and eligibility; keep source duration separate for decoding.

**12. Clipboard export copies a pathname, not a video.** [ClipboardCopier](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/lib/services/destination_handlers.dart:166) writes plain text such as `/.../slipreel_export_....mp4`. Pasting into a chat produces a local path, not an attachment. The UI calls the destination Clipboard and claims it can be pasted into Finder or any app. Implement an actual file pasteboard representation, or label it explicitly “Copy local file path” and offer Reveal in Finder. Keep the unfinished hosted-link destination hidden; the current dialog cleanup does that, but requires a new app build to reach users.

**13. License refresh only runs at launch.** [main.dart](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/lib/main.dart:248) schedules the only automatic refresh; [export gating](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/lib/licensing/entitlement.dart:38) rejects expired tokens. A paid app left open beyond the token lifetime, or launched offline and later reconnected, can remain locked until restart/sign-in. Refresh with a timeout before expiry, on resume/reconnect, and when a paid export encounters expired credentials. Clarify that the current one-time license also depends on periodic online renewal of its token.

**14. The permanent-version promise lacks a durable fallback download.** [Release deployment](/Users/mohn93/Desktop/side_projects/screenflow_studio/.github/workflows/release-macos.yml:132) removes all but three DMGs while preserving their appcast entries. The advertised older 1.0.0 download currently returns 404. [The updater](/Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/lib/update/updater_service.dart:28) is not aware of the license's update ceiling, while the app blocks exports in builds beyond that ceiling. Retain eligible versions in durable storage and provide a downgrade/download path; warn before installing an update that needs renewal. A private or undiscoverable GitHub release is not a customer-facing substitute.

**15. CI does not cover the backend, and publishing is not gated by these suites.** [Current CI](/Users/mohn93/Desktop/side_projects/screenflow_studio/.github/workflows/test-all-platforms.yml:10) runs Flutter/site checks but no server typecheck or Postgres-backed tests. The separate release workflow builds and publishes without a test dependency. Add a backend job and gate release publication on the exact commit's required checks. Include the security and data-preservation regressions discovered here; passing existing tests is demonstrably insufficient.

**16. The landing FAQ contradicts the app's network behavior.** [The FAQ](/Users/mohn93/Desktop/side_projects/screenflow_studio/site/index.html:686), including its structured data, says only license activation talks to a server. The app also supports analytics, diagnostics, update checks, feedback, and model download. The privacy page acknowledges analytics, but the prominent FAQ makes a broader promise. Say that recording media stays local, then accurately describe the other traffic and opt-outs. Also soften the hero's implication that captions appear immediately when recording stops: transcription is explicitly initiated in the caption-generation flow and may first download a roughly 488MB model.

**Landing, accessibility, and release polish**

The hero is readable, the product demo is visible, and download/trial/pricing information is easy to find. The mobile hero and pricing cards fit at 390px without horizontal overflow. Homepage browser inspection reported no warning/error logs. The selected one-time plan carried correctly into the checkout page, empty-email validation produced a visible alert, and a signed-out account linked correctly to login. The code includes a skip link, semantic headings, alt descriptions, reduced-motion handling, and lazy media loading. These are useful foundations, not a full accessibility certification.

Recommended before sharing widely:

- Add a visible Account/Sign in link on the homepage and pricing page. Returning customers should not have to find an unlinked account URL or enter another purchase flow.
- Add a short download → record → edit → export onboarding guide and a public changelog. The appcast currently gives versions without user-facing release notes.
- Disclose the approximate first-use caption model download size and the current online license-check behavior.
- Keep comparisons dated and linked to primary pricing pages. Loom's current page lists [$18/user/month Business](https://www.loom.com/pricing); ScreenFlow lists [$199 and an optional $99/year library](https://www.telestream.net/screenflow/store.asp), with first-year package discounts. Billing cadence and promotions should be explicit when comparing prices. Screen Studio's [product page](https://screen.studio/) supports the on-device transcription/shareable-link distinctions; this review did not independently validate every comparative feature or billing option.
- Fix the analytics identification timing: `applyPendingIdentify()` waits for `__loaded`, but is only called immediately around asynchronous initialization or an identify request. A request queued before SDK load can stay unapplied. Use the SDK's loaded callback or its supported queue.
- Make pricing radios keyboard-operable as a group; give login a real form/Enter submission, and prevent repeat submissions while requests are pending. Complete a keyboard/screen-reader pass across authenticated flows after auth fixes.
- Update README/server README and the go-live runbook. They still describe missing distribution machinery, a skeleton API, test-mode-only billing, and obsolete test counts/prices. Those statements no longer describe the inspected release.

**Operations and remaining validation**

The API's public health and key endpoints worked. Authentication cookies are HttpOnly/Secure/SameSite=Lax; magic-link/refresh credentials are hashed in the database; webhook signature verification and transactional event claiming are present. These controls do not mitigate the account-linking defect above.

Production startup currently swallows missing/invalid billing, signing, or email configuration and can stay “healthy” with important routes or email delivery disabled. Make readiness include required production dependencies and fail startup on invalid production configuration. The deployment templates assume nginx/systemd, whereas live API headers show Caddy in the path: verify monitoring and proxy configuration against the actual deployment rather than the old runbook. No production SSH, logs, environment variables, backups, or customer data were inspected.

The npm audit reported one moderate `qs` dependency with a fix available: [array-limit bypass](https://github.com/advisories/GHSA-x5fp-wj9c-mxmx) and [isBuffer denial of service](https://github.com/advisories/GHSA-4mjr-xmp4-gh2g). Update the lockfile and rerun backend checks. An advisory match is not proof that a reachable Slipreel route exercises the vulnerable parsing options.

Before a final go decision, the remaining end-to-end release evidence should include:

1. A completed purchase on the final production configuration, correct charged prices/mode, receipt and magic-link delivery, app activation, refund, and cancellation. No real payment or email was sent in this review.
2. A clean installed-app pass on macOS 13 and current macOS, on Intel and Apple Silicon: permission denial/regrant, full-screen/window/region recording, mic/system/camera sync, pause/resume/sleep, long recordings, low disk, export/cancel, and reopening saved edits. Automated synthetic tests and binary architectures do not establish that whole hardware matrix.
3. Update installation from an older release and a one-time entitlement beyond its update ceiling. The signatures were verified, but a live update installation was not performed.
4. Working backup restoration, error/uptime alerting, and rollback of both application code and database-compatible releases. These depend on operational state unavailable in this review.

**Suggested repair order:** account identity and credential handling; source-safe export and lossless recovery; payment fulfillment/revocation and activation retries; then the P2 flow/CI fixes and final installed-app/purchase smoke pass. Do not launch on the strength of the green existing suites alone.

Reproduction outputs and verification summary are preserved in [the evidence file](/Users/mohn93/Desktop/side_projects/screenflow_studio/docs/reviews/2026-09-08-release-readiness-evidence.txt). Additional temporary logs and local-only harnesses are under `/tmp/slipreel-release-review/` on the review machine.
