// Optional live diagnostic. Logs only stages/counts, never account credentials or media URLs.
import crypto from 'node:crypto';
import fs from 'node:fs';
import vm from 'node:vm';
import zlib from 'node:zlib';
const TIMEOUT_MS = 30000;
const SITE = 'https://hongguoduanju.com';
const context = vm.createContext({
  nativeHash: (name,input) => crypto.createHash(name).update(Buffer.from(input,'base64')).digest('base64'),
  nativeNonce: () => crypto.randomBytes(18).toString('base64url'),
  nativeAES: (input,key,iv) => {
    const cipher = crypto.createCipheriv('aes-128-cbc',Buffer.from(key,'base64'),Buffer.from(iv,'base64'));
    return Buffer.concat([cipher.update(Buffer.from(input,'base64')),cipher.final()]).toString('base64');
  },
});
vm.runInContext(fs.readFileSync(new URL('../Resources/signer.js',import.meta.url),'utf8'),context);
async function request(url,options={}) {
  const response = await fetch(url,{...options,signal:AbortSignal.timeout(TIMEOUT_MS)});
  if(!response.ok)throw new Error(`HTTP ${response.status}`);
  return response;
}
function router(html) {
  const marker=html.indexOf('_ROUTER_DATA'),start=html.indexOf('{',marker);
  if(marker<0||start<0)throw new Error('Missing router data');
  let depth=0,quote=false,escape=false;
  for(let i=start;i<html.length;i++){
    const ch=html[i];if(quote){if(escape)escape=false;else if(ch==='\\')escape=true;else if(ch==='"')quote=false;continue;}
    if(ch==='"')quote=true;else if(ch==='{'||ch==='[')depth++;else if(ch==='}'||ch===']'){if(--depth===0)return JSON.parse(html.slice(start,i+1)).loaderData;}
  }
  throw new Error('Incomplete router');
}
const homepage=router(await (await request(SITE+'/category?tab=1&sort_type=1',{headers:{'User-Agent':'Mozilla/5.0'}})).text());
const category=homepage.category_page||homepage['category_$'];
const rows=category.recommendList||category.categoryData?.recommendList;
if(!rows?.length)throw new Error('Empty catalog');
const id=(rows[0].video_data||rows[0]).series_id;
console.log('Catalog OK:',rows.length,'items');
const detail=router(await (await request(SITE+'/detail?series_id='+id,{headers:{'User-Agent':'Mozilla/5.0'}})).text()).detail_page.seriesDetail;
const episode=String(detail.vid_list[0]);
console.log('Detail OK:',detail.vid_list.length,'episodes');
const header={display_name:'红果免费短剧',update_version_code:73932,manifest_version_code:73932,app_version_minor:'7.3.9.32',aid:8662,channel:'update_64',package:'com.phoenix.read',app_version:'7.3.9.32',version_code:73932,sdk_version:'3.7.0-rc.34-fanqie-xiaoshuo',sdk_target_version:29,git_hash:'3a88f4e',os:'Android',os_version:'16',os_api:36,device_model:'25053RT47C',device_brand:'Redmi',device_manufacturer:'Redmi',cpu_abi:'arm64-v8a',release_build:'b5e187f',density_dpi:520,display_density:'mdpi',resolution:'1280x2772',language:'zh',timezone:8,access:'wifi',not_request_sender:0,carrier:'CHINA MOBILE',mcc_mnc:'46000',rom:'eng.root.20231116.160340',rom_version:'W528JS release-keys',cdid:crypto.randomUUID(),sig_hash:'56a962410c494bbaf0b58dba20cae56f',openudid:crypto.randomBytes(8).toString('hex'),clientudid:crypto.randomUUID(),ipv6_list:[],region:'CN',tz_name:'Asia/Shanghai',tz_offset:28800,sim_region:'cn',sim_serial_number:[],oaid_may_support:false,req_id:crypto.randomUUID(),device_platform:'android',custom:{account_region_src:'fallback',host_bit:64,account_region:'cn',dragon_device_type:'phone'},pre_installed_channel:'',apk_first_install_time:Date.now(),is_system_app:0,sdk_flavor:'china',guest_mode:0};
const hash=(name,data)=>crypto.createHash(name).update(data).digest();
const salt=Buffer.from('4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58','hex');
const seed=crypto.randomBytes(32),derived=hash('sha512',Buffer.concat([hash('sha512',seed),salt]));
const compressed=zlib.gzipSync(Buffer.from(JSON.stringify({magic_tag:'ss_app_log',header,_gen_time:Date.now()})));
const cipher=crypto.createCipheriv('aes-128-cbc',derived.subarray(0,16),derived.subarray(16,32));
const body=Buffer.concat([Buffer.from('746305100000','hex'),seed,cipher.update(Buffer.concat([hash('sha512',compressed),compressed])),cipher.final()]);
const response=await request('https://log5-applog-lf.fqnovel.com/service/2/device_register/?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1',{method:'POST',body,headers:{'User-Agent':'com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)','Content-Type':'application/octet-stream;tt-data=a','log-encode-type':'gzip','x-ss-dp':'8662','x-ss-req-ticket':String(Date.now()),'x-vc-bdturing-sdk-version':'4.0.3.cn',lc:'101','sdk-version':'2','passport-sdk-version':'5051452','x-neptune':'-8|50:51:59:30:40:47:49:39','x-ss-stub':hash('md5',body).toString('hex').toUpperCase()}});
const identity=await response.json();
const device=String(identity.device_id_str||identity.device_id),install=String(identity.install_id_str||identity.install_id);
if(!/^[1-9]\d+$/.test(device)||!/^[1-9]\d+$/.test(install))throw new Error('Device registration rejected');
console.log('Anonymous registration OK');
const now=Date.now(),values={ac:'wifi',channel:'update_64',aid:'8662',app_name:'novelread',version_code:'73532',version_name:'7.3.5.32',device_platform:'android',os:'android',ssmix:'a',device_type:'25053RT47C',device_brand:'Redmi',language:'zh',os_api:'36',os_version:'16',manifest_version_code:'73532',resolution:'1280*2772',dpi:'520',update_version_code:'73532',device_id:device,iid:install,_rticket:String(now)};
const enc=s=>encodeURIComponent(s).replace(/[!'()*]/g,c=>'%'+c.charCodeAt(0).toString(16).toUpperCase());
const query=Object.keys(values).sort().map(k=>enc(k)+'='+enc(values[k])).join('&');
const payload=Buffer.from(JSON.stringify({biz_param:{need_all_video_definition:true,video_platform:3},content_type:1,video_id:episode}));
const headers=JSON.parse(context.hgPlayerHeaders(query,payload.toString('base64'),device,now,crypto.randomBytes(11).toString('base64')));
const reply=await request('https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_model/v1/?'+query,{method:'POST',body:payload,headers:{...headers,'User-Agent':'com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)','Content-Type':'application/json; charset=utf-8',Accept:'application/json','Sdk-Version':'2','X-XS-From-Web':'0'}});
let text=await reply.text();
let result=text?JSON.parse(text):{};
let model=result.data?.video_model||result.data;
if(!model) {
  console.log('Single-video response unavailable; checking bounded batch fallback');
  const profile={...values,version_code:'73932',version_name:'7.3.9.32',manifest_version_code:'73932',update_version_code:'73932',pv_player:'73932',host_abi:'arm64-v8a',dragon_device_type:'phone',compliance_status:'0',need_personal_recommend:'1',player_so_load:'1',is_android_pad_screen:'0',cdid:header.cdid};
  delete profile._rticket;
  const cookies=response.headers.getSetCookie().map(s=>s.split(';')[0]).join('; ');
  for(const post of [false,true]) {
    const extra={video_id:episode,video_id_type:'0',device_level:'1',need_all_video_definition:'1',need_mp4_align:'0',use_os_player:'0',video_platform:'1024',source:'0',from_video_id:''};
    const data=post?Buffer.from(JSON.stringify({biz_param:{detail_page_version:0,device_level:1,disable_digg_stat:false,need_all_video_definition:true,need_mp4_align:false,use_os_player:false,use_server_dns:false,video_platform:1024},mixed_video_id_map:{1004:[episode]}})):null;
    const signed=JSON.parse(context.hgSign('https://api5-normal-sinfonlineb.fqnovel.com'+(post?'/novel/player/multi_video_model/v1/':'/reading/bookapi/video_tab/multi_video_model/v1/'),post?profile:{...profile,...extra},data?.toString('base64')??null,true));
    const response=await request(signed.url,{method:post?'POST':'GET',body:data,headers:{...signed.headers,Cookie:cookies}});
    text=await response.text();console.log(post?'POST fallback':'GET fallback','response bytes:',text.length);
    if(!text)continue;
    result=JSON.parse(text);const entries=result.data?.video_model_data||result.data;
    model=entries?.[episode]?.video_model||entries?.video_model;
    if(model)break;
  }
}
if(!model)throw new Error('All playback routes returned no model');
if(typeof model==='string'){try{model=JSON.parse(model);}catch{model=JSON.parse(Buffer.from(model,'base64').toString());}}
const list=Array.isArray(model.video_list)?model.video_list:Object.values(model.video_list||{});
if(!list.length)throw new Error('Playback model has no renditions');
console.log('Playback model OK:',list.length,'renditions');
const media=list.find(r=>/^https?:/.test(r.main_url));
if(media){const range=await request(media.main_url,{headers:{Range:'bytes=0-1023'}});const bytes=Buffer.from(await range.arrayBuffer());if(range.status!==206||bytes.subarray(4,8).toString()!=='ftyp')throw new Error('Media range is invalid');console.log('Media CDN MP4 range OK');}
