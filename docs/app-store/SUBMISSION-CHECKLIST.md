# Slipreel submission checklist

Checked September 12, 2026. This status supersedes the historical rollout notes in RELEASE.md.

## Completed

- Store edition and channel-specific StoreKit checkout; $9/month and $79/year plans.
- Shared account entitlement implementation with separate Apple and Stripe billing records.
- Production backend rollout and sandbox server notification delivery test.
- Signed build 1.1.0 (10101) processed and available for internal TestFlight testing.
- Owner-selected export declaration saved in Apple and merged into Info.plist (PR 129).
- User installed/tried TestFlight; screenshot confirms Apple purchase/Touch ID flow opens. Successful entitlement activation is not yet independently verified.
- Icon source fix: regenerate all seven macOS icon PNG sizes from the existing SVG without a white background. Alpha checks and Xcode asset catalog compilation pass. This is not yet in the installed TestFlight build.

## Next build

- [x] Merge icon changes after CI passes (PR 130).
- [ ] Build, sign, validate and upload a new build from merged main, including the icon and plist changes.
- [ ] Install the update through TestFlight and visually verify the icon in Apple's purchase sheet.

## Functional acceptance on the provisioned build

- [ ] Email and Apple sign-in, Hide My Email, sign-out and persistence after restart.
- [ ] Monthly/yearly successful sandbox purchase unlocks exports; cancellation, restore and plan changes behave correctly.
- [ ] Shared access and duplicate-subscription suppression across editions. Use an isolated backend for sandbox cross-edition tests: sandbox purchases must not grant production website licenses.
- [ ] Recording permissions, screen/window/area, microphone/system audio/webcam, editing and MP4/GIF export.
- [ ] Saved project/folder access survives restart; captions and bundled helpers work under the sandbox.
- [ ] Account deletion, purchase ownership mismatch and offline/expired access behavior.

## App Store Connect

Live API checks show version 1.1.0 is PREPARE_FOR_SUBMISSION, with manual release selected.

- [ ] Attach the final tested build (currently no build selected for the release version).
- [ ] Upload final macOS screenshots (currently no screenshot sets).
- [ ] Finish and upload the requested native app preview video (currently no preview sets; website-derived draft exists locally).
- [ ] Complete monthly and yearly subscription review metadata/screenshots; both currently MISSING_METADATA.
- [ ] Set primary category (currently unset), age rating and copyright.
- [ ] Fill support URL (currently unset), review contact and review instructions/access (currently no review detail).
- [ ] Complete/verify app privacy responses and privacy URL, including third-party SDK collection.
- [ ] Verify Apple private email relay configuration and real Hide My Email delivery.
- [ ] Verify paid-app agreements, tax/banking and applicable trader details in the account; their current readiness has not been verified here.
- [ ] Submit the app and initial subscriptions for review, address any review feedback, then manually release after approval.

## Icon regeneration

`scripts/render-macos-icon.cjs` uses Sharp to render the tracked SVG, preserving alpha. Install Sharp outside the checkout and expose its node_modules through NODE_PATH before running the script. No new runtime dependency is added to the app.

## September 12 native acceptance and UX follow-up

- TestFlight 10101 retained both paid export access and the signed-in account after quitting/relaunching. The existing-access screen suppressed plan buttons. Restore eventually completed with active access, but the long native wait prompted a bounded restore timeout in the next build.
- A disposable TextEdit window was recorded into `recording_1789226907720.mp4` (59.48 seconds), loaded in the editor, and marked saved. Export reached the native save panel.
- **Release blocker found on 10101:** MP4 export to Documents failed with `PathAccessException: Creation of temporary directory failed`. The save panel grants the selected output, not arbitrary sibling folders. The candidate uses Foundation's same-volume item replacement directory before atomic publication. Retest MP4/GIF and replacement of an existing output through TestFlight before marking this fixed in the distributed app.
- Candidate UX replaces the store-branded upgrade button with contextual export-gate copy, localized monthly/yearly plan selection and a single upgrade action. Settings distinguishes free, paid and recovery states. Existing licenses that need verification are not offered another purchase. Pending, cancellation, error, restore and account-sync states are covered by widget tests.
- UI preview images use fake accounts/products for layout review, not submission screenshots or proof of real purchases. No refund, account deletion, or second real purchase was performed on the owner's account.
- Remaining native acceptance: Apple sign-in/Hide My Email, real shared access in both editions, microphone/system audio/webcam, selected-folder persistence, the corrected export path and offline/expiry behavior. Mock tests do not replace these checks.

The candidate export staging also passed a native macOS restriction test: creating a sibling directory was denied, but Foundation replacement staging and POSIX atomic publication to the explicitly allowed file succeeded. This reproduces the file-only permission boundary; it does not replace the next TestFlight retest.

## Subscription management environment routing

The native bridge now resolves the environment from verified StoreKit subscription history (including expired purchases), with verified AppTransaction fallback and a sandbox-receipt guard. Only verified production opens the App Store subscription URL. Sandbox purchases show test-account guidance and an optional Apple testing guide; Xcode purchases direct testers to its transaction manager. Unknown environments stay in the app with recovery instructions. No undocumented sandbox deep link is used: the native macOS SDK does not expose `AppStore.showManageSubscriptions`.

Validation: Swift typecheck against the macOS 13 deployment target and diff whitespace checks pass. This change is not in TestFlight 10102; native acceptance requires a subsequent build. Apple reference: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight/
