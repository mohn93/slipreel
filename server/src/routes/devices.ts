import type { FastifyInstance } from 'fastify';
import { requireSession } from '../auth/require_session.js';

export async function deviceRoutes(app: FastifyInstance): Promise<void> {
  app.get('/v1/devices', { preHandler: requireSession(app) }, async (req, reply) => {
    const { rows } = await app.pool.query<{ id: string; name: string | null; location: string | null; last_seen_at: Date | null; created_at: Date }>(
      'SELECT id, name, location, last_seen_at, created_at FROM devices WHERE user_id = $1 ORDER BY created_at',
      [req.userId!],
    );
    return reply.send({
      devices: rows.map((r) => ({
        id: r.id, name: r.name, location: r.location,
        last_seen_at: r.last_seen_at?.toISOString() ?? null,
        created_at: r.created_at.toISOString(),
      })),
    });
  });

  app.delete('/v1/devices/:id', { preHandler: requireSession(app) }, async (req, reply) => {
    const id = (req.params as { id: string }).id;
    const { rowCount } = await app.pool.query(
      'DELETE FROM devices WHERE id = $1 AND user_id = $2',
      [id, req.userId!],
    );
    if (rowCount === 0) return reply.code(404).send({ error: 'not found' });
    return reply.send({ ok: true });
  });
}
