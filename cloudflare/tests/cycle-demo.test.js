import test from 'node:test';
import assert from 'node:assert/strict';
import { selfTestFrame, waveCount, waveHead, paceFill, visibleArcInterval } from '../public/cycle-demo.js';
test('self test uses native three-second quota and directional pace cycle',()=>{
 assert.equal(selfTestFrame(0).remaining,.08);
 assert.equal(selfTestFrame(1).delta,0);
 assert.equal(selfTestFrame(1.5).remaining,.92);
 assert.ok(selfTestFrame(2).delta>0);
 assert.deepEqual(selfTestFrame(3),selfTestFrame(0));
});
test('task waves cap at five, are evenly spaced and travel counterclockwise',()=>{
 assert.equal(waveCount(0),0);assert.equal(waveCount(8),5);
 assert.ok(Math.abs(waveHead(.9,0,1)-.5)<1e-10);
 assert.ok(Math.abs(waveHead(0,1,3)-2/3)<1e-10);
 assert.ok(Math.abs(waveHead(1.8,0,1))<1e-10);
});
test('pace uses native staged fill and two-day normalization',()=>{
 assert.equal(paceFill(2),0);assert.equal(paceFill(-7),.25);
 assert.equal(paceFill(100/7),.5);assert.equal(paceFill(200/7),1);
});

test('task waves are masked in the provider opening',()=>{
 assert.equal(visibleArcInterval(0,.1),null);
 assert.equal(visibleArcInterval(.9,1),null);
 assert.deepEqual(visibleArcInterval(0,1),[0,1]);
 assert.ok(visibleArcInterval(.2,.3)[1]<.5);
});
