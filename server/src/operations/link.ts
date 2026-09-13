import type pg from "pg";
export type AccountLink = {
  userId: string;
  licenseDeviceId: string | null;
  credentialHash: string;
  kind: "device" | "session";
};
export async function validAccountLink(
  pool: pg.Pool,
  link: AccountLink,
): Promise<boolean> {
  if (link.kind === "session")
    return (
      (
        await pool.query(
          "SELECT 1 FROM sessions WHERE user_id=$1 AND token_hash=$2 AND expires_at>now()",
          [link.userId, link.credentialHash],
        )
      ).rowCount === 1
    );
  return (
    (
      await pool.query(
        `SELECT 1 FROM devices d WHERE d.id=$1 AND d.user_id=$2 AND
    (d.refresh_token_hash=$3 OR EXISTS(SELECT 1 FROM store_device_credentials s WHERE s.device_id=d.id AND s.refresh_token_hash=$3))`,
        [link.licenseDeviceId, link.userId, link.credentialHash],
      )
    ).rowCount === 1
  );
}
