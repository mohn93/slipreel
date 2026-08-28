import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { requireSession } from '../auth/require_session.js';
import { registerDevice, refreshDevice, SEAT_LIMIT } from '../auth/devices.js';
import { resolveEffectiveEntitlement } from '../billing/effective_entitlement.js';

/** Coarse location (country) from Cloudflare's IP-geo header, or null. */
function locationFromRequest(req: FastifyRequest): string | null {
  const cc = req.headers['cf-ipcountry'];
  if (typeof cc !== 'string' || !cc || cc === 'XX' || cc === 'T1') return null;
  try {
    return new Intl.DisplayNames(['en'], { type: 'region' }).of(cc) ?? cc;
  } catch {
    return cc;
  }
}

// device_name is nullish: the web success/login pages post `device_name: null`
// when the app didn't supply one, so accept null as well as omitted.
const tokenBody = z.object({ fingerprint: z.string().min(1), device_name: z.string().nullish() });
const refreshReq = z.object({ refresh_token: z.string().min(1), device_id: z.string().min(1) });

async function mintFor(app: FastifyInstance, userId: string, deviceId: string): Promise<string> {
  const eff = await resolveEffectiveEntitlement(app.pool, userId);
  return app.tokenSigner.mint({
    sub: userId,
    plan: eff.plan,
    export: eff.export,
    status: eff.status,
    updates_until: eff.updatesUntil,
    device_id: deviceId,
    seat_limit: SEAT_LIMIT,
  });
}

export async function tokenRoutes(app: FastifyInstance): Promise<void> {
  app.post('/v1/token', { preHandler: requireSession(app) }, async (req, reply) => {
    const parsed = tokenBody.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: 'invalid request' });

    const reg = await registerDevice(
      app.pool, req.userId!, parsed.data.fingerprint, parsed.data.device_name ?? null, SEAT_LIMIT,
      locationFromRequest(req),
    );
    if (!reg.ok) return reply.code(409).send({ error: 'seat_limit', devices: reg.devices });

    const token = await mintFor(app, req.userId!, reg.deviceId);
    return reply.send({ token, refresh_token: reg.refreshToken, device_id: reg.deviceId });
  });

  app.post('/v1/token/refresh', async (req, reply) => {
    const parsed = refreshReq.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: 'invalid request' });

    const dev = await refreshDevice(
      app.pool, parsed.data.device_id, parsed.data.refresh_token, locationFromRequest(req),
    );
    if (!dev) return reply.code(401).send({ error: 'invalid refresh token' });

    const token = await mintFor(app, dev.userId, parsed.data.device_id);
    return reply.send({ token });
  });
}
