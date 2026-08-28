import type { FastifyInstance } from 'fastify';

export async function healthRoutes(app: FastifyInstance): Promise<void> {
  app.get('/health', async (_req, reply) => {
    try {
      await app.pool.query('SELECT 1');
      return { status: 'ok', db: 'up' };
    } catch (err) {
      app.log.error({ err }, 'health check DB query failed');
      return reply.code(503).send({ status: 'degraded', db: 'down' });
    }
  });
}
