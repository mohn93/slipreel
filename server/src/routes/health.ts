import type { FastifyInstance } from 'fastify';

export async function healthRoutes(app: FastifyInstance): Promise<void> {
  app.get('/ready', async (_req, reply) => {
    const configured = ['stripe', 'billing', 'tokenSigner', 'email'].every(name => app.hasDecorator(name));
    try { await app.pool.query('SELECT 1'); } catch { return reply.code(503).send({status: 'not_ready'}); }
    const legacy = await app.pool.query('SELECT 1 FROM purchase_grants WHERE legacy_until IS NOT NULL LIMIT 1');
    if (legacy.rowCount) return reply.code(503).send({status: 'not_ready', reason: 'legacy_purchase_reconciliation_required'});
    return configured ? {status: 'ready'} : reply.code(503).send({status: 'not_ready'});
  });
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
