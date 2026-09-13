import type { AccountLink } from "./link.js";
import { FieldValue, type Firestore } from "firebase-admin/firestore";
import { randomUUID } from "node:crypto";
import { newSecretToken, hashToken } from "../auth/secret_token.js";

export type Registration = {
  name: string;
  channel: "direct" | "app-store";
  permission: "notDetermined" | "denied" | "authorized" | "provisional";
  apnsToken: string | null;
  environment: "development" | "production";
  version: string;
};
export class InstallationAuthError extends Error {}
export class InstallationRegistry {
  constructor(readonly db: Firestore) {}
  async create(input: Registration) {
    const id = randomUUID(),
      credential = newSecretToken();
    await this.db
      .collection("installations")
      .doc(id)
      .create({
        ...input,
        secretHash: credential.hash,
        userId: null,
        anonymousId: randomUUID(),
        bindingVersion: 0,
        createdAt: FieldValue.serverTimestamp(),
        lastSeenAt: FieldValue.serverTimestamp(),
      });
    return { id, secret: credential.token };
  }
  async sync(
    id: string,
    secret: string,
    input: Registration,
    userId: string | null,
    licenseDeviceId: string | null = null,
    accountLink: AccountLink | null = null,
  ) {
    const ref = this.db.collection("installations").doc(id);
    return this.db.runTransaction(async (tx) => {
      const snapshot = await tx.get(ref),
        data = snapshot.data();
      if (!data || data.secretHash !== hashToken(secret))
        throw new InstallationAuthError();
      const changed = data.userId !== userId;
      // Claim the anonymous identity once, to the authenticated account. Never
      // carry account A's inbox through logout or an account B sign-in.
      if (!data.userId && userId) {
        tx.set(this.db.collection("anonymousClaims").doc(data.anonymousId), {
          userId,
          claimedAt: FieldValue.serverTimestamp(),
        });
      }
      const anonymousId =
        data.userId && changed ? randomUUID() : data.anonymousId;
      const bindingVersion = data.bindingVersion + (changed ? 1 : 0);
      const inheritedAnonymousId =
        !data.userId && userId
          ? data.anonymousId
          : changed
            ? null
            : (data.inheritedAnonymousId ?? null);
      tx.update(ref, {
        ...input,
        userId,
        licenseDeviceId,
        accountLink,
        anonymousId,
        bindingVersion,
        inheritedAnonymousId,
        lastSeenAt: FieldValue.serverTimestamp(),
      });
      if (userId)
        tx.set(
          this.db.collection("users").doc(userId),
          { lastSeenAt: FieldValue.serverTimestamp() },
          { merge: true },
        );
      return { userId, anonymousId, bindingVersion };
    });
  }
  async authenticate(id: string, secret: string) {
    const data = (
      await this.db.collection("installations").doc(id).get()
    ).data();
    if (!data || data.secretHash !== hashToken(secret))
      throw new InstallationAuthError();
    return data;
  }
  async deleteUser(userId: string) {
    const devices = await this.db
      .collection("installations")
      .where("userId", "==", userId)
      .get();
    for (const device of devices.docs) {
      await this.db.runTransaction(async (tx) => {
        const current = await tx.get(device.ref);
        if (current.get("userId") === userId)
          tx.update(device.ref, {
            userId: null,
            accountLink: null,
            anonymousId: randomUUID(),
            inheritedAnonymousId: null,
            apnsToken: null,
            bindingVersion: current.get("bindingVersion") + 1,
          });
      });
      await this.db.recursiveDelete(device.ref.collection("inbox"));
    }
    const claims = await this.db
      .collection("anonymousClaims")
      .where("userId", "==", userId)
      .get();
    for (const claim of claims.docs) await claim.ref.delete();
    await this.db.collection("users").doc(userId).delete();
    await this.db.collection("restrictions").doc(userId).delete();
  }
  async policy(userId: string | null) {
    const [maintenance, restriction] = await Promise.all([
      this.db.doc("controls/maintenance").get(),
      userId
        ? this.db.collection("restrictions").doc(userId).get()
        : Promise.resolve(null),
    ]);
    const blocked = restriction?.get("blocked") === true,
      active = maintenance.get("enabled") === true;
    return {
      blocked,
      maintenance: active,
      message: blocked
        ? (restriction?.get("message") ?? "Contact support about your account.")
        : active
          ? (maintenance.get("message") ??
            "Online services are temporarily unavailable.")
          : null,
    };
  }
}
