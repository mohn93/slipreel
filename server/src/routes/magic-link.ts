import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { createMagicLink, consumeMagicLink } from '../auth/magic_link.js';
import { createSession } from '../auth/sessions.js';
import { setSessionCookie } from '../auth/cookie.js';

const requestBody = z.object({ email: z.string().email() });
const verifyBody = z.object({ token: z.string().min(1) });

export async function magicLinkRoutes(app: FastifyInstance): Promise<void> {
  // Request a sign-in link. Always 200 (don't leak which emails exist).
  // Email delivery is stubbed: the link is logged, and the token is returned
  // ONLY in non-production so the flow is testable until a provider is wired.
  app.post('/v1/auth/magic-link', async (req, reply) => {
    const parsed = requestBody.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: 'invalid request' });

    const { rows } = await app.pool.query<{ id: string }>(
      'SELECT id FROM users WHERE email = $1',
      [parsed.data.email],
    );
    const user = rows[0];
    if (user) {
      const { token } = await createMagicLink(app.pool, user.id);
      const link = `${app.billing.siteUrl}/login?token=${token}`;
      if (app.email) {
        try {
          await app.email.sendMagicLink(parsed.data.email, link);
        } catch (err) {
          app.log.error({ err }, 'magic link email send failed');
        }
      } else {
        app.log.info({ email: parsed.data.email }, 'magic link issued (email delivery not configured)');
      }
      if (process.env.NODE_ENV !== 'production') {
        return reply.send({ sent: true, debug_token: token });
      }
    }
    return reply.send({ sent: true });
  });

  // Verify a link -> establish a session cookie.
  app.post('/v1/auth/magic-link/verify', async (req, reply) => {
    const parsed = verifyBody.safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: 'invalid request' });

    const consumed = await consumeMagicLink(app.pool, parsed.data.token);
    if (!consumed) return reply.code(401).send({ error: 'invalid or used link' });

    const { rows } = await app.pool.query<{ id: string; email: string }>(
      'SELECT id, email FROM users WHERE id = $1',
      [consumed.userId],
    );
    const { token, expiresAt } = await createSession(app.pool, consumed.userId);
    setSessionCookie(reply, token, expiresAt);
    return reply.send({ user: rows[0] ? { id: rows[0].id, email: rows[0].email } : { id: consumed.userId } });
  });
}
