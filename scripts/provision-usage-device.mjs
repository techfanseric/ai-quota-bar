#!/usr/bin/env node
// Admin credential is read from the environment; never passed in a URL or logged.
const [endpoint, teamID, memberID, memberName, deviceID] = process.argv.slice(2);
if (!endpoint || !teamID || !memberID || !memberName || !deviceID || !process.env.USAGE_ADMIN_TOKEN) {
  console.error('Usage: USAGE_ADMIN_TOKEN=... node scripts/provision-usage-device.mjs https://worker.example team member "Member name" device-id');
  process.exit(1);
}
const url = new URL(endpoint);
if(url.protocol!=='https:' && !(url.protocol==='http:' && ['127.0.0.1','localhost'].includes(url.hostname))) throw new Error('HTTPS required');
const response = await fetch(new URL('/v1/usage/devices',url),{method:'POST',redirect:'error',headers:{authorization:`Bearer ${process.env.USAGE_ADMIN_TOKEN}`,'content-type':'application/json'},body:JSON.stringify({teamID,memberID,memberName,deviceID,reassign:process.argv.includes("--reassign")})});
if(!response.ok)throw new Error(`Registration failed: HTTP ${response.status}`);
console.log(JSON.stringify(await response.json(),null,2));
