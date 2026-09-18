// Website preview only: drives the real TeamCharts module (the same code the
// /team page ships) with deterministic fictional data. No network requests.
(function(){
 const mount=document.getElementById('team-charts');
 if(!mount||!window.TeamCharts)return;
 const now=new Date();
 const members=[
  {memberID:'m-bob',memberName:'Bob',devices:[{deviceID:'b3d84f16a902',revoked:false,lastEventAt:new Date(now-16*60000).toISOString()}]},
  {memberID:'m-alice',memberName:'Alice',devices:[
    {deviceID:'4f21a9c2e7b8',revoked:false,lastEventAt:new Date(now-14*60000).toISOString()},
    {deviceID:'9d02c7a1f3b4',revoked:false,lastEventAt:new Date(now-12*3600000).toISOString()}]}];
 const memberRows=[
  {memberID:'m-bob',input:7440000,output:1860000,cached:2600000,reasoning:744000,cacheWrite:0,records:640,pricedRecords:640,costUSD:2.4310,estimatedRecords:0},
  {memberID:'m-alice',input:3840000,output:960000,cached:1340000,reasoning:384000,cacheWrite:0,records:360,pricedRecords:360,costUSD:1.3720,estimatedRecords:0}];
 const overview={
  ok:true,timezone:'UTC',days:'30',generatedAt:now.toISOString(),
  team:{teamID:'t990e7052b3954a79',teamName:'设计团队 · Design team',inviteRotatedAt:new Date(now-8*86400000).toISOString(),memberLimit:20},
  members,usage:{member:memberRows,device:[],account:[{id:'4f8a2c1e9b07d6e5a9c0b1d2',input:11280000,output:2820000,cached:3940000,reasoning:1128000,cacheWrite:0,records:1000,pricedRecords:1000,costUSD:3.8030,estimatedRecords:0}]}};
 function timeline(from,to,seconds){
  const size=seconds*1000,n=Math.ceil((to.getTime()-from.getTime())/size),groups=[];
  for(let i=0;i<n;i++){
   const start=from.getTime()+i*size,d=new Date(start),h=d.getUTCHours(),dow=d.getUTCDay();
   let tokens=0;
   if(seconds===300)tokens=(h>=7&&h<=22)?Math.round(12000+9000*Math.abs(Math.sin(i*.7))):0;
   else tokens=(dow===0||dow===6)?Math.round(190000+110000*Math.abs(Math.sin(i*.9))):Math.round(410000+240000*Math.abs(Math.sin(i*.6)));
   const input=Math.round(tokens*.85),output=tokens-input,cached=Math.round(input*.34);
   const records=tokens>0?Math.max(1,Math.round(tokens/24000)):0;
   groups.push({id:i,input,output,cached,reasoning:Math.round(output*.4),cacheWrite:0,records,pricedRecords:records,costUSD:+(records*0.00112).toFixed(4),estimatedRecords:0});
  }
  return Promise.resolve({ok:true,from:new Date(from).toISOString(),to:new Date(to).toISOString(),bucketSeconds:seconds,groups});
 }
 function api(path){const q=new URLSearchParams(path.split('?')[1]||'');return timeline(new Date(q.get('from')),new Date(q.get('to')),Number(q.get('bucket_seconds'))||300);}
 window.TeamCharts.update(overview,api,()=>true);
})();
