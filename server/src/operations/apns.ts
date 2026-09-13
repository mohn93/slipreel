import { connect } from "node:http2";
import { importPKCS8, SignJWT } from "jose";
import { readFileSync } from "node:fs";
export type PushTarget = {
  apnsToken: string;
  environment: "development" | "production";
  channel: "direct" | "app-store";
};
export type PushResult = {
  accepted: boolean;
  reason?: string;
  invalidToken?: boolean;
};
export interface PushSender {
  send(target: PushTarget, messageId: string): Promise<PushResult>;
}
export function createApnsSender(): PushSender | undefined {
  const path = process.env.APNS_KEY_FILE,
    keyId = process.env.APNS_KEY_ID,
    team = process.env.APNS_TEAM_ID;
  if (!path || !keyId || !team) return undefined;
  const key = importPKCS8(readFileSync(path, "utf8"), "ES256");
  let cachedJwt = "",
    issuedAt = 0;
  return {
    async send(target, messageId) {
      if (!cachedJwt || Date.now() - issuedAt > 50 * 60 * 1000) {
        cachedJwt = await new SignJWT({})
          .setProtectedHeader({ alg: "ES256", kid: keyId })
          .setIssuer(team)
          .setIssuedAt()
          .sign(await key);
        issuedAt = Date.now();
      }
      const jwt = cachedJwt;
      return new Promise((resolve) => {
        const session = connect(
          target.environment === "development"
            ? "https://api.sandbox.push.apple.com"
            : "https://api.push.apple.com",
        );
        let done = false;
        const finish = (result: PushResult) => {
          if (done) return;
          done = true;
          clearTimeout(timer);
          session.destroy();
          resolve(result);
        };
        const timer = setTimeout(
          () => finish({ accepted: false, reason: "timeout" }),
          10000,
        );
        session.on("error", () =>
          finish({ accepted: false, reason: "connection_failed" }),
        );
        const request = session.request({
          ":method": "POST",
          ":path": `/3/device/${target.apnsToken}`,
          authorization: `bearer ${jwt}`,
          "apns-topic":
            target.channel === "app-store"
              ? "com.slipreel.store"
              : "com.slipreel.app",
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-expiration": "0",
          "apns-collapse-id": messageId,
        });
        let status = 0,
          body = "";
        request.on("response", (headers) => {
          status = Number(headers[":status"]);
        });
        request.on("data", (chunk) => {
          body += chunk.toString();
        });
        request.on("error", () =>
          finish({ accepted: false, reason: "request_failed" }),
        );
        request.on("end", () => {
          let reason: string | undefined;
          try {
            reason = JSON.parse(body).reason;
          } catch {}
          finish({
            accepted: status === 200,
            reason,
            invalidToken: status === 410 || reason === "BadDeviceToken",
          });
        });
        // Account content stays in the authenticated inbox, including after logout.
        request.end(
          JSON.stringify({
            aps: {
              alert: {
                title: "Slipreel",
                body: "You have a new message. Open Slipreel to read it.",
              },
            },
            messageId,
          }),
        );
      });
    },
  };
}
