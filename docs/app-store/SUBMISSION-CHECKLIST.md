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

- [ ] Merge icon changes after CI passes.
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
