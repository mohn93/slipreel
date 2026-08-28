import type { FastifyInstance } from 'fastify';

export async function entitlementPubkeyRoutes(app: FastifyInstance): Promise<void> {
  // The desktop app embeds this key to verify tokens offline; served here for
  // the build pipeline / ops convenience. Public key only — safe to expose.
  app.get('/v1/entitlement/public-key', async (_req, reply) => {
    return reply.header('content-type', 'text/plain; charset=utf-8').send(app.tokenSigner.publicKeyPem);
  });
}
