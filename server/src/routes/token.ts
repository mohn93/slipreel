import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { requireSession } from '../auth/require_session.js';
import { registerDevice, refreshDevice, SEAT_LIMIT } from '../auth/devices.js';
import { resolveEffectiveEntitlement } from '../billing/effective_entitlement.js';
import { intentStatus, fillIntent, claimHandoff, supportsHandoff, type HandoffResult } from '../auth/handoff.js';

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
// `state` is the app's sign-in nonce. When present, the result is also parked
// for the app to claim by polling, so the sign-in can be approved on any device.
const tokenBody = z.object({
  fingerprint: z.string().min(1).max(200),
  device_name: z.string().max(120).nullish(),
  state: z.string().min(16).max(200).nullish(),
});
const claimBody = z.object({ state: z.string().min(16).max(200), fingerprint: z.string().min(1).max(200) });
const refreshReq = z.object({ refresh_token: z.string().min(1), device_id: z.string().min(1) });

async function mintFor(app: FastifyInstance, userId: string, deviceId: string): Promise<string> {
  try { await app.appleSubscriptions?.refreshUser?.(userId); }
  catch { app.log.warn('Apple subscription refresh unavailable; using last verified paid-through date'); }
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

    const fingerprint = parsed.data.fingerprint;
    // Park the result for the Mac app only when this user verified a link or
    // checkout carrying this exact state for this exact device.
    const state = supportsHandoff(parsed.data.state) ? parsed.data.state : null;
    const intent = state ? await intentStatus(app.pool, app.handoffSecret, state, req.userId!, fingerprint) : 'none';
    // A second approval (another email clicked) must not rotate the refresh
    // token the app may already have claimed.
    if (intent === 'used') return reply.code(409).send({ error: 'already_approved' });
    const park = async (value: HandoffResult) => {
      if (intent !== 'open' || !state) return;
      try {
        await fillIntent(app.pool, app.handoffSecret, state, req.userId!, fingerprint, value);
      } catch (err) {
        // The deep link still works on a Mac; do not fail the browser.
        req.log.error({ err }, 'handoff park failed');
      }
    };

    const reg = await registerDevice(
      app.pool, req.userId!, fingerprint, parsed.data.device_name ?? null, SEAT_LIMIT,
      locationFromRequest(req),
    );
    if (!reg.ok) {
      await park({ error: 'seat_limit' });
      return reply.code(409).send({ error: 'seat_limit', devices: reg.devices });
    }

    const policy=await app.installations?.policy(req.userId!);
    if (policy?.blocked || policy?.maintenance) {
      await park({ error: 'activation_failed' });
      return reply.code(policy.blocked ? 403 : 503).send({error:policy.blocked?'account_restricted':'maintenance'});
    }
    const token = await mintFor(app, req.userId!, reg.deviceId);
    const result = { token, refresh_token: reg.refreshToken, device_id: reg.deviceId };
    if (intent === 'open') {
      const { rows } = await app.pool.query<{ email: string }>('SELECT email FROM users WHERE id = $1', [req.userId!]);
      await park({ ...result, email: rows[0]?.email ?? null });
    }
    return reply.send(result);
  });

  // The Mac app polls this after opening the browser sign-in. 204 = not yet
  // approved; 200 = credentials (single use); 409 = approval failed. Behind
  // Cloudflare every request shares a few edge IPs, so key the limit on the
  // client IP Cloudflare reports. The state carries 256 bits, so this limit is
  // about load, not guessing.
  app.post('/v1/auth/handoff/claim', { config: { rateLimit: {
    max: 120, timeWindow: '1 minute',
    keyGenerator: (req: FastifyRequest) => {
      const cf = req.headers['cf-connecting-ip'];
      return typeof cf === 'string' && cf ? cf : req.ip;
    },
  } } }, async (req, reply) => {
    const parsed = claimBody.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: 'invalid request' });
    const result = await claimHandoff(app.pool, app.handoffSecret, parsed.data.state, parsed.data.fingerprint);
    if (!result) return reply.code(204).send();
    if ('error' in result) return reply.code(409).send({ error: result.error });
    return reply.send(result);
  });

  app.post('/v1/token/refresh', async (req, reply) => {
    const parsed = refreshReq.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: 'invalid request' });

    const dev = await refreshDevice(
      app.pool, parsed.data.device_id, parsed.data.refresh_token, locationFromRequest(req),
    );
    if (!dev) return reply.code(401).send({ error: 'invalid refresh token' });

    const policy=await app.installations?.policy(dev.userId);
    if (policy?.blocked || policy?.maintenance) return reply.code(policy.blocked ? 403 : 503).send({error:policy.blocked?'account_restricted':'maintenance'});
    const token = await mintFor(app, dev.userId, parsed.data.device_id);
    return reply.send({ token });
  });
}
