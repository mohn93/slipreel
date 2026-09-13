import { describe, it, expect, beforeAll, afterAll, beforeEach } from "vitest";
import { initializeApp, deleteApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { InstallationRegistry } from "../src/operations/registry.js";
import { dispatchRequests } from "../src/operations/dispatch.js";
const enabled = !!process.env.FIRESTORE_EMULATOR_HOST;
describe.skipIf(!enabled)("notification identity and dispatch", () => {
  const app = initializeApp(
    { projectId: "demo-slipreel" },
    "notification-tests",
  );
  const db = getFirestore(app),
    registry = new InstallationRegistry(db);
  const registration = {
    name: "Test Mac",
    channel: "app-store" as const,
    permission: "authorized" as const,
    apnsToken: "a".repeat(64),
    environment: "development" as const,
    version: "test",
  };
  beforeAll(async () => {
    await db.listCollections();
  });
  beforeEach(async () => {
    for (const collection of await db.listCollections())
      await db.recursiveDelete(collection);
  });
  afterAll(async () => {
    await db.terminate();
    await deleteApp(app);
  });
  it("claims an anonymous installation without migrating another account", async () => {
    const install = await registry.create(registration);
    const anonymous = await registry.authenticate(install.id, install.secret);
    const linked = await registry.sync(
      install.id,
      install.secret,
      registration,
      "u1",
    );
    expect(linked.userId).toBe("u1");
    expect(
      (await db.doc(`anonymousClaims/${anonymous.anonymousId}`).get()).get(
        "userId",
      ),
    ).toBe("u1");
    expect(
      (await registry.authenticate(install.id, install.secret))
        .inheritedAnonymousId,
    ).toBe(anonymous.anonymousId);
    await registry.sync(install.id, install.secret, registration, null);
    const signedOut = await registry.authenticate(install.id, install.secret);
    expect(signedOut.anonymousId).not.toBe(anonymous.anonymousId);
    expect(signedOut.inheritedAnonymousId).toBeNull();
    await registry.sync(install.id, install.secret, registration, "u2");
    expect(
      (await registry.authenticate(install.id, install.secret))
        .inheritedAnonymousId,
    ).toBe(signedOut.anonymousId);
    expect(
      (await db.doc(`anonymousClaims/${anonymous.anonymousId}`).get()).get(
        "userId",
      ),
    ).toBe("u1");
  });
  it("rejects installation takeover and preserves permission decline", async () => {
    const install = await registry.create(registration);
    await expect(
      registry.sync(install.id, "wrong", registration, "attacker"),
    ).rejects.toThrow();
    await registry.sync(
      install.id,
      install.secret,
      { ...registration, permission: "denied", apnsToken: null },
      null,
    );
    expect(
      (await registry.authenticate(install.id, install.secret)).permission,
    ).toBe("denied");
  });
  it("targets all linked devices once and ignores unrelated accounts", async () => {
    const installs = await Promise.all([
      registry.create(registration),
      registry.create(registration),
      registry.create(registration),
    ]);
    for (let i = 0; i < installs.length; i++)
      await registry.sync(
        installs[i]!.id,
        installs[i]!.secret,
        registration,
        i < 2 ? "u1" : "u2",
      );
    const request = db.collection("notificationRequests").doc("request1");
    await request.set({
      status: "queued",
      target: { type: "user", id: "u1" },
      title: "Hello",
      body: "Test",
      expiresInDays: 1,
      push: true,
    });
    let sent = 0;
    const sender = {
      send: async () => {
        sent++;
        return { accepted: true };
      },
    };
    await Promise.all([
      dispatchRequests(db, sender),
      dispatchRequests(db, sender),
    ]);
    expect(sent).toBe(2);
    expect((await request.get()).get("inboxCount")).toBe(2);
    expect(
      (
        await db
          .collection("installations")
          .doc(installs[2]!.id)
          .collection("inbox")
          .get()
      ).empty,
    ).toBe(true);
    await dispatchRequests(db, sender);
    expect(sent).toBe(2);
  });
  it("sends a device-targeted inbox message without push permission", async () => {
    const install = await registry.create({
      ...registration,
      permission: "denied",
    });
    await db
      .doc("notificationRequests/device")
      .set({
        status: "queued",
        target: { type: "installation", id: install.id },
        title: "Hello",
        body: "Test",
        expiresInDays: 1,
        push: true,
      });
    let sent = 0;
    await dispatchRequests(db, {
      send: async () => {
        sent++;
        return { accepted: true };
      },
    });
    expect(sent).toBe(0);
    expect(
      (await db.doc(`installations/${install.id}/inbox/device`).get()).exists,
    ).toBe(true);
  });
  it("removes account data and detaches its installations on deletion", async () => {
    const install = await registry.create(registration);
    await registry.sync(install.id, install.secret, registration, "u1");
    await db
      .doc(`installations/${install.id}/inbox/private`)
      .set({ body: "private" });
    await registry.deleteUser("u1");
    const after = await registry.authenticate(install.id, install.secret);
    expect(after.userId).toBeNull();
    expect(after.apnsToken).toBeNull();
    expect(
      (await db.doc(`installations/${install.id}/inbox/private`).get()).exists,
    ).toBe(false);
    expect((await db.doc("users/u1").get()).exists).toBe(false);
  });
  it("unblocks without touching the stored account", async () => {
    await db.doc("users/u1").set({ name: "Test" });
    await db
      .doc("restrictions/u1")
      .set({ blocked: true, message: "Contact support" });
    expect((await registry.policy("u1")).blocked).toBe(true);
    await db.doc("restrictions/u1").update({ blocked: false });
    expect((await registry.policy("u1")).blocked).toBe(false);
    expect((await db.doc("users/u1").get()).get("name")).toBe("Test");
    await db
      .doc("controls/maintenance")
      .set({ enabled: true, message: "Back soon" });
    expect(await registry.policy(null)).toEqual({
      blocked: false,
      maintenance: true,
      message: "Back soon",
    });
  });
});
