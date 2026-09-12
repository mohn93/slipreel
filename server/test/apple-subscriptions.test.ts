import {beforeAll,afterAll,beforeEach,describe,it,expect,vi} from 'vitest';
import type pg from 'pg';
import {testPool,resetDatabase} from './helpers/testDb.js';
import {runMigrations} from '../src/migrate.js';
import {createAppleSubscriptions} from '../src/apple/subscriptions.js';

const apple=vi.hoisted(()=>({transactions:new Map<string,any>(),status:vi.fn()}));
vi.mock('node:fs',()=>({readFileSync:()=>Buffer.from('test fixture')}));
vi.mock('@apple/app-store-server-library',()=>({
  Environment:{PRODUCTION:'Production',SANDBOX:'Sandbox'},
  SignedDataVerifier:class {
    async verifyAndDecodeTransaction(jws:string){
      if(!apple.transactions.has(jws))throw new Error('Invalid signature');
      return apple.transactions.get(jws);
    }
  },
  AppStoreServerAPIClient:class {getAllSubscriptionStatuses=apple.status;},
}));

describe('Apple monthly and yearly reconciliation',()=>{
  let pool:pg.Pool;
  const owner='10000000-0000-4000-8000-000000000001';
  const env={APPLE_STORE_BUNDLE_ID:'com.slipreel.store',APPLE_STORE_APP_ID:'6811278947',APPLE_IAP_KEY_FILE:'fixture',APPLE_IAP_KEY_ID:'fixture',APPLE_IAP_ISSUER_ID:'fixture',APPLE_ROOT_CERT_FILES:'fixture'};
  beforeAll(async()=>{pool=testPool();await resetDatabase(pool);await runMigrations(pool);});
  afterAll(async()=>pool.end());
  beforeEach(async()=>{
    await pool.query('DELETE FROM users');
    await pool.query("INSERT INTO users(id,email,app_account_token) VALUES('buyer','buyer@example.com',$1)",[owner]);
    apple.transactions.clear(); apple.status.mockReset();
  });
  function transaction(productId:string,signedDate:number){return {originalTransactionId:'original',transactionId:`tx-${signedDate}`,appAccountToken:owner,productId,expiresDate:Date.now()+86400000,signedDate};}
  function status(tx:unknown){apple.transactions.set('fresh',tx);apple.status.mockResolvedValue({data:[{lastTransactions:[{signedTransactionInfo:'fresh',status:1}]}]});}
  it('uses fresh yearly status for a monthly hint and does not roll back to older monthly data',async()=>{
    const service=createAppleSubscriptions(pool,env)!;
    const now=Date.now();
    const monthly=transaction('com.slipreel.store.monthly',now);
    apple.transactions.set('hint',monthly);status(monthly);
    await service.sync('hint','buyer');
    status(transaction('com.slipreel.store.yearly',now+1000));
    await service.sync('hint','buyer');
    expect((await pool.query('SELECT product_id FROM apple_subscriptions')).rows[0].product_id).toBe('com.slipreel.store.yearly');
    status(monthly);await service.sync('hint','buyer');
    expect((await pool.query('SELECT product_id FROM apple_subscriptions')).rows[0].product_id).toBe('com.slipreel.store.yearly');
  });
  it('rejects unverified, unsupported and differently owned purchases without granting access',async()=>{
    const service=createAppleSubscriptions(pool,env)!;
    await expect(service.sync('forged','buyer')).rejects.toThrow('Invalid Apple transaction');
    apple.transactions.set('hint',transaction('com.slipreel.store.unknown',Date.now()));
    await expect(service.sync('hint','buyer')).rejects.toThrow('Unsupported transaction');
    apple.transactions.set('hint',transaction('com.slipreel.store.yearly',Date.now()));
    await expect(service.sync('hint','different-user')).rejects.toThrow('another Slipreel account');
    expect((await pool.query('SELECT * FROM apple_subscriptions')).rows).toHaveLength(0);
    expect(apple.status).not.toHaveBeenCalled();
  });
});
