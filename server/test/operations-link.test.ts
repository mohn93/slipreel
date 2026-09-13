import { it, expect, vi } from "vitest";
import type pg from "pg";
import { validAccountLink } from "../src/operations/link.js";
it("validates the native session rather than requiring an activated license", async () => {
  const query = vi.fn().mockResolvedValue({ rowCount: 1 });
  expect(
    await validAccountLink({ query } as unknown as pg.Pool, {
      userId: "u1",
      licenseDeviceId: null,
      credentialHash: "session-hash",
      kind: "session",
    }),
  ).toBe(true);
  expect(query.mock.calls[0]![0]).toContain("expires_at>now()");
  expect(query.mock.calls[0]![1]).toEqual(["u1", "session-hash"]);
});
it("rejects a revoked or expired identity", async () => {
  const query = vi.fn().mockResolvedValue({ rowCount: 0 });
  expect(
    await validAccountLink({ query } as unknown as pg.Pool, {
      userId: "u1",
      licenseDeviceId: "d1",
      credentialHash: "device-hash",
      kind: "device",
    }),
  ).toBe(false);
  expect(query.mock.calls[0]![1]).toEqual(["d1", "u1", "device-hash"]);
  expect(query.mock.calls[0]![0]).toContain("store_device_credentials");
});
