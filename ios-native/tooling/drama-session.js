// SPDX-License-Identifier: GPL-3.0-only
// SDI/session protocol port of jackotom/hongguo-drama scripts/sdk-playback.
// Native bridges supply cryptography/compression; no Python, ELF execution or helper server.
function dsProto(fields) {
  return Buffer.concat(fields.map(([tag,value]) => {
    if (typeof value === 'number' || typeof value === 'bigint') return Buffer.concat([varint(BigInt(tag)<<3n),varint(BigInt(value))]);
    if (typeof value === 'string') value=Buffer.from(value);
    return value.length ? Buffer.concat([varint((BigInt(tag)<<3n)|2n),varint(value.length),value]) : Buffer.alloc(0);
  }));
}
function dsFields(data) {
  let at=0; const fields=[];
  function integer() {
    let n=0n;
    for(let i=0;i<10;i++) {
      if(at>=data.length)throw Error('Truncated protobuf');
      const b=data[at++]; if(i===9&&b>1)throw Error('Overflow protobuf');
      n|=BigInt(b&127)<<BigInt(7*i); if(b<128)return n;
    }
    throw Error('Invalid protobuf');
  }
  while(at<data.length) {
    const tag=integer(), kind=Number(tag&7n), field=Number(tag>>3n);
    if(field<1||field>=2**29||fields.length>=512)throw Error('Invalid protobuf field');
    let value;
    if(kind===0)value=integer();
    else {
      const size=kind===2?Number(integer()):kind===5?4:kind===1?8:-1;
      if(size<0||size>data.length-at)throw Error('Invalid protobuf length');
      value=data.subarray(at,at+size);at+=size;
    }
    fields.push([field,kind,value]);
  }
  return fields;
}
function dsRC4(data,key) {
  const s=Array.from({length:256},(_,i)=>i);let j=0,i=0;
  for(i=0;i<256;i++){j=(j+s[i]+key[i%key.length])&255;[s[i],s[j]]=[s[j],s[i]];}
  i=0;j=0;return Buffer.from(data.map(b=>{i=(i+1)&255;j=(j+s[i])&255;[s[i],s[j]]=[s[j],s[i]];return b^s[(s[i]+s[j])&255];}));
}
function dsAES(data,key,iv,encrypt,ecb=false) {
  const result=nativeSessionAES(data.toString('base64'),key.toString('base64'),iv.toString('base64'),encrypt,ecb);
  if(!result)throw Error('Invalid AES frame');return Buffer.from(result,'base64');
}
function dsZip(data,inflate=false) {
  const result=nativeSessionZip(data.toString('base64'),inflate);
  if(!result)throw Error('Invalid compression frame');return Buffer.from(result,'base64');
}
function dsMaterials(configuration,image) {
  const config=Buffer.from(configuration,'base64'),raw=Buffer.from(config.toString(),'base64'),sdk=Buffer.from(image,'base64');
  if(config.length!==304||sdk.length!==4501136)throw Error('Invalid SDK assets');
  const nonce=raw.subarray(0,4),app=Buffer.from('8662');
  const plain=dsAES(raw.subarray(4),v5Md5(Buffer.concat([app,nonce,app])),Buffer.alloc(16),false,true);
  const head=plain.subarray(0,4),tail=plain.subarray(-4);
  const mask=Buffer.concat([nonce,head,tail]).reduce((a,b)=>a^b,0);
  const key=crypto.createHash('sha1').update(Buffer.concat([head,app,nonce])).digest();
  const decoded=Buffer.from(dsRC4(plain.subarray(4,-4),key)).reverse().map(b=>b^mask);
  const keys={};
  for(const [field,kind,value] of dsFields(decoded))if(field===8&&kind===2){
    const pair=dsFields(value),name=pair.find(x=>x[0]===1)?.[2]?.toString(),encoded=pair.find(x=>x[0]===2)?.[2];
    if(!['sign_key','common_key'].includes(name)||keys[name])throw Error('Invalid material entry');
    keys[name]=Buffer.from(encoded.toString(),'base64');if(keys[name].length!==32)throw Error('Invalid material key');
  }
  if(!keys.sign_key||!keys.common_key)throw Error('Missing materials');
  return {sign:keys.sign_key,common:keys.common_key,frame:sdk.subarray(0x665f0,0x66600),
    tables:sdk.subarray(0xffcf9,0x1000f9),inner:Buffer.concat([sdk.subarray(0x66690,0x66698),bxor(sdk.subarray(0x9d08c,0x9d094),sdk.subarray(0x9d118,0x9d120))]),
    unavailable:sdk.subarray(0x66c44,0x66c4c).toString()};
}
function dsXtea(data,key,nonce,decrypt=false) {
  const keys=[0,4,8,12].map(i=>key.readUInt32BE(i)),cycles=32+8*(nonce.readUInt32LE(0)%5),out=[];
  let previous=Buffer.concat([nonce,le32(0x20200427)]);
  for(let offset=0;offset<data.length;offset+=8) {
    const source=data.subarray(offset,offset+8),block=decrypt?source:bxor(source,previous),words=[block.readUInt32BE(0),block.readUInt32BE(4)];
    for(let n=0;n<cycles*2;n++) {
      const step=decrypt?cycles*2-1-n:n,target=step&1,total=u32(Math.floor((step+1)/2)*0x9e3779b9),other=words[1-target];
      const mix=u32(u32(((other<<4)^(other>>>5))+other)^u32(total+keys[(total>>>(11*target))&3]));
      words[target]=u32(words[target]+(decrypt?-mix:mix));
    }
    const transformed=Buffer.concat(words.map(be32));out.push(decrypt?bxor(transformed,previous):transformed);previous=decrypt?source:transformed;
  }
  return Buffer.concat(out);
}
function dsEncrypt(plaintext,m,nonce,entropy) {
  const compressed=dsZip(plaintext);compressed[0]=0x78;compressed[1]=1;
  const container=Buffer.concat([le32(plaintext.length),compressed]),extra=(8-container.length%8)%8,position=1+((extra+3)%4);
  const frame=Buffer.alloc(container.length+8+extra);frame[0]=(entropy&248)|extra;container.copy(frame,position);
  let crc=0;for(const b of container){crc^=b<<8;for(let i=0;i<8;i++)crc=((crc<<1)^((crc&32768)?0x1021:0))&65535;}
  frame.writeUInt16BE(crc,position>=3?1:position+container.length);
  const encrypted=dsXtea(frame,m.inner,nonce);
  return dsAES(Buffer.concat([Buffer.from([encrypted[0]^3]),encrypted,nonce]),m.common.subarray(0,16),m.common.subarray(16),true);
}
function dsExchangeResponse(packet,m) {
  const fields=dsFields(packet),get=n=>fields.filter(f=>f[0]===n);
  if(get(1).length!==1||get(1)[0][2]!==BigInt(0x20120312)*2n||get(2).length!==1||get(2)[0][2]!==2n||get(6).length!==1||get(6)[0][1]!==2)throw Error('SDK exchange rejected');
  const wrapped=dsAES(get(6)[0][2],m.common.subarray(0,16),m.common.subarray(16),false);
  if(wrapped.length<13||(wrapped.length-5)%8||(wrapped[0]^wrapped[1])!==3)throw Error('Invalid exchange frame');
  const frame=dsXtea(wrapped.subarray(1,-4),m.inner,wrapped.subarray(-4),true),extra=frame[0]&7,position=1+(extra+3)%4;
  const container=frame.subarray(position,position+frame.length-8-extra);
  if(container.length<4||container.readUInt32LE(0)>65536)throw Error('Invalid response size');
  const plain=dsZip(container.subarray(4),true);if(plain.length!==container.readUInt32LE(0))throw Error('Invalid response length');
  const result=dsFields(plain).filter(f=>[1,2].includes(f[0]));
  if(result.length!==2||result.filter(f=>f[0]===1&&f[1]===2).length!==1||result.filter(f=>f[0]===2&&f[1]===0).length!==1)throw Error('Invalid SDK session');
  const token=result.find(f=>f[0]===1)[2].toString(),status=Number(result.find(f=>f[0]===2)[2])/2;
  if(!/^[\x21-\x7e]{1,256}$/.test(token)||![200,202].includes(status))throw Error('SDK session rejected');
  return {token,status};
}
function dsDevicePayload(p,marker,token) {
  const fields={};
  for(const n of [1,19,20,23,28,31,32,38,39,50,53,93,94,95,96,109,110,111,115,135,2000,2001])fields[n]=marker;
  for(const n of [13,29,30,36,37,41,42,43,49,51,52,56,57,58,59,60,61,62,63,64,66,67,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,97,98,99,100,101,102,103,104,105,106,113,114,116,117,118])fields[n]=1999997;
  for(const [n,k] of [[2,'device_brand'],[3,'device_type'],[6,'os_version'],[7,'resolution'],[9,'rom_version']])fields[n]=p[k]||marker;
  fields[5]='Android';fields[12]='Asia/Shanghai,8';for(const [n,k] of [[8,'dpi'],[48,'os_api']])fields[n]=/^\d+$/.test(p[k])?Number(p[k])*2:1999997;
  return dsProto([[1,dsProto(Object.entries(fields).map(([n,v])=>[Number(n),v]))],...(token?[[2,token]]:[]),[3,'android'],[4,'v04.10.03-ml-android'],[5,0x040a0300*2],[6,p.aid],[7,p.version_name],[8,p.device_id],[11,1999997],[16,1999997],[17,marker]]);
}
function dsDeviceProof(p) {
  const fields=dsFields(deviceProto(p.device_id)),replacements={3:p.aid,4:p.device_id,5:p.cdid,22:p.os_version,30:p.device_type,31:p.device_brand,32:p.device_type,33:p.device_type,34:p.device_brand,35:p.device_brand,36:p.device_brand};
  return Buffer.concat(fields.map(([n,k,v])=>k===5?Buffer.concat([varint((BigInt(n)<<3n)|5n),v]):dsProto([[n,replacements[n]??v]])));
}
function dsGorgon(query,body,ts,nonce,flags) {
  const input=Buffer.concat([v5Md5(Buffer.from(query)).subarray(0,4),v5Md5(body).subarray(0,4),Buffer.alloc(4),le32(0x040a0300),be32(ts)]);
  const out=dsRC4(input,Buffer.from([0x4a,flags[0],0x16,nonce>>>8,0x47,0x6c,flags[1],nonce&255]));
  for(let i=0;i<20;i++){const v=((out[i]>>>4)|(out[i]<<4))&255,next=out[(i+1)%20];out[i]=(~(reverseBits(next^v)^20))&255;}
  return Buffer.concat([Buffer.from([0x84,4,nonce&255,nonce>>>8]),flags,out]).toString('hex');
}
function dsSign(p,cookies,values,body,now,m,token,previous,bootstrap,random=Math.random) {
  const ts=Math.floor(now/1000),bodyHash=v5Md5(body);let query,qh;
  // Use the independently SDK-verified selector 12 by changing only _rticket.
  for(let i=0;i<1024;i++){query=v5Encode({...values,_rticket:String(now+i)});qh=sm3(Buffer.from(query));if(v5Nibble(qh,bodyHash,ts)===12)break;if(i===1023)throw Error('SDK digest selection failed');}
  const proof=v5HashF13(qh,bodyHash,ts),prefix=Buffer.concat([le32(bootstrap?2:0x0504),le32(0)]),r32=()=>Math.floor(random()*2**32);
  const env=dsProto([[1,2],[6,'v04.10.03.04-bugfix'],[7,2],[8,p.channel||''],[12,dsDeviceProof(p)],[14,p.version_name],[15,4228],[19,now*2]]);
  const message=dsProto([[1,m.frame],[2,10],[3,r32()*2],[4,'8662'],[5,p.device_id],[6,'646637794'],[7,p.version_name],[8,'v04.10.03-ml-android'],[9,0x040a0300*2],[10,prefix],[12,ts*2],[13,proof],[14,qh.subarray(0,6)],[15,dsProto([[1,2],[2,1388734],[3,1388734],[5,1388734]])],[16,token||''],[17,ts*2],[20,'none'],[21,738],[23,env],[24,JSON.stringify({cmr:16777216,cmr2:16777216,vpn:0,kd:0,dyn:'',do:0,tk:!!token})]]);
  const nonce=r32(),frameNonce=r32(),[hash,mask]=keyHash(m.sign,nonce),mixed=Buffer.concat([prefix,xmxor(message,hash)]).reverse();
  for(let i=0;i<mixed.length;i++)mixed[i]^=mask[(~i)&3];
  const packed=Buffer.concat([Buffer.from([0xca]),le32(frameNonce),le32(0x18000001|((qh[0]&63)<<14)|((proof[0]&63)<<8)),mixed,Buffer.from([nonce>>>16,nonce>>>24])]);
  const carrier=new V5Carrier(v5Md5(m.sign.subarray(0,16)),ts);carrier.box=m.tables.subarray((ts&3)*256,((ts&3)+1)*256);
  // Constructor key expansion must use the same verified SDK tables.
  if(!m.tables.equals(V5_SBOX))throw Error('Unsupported SDK carrier tables');
  const medusa=Buffer.concat([le32(ts^5),xorBytes(m.frame,le32(ts)),Buffer.from([nonce,nonce>>>8,0,1]),carrier.encrypt(packed,v5Md5(m.sign.subarray(16)))]).toString('base64');
  let checksum=0n;for(const b of Buffer.from('646637794')){checksum^=BigInt(b);for(let i=0;i<8;i++)checksum=(checksum>>1n)^((checksum&1n)?0x95ac9329ac4bc9b5n:0n);}
  const allocation=((BigInt(r32())<<32n)|BigInt(r32()))&~15n,mix=allocation^checksum^BigInt(ts),rot=BigInt.asUintN(64,(mix<<4n)|(mix>>60n));
  const ladon=u32(previous^Number(rot&0xffffffffn));
  const selected={install_id:p.iid};for(const name of ['odin_tt','ttreq','store-region'])if(cookies[name]){if(!/^[\x21-\x7e]{1,8192}$/.test(cookies[name])||cookies[name].includes(';'))throw Error('Invalid device cookie');selected[name]=cookies[name];}selected['store-region-src']='did';
  const headers={'Content-Type':'application/octet-stream',Accept:'*/*','X-TT-Request-Tag':'t=0;n=0','X-SS-DP':'8662','X-Khronos':String(ts),
    'X-Argus':le32(ts).toString('base64'),'X-Ladon':be32(ladon).toString('base64'),'X-Gorgon':dsGorgon(query,body,ts,r32()&65535,prefix.subarray(0,2)),
    'X-Helios':v5Helios(ts,random),'X-Medusa':medusa,'X-SS-STUB':bodyHash.toString('hex').toUpperCase(),'X-VC-Bdturing-SDK-Version':'4.0.3.cn',
    'User-Agent':`com.phoenix.read/74332 (Linux; U; Android ${p.os_version}; zh_CN; ${p.device_type}; Cronet/TTNetVersion:8d40f833_2026-03-03)`,Cookie:Object.entries(selected).map(([k,v])=>k+'='+v).join('; ')};
  const origin=bootstrap?'https://mssdk.zijieapi.com/sdi/get_token':'https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/player/v1';
  if(!bootstrap)Object.assign(headers,{'Content-Type':'application/json; charset=utf-8','Content-Encoding':'gzip',Accept:'application/json','X-Reading-Request':`${now}-${100000000+r32()%900000000}`,'X-TT-Store-Region':cookies['store-region']||'cn','X-TT-Store-Region-Src':'did','X-SS-REQ-TICKET':String(now)});
  return {url:origin+'?'+query,headers,body:body.toString('base64'),ladon};
}
let dsLoaded;
globalThis.hgDramaMaterials=(config,image)=>{dsLoaded=dsMaterials(config,image);return true;};
globalThis.hgDramaResponse=packet=>JSON.stringify(dsExchangeResponse(Buffer.from(packet,'base64'),dsLoaded));
globalThis.hgDramaRequest=(profile,cookies,id,token,previous,now,body64)=>{
  if(!dsLoaded)throw Error('SDK materials missing');
  const p={...profile,version_name:'7.4.3.32',version_code:'74332',manifest_version_code:'74332',update_version_code:'74332',device_platform:'android',os:'android'};
  const bootstrap=!id,values={};let body;
  if(bootstrap){
    Object.assign(values,{lc_id:'646637794',platform:'android',device_platform:'android',sdk_ver:'v04.10.03-ml-android',sdk_ver_code:String(0x040a0300),app_ver:p.version_name,version_code:p.version_code,aid:p.aid,sdkid:'',subaid:'',iid:p.iid,did:p.device_id,bd_did:'',client_type:'inhouse',region_type:'ml',mode:'2',full_update_version_code:p.update_version_code});
    for(const k of 'os ssmix _rticket cdid channel app_name version_name manifest_version_code update_version_code resolution dpi device_type device_brand language os_api os_version ac host_abi dragon_device_type pv_player compliance_status need_personal_recommend player_so_load is_android_pad_screen rom_version device_id klink_egdi'.split(' '))values[k]=k==='_rticket'?String(now):k==='need_personal_recommend'?'1':p[k]||'';
    const encrypted=dsEncrypt(dsDevicePayload(p,dsLoaded.unavailable,token),dsLoaded,le32(Math.floor(Math.random()*2**32)),Math.floor(Math.random()*256));
    body=dsProto([[1,0x20200422*2],[2,2],[3,2],[4,encrypted],[5,now*2]]);
  }else{
    if(!/^[1-9][0-9]{7,23}$/.test(id)||!/^[\x21-\x7e]{1,256}$/.test(token))throw Error('Invalid playback session');
    p._rticket=String(now);
    for(const k of 'device_platform os ssmix _rticket cdid channel aid app_name version_code version_name manifest_version_code update_version_code resolution dpi device_type device_brand language os_api os_version ac host_abi dragon_device_type pv_player compliance_status need_personal_recommend player_so_load is_android_pad_screen rom_version device_id iid klink_egdi'.split(' '))if(p[k])values[k]=p[k];
    body=Buffer.from(body64,'base64');
  }
  return JSON.stringify(dsSign(p,cookies,values,body,now,dsLoaded,token,previous,bootstrap));
};
