import { SignJWT, jwtVerify, importPKCS8, importSPKI, type JWTPayload } from 'jose';
import type { TokenConfig } from './config.js';

export type EntitlementClaims = {
  sub: string;
  plan: 'subscription' | 'onetime' | 'free';
  export: boolean;
  status: 'active' | 'grace' | 'canceled' | 'none';
  updates_until: string | null;
  device_id: string;
  seat_limit: number;
};

export type TokenSigner = {
  publicKeyPem: string;
  mint(claims: EntitlementClaims): Promise<string>;
  verify(jwt: string): Promise<JWTPayload>;
};

export async function createTokenSigner(config: TokenConfig): Promise<TokenSigner> {
  const privateKey = await importPKCS8(config.privateKeyPem, 'EdDSA');
  const publicKey = await importSPKI(config.publicKeyPem, 'EdDSA');

  return {
    publicKeyPem: config.publicKeyPem,
    async mint(claims) {
      const { sub, ...rest } = claims;
      return new SignJWT(rest as unknown as JWTPayload)
        .setProtectedHeader({ alg: 'EdDSA' })
        .setIssuedAt()
        .setIssuer(config.issuer)
        .setSubject(sub)
        .setExpirationTime(`${config.ttlDays}d`)
        .sign(privateKey);
    },
    async verify(jwt) {
      const { payload } = await jwtVerify(jwt, publicKey, { issuer: config.issuer, algorithms: ['EdDSA'] });
      return payload;
    },
  };
}
