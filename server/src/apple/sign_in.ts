import { createRemoteJWKSet, jwtVerify, SignJWT, importPKCS8 } from 'jose';
import { readFileSync } from 'node:fs';
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';

export interface AppleSignIn {
  verify(identityToken: string, code: string, nonce: string): Promise<{subject:string; email:string; encryptedRefreshToken:string}>;
  revoke(encryptedRefreshToken: string): Promise<void>;
}
export function createAppleSignIn(env = process.env): AppleSignIn | undefined {
  if (!env.APPLE_SIGN_IN_KEY_FILE) return undefined;
  const clientId = env.APPLE_STORE_BUNDLE_ID;
  const team = env.APPLE_TEAM_ID, keyId = env.APPLE_SIGN_IN_KEY_ID;
  const encryptionKey = Buffer.from(env.APPLE_TOKEN_ENCRYPTION_KEY ?? '', 'base64');
  if (!clientId || !team || !keyId || encryptionKey.length !== 32) throw new Error('Incomplete Sign in with Apple configuration');
  const pem = readFileSync(env.APPLE_SIGN_IN_KEY_FILE, 'utf8');
  const jwks = createRemoteJWKSet(new URL('https://appleid.apple.com/auth/keys'));
  async function secret() {
    return new SignJWT({}).setProtectedHeader({alg:'ES256',kid:keyId}).setIssuer(team!)
      .setSubject(clientId!).setAudience('https://appleid.apple.com').setIssuedAt()
      .setExpirationTime('5m').sign(await importPKCS8(pem,'ES256'));
  }
  function encrypt(value: string) {
    const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm',encryptionKey,iv);
    const ciphertext = Buffer.concat([cipher.update(value,'utf8'),cipher.final()]);
    return Buffer.concat([iv,cipher.getAuthTag(),ciphertext]).toString('base64');
  }
  function decrypt(value: string) {
    const data = Buffer.from(value,'base64');
    const cipher = createDecipheriv('aes-256-gcm',encryptionKey,data.subarray(0,12));
    cipher.setAuthTag(data.subarray(12,28));
    return Buffer.concat([cipher.update(data.subarray(28)),cipher.final()]).toString('utf8');
  }
  return {
    async verify(identityToken, code, nonce) {
      const {payload} = await jwtVerify(identityToken,jwks,{issuer:'https://appleid.apple.com',audience:clientId,algorithms:['RS256']});
      if (payload.nonce !== nonce || !payload.sub || typeof payload.email !== 'string' || ![true,'true'].includes(payload.email_verified as boolean|string)) throw new Error('Invalid Apple identity');
      const response = await fetch('https://appleid.apple.com/auth/token',{
        method:'POST',signal:AbortSignal.timeout(10000),
        headers:{'content-type':'application/x-www-form-urlencoded'},
        body:new URLSearchParams({client_id:clientId!,client_secret:await secret(),code,grant_type:'authorization_code'}),
      });
      if (!response.ok) throw new Error('Apple authorization failed');
      const tokens = await response.json() as {refresh_token?:string;id_token?:string};
      if (!tokens.refresh_token || !tokens.id_token) throw new Error('Missing Apple credentials');
      const confirmed = await jwtVerify(tokens.id_token,jwks,{issuer:'https://appleid.apple.com',audience:clientId,algorithms:['RS256']});
      if (confirmed.payload.sub !== payload.sub || confirmed.payload.nonce !== nonce) throw new Error('Apple identity mismatch');
      return {subject:payload.sub,email:payload.email,encryptedRefreshToken:encrypt(tokens.refresh_token) as string};
    },
    async revoke(encrypted) {
      const response = await fetch('https://appleid.apple.com/auth/revoke',{
        method:'POST',signal:AbortSignal.timeout(10000),headers:{'content-type':'application/x-www-form-urlencoded'},
        body:new URLSearchParams({client_id:clientId!,client_secret:await secret(),token:decrypt(encrypted),token_type_hint:'refresh_token'}),
      });
      if (!response.ok) throw new Error('Apple revocation failed');
    },
  };
}
