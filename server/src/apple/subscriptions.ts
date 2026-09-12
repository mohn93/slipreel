import type pg from 'pg';
import { readFileSync } from 'node:fs';
import { AppStoreServerAPIClient, SignedDataVerifier, Environment } from '@apple/app-store-server-library';

export interface AppleSubscriptions {
  sync(signedTransaction: string, userId?: string): Promise<void>;
  notification(signedPayload: string): Promise<void>;
  refreshUser?(userId: string): Promise<void>;
}

/** Online status reconciliation prevents replaying an old, pre-refund JWS.
 * Notifications trigger the same reconciliation, so out-of-order delivery is safe.
 */
export function createAppleSubscriptions(pool: pg.Pool, env = process.env): AppleSubscriptions | undefined {
  if (!env.APPLE_IAP_KEY_FILE) return undefined;
  const bundle = env.APPLE_STORE_BUNDLE_ID;
  const appId = Number(env.APPLE_STORE_APP_ID);
  if (!bundle || !Number.isSafeInteger(appId) || appId <= 0 || !env.APPLE_IAP_KEY_ID || !env.APPLE_IAP_ISSUER_ID || !env.APPLE_ROOT_CERT_FILES) {
    throw new Error('Incomplete Apple Store configuration');
  }
  const roots = env.APPLE_ROOT_CERT_FILES.split(',').map(p => readFileSync(p.trim()));
  const key = readFileSync(env.APPLE_IAP_KEY_FILE, 'utf8');
  const environments = [Environment.PRODUCTION, Environment.SANDBOX];
  const verifiers = environments.map(e => new SignedDataVerifier(roots, true, e, bundle, appId));
  const clients = environments.map(e => new AppStoreServerAPIClient(key, env.APPLE_IAP_KEY_ID!, env.APPLE_IAP_ISSUER_ID!, bundle, e));

  async function verifiedTransaction(jws: string) {
    for (let i = 0; i < verifiers.length; i++) {
      try { return { transaction: await verifiers[i]!.verifyAndDecodeTransaction(jws), index: i }; } catch { /* try the other signed environment */ }
    }
    throw new Error('Invalid Apple transaction');
  }
  async function sync(jws: string, expectedUser?: string): Promise<void> {
    const { transaction: hint, index } = await verifiedTransaction(jws);
    if (!hint.originalTransactionId || !hint.appAccountToken || hint.productId !== 'com.slipreel.store.monthly') throw new Error('Unsupported transaction');
    const owner = await pool.query<{id:string}>('SELECT id FROM users WHERE app_account_token=$1', [hint.appAccountToken]);
    const userId = owner.rows[0]?.id;
    if (!userId && !expectedUser) return; // A deleted account must not be recreated by notifications.
    if (!userId || (expectedUser && userId !== expectedUser)) throw new Error('Purchase belongs to another Slipreel account');
    const response = await clients[index]!.getAllSubscriptionStatuses(hint.originalTransactionId);
    const statuses = response.data?.flatMap(group => group.lastTransactions ?? []) ?? [];
    let found = false;
    for (const status of statuses) {
      if (!status.signedTransactionInfo) continue;
      const tx = await verifiers[index]!.verifyAndDecodeTransaction(status.signedTransactionInfo);
      if (tx.originalTransactionId !== hint.originalTransactionId || tx.appAccountToken?.toLowerCase() !== hint.appAccountToken.toLowerCase() || tx.productId !== 'com.slipreel.store.monthly' || !tx.expiresDate || !tx.signedDate || !tx.transactionId) continue;
      found = true;
      // Billing grace must be enabled and separately verified before granting it.
      // For this launch access lasts through the signed paid-through date.
      const revoked = tx.revocationDate ? new Date(tx.revocationDate) : status.status === 5 ? new Date(tx.signedDate) : null;
      await pool.query(`INSERT INTO apple_subscriptions
        (original_transaction_id,environment,user_id,product_id,transaction_id,expires_at,revoked_at,signed_at)
        VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
        ON CONFLICT (original_transaction_id,environment) DO UPDATE SET
          transaction_id=EXCLUDED.transaction_id, expires_at=EXCLUDED.expires_at,
          revoked_at=EXCLUDED.revoked_at,signed_at=EXCLUDED.signed_at,checked_at=now()
        WHERE apple_subscriptions.user_id=EXCLUDED.user_id AND apple_subscriptions.signed_at <= EXCLUDED.signed_at`,
        [tx.originalTransactionId,environments[index],userId,tx.productId,tx.transactionId,new Date(tx.expiresDate),revoked,new Date(tx.signedDate)]);
    }
    if (!found) throw new Error('Subscription status unavailable');
  }
  return {
    sync,
    async refreshUser(userId) {
      // Recover missed renewal/refund notifications even if the store app is closed.
      const rows = await pool.query<{original_transaction_id:string;environment:string}>(
        `SELECT original_transaction_id,environment FROM apple_subscriptions
         WHERE user_id=$1 AND checked_at < now()-interval '1 hour'`, [userId]);
      for (const row of rows.rows) {
        const index = environments.findIndex(e => e === row.environment);
        if (index < 0) continue;
        const response = await clients[index]!.getAllSubscriptionStatuses(row.original_transaction_id);
        const statuses = response.data?.flatMap(group => group.lastTransactions ?? []) ?? [];
        const match = statuses.find(status => status.originalTransactionId === row.original_transaction_id);
        if (!match?.signedTransactionInfo) throw new Error('Subscription reconciliation unavailable');
        await sync(match.signedTransactionInfo,userId);
      }
    },
    async notification(jws) {
      for (const verifier of verifiers) {
        let notification;
        try { notification = await verifier.verifyAndDecodeNotification(jws); } catch { continue; }
        if (notification.notificationType === 'TEST') return;
        if (!notification.data?.signedTransactionInfo) return;
        await sync(notification.data.signedTransactionInfo);
        return;
      }
      throw new Error('Invalid Apple notification');
    },
  };
}
