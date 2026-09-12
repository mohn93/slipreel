import {registerDevice,refreshDevice} from '../src/auth/devices.js';
import {describe,it,expect,beforeAll,afterAll,beforeEach} from 'vitest';
import type pg from 'pg';
import {testPool,resetDatabase} from './helpers/testDb.js';
import {runMigrations} from '../src/migrate.js';
import {makeLicensingApp} from './helpers/licensing.js';
import {resolveEffectiveEntitlement} from '../src/billing/effective_entitlement.js';

describe('native account and shared payment access',()=>{
  let pool:pg.Pool;
  beforeAll(async()=>{pool=testPool();await resetDatabase(pool);await runMigrations(pool);});
  afterAll(async()=>pool.end());
  beforeEach(async()=>{await pool.query('DELETE FROM users');await pool.query('DELETE FROM native_auth_challenges');});
  async function login(){
    let code='';
    const {app,signer}=await makeLicensingApp(pool,{email:{sendMagicLink:async()=>{},sendSignInCode:async(_to,value)=>{code=value;}}});
    const challenge=(await app.inject({method:'POST',url:'/v1/native/email/request',payload:{email:'buyer@example.com'}})).json().challenge;
    const payload={challenge,code};
    const response=await app.inject({method:'POST',url:'/v1/native/email/verify',payload});
    expect(response.statusCode).toBe(200);
    const headers={authorization:`Bearer ${response.json().session}`};
    const user=(await app.inject({url:'/v1/native/account',headers})).json().user;
    return {app,signer,headers,user,payload};
  }
  it('verifies email once, persists the same purchase account UUID, and rejects code replay',async()=>{
    const {app,headers,user,payload}=await login();
    expect(user.app_account_token).toMatch(/^[0-9a-f-]{36}$/);
    const replay=await app.inject({method:'POST',url:'/v1/native/email/verify',payload});
    expect(replay.statusCode).toBe(401);
    expect((await app.inject({url:'/v1/native/account',headers})).json().user.app_account_token).toBe(user.app_account_token);
    await app.close();
  });
  it('locks a code after five wrong attempts even from different IPs',async()=>{
    let code='';
    const {app}=await makeLicensingApp(pool,{email:{sendMagicLink:async()=>{},sendSignInCode:async(_to,value)=>{code=value;}}});
    const challenge=(await app.inject({method:'POST',url:'/v1/native/email/request',payload:{email:'new@example.com'}})).json().challenge;
    for(let i=0;i<5;i++) expect((await app.inject({method:'POST',url:'/v1/native/email/verify',remoteAddress:`192.0.2.${i+1}`,payload:{challenge,code:code==='00000000'?'11111111':'00000000'}})).statusCode).toBe(401);
    expect((await app.inject({method:'POST',url:'/v1/native/email/verify',remoteAddress:'192.0.2.99',payload:{challenge,code}})).statusCode).toBe(401);
    expect((await pool.query('SELECT * FROM users')).rows).toHaveLength(0);
    await app.close();
  });
  it('does not return the sign-in code or create a user when delivery fails',async()=>{
    const {app}=await makeLicensingApp(pool,{email:{sendMagicLink:async()=>{},sendSignInCode:async()=>{throw new Error('delivery failed');}}});
    const response=await app.inject({method:'POST',url:'/v1/native/email/request',payload:{email:'new@example.com'}});
    expect(response.statusCode).toBe(503);
    expect((await pool.query('SELECT * FROM users')).rows).toHaveLength(0);
    expect((await pool.query('SELECT * FROM native_auth_challenges')).rows).toHaveLength(0);
    await app.close();
  });
  it('website purchase activates the store edition through a signed device token',async()=>{
    const {app,headers,user,signer}=await login();
    await pool.query(`INSERT INTO entitlements(id,user_id,plan,status,stripe_subscription_id,current_period_end) VALUES('ent_web',$1,'subscription','active','sub_web',now()+interval '1 day')`,[user.id]);
    const activation=await app.inject({method:'POST',url:'/v1/native/activate',headers,payload:{fingerprint:'store-device',name:'Store Mac'}});
    expect(activation.statusCode,activation.body).toBe(200);
    expect(await signer.verify(activation.json().token)).toMatchObject({sub:user.id,export:true,plan:'subscription'});
    await app.close();
  });
  it('Apple production purchase grants direct access, refund preserves an active Stripe purchase',async()=>{
    const {app,user}=await login();
    await pool.query(`INSERT INTO apple_subscriptions VALUES('original','Production',$1,'com.slipreel.store.monthly','tx',now()+interval '1 day',NULL,now(),now())`,[user.id]);
    expect((await resolveEffectiveEntitlement(pool,user.id)).export).toBe(true);
    await pool.query("UPDATE apple_subscriptions SET revoked_at=now()");
    expect((await resolveEffectiveEntitlement(pool,user.id)).export).toBe(false);
    await pool.query(`INSERT INTO entitlements(id,user_id,plan,status,stripe_subscription_id,current_period_end) VALUES('ent_web',$1,'subscription','active','sub_web',now()+interval '1 day')`,[user.id]);
    expect((await resolveEffectiveEntitlement(pool,user.id)).export).toBe(true);
    await app.close();
  });
  it('sandbox transactions and expired transactions never grant production shared access',async()=>{
    const {app,user}=await login();
    await pool.query(`INSERT INTO apple_subscriptions VALUES('original','Sandbox',$1,'com.slipreel.store.monthly','tx',now()+interval '1 day',NULL,now(),now())`,[user.id]);
    expect((await resolveEffectiveEntitlement(pool,user.id)).export).toBe(false);
    await pool.query("UPDATE apple_subscriptions SET environment='Production',expires_at=now()-interval '1 second'");
    expect((await resolveEffectiveEntitlement(pool,user.id)).export).toBe(false);
    await app.close();
  });
  it('rejects unauthenticated activation, purchase linking and deletion',async()=>{
    const {app}=await makeLicensingApp(pool);
    for(const [method,url] of [['POST','/v1/native/activate'],['POST','/v1/native/apple/purchase'],['DELETE','/v1/native/account']] as const) {
      expect((await app.inject({method,url,payload:{confirm:'DELETE'}})).statusCode).toBe(401);
    }
    await app.close();
  });
  it('two editions share one seat without revoking one another',async()=>{
    const {app,user}=await login();
    const direct=await registerDevice(pool,user.id,'same-mac','Mac',2);
    const store=await registerDevice(pool,user.id,'same-mac','Mac',2,null,'app-store');
    if(!direct.ok || !store.ok) throw new Error('activation failed');
    expect(store.deviceId).toBe(direct.deviceId);
    expect(await refreshDevice(pool,direct.deviceId,direct.refreshToken)).toEqual({userId:user.id});
    expect(await refreshDevice(pool,store.deviceId,store.refreshToken)).toEqual({userId:user.id});
    const directAgain=await registerDevice(pool,user.id,'same-mac','Mac',2);
    expect(directAgain.ok).toBe(true);
    expect(await refreshDevice(pool,store.deviceId,store.refreshToken)).toEqual({userId:user.id});
    expect(Number((await pool.query('SELECT count(*) FROM devices WHERE user_id=$1',[user.id])).rows[0].count)).toBe(1);
    await app.close();
  });
  it('logout revokes the bearer session',async()=>{
    const {app,headers}=await login();
    expect((await app.inject({method:'POST',url:'/v1/native/logout',headers})).statusCode).toBe(200);
    expect((await app.inject({url:'/v1/native/account',headers})).statusCode).toBe(401);
    await app.close();
  });
});
