import type { FastifyInstance, preHandlerHookHandler } from 'fastify';
import { resolveSession } from './sessions.js';
import { SESSION_COOKIE } from './cookie.js';

declare module 'fastify' {
  interface FastifyRequest {
    userId?: string;
  }
}

/** preHandler that requires a valid session cookie; sets req.userId or 401s. */
export function requireSession(app: FastifyInstance): preHandlerHookHandler {
  return async (req, reply) => {
    const token = req.cookies?.[SESSION_COOKIE];
    if (!token) return reply.code(401).send({ error: 'not authenticated' });
    const session = await resolveSession(app.pool, token);
    if (!session) return reply.code(401).send({ error: 'not authenticated' });
    req.userId = session.userId;
  };
}
