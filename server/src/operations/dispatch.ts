import type { AccountLink } from "./link.js";
import {
  FieldValue,
  Timestamp,
  type Firestore,
} from "firebase-admin/firestore";
import { z } from "zod";
import type { PushSender } from "./apns.js";
const requestSchema = z.object({
  target: z.discriminatedUnion("type", [
    z.object({ type: z.literal("user"), id: z.string().min(1).max(200) }),
    z.object({ type: z.literal("installation"), id: z.string().uuid() }),
  ]),
  title: z.string().trim().min(1).max(120),
  body: z.string().trim().min(1).max(1000),
  expiresInDays: z.number().int().min(1).max(30),
  push: z.boolean(),
});
/** Each request is claimed once. An uncertain push is never automatically resent. */
export async function dispatchRequests(
  db: Firestore,
  sender?: PushSender,
  isLinked?: (link: AccountLink) => Promise<boolean>,
) {
  const pending = await db
    .collection("notificationRequests")
    .where("status", "==", "queued")
    .limit(20)
    .get();
  for (const request of pending.docs) {
    const parsed = await db.runTransaction(async (tx) => {
      const fresh = await tx.get(request.ref);
      if (fresh.get("status") !== "queued") return null;
      const validated = requestSchema.safeParse(fresh.data());
      tx.update(request.ref, {
        status: validated.success ? "processing" : "invalid",
        startedAt: FieldValue.serverTimestamp(),
      });
      return validated;
    });
    if (!parsed?.success) continue;
    try {
      const data = parsed.data;
      const devices =
        data.target.type === "installation"
          ? [await db.collection("installations").doc(data.target.id).get()]
          : (
              await db
                .collection("installations")
                .where("userId", "==", data.target.id)
                .get()
            ).docs;
      let inboxCount = 0,
        pushAccepted = 0;
      for (const device of devices) {
        const binding = await db.runTransaction(async (tx) => {
          const current = await tx.get(device.ref),
            registration = current.data();
          if (
            !registration ||
            (data.target.type === "user" &&
              registration.userId !== data.target.id)
          )
            return null;
          tx.create(device.ref.collection("inbox").doc(request.id), {
            title: data.title,
            body: data.body,
            bindingVersion: registration.bindingVersion,
            anonymousId: registration.userId ? null : registration.anonymousId,
            createdAt: Timestamp.now(),
            expiresAt: Timestamp.fromMillis(
              Date.now() + data.expiresInDays * 86400000,
            ),
            readAt: null,
          });
          return registration;
        });
        if (!binding) continue;
        if (
          binding.userId &&
          isLinked &&
          (!binding.accountLink || !(await isLinked(binding.accountLink)))
        )
          continue;
        inboxCount++;
        let outcome = "inbox_only";
        if (
          data.push &&
          binding.permission === "authorized" &&
          binding.apnsToken
        ) {
          if (!sender) outcome = "push_not_configured";
          else {
            // Recheck binding before push; generic payload protects account privacy
            // even if logout races with Apple's asynchronous delivery.
            const current = await device.ref.get();
            if (current.get("bindingVersion") !== binding.bindingVersion)
              outcome = "account_changed";
            else {
              const result = await sender.send(
                {
                  apnsToken: binding.apnsToken,
                  environment: binding.environment,
                  channel: binding.channel,
                },
                request.id,
              );
              outcome = result.accepted
                ? "apns_accepted"
                : (result.reason ?? "push_failed");
              if (result.accepted) pushAccepted++;
              if (result.invalidToken)
                await db.runTransaction(async (tx) => {
                  const now = await tx.get(device.ref);
                  if (now.get("apnsToken") === binding.apnsToken)
                    tx.update(device.ref, { apnsToken: null });
                });
            }
          }
        }
        await request.ref
          .collection("deliveries")
          .doc(device.id)
          .set({ outcome, updatedAt: FieldValue.serverTimestamp() });
      }
      await request.ref.update({
        status: "completed",
        inboxCount,
        pushAccepted,
        completedAt: FieldValue.serverTimestamp(),
      });
    } catch {
      await request.ref.update({
        status: "needs_attention",
        error: "Dispatch interrupted; inspect deliveries before retrying.",
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
  }
}
