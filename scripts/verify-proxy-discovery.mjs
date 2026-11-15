import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import { createClient } from 'redis';
import { validateProxyBody } from '../dist/proxy-balancer.js';
import { ProxyDiscovery, discoveredCall, PROXY_LEASE_MS } from '../dist/proxy-discovery.js';

let checks=0;
const check=(condition,label)=>{assert.ok(condition,label);checks++;};
const registration={id:'sg1',pool:'as',region:'AS',name:'Singapore',host:'sg1.example.net',port:25565,capacity:300,priority:100,headTexture:'',backends:{smp:'smp'}};
const heartbeat={instanceId:randomUUID(),sequence:1,state:'READY',players:1,cpu:.2,heap:.3,schedulerDelayMs:0,backends:['smp'],registration};
check(validateProxyBody('heartbeat',heartbeat).registration.id==='sg1','self-registration validates');
for(const change of [{host:'0.0.0.0'},{host:'127.0.0.1'},{host:'10.0.0.1'},{host:'localhost'},{host:'bad.example/route'},
  {id:'../bad'},{pool:'AS'},{port:0},{port:1.5},{region:'??'},{capacity:0},{backends:{}},{backends:{'../role':'smp'}},{headTexture:'a'.repeat(2049)}]){
  assert.throws(()=>validateProxyBody('heartbeat',{...heartbeat,registration:{...registration,...change}}));checks++;
}
assert.throws(()=>validateProxyBody('heartbeat',{...heartbeat,backends:['unknown']}));checks++;
check(!('extra' in validateProxyBody('heartbeat',{...heartbeat,registration:{...registration,extra:'discard'}}).registration),'registration allowlist');

const source={...registration,instanceId:heartbeat.instanceId,state:'DRAINING',players:1,lastSeen:new Date().toISOString()};
const target={...source,id:'sg2',host:'sg2.example.net',state:'READY',instanceId:randomUUID()};
let live=[source,target],published=[];
const store={publish:async(n,seq)=>{published.push([n.id,seq]);},live:async nodes=>nodes.filter(n=>live.some(l=>l.id===n.id&&l.instanceId===n.instanceId))};
let actions=[];
const call=async action=>{actions.push(action);return action==='catalog'||action==='heartbeat'?{ok:true,proxyId:'sg1',pool:'as',proxies:[source,target]}:{ok:true};};
await discoveredCall(store,'heartbeat',heartbeat,call);
check(published.length===1&&published[0][0]==='sg1'&&published[0][1]===1,'only accepted self heartbeat published');
check((await discoveredCall(store,'handoff-create',{instanceId:source.instanceId,targetProxyId:'sg2'},call)).ok,'draining source can transfer to live ready target');
check((await discoveredCall(store,'handoff-create',{instanceId:source.instanceId,targetProxyId:'sg2',targetInstanceId:randomUUID()},call)).ok===false,'changed target generation rejects stale selection');
live=[source];actions=[];
check((await discoveredCall(store,'handoff-create',{instanceId:source.instanceId,targetProxyId:'sg2'},call)).code==='proxy_unavailable'&&!actions.includes('handoff-create'),'expired destination cannot issue ticket');
const catalog=await discoveredCall(store,'catalog',{},call);
check(catalog.proxies[1].state==='UNHEALTHY','expired health remains unavailable in menu');
live=[target];actions=[];
check((await discoveredCall(store,'handoff-create',{instanceId:source.instanceId,targetProxyId:'sg2'},call)).ok===false&&!actions.includes('handoff-create'),'expired source cannot issue ticket');
const unavailable={...store,live:async()=>{throw new Error('offline');},publish:async()=>{throw new Error('offline');}};
await assert.rejects(discoveredCall(unavailable,'handoff-create',{instanceId:source.instanceId,targetProxyId:'sg2'},call));checks++;
check((await discoveredCall(unavailable,'handoff-complete',{},call)).ok,'in-flight destination completion can preserve account ownership during Redis outage');
const denied=await discoveredCall(store,'heartbeat',heartbeat,async()=>({ok:false,code:'stale_proxy_instance'}));
check(denied.code==='stale_proxy_instance'&&published.length===1,'rejected heartbeat never refreshes Redis');

// Optional dedicated Redis (or Lua-capable RESP emulator). All keys use an isolated random prefix.
if(process.env.PROXY_TEST_REDIS_URL){
  const url=process.env.PROXY_TEST_REDIS_URL,prefix=`strafe-test:${randomUUID()}:`;
  const redis=createClient({url,socket:{reconnectStrategy:false,connectTimeout:1500}});redis.on('error',()=>{});
  const discovery=new ProxyDiscovery(url,prefix);
  try{
    await redis.connect();
    const node={...source,state:'READY',lastSeen:new Date().toISOString()};
    let connected=false;
    for(let i=0;i<40;i++){try{await discovery.publish(node,1);connected=true;break;}catch{await sleep(50);}}
    check(connected,'discovery client connects');
    check((await discovery.live([node])).length===1,'published node discovered over RESP');
    const key=`${prefix}as:sg1`,ttl=await redis.pTTL(key);
    check(ttl>0&&ttl<=PROXY_LEASE_MS,'health key has bounded TTL');
    await discovery.publish({...node,state:'DRAINING'},2);
    await discovery.publish({...node,state:'READY'},1);
    check((await discovery.live([{...node,state:'DRAINING'}]))[0].state==='DRAINING','reordered heartbeat cannot undo drain');
    check((await discovery.live([node])).length===0,'inconsistent SQL and Redis state fails closed');
    const refreshed={...node,state:'DRAINING',lastSeen:new Date(Date.now()+1).toISOString()};
    await discovery.publish(refreshed,3);
    check((await discovery.live([{...node,state:'DRAINING'}])).length===1,'concurrent newer heartbeat does not hide a healthy peer');
    await sleep(5);
    const replacement={...node,instanceId:randomUUID(),lastSeen:new Date(Date.now()+1).toISOString()};
    await discovery.publish(replacement,1);await discovery.publish(node,99);
    check((await discovery.live([replacement])).length===1&&(await discovery.live([node])).length===0,'former instance cannot overwrite replacement');
    const stale={...node,id:'expired',lastSeen:new Date(Date.now()-PROXY_LEASE_MS-1).toISOString()};
    await discovery.publish(stale,1);
    check((await discovery.live([stale])).length===0,'delayed expired heartbeat cannot resurrect health');
    const short={...node,id:'short',lastSeen:new Date(Date.now()-PROXY_LEASE_MS+250).toISOString()};
    await discovery.publish(short,1);check((await discovery.live([short])).length===1,'short lease initially live');
    await sleep(350);check((await discovery.live([short])).length===0,'crashed proxy expires without cleanup job');
    const other={...node,pool:'eu'};check((await discovery.live([other])).length===0,'Redis pools isolated');
    await redis.del(key);
  }finally{discovery.close();if(redis.isOpen)redis.destroy();}
}
console.log(`Proxy discovery verification passed: ${checks} checks${process.env.PROXY_TEST_REDIS_URL?' (including RESP/Lua lease checks)':' (Redis not supplied)'}`);
