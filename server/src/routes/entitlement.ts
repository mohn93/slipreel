import type { FastifyInstance } from 'fastify';
import { requireSession } from '../auth/require_session.js';
import { resolveEffectiveEntitlement } from '../billing/effective_entitlement.js';

export async function entitlementRoutes(app: FastifyInstance): Promise<void> {
  // Session-scoped: the logged-in user's effective entitlement, so the web
  // account page can show what they actually have (plan, status, updates
  // ceiling). Billing changes still go through the Stripe portal.
  app.get('/v1/entitlement', { preHandler: requireSession(app) }, async (req, reply) => {
    const entitlement = await resolveEffectiveEntitlement(app.pool, req.userId!);
    const apple = await app.pool.query(`SELECT 1 FROM apple_subscriptions WHERE user_id=$1
      AND environment='Production' AND revoked_at IS NULL AND expires_at>now() LIMIT 1`,[req.userId!]);
    return reply.send(apple.rows.length ? {...entitlement,billingProvider:'apple'} : entitlement);
  });
}
