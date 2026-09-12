# Slipreel Mac App Store release preparation

Decision: $9/month subscription only in the store. Access is shared with the website edition through the same Slipreel account. Checkout is exclusive to the installed edition. Existing website one-time licenses retain their release-date ceiling.

## Package identity and billing

- Direct: `com.slipreel.app`, Stripe checkout, Sparkle updates.
- Store: `com.slipreel.store`, `SlipreelStore.app` (display name Slipreel), StoreKit 2, Apple updates.
- Monthly auto-renewable product: `com.slipreel.store.monthly`, subscription group “Slipreel Pro”. No store lifetime product.
- Display prices always come from StoreKit. The draft subscription pricing was set to exactly $9.00 USD using Apple’s expanded price points, with Apple-calculated regional equivalents.
- Sign in before buying links an immutable `appAccountToken` UUID to the Slipreel account. Do not transfer an Apple transaction to a different account based on a client-provided email.
- Apple/Stripe rows are separate. Apple refunds do not overwrite Stripe access, and Stripe cancellation does not remove Apple access.
- Website checkout refuses a second purchase while an Apple subscription grants access. Store checkout refreshes account access before opening Apple’s purchase sheet.
- Production Apple purchases grant shared server access; sandbox payments do not grant production website licenses. Test cross-edition sandbox sharing against an isolated test backend, never enable sandbox payments as production entitlement.
- Local StoreKit access works offline until the signed subscription expiry. Shared website access uses the existing signed, periodically refreshed device license.

## Build

The working source remains a direct build by default. `scripts/prepare-app-store.py NEW_DIRECTORY` stages a separate source tree, removes the updater dependency before plugin generation, selects sandbox entitlements and compiles native code with `APP_STORE`. Dart uses `SLIPREEL_DISTRIBUTION=app-store`; native code checks the channel independently.

Set `APP_STORE_PROFILE` to the installed Mac App Store distribution profile name or UUID, then run `scripts/build-app-store.sh VERSION BUILD_NUMBER NEW_DIRECTORY` on a Mac with the correct Apple provisioning profile. Vendored ffmpeg, ffprobe, whisper-cli and their license/provenance files must exist. Helpers inherit the sandbox. No Homebrew/PATH fallback is allowed in the store edition.

`verify-app-store.py APP_PATH` requires a distribution signature, profile, Sign in with Apple and Keychain groups, and checks the sandbox and helper signatures, absence of updater frameworks/direct callback, bundle identity and private cursor API strings. Use `--local-test` only to inspect an ad-hoc artifact. This structural check is not App Review approval or proof of recording/purchase behavior.

The local validation build was compiled without Apple provisioning and ad-hoc signed with a separate test entitlement file. Its Sign in with Apple/keychain distribution entitlements were omitted for local UI inspection. **It is not an uploadable distribution build.**

## Apple setup required before TestFlight

Under Becoming Ventures, LLC (`UD7WB2694V`):

1. DONE: Registered the explicit Mac App ID `com.slipreel.store` with In-App Purchase and Sign in with Apple; configure it as the primary Sign in with Apple App ID.
2. DONE: Created [Slipreel macOS](https://appstoreconnect.apple.com/apps/6811278947/distribution), app ID `6811278947`, English US, SKU `slipreel-macos-store`, manual release. No public submission has been made.
3. DONE: Created monthly product Apple ID `6811279465` in group `22378909`, with English US product localization. English US subscription group localization is saved as Slipreel Pro, using app name Slipreel. Review screenshot and availability remain required. Complete paid-app agreements/tax/banking if Apple requires action.
4. DONE: Generated and installed Mac App Store profile `Slipreel Mac App Store`, UUID `d3928fdc-491c-4352-b660-965df8890d05`, portal ID `AZHNTDN5YJ`, expires 2027-09-01. Verified bundle/team, Apple Sign In and matching installed distribution certificate. Mac Installer Distribution certificate was subsequently created by the account holder, verified against the prepared private key and installed; expires 2027-09-12.
5. Configure Sign in with Apple and In-App Purchase server credentials. Keep private keys outside Git. Register the Resend sending domain/email with Apple private email relay.
6. Set App Store Server Notifications V2 production and sandbox URL to `https://api.slipreel.app/v1/apple/notifications` only after the new API is deployed and tested.
7. Supply app privacy responses for account email/user ID, purchase history, diagnostics/usage (when enabled). No recording, screen or microphone content is sent to our server.
8. Fill support/privacy URLs, export compliance, age rating, categories and review contact using the actual account holder details. Do not guess legal declarations.

## Server configuration and rollout

Migration `0009_app_store.sql` adds the account UUID, native auth challenges, encrypted Apple identities and separate Apple subscription records. Back up the database and deploy the migration before code that queries it. Existing Stripe secrets/endpoints remain unchanged.

Required environment variables (values are secrets except IDs/paths):

```
APPLE_STORE_BUNDLE_ID=com.slipreel.store
APPLE_STORE_APP_ID=6811278947
APPLE_TEAM_ID=UD7WB2694V
APPLE_SIGN_IN_KEY_FILE=<private P8 path>
APPLE_SIGN_IN_KEY_ID=<key ID>
APPLE_TOKEN_ENCRYPTION_KEY=<base64 32 random bytes; persist/back up securely>
APPLE_IAP_KEY_FILE=<private P8 path>
APPLE_IAP_KEY_ID=<key ID>
APPLE_IAP_ISSUER_ID=d8910093-5191-47fe-a6f4-8dc988df6ae1
APPLE_ROOT_CERT_FILES=<comma-separated Apple root certificate paths>
```

Apple’s official server library checks certificate chains, bundle/environment and JWS signatures. A fresh Apple subscription-status lookup precedes database writes, preventing replay of pre-refund signed transactions. Notifications repeat that lookup and older signed status cannot overwrite newer status. All native auth requests use TLS; OTPs have a 10-minute lifetime, five-attempt cap and atomic consumption. Native bearer sessions stay in Keychain in the provisioned store app. Apple refresh credentials are AES-256-GCM encrypted for revocation on account deletion.

Account deletion removes local account access and deletes server account data; it cancels Stripe subscriptions and revokes Sign in with Apple credentials. Apple billing must be cancelled by the user separately, which the UI explains. Verify deletion and late webhook behavior in staging before enabling real accounts.

## Feature differences and acceptance gates

The App Store build removes private cursor fallbacks and global keystroke recording, along with its onboarding card, permission request and inspector tab. Public cursor tracking, zoom, framing and capture remain, subject to device validation. Existing projects with recorded keystroke data can still render their stored overlays; new store recordings do not capture keystrokes.

Before submission, verify on a provisioned build and clean user environment:

- Fresh install, screen recording/mic/camera consent, denial/regrant; no Accessibility prompt.
- Record screen/window/area + system audio/mic/webcam; pause/resume; cursor/click/autozoom; export MP4/GIF; captions with bundled helper.
- Save to a selected folder, quit/relaunch, resume editing/export using its security-scoped bookmark; revoke folder access and recover clearly.
- Product loading, localized monthly price, cancelled/pending/success purchase, renewal/expiry/refund, restore after reinstall, offline expiry, account switching and purchase ownership mismatch.
- Website subscription -> store unlock without another charge; Apple production-equivalent test purchase -> direct token/website access; cancel/refund one provider while the other remains valid.
- Email OTP and Apple sign-in with/without Hide My Email; sign out, session expiry, account deletion, Apple authorization revocation, device-seat limits.
- No Stripe purchasing in store; no Apple purchasing or Sparkle removal in direct; provider-appropriate management.
- Archive/export/upload validation, TestFlight processing, real sandbox Apple purchase/sign-in, then App Review. Use manual release.

## Media

`scripts/prepare-app-store-preview.py` produces `dist/app-store/slipreel-app-preview-draft.mp4` and a provenance/probe manifest: 27 seconds, 1920x1080, 30fps H.264, AAC stereo, fast-start. It uses the local website hero/zoom/frames clips; 720p sources are upscaled. No keystroke footage is included.

It is a draft demonstration of output, not verified native store-app workflow footage. Add actual recording/editor/export footage and final screenshots from the provisioned build, then review against Apple’s preview rules. Do not submit a video that promises removed features.

Sources: [Review guidelines](https://developer.apple.com/app-store/review/guidelines/), [preview specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications), [Apple server library](https://github.com/apple/app-store-server-library-node), [account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/).

## Validation observed on September 12, 2026

- Full Flutter app suite: 1,122 passed, 14 skipped (before final guard-only edits; targeted tests repeated afterward).
- Final Flutter analyzer: clean; targeted licensing/store tests: 97 passed. Direct universal native build also compiled successfully with signing disabled.
- Backend suite: 119 passed against isolated scratch PostgreSQL, including shared provider access, OTP replay/lockout, and independent edition refresh credentials on a single device seat.
- Universal store native build compiled successfully with signing disabled. Sandboxed ad-hoc build launched; onboarding, settings and store paywall inspected. This does not validate provisioned Apple login or purchases.
- Website-derived 27-second preview is generated locally as a draft; final native UI footage/screenshots and App Review metadata remain pending.
- Apple server status recovery runs on account activation/direct token refresh when the previous check is more than one hour old. API failure retains the last verified paid-through date; no new Apple dates are inferred.

Not deployed or submitted. Deployed Apple credentials, provisioned signing, purchase lifecycle/sign-in acceptance, recording/export/folder-access acceptance and final metadata/media are release blockers.

Sign in with Apple key `ZJ4RL462K3` was created and downloaded by the account holder, then verified against Apple Developer. Its private P8 and an owner-only local configuration are stored outside Git under `~/.config/slipreel/apple-store/`. Local ES256 signing/verification and server configuration loading passed. This is not an end-to-end Apple login test or a deployed server configuration. The separate purchase key is configured locally as described below; distribution provisioning still needs setup.

The account holder created/downloaded `Slipreel Purchases`, key ID `7L8C835T2X`; App Store Connect confirms it is active under Becoming Ventures. Its P8 and `purchases.env` are stored owner-only outside Git beside the sign-in configuration. The three public roots were downloaded from Apple PKI and their self-signatures verified. The EC P-256 key and subscription-service initialization passed. A read-only notification-history request authenticated successfully against Sandbox (empty history); Production returned HTTP 401. This proves sandbox API authentication only, not purchase verification. Apple commerce engineering confirms that production API access is unavailable until a production release ([official response](https://developer.apple.com/forums/thread/806452)). This is consistent with the observed 401 for this unreleased app; do not rotate a working sandbox key or treat this alone as a pre-release blocker. Recheck production authentication after release. Credentials have not been deployed. No private material is included in this document.

The Mac App Store distribution profile form is prepared for `Slipreel Mac App Store`, bundle `com.slipreel.store`, using existing Becoming Ventures Apple Distribution certificate `8ZF9CAH2WD` (expires 2027-09-01). The user approved generation and the profile was generated, downloaded and installed.

App Store Connect now has the promotional text, description, keywords and marketing URL saved as an unpublished draft. The separate distribution staging tree `/private/tmp/slipreel-store-distribution` is configured for the named profile and all ten workspace packages bootstrapped successfully. A universal Apple Distribution-signed 1.1.0 (10100) build from that tree passed the strict structural verifier. The verifier required a correction from `codesign -dv` to `-dvv` to expose the Authority lines; the signature itself was valid. Real recording, sign-in and purchase tests remain pending.

Streamlined Purchasing remains on. [Apple documentation](https://developer.apple.com/help/app-store-connect/manage-subscriptions/manage-streamlined-purchasing) permits disabling it when app sign-in is required but requires StoreKit purchase-intent support in an approved binary first. Do not enable contingent/win-back offers or redemption campaigns before validating account linking for outside-app purchases.

Installer CSR is prepared at `~/.config/slipreel/apple-store/mac-installer.certSigningRequest`, with its private RSA key stored owner-only beside it. Only the public CSR is copied to the preparation artifacts. The correct `mac_installer.cer` is now installed with its matching private key. A signed installer package was generated and `pkgutil --check-signature` verified its Apple certificate chain. The earlier `mac_app.cer` downloads were application certificates with a different key and were not used. Browser tab control repeatedly timed out after the profile step. No upload, submission or deployment occurred.

`scripts/package-app-store.sh APP_PATH NEW_PACKAGE_PATH` verifies the provisioned app and creates a package signed by the Becoming Ventures Mac Installer Distribution identity. It refuses to overwrite an existing package. The generated artifact is `dist/app-store-preparation-2026-09-12/SlipreelStore-1.1.0-10100.pkg` in the original checkout (160,874,602 bytes). This package still targets the production API whose new Apple/native-account routes have not been deployed. Do not present it as ready for user payment/login acceptance yet.

Apple `altool --validate-app` succeeded with no errors on 2026-09-12 for the signed package, authenticated using the existing Slipreel App Store Connect API key. Validation is not an upload, TestFlight processing, App Review approval or functional acceptance. The validation log is copied beside the package.
