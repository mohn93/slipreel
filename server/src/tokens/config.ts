import { z } from 'zod';

const schema = z.object({
  ENTITLEMENT_ED25519_PRIVATE_KEY: z.string().min(1, 'ENTITLEMENT_ED25519_PRIVATE_KEY is required'),
  ENTITLEMENT_ED25519_PUBLIC_KEY: z.string().min(1, 'ENTITLEMENT_ED25519_PUBLIC_KEY is required'),
  ENTITLEMENT_ISSUER: z.string().url().default('https://api.slipreel.app'),
  ENTITLEMENT_TOKEN_TTL_DAYS: z.coerce.number().int().positive().default(14),
});

export type TokenConfig = {
  privateKeyPem: string;
  publicKeyPem: string;
  issuer: string;
  ttlDays: number;
};

const fromB64 = (b64: string): string => Buffer.from(b64, 'base64').toString('utf8');

export function loadTokenConfig(env: NodeJS.ProcessEnv = process.env): TokenConfig {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const issues = parsed.error.issues
      .map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`)
      .join('; ');
    throw new Error(`Invalid entitlement token configuration: ${issues}`);
  }
  const e = parsed.data;
  return {
    privateKeyPem: fromB64(e.ENTITLEMENT_ED25519_PRIVATE_KEY),
    publicKeyPem: fromB64(e.ENTITLEMENT_ED25519_PUBLIC_KEY),
    issuer: e.ENTITLEMENT_ISSUER,
    ttlDays: e.ENTITLEMENT_TOKEN_TTL_DAYS,
  };
}
