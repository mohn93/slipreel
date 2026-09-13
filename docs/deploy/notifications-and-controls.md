# Notifications and account controls

Implementation in progress; not deployed to the API or a distributed Mac build yet.
Firebase project: `slipreel-app`, Firestore `(default)`, Frankfurt (`europe-west3`).
Existing Postgres accounts and payment entitlements remain authoritative.

## Firestore collections

- `installations/{uuid}`: one app installation per edition. `userId` is null before sign-in; a verified license device credential links it to a Postgres account. Stores name, channel, permission, APNs environment/token, lastSeenAt, anonymousId, and bindingVersion. `secretHash` authenticates registration updates. Never publish these documents or log push tokens.
- `users/{postgresUserId}`: last seen. Multiple installation documents may point at this account. Notification registrations do not consume license seats.
- `anonymousClaims/{anonymousId}`: account that claimed this anonymous identity. This never grants or merges purchases.
- `installations/{uuid}/inbox/{requestId}`: notification content bound to the installation's account generation; content from another signed-in account is hidden after switching.
- `notificationRequests/{uniqueId}`: trusted operator requests. Set `status: "queued"`, `target: {type: "user", id: "usr_..."}` or `{type: "installation", id: "UUID"}`, `title`, `body`, `expiresInDays` (1–30), and `push` (boolean).
- `notificationRequests/{id}/deliveries/{installationId}`: per-device result. `apns_accepted` means Apple accepted the request, not that the person received or read it.
- `controls/maintenance`: `{enabled: boolean, message: string}`.
- `restrictions/{postgresUserId}`: `{blocked: boolean, message: string}`. Set false to unblock. Payments are never canceled or erased by a restriction.

A server worker checks queued requests every 15 seconds. User-targeted requests resolve all currently linked installations; device-targeted requests address only the selected installation. Generic native push previews protect account content during logout/delivery races. The actual message is in the authenticated inbox.

An interrupted dispatch is marked `needs_attention`. A process crash can leave `processing`; inspect its per-device deliveries before retrying. Automatic retries are deliberately absent because uncertain delivery can duplicate a notification. Use a new request ID only after checking the prior outcome.

## Programmatic operation

Use Firebase Admin with operator IAM credentials. Mobile/web Firestore reads and writes are denied by `firestore.rules`. API service credentials stay on the server. No dashboard and no client-side admin secret.

```js
import { initializeApp, applicationDefault } from 'firebase-admin/app';
import { getFirestore } from 'firebase-admin/firestore';
initializeApp({ credential: applicationDefault(), projectId: 'slipreel-app' });
const db = getFirestore();
// Inspect exact targets before creating a send request.
const devices = await db.collection('installations').where('userId', '==', 'usr_...').get();
console.log(devices.docs.map(d => ({ id: d.id, name: d.get('name'), permission: d.get('permission') })));
await db.collection('notificationRequests').add({
  status: 'queued', target: { type: 'user', id: 'usr_...' },
  title: 'Service update', body: 'Your message here.', expiresInDays: 7, push: true,
});
```

Maintenance and restrictions preserve recording/editing and running exports. New paid exports and license activation/refresh check the policy. Offline cached licenses remain subject to the existing offline licensing window; remote controls cannot instantly reach a disconnected Mac.

## Required release verification

- Configure server Application Default Credentials with Firestore access.
- Enable Push Notifications on both Apple bundle IDs, refresh provisioning, and add the signed APS environment entitlement.
- Configure a server APNs key; never reuse the App Store Connect upload key as an APNs key.
- Test anonymous register → permission decline/grant → token rotation → sign-in → two Macs → sign-out → account switch; verify message isolation.
- Test foreground inbox and a real background/closed-app alert on the signed Store and direct editions.
- Test maintenance/restriction while recording/exporting, unblock, offline recovery, and revoked device credentials.
- Account deletion cleanup is implemented and emulator-tested; configure retention and review privacy disclosures before release.

## Verified in development (2026-09-13)

- Firestore created and deny-all client rules deployed; maintenance initialized off.
- Both Apple bundle IDs registered with Push Notifications selected. Store capability change invalidated its old distribution profiles; regenerate before the next upload.
- Native Store development build succeeded with the development APS entitlement, application identifier UD7WB2694V.com.slipreel.store, and team UD7WB2694V verified in the signed bundle.
- Six Firestore emulator tests passed; 22 Flutter notification/licensing/settings regression tests passed. These do not establish live push delivery.
- Firebase API service account slipreel-operations@slipreel-app.iam.gserviceaccount.com has roles/datastore.user; its key remains outside the repo. The production API has not been changed.

For direct release signing, set SLIPREEL_DIRECT_PUSH_PROFILE to a Developer ID profile for com.slipreel.app with production APNs. The release script embeds the profile and signs the final app with its required entitlements before normal verification and notarization. This path still needs a real signed direct-build check.
