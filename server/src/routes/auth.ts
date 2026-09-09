import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { deleteSession } from '../auth/sessions.js';
import { clearSessionCookie, SESSION_COOKIE } from '../auth/cookie.js';
import { requireSession } from '../auth/require_session.js';
import { resolveEffectiveEntitlement } from '../billing/effective_entitlement.js';
import { reconcileCheckout } from '../billing/entitlements.js';

const fromCheckout = z.object({ checkout_session_id: z.string().min(1).max(200) });

export async function authRoutes(app: FastifyInstance): Promise<void> {
  // A checkout reference is never an authentication credential. The buyer must
  // already have proved email ownership, even when returning on another browser.
  app.post('/v1/auth/session-from-checkout', { preHandler: requireSession(app), config: { rateLimit: { max: 60, timeWindow: '1 minute' } } }, async (req, reply) => {
    const parsed = fromCheckout.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: 'invalid request' });
    const cs = await app.stripe.checkout.sessions.retrieve(parsed.data.checkout_session_id);
    const customer = typeof cs.customer === 'string' ? cs.customer : cs.customer?.id;
    const { rows } = await app.pool.query<{ id: string; email: string; stripe_customer_id: string | null }>(
      'SELECT id, email, stripe_customer_id FROM users WHERE id = $1', [req.userId!],
    );
    const user = rows[0];
    if (!user || !customer || user.stripe_customer_id !== customer) return reply.code(403).send({ error: 'checkout ownership mismatch' });
    if (cs.payment_status !== 'paid') {
      const failed = await app.pool.query('SELECT 1 FROM failed_checkouts WHERE session_id = $1', [cs.id]);
      if (failed.rowCount) return reply.code(402).send({error:'payment_failed'});
    }
    if (cs.status === 'expired') return reply.code(410).send({error:'checkout_expired'});
    if (cs.status !== 'complete') return reply.code(202).send({ error: 'payment_pending' });
    if (!(await reconcileCheckout(app.pool, app.stripe, app.billing, cs))) {
      return cs.payment_status === 'paid' ? reply.code(409).send({error:'payment_not_entitled'}) : reply.code(202).send({error:'payment_pending'});
    }
    if (!(await resolveEffectiveEntitlement(app.pool, user.id)).export) return reply.code(409).send({error:'payment_not_entitled'});
    const md = cs.metadata ?? {};
    return reply.send({user: {id: user.id, email: user.email}, device: md.device ?? null, device_name: md.device_name ?? null, state: md.state ?? null});
  });

  app.post('/v1/auth/logout', { preHandler: requireSession(app) }, async (req, reply) => {
    const token = req.cookies?.[SESSION_COOKIE];
    if (token) await deleteSession(app.pool, token);
    clearSessionCookie(reply);
    return reply.send({ ok: true });
  });
}
