/**
 * Generate a dedicated Ed25519 keypair for entitlement tokens (NOT the Sparkle
 * update key). Prints base64-encoded PEM lines to paste into server/.env.
 *   npm run gen:entitlement-keys
 */
import { generateKeyPair, exportPKCS8, exportSPKI } from 'jose';

const { publicKey, privateKey } = await generateKeyPair('EdDSA', { crv: 'Ed25519', extractable: true });
const priv = Buffer.from(await exportPKCS8(privateKey)).toString('base64');
const pub = Buffer.from(await exportSPKI(publicKey)).toString('base64');

console.log('# Entitlement token keypair (test/dev). Keep the private key secret.');
console.log(`ENTITLEMENT_ED25519_PRIVATE_KEY=${priv}`);
console.log(`ENTITLEMENT_ED25519_PUBLIC_KEY=${pub}`);
