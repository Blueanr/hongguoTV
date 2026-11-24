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
// Registration IDs can exceed JS's safe integer range. Preserve numeric JSON IDs
// as strings before parsing, matching Swift's exact NSNumber representation.
const registrationText=await response.text();
const identity=JSON.parse(registrationText.replace(/("(?:device_id|install_id)"\s*:\s*)(\d+)(?=\s*[,}])/g,'$1"$2"'));
const device=String(identity.device_id_str||identity.device_id),install=String(identity.install_id_str||identity.install_id);
if(!/^[1-9]\d+$/.test(device)||!/^[1-9]\d+$/.test(install))throw new Error('Device registration rejected');
console.log('Anonymous registration OK');
const values={aid:'8662',app_name:'novelread',version_code:'74532',version_name:'7.4.5.32',update_version_code:'74532',manifest_version_code:'74532',os:'android',ssmix:'a',channel:'update_64',device_platform:'android',device_type:'25053RT47C',device_brand:'Redmi',os_version:'16',os_api:'36',ac:'wifi',language:'zh',host_abi:'arm64-v8a',iid:install,cdid:header.cdid,device_id:device};
async function modelRequest(id,tab,host) {
  const extra={video_id:id,video_id_type:'0',device_level:'1',need_all_video_definition:'1',need_mp4_align:'0',use_os_player:'0',video_platform:'1024',source:'0',from_video_id:''};
   const data=tab?null:zlib.gzipSync(Buffer.from(JSON.stringify({biz_param:{detail_page_version:0,device_level:2,disable_digg_stat:false,disable_video_relate_book:false,need_all_video_definition:true,need_mp4_align:false,use_os_player:false,use_server_dns:false,video_platform:1024},mixed_video_id_map:{1004:[id]},dr_scene:'preload'})));
   const signed=JSON.parse(context.hgSignV5('https://'+host+(tab?'/reading/bookapi/video_tab/multi_video_model/v1/':'/novel/player/multi_video_model/preload/v1'),tab?{...values,...extra}:values,data?.toString('base64')??''));
   const headers={...signed.headers,Accept:tab?'application/json; charset=utf-8':'application/json','User-Agent':tab?'com.phoenix.read/73932 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)':'okhttp/4.12.0'};
  if(tab){for(const key of ['Content-Type','Content-Encoding','x-ss-stub'])delete headers[key];headers['Accept-Language']='zh-CN,zh;q=0.9';}else headers['Content-Encoding']='gzip';
  const reply=await request(signed.url,{method:tab?'GET':'POST',body:data,headers});
  const text=await reply.text();
   console.log(tab?'V5 GET':'V5 POST',host,'HTTP:',reply.status,'bytes:',Buffer.byteLength(text));
  if(!text.trim()){if(reply.headers.has('Retry-After'))throw new Error('Service backoff');return null;}
  const root=JSON.parse(text);if((root.code||root.Code||0)!==0)throw new Error('Model rejected');
  const entries=tab?(root.data?.video_model_data||root.data):(root.data?.['1004']||root.data);
  const raw=entries?.[id]?.video_model;
  if(!raw)throw new Error('Exact episode absent');
  return typeof raw==='string'?JSON.parse(raw):raw;
}
const compatible=model=>(Array.isArray(model.video_list)?model.video_list:Object.values(model.video_list||{})).filter(r=>!/bytevc2|bvc2/i.test([r.codec_type,r.gear_des_key,r.video_meta?.codec_type].join(' ')));
for(const id of [...new Set([episode,String(detail.vid_list[Math.min(53,detail.vid_list.length-1)]),String(detail.vid_list.at(-1))])]){
  let model=await modelRequest(id,false,'reading.snssdk.com');
  if(!model){model=await modelRequest(id,true,'api5-normal-sinfonlineb.fqnovel.com');if(model&&!compatible(model).length)model=await modelRequest(id,false,'api5-normal-sinfonlineb.fqnovel.com');}
  if(!model)throw new Error('Playback routes empty');
  const list=compatible(model);if(!list.length)throw new Error('No compatible renditions');
  console.log('V5 playback OK:',list.length,'compatible renditions');
  let media=list.map(r=>r.main_url||r.play_url||r.backup_url_1).map(url=>/^https?:/.test(url)?url:Buffer.from(url,'base64').toString()).find(url=>/^https?:/.test(url));
  if(!media)throw new Error('No directly decodable CDN URL for probe');
  const range=await request(media,{headers:{Range:'bytes=0-1023'}}),bytes=Buffer.from(await range.arrayBuffer());
  if(range.status!==206||bytes.subarray(4,8).toString()!=='ftyp')throw new Error('Media range invalid');
  console.log('Media CDN MP4 range OK');
}
