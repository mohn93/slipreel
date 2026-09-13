# Mac App Store update policy

The Store edition uses Firebase Remote Config in project `slipreel-app`.
It never initializes Sparkle or reads the appcast. Store staging removes the
`auto_updater` dependency and all `SU*` Info.plist keys; the package verifier
rejects Sparkle frameworks and appcast metadata. Direct downloads keep their
existing license-aware Sparkle updater. Firebase is initialized only in Store
builds. Analytics collection and Firebase AppDelegate swizzling are disabled;
the existing native APNs delegate continues to handle notifications.

## Remote Config parameters

| Parameter | Meaning |
| --- | --- |
| `store_update_available` | Publish `true` only once the target release is available in every supported storefront. |
| `store_latest_build` | Target App Store CFBundleVersion, as an integer. |
| `store_latest_version` | Display version, for example `1.1.0`. |
| `store_minimum_build` | Builds below this must update. Zero leaves all updates optional. |

For example, latest `10110` and minimum `10108` offers an optional update to
10108/10109 and requires one for 10107. Build 10110 and newer TestFlight builds
show no prompt. These numbers are examples, not the deployed policy.

The checked-in template starts disabled (`false`, zero build numbers). The
initial deployed template is also disabled. Use the Firebase console to publish
later changes; do not redeploy the checked-in defaults over a live policy.
No private server credentials are included in the app. The Firebase client
identifiers are public, and Firestore remains inaccessible to client SDKs.

## Behavior

Checks run at startup, on resume, hourly, and through Remote Config's live
update stream. Normal fetches use a one-hour minimum interval; live publishes
bypass it. Valid activated values persist across launches, including offline
launches. A malformed policy or a first-launch network failure cannot create a
lockout. Turn `store_update_available` off to withdraw a policy; offline clients
need to reconnect to receive that change.

Optional prompts offer Later, remembered for that build until the next launch.
Required prompts have no dismiss action. Both open the fixed Slipreel App Store
listing, never a remotely supplied download URL. Users can still quit normally.
Prompts wait for recording/processing and existing exports to finish. Required
policy also prevents new recordings and exports through their shared entry
points, including shortcuts. Local files are never removed or migrated.

## Verification

Run the ordinary update tests for direct-download behavior, plus:

```
flutter test --dart-define=SLIPREEL_DISTRIBUTION=app-store test/update/store_update_gate_test.dart test/update/store_update_policy_test.dart test/update/store_update_isolation_test.dart
```

Before enabling a policy, verify the target release is public. TestFlight
processing alone does not make an App Store update available. Use an isolated QA Firebase project when live-testing prompts; do not enable a
future minimum globally for a test.
