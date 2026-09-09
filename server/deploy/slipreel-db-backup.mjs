#!/usr/bin/env node
import {spawn,execFileSync} from 'node:child_process';
import {promises as fs} from 'node:fs';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {fileURLToPath} from 'node:url';

async function run(binary,args,{env={PATH:process.env.PATH,LANG:'C'},uid,gid,stdout='ignore'}={}) {
  await new Promise((resolve,reject)=>{
    const child=spawn(binary,args,{env,uid,gid,stdio:['ignore',stdout,'pipe']});
    // Never echo command stderr: connection diagnostics can contain credentials.
    child.stderr.resume();
    child.once('error',()=>reject(new Error(`${path.basename(binary)} could not start`)));
    child.once('close',code=>code===0?resolve():reject(new Error(`${path.basename(binary)} failed (exit ${code})`)));
  });
}

export function connectionEnvironment(databaseUrl) {
  // node-postgres also accepts user@/database for a Unix-socket connection.
  const emptyHost=/^(postgres(?:ql)?:\/\/[^/?#]*@)\//.test(databaseUrl);
  const uri=new URL(emptyHost?databaseUrl.replace(/^(postgres(?:ql)?:\/\/[^/?#]*@)\//,'$1localhost/'):databaseUrl);
  if(!['postgres:','postgresql:'].includes(uri.protocol))throw new Error('DATABASE_URL must be a PostgreSQL URI');
  const env={PATH:process.env.PATH,LANG:'C'};
  const fields={PGHOST:uri.hostname,PGPORT:uri.port,PGUSER:uri.username,PGPASSWORD:uri.password,PGDATABASE:uri.pathname.slice(1)};
  if(emptyHost)fields.PGHOST='';
  for(const [key,value] of Object.entries(fields))if(value)env[key]=decodeURIComponent(value);
  const parameters={host:'PGHOST',port:'PGPORT',user:'PGUSER',password:'PGPASSWORD',dbname:'PGDATABASE',sslmode:'PGSSLMODE',sslrootcert:'PGSSLROOTCERT',sslcert:'PGSSLCERT',sslkey:'PGSSLKEY',connect_timeout:'PGCONNECT_TIMEOUT',application_name:'PGAPPNAME',options:'PGOPTIONS'};
  for(const [key,value] of uri.searchParams){
    if(key==='ssl'){env.PGSSLMODE=value==='false'?'disable':'require';continue;}
    if(!parameters[key])throw new Error('Unsupported DATABASE_URL connection option');
    env[parameters[key]]=value;
  }
  return env;
}

export async function backup({directory,databaseUrl,uid,gid,pgDump='/usr/bin/pg_dump',pgRestore='/usr/bin/pg_restore',now=new Date(),requireRoot=true}) {
  if(requireRoot && process.getuid()!==0)throw new Error('Backup must run as root');
  if(!databaseUrl)throw new Error('DATABASE_URL is required');
  await fs.mkdir(directory,{recursive:true,mode:0o700});
  const dir=await fs.lstat(directory);
  if(!dir.isDirectory() || dir.isSymbolicLink() || (requireRoot && dir.uid!==0))throw new Error('Backup directory must be a root-owned real directory');
  await fs.chmod(directory,0o700);
  const day=now.toISOString().slice(0,10);
  const target=path.join(directory,`slipreel-db-${day}.dump`);
  const staging=path.join(directory,`.slipreel-db-${day}-${randomUUID()}.partial`);
  let output;
  try {
    output=await fs.open(staging,'wx',0o600);
    // Decode libpq connection settings into the child environment, never
    // password-bearing process arguments or shell expansion.
    await run(pgDump,['--format=custom','--no-password'],{env:connectionEnvironment(databaseUrl),uid,gid,stdout:output.fd});
    await output.sync();await output.close();output=undefined;
    if((await fs.stat(staging)).size===0)throw new Error('Empty database dump');
    await run(pgRestore,['--list',staging]);
    await run(pgRestore,['--file=/dev/null',staging]);
    await fs.rename(staging,target);
    const directoryHandle=await fs.open(directory,'r');
    try{await directoryHandle.sync();}finally{await directoryHandle.close();}
    // Keep today and the previous13 UTC dates; touch only this task's exact
    // daily filename format, after a new dump has passed both validations.
    const cutoff=new Date(Date.UTC(now.getUTCFullYear(),now.getUTCMonth(),now.getUTCDate())-13*86400000).toISOString().slice(0,10);
    let removed=0;
    for(const name of await fs.readdir(directory)) {
      const match=/^slipreel-db-(\d{4}-\d{2}-\d{2})\.dump$/.exec(name);
      if(match && match[1]<cutoff && !Number.isNaN(Date.parse(match[1])) && new Date(match[1]).toISOString().slice(0,10)===match[1]){await fs.unlink(path.join(directory,name));removed++;}
    }
    return {file:target,bytes:(await fs.stat(target)).size,retentionDays:14,removed,validated:true};
  }finally{
    if(output)await output.close();
    await fs.unlink(staging).catch(error=>{if(error.code!=='ENOENT')throw error;});
  }
}

if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {
    const user=process.env.SLIPREEL_BACKUP_DB_USER??'slipreel-api';
    const uid=Number(execFileSync('/usr/bin/id',['-u',user],{encoding:'utf8'}).trim());
    const gid=Number(execFileSync('/usr/bin/id',['-g',user],{encoding:'utf8'}).trim());
    const result=await backup({directory:'/var/backups/slipreel',databaseUrl:process.env.DATABASE_URL,uid,gid});
    console.log(JSON.stringify({status:'ok',...result}));
  }catch(error){console.error(JSON.stringify({status:'failed',reason:error.message}));process.exitCode=1;}
}
