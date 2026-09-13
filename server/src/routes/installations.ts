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
      if (data.device && !device)
        return reply.code(401).send({ error: "invalid_device" });
      try {
        const binding = await registry.sync(
          data.id,
          data.secret,
          data.registration,
          device?.userId ?? null,
          data.device?.id ?? null,
        );
        if (device) {
          const user = await app.pool.query(
            "SELECT email FROM users WHERE id=$1",
            [device.userId],
          );
          if (user.rows[0])
            await registry.db
              .collection("users")
              .doc(device.userId)
              .set({ email: user.rows[0].email }, { merge: true });
        }
        return { ...binding, policy: await registry.policy(binding.userId) };
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
          const valid = await app.pool.query(
            "SELECT 1 FROM devices WHERE id=$1 AND user_id=$2",
            [binding.licenseDeviceId, binding.userId],
          );
          if (!valid.rowCount)
            return reply.code(401).send({ error: "invalid_device" });
        }
        const messages = await registry.db
          .collection("installations")
          .doc(body.data.id)
          .collection("inbox")
          .orderBy("createdAt", "desc")
          .limit(100)
          .get();
        return {
          policy: await registry.policy(binding.userId),
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
