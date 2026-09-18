import test from 'node:test';
import assert from 'node:assert/strict';
import {usageFixture,summarize,intensity} from '../public/usage-fixture.js';
import worker from '../src/worker.js';

test('website usage mirrors the native calendar, rolling 5-minute grid and future days',()=>{
 const f=usageFixture();assert.equal(f.daily.length,30);assert.equal(f.daily[0].start.getDate(),1);
 assert.equal(f.hourly.length,288);assert.equal(+f.hourly[0].start,+f.now-86400000);assert.equal(+f.hourly.at(-1).end,+f.now);
 for(const b of f.hourly)assert.equal(+b.end- +b.start,300000);
 assert(f.daily.filter(b=>b.start>f.now).every(b=>b.records===0));
 assert.equal(usageFixture('all',new Date(2028,1,18)).daily.length,29);
});
test('account totals reconcile without double-counting cached tokens and hide unpriced costs',()=>{
 const all=usageFixture(),current=usageFixture('current'),previous=usageFixture('previous'),unknown=usageFixture('unknown');
 assert.equal(all.total.tokens,current.total.tokens+previous.total.tokens+unknown.total.tokens);
 assert.equal(all.total.tokens,all.total.input+all.total.output);
 assert.equal(all.total.cache,100*all.total.cached/all.total.input);
 assert.deepEqual(all.recent,summarize(all.hourly));assert.equal(all.total.cost,null);
 assert(all.daily.every(b=>b.cost===null||b.records===0));
 assert.equal(intensity(1,100),.25);assert.equal(intensity(0,100),0);assert.equal(intensity(null,100),null);
});
test('all new preview resources are public without weakening private routes',async()=>{
 const env={ASSETS:{fetch:async()=>new Response('fixture')}};
 for(const path of ['/usage-demo.js','/usage-fixture.js','/provider-logos/codex.svg','/provider-logos/kimi.svg','/team-settings-en.png','/team-settings-zh-Hans.png']){
  const r=await worker.fetch(new Request('https://example.com'+path),env);assert.equal(r.status,200,path);
 }
 assert.equal((await worker.fetch(new Request('https://example.com/v1/quota-samples'),env)).status,401);
});
