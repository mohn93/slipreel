import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { createSession, deleteSession } from '../auth/sessions.js';
import { setSessionCookie, clearSessionCookie, SESSION_COOKIE } from '../auth/cookie.js';
import { requireSession } from '../auth/require_session.js';

const fromCheckout = z.object({ checkout_session_id: z.string().min(1) });

export async function authRoutes(app: FastifyInstance): Promise<void> {
  // Reuse a completed Stripe Checkout session to log the buyer in (no password).
  app.post('/v1/auth/session-from-checkout', async (req, reply) => {
    const parsed = fromCheckout.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: 'invalid request' });

    const cs = await app.stripe.checkout.sessions.retrieve(parsed.data.checkout_session_id);
    if (cs.status !== 'complete') return reply.code(400).send({ error: 'checkout not complete' });

    // Freshness window: a checkout_session_id can leak via the success URL, browser
    // history, or logs, and would otherwise be replayable to log in as the buyer
    // indefinitely. Reject stale sessions. Binding this id to a `state` nonce is
    // deferred to the web-pages phase, where the redirect flow that carries it is built.
    const MAX_AGE_S = 30 * 60;
    if (typeof cs.created === 'number' && Date.now() / 1000 - cs.created > MAX_AGE_S) {
      return reply.code(400).send({ error: 'checkout session expired' });
    }

    // Single-use: claim the session id so a leaked checkout_session_id cannot be
    // replayed to log in a second time.
    const claim = await app.pool.query(
      'INSERT INTO consumed_checkout_sessions (session_id) VALUES ($1) ON CONFLICT DO NOTHING RETURNING session_id',
      [parsed.data.checkout_session_id],
    );
    if (claim.rowCount === 0) {
      return reply.code(409).send({ error: 'checkout session already used' });
    }

    const customer = typeof cs.customer === 'string' ? cs.customer : cs.customer?.id;
    if (!customer) return reply.code(400).send({ error: 'no customer on session' });

    const { rows } = await app.pool.query<{ id: string; email: string }>(
      'SELECT id, email FROM users WHERE stripe_customer_id = $1',
      [customer],
    );
    const user = rows[0];
    if (!user) return reply.code(404).send({ error: 'no user for customer' });

    const { token, expiresAt } = await createSession(app.pool, user.id);
    setSessionCookie(reply, token, expiresAt);
    const md = (cs.metadata ?? {}) as Record<string, string | undefined>;
    return reply.send({
      user: { id: user.id, email: user.email },
      device: md.device ?? null,
      device_name: md.device_name ?? null,
      state: md.state ?? null,
    });
  });

  app.post('/v1/auth/logout', { preHandler: requireSession(app) }, async (req, reply) => {
    const token = req.cookies?.[SESSION_COOKIE];
    if (token) await deleteSession(app.pool, token);
    clearSessionCookie(reply);
    return reply.send({ ok: true });
  });
}
