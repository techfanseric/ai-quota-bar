import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';

test('logout invalidates a delayed overview before it can reveal the previous team',async()=>{
 const elements=new Map();
 const element=id=>{if(!elements.has(id))elements.set(id,{hidden:true,value:'30',listeners:{},addEventListener(event,fn){this.listeners[event]=fn;},replaceChildren(){}});return elements.get(id);};
 let resolveOverview;
 const pending=new Promise(resolve=>{resolveOverview=resolve;});
 const context=vm.createContext({Intl,Map,document:{getElementById:element,addEventListener(){}},fetch:async path=>path.includes('overview')?pending:{ok:true,json:async()=>({ok:true})},URLSearchParams});
 vm.runInContext(readFileSync(new URL('../public/team.js',import.meta.url),'utf8'),context);
 await element('logout').listeners.click();
 assert.equal(element('dashboard').hidden,true);
 // Rendering this malformed response would throw/show the dashboard. It must be discarded first.
 resolveOverview({ok:true,json:async()=>({team:{teamName:'Previous private team'}})});
 await new Promise(resolve=>setImmediate(resolve));
 assert.equal(element('dashboard').hidden,true);
 assert.equal(element('entry').hidden,false);
});
