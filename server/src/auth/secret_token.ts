import { randomBytes, createHash } from 'node:crypto';

export function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

/** A high-entropy opaque token plus its sha256 hash (only the hash is stored). */
export function newSecretToken(): { token: string; hash: string } {
  const token = randomBytes(32).toString('base64url');
  return { token, hash: hashToken(token) };
}
