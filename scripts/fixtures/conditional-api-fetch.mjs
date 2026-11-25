// Test-only Supabase transport. Never makes an outbound request or loads .env.
import { createHash } from 'node:crypto';
let state = {banned:false,revoked:false,unavailable:false,migration:true};
const keyHash = createHash('sha256').update('ssmp_live_'+'a'.repeat(64)).digest('hex');
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
let calls = 0;
process.on('message',message=>{if(message?.fixture){state={...state,...message.fixture};process.send?.({ack:message.id});}});
const reply = (value,status=200)=>new Response(JSON.stringify(value),{status,headers:{'content-type':'application/json'}});
function valueFor(name,parameters) {
  if(name==='get_tier_ban_statuses') return {bans:Object.fromEntries(parameters.p_player_ids.map(id=>[id,state.banned]))};
  if(name==='get_points_snapshot') return {currentSeason:'season-2',region:'AS',subjectType:parameters.p_subject_type,items:Array.from({length:10},(_,i)=>({subjectId:'00000000-0000-4000-8000-'+String(i+1).padStart(12,'0'),subjectType:'player',points:state.banned?984:1000,wins:0,losses:0})),nextCursor:null};
  if(name==='proxy_balancer') return {ok:true,proxyId:'sg1',pool:'as',serverTime:String(calls),probeJobs:[],proxies:[{id:'sg1',pool:'as',name:'Singapore',host:'sg.example.net',headTexture:'head-texture'.repeat(100),state:'READY',players:calls,instanceId:parameters.p_body.instanceId,lastSeen:String(calls)}]};
  throw new Error('Unexpected fixture operation');
}
globalThis.fetch = async (url,options)=>{
  const parsed = new URL(url);
  if(parsed.origin!=='https://supabase.invalid') throw new Error('External network disabled in fixture');
  const name=parsed.pathname.split('/').at(-1), parameters=JSON.parse(options.body);
  calls++;
  if(name==='authenticate_point_api_key') return reply(state.revoked||parameters.p_key_hash!==keyHash?[]:[{id:'00000000-0000-4000-8000-000000000002',label:'Fixture',scopes:['points:read','leaderboards:read','accounts:read','accounts:write'],expires_at:null}]);
  if(state.unavailable) throw new Error('Simulated database outage');
  if(name==='api_read_if_changed') {
    if(!state.migration) return reply({code:'PGRST202'},404);
    const value=valueFor(parameters.p_call,parameters.p_parameters);
    if(parameters.p_call==='proxy_balancer') {
      const live=['state','players','instanceId','lastSeen'];
      const descriptive=value.proxies.map(node=>Object.fromEntries(Object.entries(node).filter(([key])=>!live.includes(key))));
      const digest=hash(descriptive),notModified=parameters.p_digest===digest;
      if(notModified)value.proxies=value.proxies.map(node=>Object.fromEntries(Object.entries(node).filter(([key])=>key==='id'||live.includes(key))));
      return reply({mode:'proxy-catalog',digest,notModified,value});
    }
    const digest=hash(value),notModified=parameters.p_digest===digest;
    return reply({mode:'value',digest,notModified,...(notModified?{}:{value})});
  }
  if(name==='regional_points_call') return reply(valueFor(parameters.p_call,parameters.p_parameters));
  if(name==='api_get_tier_ban_statuses') return reply(valueFor('get_tier_ban_statuses',parameters));
  if(name==='proxy_balancer_call') return reply(valueFor('proxy_balancer',parameters));
  throw new Error('Unexpected fixture RPC');
};
