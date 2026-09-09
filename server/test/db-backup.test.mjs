import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,readFile,readdir,stat,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {backup,connectionEnvironment} from '../deploy/slipreel-db-backup.mjs';

const options={requireRoot:false,databaseUrl:process.env.BACKUP_TEST_DATABASE_URL,pgDump:process.env.BACKUP_TEST_PG_DUMP??'/usr/bin/pg_dump',pgRestore:process.env.BACKUP_TEST_PG_RESTORE??'/usr/bin/pg_restore',now:new Date('2026-09-09T04:00:00Z')};

test('failed dump preserves prior backups and cleans staging',async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'slipreel-backup-test-'));
 try{
  await writeFile(path.join(directory,'slipreel-db-2026-08-01.dump'),'old backup');
  await assert.rejects(backup({...options,directory,databaseUrl:'postgresql:///fixture',pgDump:'/usr/bin/false'}),/failed/);
  assert.deepEqual(await readdir(directory),['slipreel-db-2026-08-01.dump']);
  assert.equal(await readFile(path.join(directory,'slipreel-db-2026-08-01.dump'),'utf8'),'old backup');
 }finally{await rm(directory,{recursive:true,force:true});}
});

test('invalid archive does not replace today or prune prior backups',async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'slipreel-backup-test-'));
 try{
  await writeFile(path.join(directory,'slipreel-db-2026-09-09.dump'),'prior good backup');
  await assert.rejects(backup({...options,directory,databaseUrl:'postgresql:///fixture',pgDump:'/bin/echo'}),/failed|could not start/);
  assert.equal(await readFile(path.join(directory,'slipreel-db-2026-09-09.dump'),'utf8'),'prior good backup');
  assert.equal((await readdir(directory)).length,1);
 }finally{await rm(directory,{recursive:true,force:true});}
});

test('real consistent custom dump validates and retention touches only owned daily files',{skip:!options.databaseUrl},async()=>{
 const directory=await mkdtemp(path.join(tmpdir(),'slipreel-backup-test-'));
 try{
  for(const name of ['slipreel-db-2026-08-26.dump','slipreel-db-2026-08-27.dump','protected-rollout-backup.dump','slipreel-db-not-a-date.dump'])await writeFile(path.join(directory,name),'preserve unless expired daily');
  const result=await backup({...options,directory});
  assert.equal(result.validated,true);assert.ok(result.bytes>0);assert.equal(result.removed,1);
  assert.equal((await stat(result.file)).mode&0o777,0o600);
  assert.equal((await stat(directory)).mode&0o777,0o700);
  assert.deepEqual((await readdir(directory)).sort(),['protected-rollout-backup.dump','slipreel-db-2026-08-27.dump','slipreel-db-2026-09-09.dump','slipreel-db-not-a-date.dump'].sort());
 }finally{await rm(directory,{recursive:true,force:true});}
});

test('connection parser preserves escaped credentials and peer socket without argv exposure',()=>{
 const env=connectionEnvironment('postgresql://name:p%40ss%3Aword@localhost:55439/fixture?sslmode=require');
 assert.equal(env.PGUSER,'name');assert.equal(env.PGPASSWORD,'p@ss:word');assert.equal(env.PGDATABASE,'fixture');assert.equal(env.PGPORT,'55439');assert.equal(env.PGSSLMODE,'require');
 const peer=connectionEnvironment('postgresql:///slipreel?host=%2Fvar%2Frun%2Fpostgresql');
 const namedPeer=connectionEnvironment('postgresql://slipreel-api@/slipreel?host=/var/run/postgresql');
 assert.equal(namedPeer.PGUSER,'slipreel-api');assert.equal(namedPeer.PGHOST,'/var/run/postgresql');
 assert.equal(peer.PGHOST,'/var/run/postgresql');assert.equal(peer.PGUSER,undefined);
});
