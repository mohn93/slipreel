import type { FastifyInstance, preHandlerHookHandler } from 'fastify';
import { randomInt } from 'node:crypto';
import { z } from 'zod';
import { newId } from '../ids.js';
import { newSecretToken, hashToken } from '../auth/secret_token.js';
import { createSession, resolveSession, deleteSession } from '../auth/sessions.js';
import { registerDevice, SEAT_LIMIT } from '../auth/devices.js';
import { resolveEffectiveEntitlement } from '../billing/effective_entitlement.js';

export function requireNativeSession(app: FastifyInstance): preHandlerHookHandler {
  return async (req,reply) => {
    const token = req.headers.authorization?.match(/^Bearer ([A-Za-z0-9_-]{40,100})$/)?.[1];
    const session = token ? await resolveSession(app.pool,token) : null;
    if (!session) return reply.code(401).send({error:'not_authenticated'});
    req.userId = session.userId;
  };
}
const rate = {rateLimit:{max:5,timeWindow:'1 minute'}};
export async function nativeAccountRoutes(app: FastifyInstance): Promise<void> {
  const auth = requireNativeSession(app);
  app.post('/v1/native/email/request',{config:rate},async(req,reply)=>{
    const body=z.object({email:z.string().email().max(254)}).safeParse(req.body);
    if (!body.success) return reply.code(400).send({error:'invalid_request'});
    if (!app.email?.sendSignInCode) return reply.code(503).send({error:'email_unavailable'});
    const id = newId('otp'), code = randomInt(0,100000000).toString().padStart(8,'0');
    await app.pool.query(`INSERT INTO native_auth_challenges(id,email,secret_hash,kind,expires_at) VALUES($1,$2,$3,'email',now()+interval '10 minutes')`,[id,body.data.email,hashToken(id+':'+code)]);
    try { await app.email.sendSignInCode(body.data.email,code); }
    catch { await app.pool.query('DELETE FROM native_auth_challenges WHERE id=$1',[id]); return reply.code(503).send({error:'email_unavailable'}); }
    return {challenge:id};
  });
  app.post('/v1/native/email/verify',{config:rate},async(req,reply)=>{
    const body=z.object({challenge:z.string().max(100),code:z.string().regex(/^\d{8}$/)}).safeParse(req.body);
    if (!body.success) return reply.code(400).send({error:'invalid_request'});
    const {challenge,code}=body.data;
    // One atomic UPDATE both limits attempts and consumes a valid code exactly once.
    const checked=await app.pool.query<{email:string;valid:boolean}>(`UPDATE native_auth_challenges SET attempts=attempts+1,
      consumed_at=CASE WHEN secret_hash=$2 THEN now() ELSE NULL END
      WHERE id=$1 AND kind='email' AND consumed_at IS NULL AND expires_at>now() AND attempts<5
      RETURNING email,secret_hash=$2 AS valid`,[challenge,hashToken(challenge+':'+code)]);
    const row=checked.rows[0];
    if (!row?.valid) return reply.code(401).send({error:'invalid_code'});
    const user=await app.pool.query<{id:string}>(`INSERT INTO users(id,email,email_verified) VALUES($1,$2,true)
      ON CONFLICT(email) DO UPDATE SET email_verified=true RETURNING id`,[newId('usr'),row.email]);
    const session=await createSession(app.pool,user.rows[0]!.id);
    return {session:session.token};
  });
  app.post('/v1/native/apple/challenge',{config:rate},async(_req,reply)=>{
    if (!app.appleSignIn) return reply.code(503).send({error:'apple_sign_in_unavailable'});
    const id=newId('sia'), {hash}=newSecretToken();
    await app.pool.query(`INSERT INTO native_auth_challenges(id,secret_hash,kind,expires_at) VALUES($1,$2,'apple',now()+interval '5 minutes')`,[id,hash]);
    return {challenge:id,nonce:hash};
  });
  app.post('/v1/native/apple/verify',{config:rate},async(req,reply)=>{
    if (!app.appleSignIn) return reply.code(503).send({error:'apple_sign_in_unavailable'});
    const body=z.object({challenge:z.string().max(100),identityToken:z.string().max(10000),code:z.string().max(5000)}).safeParse(req.body);
    if (!body.success) return reply.code(400).send({error:'invalid_request'});
    const challenge=await app.pool.query<{secret_hash:string}>(`UPDATE native_auth_challenges SET consumed_at=now() WHERE id=$1 AND kind='apple' AND consumed_at IS NULL AND expires_at>now() RETURNING secret_hash`,[body.data.challenge]);
    if (!challenge.rows[0]) return reply.code(401).send({error:'invalid_challenge'});
    let identity;
    try { identity=await app.appleSignIn.verify(body.data.identityToken,body.data.code,challenge.rows[0].secret_hash); }
    catch { return reply.code(401).send({error:'apple_sign_in_failed'}); }
    const existing=await app.pool.query<{user_id:string}>('SELECT user_id FROM apple_identities WHERE subject=$1',[identity.subject]);
    let userId=existing.rows[0]?.user_id;
    if (!userId) {
      const user=await app.pool.query<{id:string}>(`INSERT INTO users(id,email,email_verified) VALUES($1,$2,true)
        ON CONFLICT(email) DO UPDATE SET email_verified=true RETURNING id`,[newId('usr'),identity.email]);
      userId=user.rows[0]!.id;
    }
    await app.pool.query(`INSERT INTO apple_identities(subject,user_id,refresh_token_encrypted) VALUES($1,$2,$3)
      ON CONFLICT(subject) DO UPDATE SET refresh_token_encrypted=EXCLUDED.refresh_token_encrypted`,[identity.subject,userId,identity.encryptedRefreshToken]);
    return {session:(await createSession(app.pool,userId)).token};
  });
  app.get('/v1/native/account',{preHandler:auth},async(req)=>{
    const user=await app.pool.query('SELECT id,email,app_account_token FROM users WHERE id=$1',[req.userId]);
    return {user:user.rows[0],entitlement:await resolveEffectiveEntitlement(app.pool,req.userId!)};
  });
  app.post('/v1/native/activate',{preHandler:auth},async(req,reply)=>{
    const body=z.object({fingerprint:z.string().min(1).max(200),name:z.string().max(120)}).safeParse(req.body);
    if (!body.success) return reply.code(400).send({error:'invalid_request'});
    const device=await registerDevice(app.pool,req.userId!,body.data.fingerprint,body.data.name,SEAT_LIMIT,null,'app-store');
    if (!device.ok) return reply.code(409).send({error:'seat_limit'});
    try { await app.appleSubscriptions?.refreshUser?.(req.userId!); }
    catch { app.log.warn('Apple subscription refresh unavailable; using last verified paid-through date'); }
    const eff=await resolveEffectiveEntitlement(app.pool,req.userId!);
    const token=await app.tokenSigner.mint({sub:req.userId!,plan:eff.plan,export:eff.export,status:eff.status,updates_until:eff.updatesUntil,device_id:device.deviceId,seat_limit:SEAT_LIMIT});
    return {token,refresh_token:device.refreshToken,device_id:device.deviceId};
  });
  app.post('/v1/native/logout',{preHandler:auth},async(req)=>{
    await deleteSession(app.pool,req.headers.authorization!.slice(7)); return {ok:true};
  });
  app.delete('/v1/native/account',{preHandler:auth},async(req,reply)=>{
    if ((req.body as {confirm?:string})?.confirm !== 'DELETE') return reply.code(400).send({error:'confirmation_required'});
    const identities=await app.pool.query<{refresh_token_encrypted:string}>('SELECT refresh_token_encrypted FROM apple_identities WHERE user_id=$1',[req.userId]);
    if (identities.rows.length && !app.appleSignIn) return reply.code(503).send({error:'apple_sign_in_unavailable'});
    // Cancel recurring web charges before removing the account. Apple subscriptions
    // must be cancelled by the customer in Apple Account settings (shown in UI).
    const subscriptions=await app.pool.query<{stripe_subscription_id:string}>(`SELECT stripe_subscription_id FROM entitlements WHERE user_id=$1 AND stripe_subscription_id IS NOT NULL`,[req.userId]);
    for (const row of subscriptions.rows) {
      const subscription=await app.stripe.subscriptions.retrieve(row.stripe_subscription_id);
      if (subscription.status !== 'canceled' && subscription.status !== 'incomplete_expired') await app.stripe.subscriptions.cancel(subscription.id);
    }
    for (const row of identities.rows) await app.appleSignIn!.revoke(row.refresh_token_encrypted);
    await app.pool.query('DELETE FROM users WHERE id=$1',[req.userId]);
    return {ok:true};
  });
  app.post('/v1/native/apple/purchase',{preHandler:auth,config:{rateLimit:{max:30,timeWindow:'1 minute'}}},async(req,reply)=>{
    if (!app.appleSubscriptions) return reply.code(503).send({error:'store_unavailable'});
    const body=z.object({signedTransaction:z.string().min(1).max(30000)}).safeParse(req.body);
    if (!body.success) return reply.code(400).send({error:'invalid_request'});
    try { await app.appleSubscriptions.sync(body.data.signedTransaction,req.userId!); }
    catch { return reply.code(409).send({error:'purchase_not_linked'}); }
    return {ok:true};
  });
  app.post('/v1/apple/notifications',{config:{rateLimit:{max:300,timeWindow:'1 minute'}}},async(req,reply)=>{
    if (!app.appleSubscriptions) return reply.code(503).send({error:'store_unavailable'});
    const body=z.object({signedPayload:z.string().min(1).max(60000)}).safeParse(req.body);
    if (!body.success) return reply.code(400).send({error:'invalid_request'});
    try { await app.appleSubscriptions.notification(body.data.signedPayload); }
    catch { return reply.code(503).send({error:'notification_not_processed'}); }
    return {ok:true};
  });
}
