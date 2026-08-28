import { describe, it, expect, beforeAll } from 'vitest';
import { generateKeyPair, exportPKCS8, exportSPKI } from 'jose';
import { loadTokenConfig } from '../src/tokens/config.js';
import { createTokenSigner, type EntitlementClaims } from '../src/tokens/signer.js';

async function keyEnv() {
  const { publicKey, privateKey } = await generateKeyPair('EdDSA', { crv: 'Ed25519', extractable: true });
  const priv = Buffer.from(await exportPKCS8(privateKey)).toString('base64');
  const pub = Buffer.from(await exportSPKI(publicKey)).toString('base64');
  return {
    ENTITLEMENT_ED25519_PRIVATE_KEY: priv,
    ENTITLEMENT_ED25519_PUBLIC_KEY: pub,
    ENTITLEMENT_ISSUER: 'https://api.slipreel.test',
    ENTITLEMENT_TOKEN_TTL_DAYS: '14',
  };
}

const baseClaims: EntitlementClaims = {
  sub: 'usr_1', plan: 'subscription', export: true, status: 'active',
  updates_until: null, device_id: 'dev_1', seat_limit: 2,
};

describe('token signer', () => {
  let signer: Awaited<ReturnType<typeof createTokenSigner>>;
  let issuer: string;

  beforeAll(async () => {
    const env = await keyEnv();
    issuer = env.ENTITLEMENT_ISSUER;
    signer = await createTokenSigner(loadTokenConfig(env));
  });

  it('mints and verifies a token with the expected claims', async () => {
    const jwt = await signer.mint(baseClaims);
    const payload = await signer.verify(jwt);
    expect(payload.sub).toBe('usr_1');
    expect(payload.iss).toBe(issuer);
    expect(payload.plan).toBe('subscription');
    expect(payload.export).toBe(true);
    expect(payload.device_id).toBe('dev_1');
    expect(payload.seat_limit).toBe(2);
    // exp is ~14 days out.
    const days = ((payload.exp as number) - (payload.iat as number)) / 86400;
    expect(days).toBeCloseTo(14, 0);
  });

  it('rejects a tampered token', async () => {
    const jwt = await signer.mint(baseClaims);
    const tampered = jwt.slice(0, -3) + (jwt.endsWith('AAA') ? 'BBB' : 'AAA');
    await expect(signer.verify(tampered)).rejects.toBeDefined();
  });

  it('rejects a token signed by a different key', async () => {
    const other = await createTokenSigner(loadTokenConfig(await keyEnv()));
    const jwt = await other.mint(baseClaims);
    await expect(signer.verify(jwt)).rejects.toBeDefined();
  });

  it('loadTokenConfig throws when the private key is missing', () => {
    expect(() => loadTokenConfig({ ENTITLEMENT_ED25519_PUBLIC_KEY: 'x' })).toThrow(/ENTITLEMENT_ED25519_PRIVATE_KEY/);
  });
});
