// Loopback-only integration harness; synthetic data, no live cloud credentials.
import http from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import worker from '../src/worker.js';
const db = new DatabaseSync(':memory:');
db.exec(readFileSync(new URL('../migrations/0002_local_usage.sql',import.meta.url),'utf8'));
db.exec(readFileSync(new URL('../migrations/0003_usage_accounts.sql',import.meta.url),'utf8'));
const env = {USAGE_ADMIN_TOKEN:'integration-admin-token-not-for-production',DB:{
 prepare(sql){const stmt=db.prepare(sql);let args=[];return{bind(...v){args=v;return this;},async all(){return{results:stmt.all(...args)};},async run(){return{meta:{changes:Number(stmt.run(...args).changes)}};}};},
 async batch(statements){db.exec('BEGIN');try{const result=[];for(const s of statements)result.push(await s.run());db.exec('COMMIT');return result;}catch(e){db.exec('ROLLBACK');throw e;}}
}};
const registered = await worker.fetch(new Request('http://localhost/v1/usage/devices',{method:'POST',headers:{authorization:`Bearer ${env.USAGE_ADMIN_TOKEN}`},body:JSON.stringify({teamID:'integration-team',memberID:'integration-member',memberName:'Integration',deviceID:'integration-device'})}),env);
const {token}=await registered.json(); if(!token)throw new Error('registration failed');
const server=http.createServer(async(req,res)=>{
 try{
  const chunks=[];for await(const chunk of req)chunks.push(chunk);
  const response=await worker.fetch(new Request(`http://127.0.0.1${req.url}`,{method:req.method,headers:req.headers,body:req.method==='GET'?undefined:Buffer.concat(chunks)}),env);
  res.writeHead(response.status,Object.fromEntries(response.headers));res.end(Buffer.from(await response.arrayBuffer()));
 }catch{res.writeHead(500);res.end('{}');}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const endpoint=`http://127.0.0.1:${server.address().port}`;
const child=spawn('swift',['test','--filter','UsageClientTests.testRealLocalWorkerWhenConfigured'],{cwd:new URL('../../',import.meta.url),env:{...process.env,USAGE_TEST_ENDPOINT:endpoint,USAGE_TEST_TOKEN:token},stdio:'inherit'});
child.on('exit',code=>{server.close();db.close();process.exitCode=code??1;});
