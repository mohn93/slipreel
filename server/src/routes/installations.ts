import { resolveSession } from "../auth/sessions.js";
import { hashToken } from "../auth/secret_token.js";
import { validAccountLink, type AccountLink } from "../operations/link.js";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { refreshDevice } from "../auth/devices.js";
import {
  InstallationAuthError,
  type InstallationRegistry,
} from "../operations/registry.js";
const registration = z
  .object({
    name: z.string().trim().max(120),
    channel: z.enum(["direct", "app-store"]),
    permission: z.enum([
      "notDetermined",
      "denied",
      "authorized",
      "provisional",
    ]),
    apnsToken: z
      .string()
      .regex(/^[a-f0-9]{32,512}$/)
      .nullable(),
    environment: z.enum(["development", "production"]),
    version: z.string().max(40),
  })
  .strict();
const identity = z.object({
  id: z.string().uuid(),
  secret: z.string().min(40).max(100),
});
export async function installationRoutes(
  app: FastifyInstance,
  registry: InstallationRegistry,
) {
  app.post(
    "/v1/installations",
    { config: { rateLimit: { max: 5, timeWindow: "1 hour" } } },
    async (req, reply) => {
      const data = registration.safeParse(req.body);
      if (!data.success)
        return reply.code(400).send({ error: "invalid_request" });
      return registry.create(data.data);
    },
  );
  app.post(
    "/v1/installations/sync",
    { config: { rateLimit: { max: 30, timeWindow: "1 minute" } } },
    async (req, reply) => {
      const body = identity
        .extend({
          registration,
          nativeSession: z
            .string()
            .regex(/^[A-Za-z0-9_-]{40,100}$/)
            .nullable()
            .optional(),
          device: z
            .object({
              id: z.string().max(200),
              refreshToken: z.string().max(200),
            })
            .nullable(),
        })
        .strict()
        .safeParse(req.body);
      if (!body.success)
        return reply.code(400).send({ error: "invalid_request" });
      const data = body.data;
      const device = data.device
        ? await refreshDevice(
            app.pool,
            data.device.id,
            data.device.refreshToken,
          )
        : null;
      const session = data.nativeSession
        ? await resolveSession(app.pool, data.nativeSession)
        : null;
      if (data.nativeSession && !session)
        return reply.code(401).send({ error: "invalid_session" });
      if (data.device && !device && !session)
        return reply.code(401).send({ error: "invalid_device" });
      if (device && session && device.userId !== session.userId)
        return reply.code(409).send({ error: "account_mismatch" });
      const userId = session?.userId ?? device?.userId ?? null;
      const accountLink: AccountLink | null = session
        ? {
            userId: session.userId,
            licenseDeviceId: null,
            credentialHash: hashToken(data.nativeSession!),
            kind: "session",
          }
        : device
          ? {
              userId: device.userId,
              licenseDeviceId: data.device!.id,
              credentialHash: hashToken(data.device!.refreshToken),
              kind: "device",
            }
          : null;
      try {
        const binding = await registry.sync(
          data.id,
          data.secret,
          data.registration,
          userId,
          data.device?.id ?? null,
          accountLink,
        );
        if (userId) {
          const user = await app.pool.query(
            "SELECT email FROM users WHERE id=$1",
            [userId],
          );
          if (user.rows[0])
            await registry.db
              .collection("users")
              .doc(userId)
              .set({ email: user.rows[0].email }, { merge: true });
        }
        return { ...binding, policy: await registry.policy(binding.userId ?? binding.restrictionSubject) };
      } catch (err) {
        if (err instanceof InstallationAuthError)
          return reply.code(401).send({ error: "invalid_installation" });
        throw err;
      }
    },
  );
  app.post(
    "/v1/installations/inbox",
    { config: { rateLimit: { max: 30, timeWindow: "1 minute" } } },
    async (req, reply) => {
      const body = identity.safeParse(req.body);
      if (!body.success)
        return reply.code(400).send({ error: "invalid_request" });
      try {
        const binding = await registry.authenticate(
          body.data.id,
          body.data.secret,
        );
        if (binding.userId) {
          if (
            !binding.accountLink ||
            !(await validAccountLink(app.pool, binding.accountLink))
          )
            return reply.code(401).send({ error: "invalid_account_link" });
        }
        const messages = await registry.db
          .collection("installations")
          .doc(body.data.id)
          .collection("inbox")
          .orderBy("createdAt", "desc")
          .limit(100)
          .get();
        return {
          policy: await registry.policy(binding.userId ?? binding.restrictionSubject),
          messages: messages.docs
            .filter((doc) => {
              const m = doc.data();
              return (
                (m.bindingVersion === binding.bindingVersion ||
                  (binding.userId &&
                    binding.inheritedAnonymousId &&
                    m.anonymousId === binding.inheritedAnonymousId)) &&
                m.expiresAt.toMillis() > Date.now()
              );
            })
            .map((doc) => ({ id: doc.id, ...doc.data() })),
        };
      } catch (err) {
        if (err instanceof InstallationAuthError)
          return reply.code(401).send({ error: "invalid_installation" });
        throw err;
      }
    },
  );
}
