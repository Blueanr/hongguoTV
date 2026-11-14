// SPDX-License-Identifier: GPL-3.0-only
// SM3 is not supplied by CommonCrypto. Other hashes are delegated to the OS.
function sm3Bytes(input) {
  const n = input.length, size = Math.ceil((n + 9) / 64) * 64;
  const b = Buffer.alloc(size); Buffer.from(input).copy(b); b[n] = 128;
  b.writeUInt32BE(Math.floor(n / 0x20000000), size - 8); b.writeUInt32BE((n * 8) >>> 0, size - 4);
  const v = [0x7380166f,0x4914b2b9,0x172442d7,0xda8a0600,0xa96f30bc,0x163138aa,0xe38dee4d,0xb0fb0e4e];
  const rot = (x,n) => (x << (n & 31)) | (x >>> ((32-n) & 31));
  const p0 = x => x ^ rot(x,9) ^ rot(x,17), p1 = x => x ^ rot(x,15) ^ rot(x,23);
  for(let off=0;off<size;off+=64) {
    const w = new Int32Array(68);
    for(let i=0;i<16;i++) w[i]=b.readInt32BE(off+i*4);
    for(let i=16;i<68;i++) w[i]=p1(w[i-16]^w[i-9]^rot(w[i-3],15))^rot(w[i-13],7)^w[i-6];
    let [a,c,d,e,f,g,h,k]=v;
    for(let j=0;j<64;j++) {
      const ss1=rot((rot(a,12)+f+rot(j<16?0x79cc4519:0x7a879d8a,j))|0,7), ss2=ss1^rot(a,12);
      const ff=j<16?a^c^d:(a&c)|(a&d)|(c&d), gg=j<16?f^g^h:(f&g)|(~f&h);
      const t1=(ff+e+ss2+(w[j]^w[j+4]))|0, t2=(gg+k+ss1+w[j])|0;
      e=d;d=rot(c,9);c=a;a=t1;k=h;h=rot(g,19);g=f;f=p0(t2);
    }
    [a,c,d,e,f,g,h,k].forEach((x,i)=>v[i]^=x);
  }
  const out=Buffer.alloc(32);v.forEach((x,i)=>out.writeUInt32BE(x>>>0,i*4));return out;
}
const crypto = {
  createHash(name) {
    const chunks=[];
    return { update(value) { chunks.push(Buffer.from(value));return this; }, digest(encoding) {
      const data=Buffer.concat(chunks);
      const out=name==='sm3'?sm3Bytes(data):Buffer.from(nativeHash(name,data.toString('base64')),'base64');
      return encoding?out.toString(encoding):out;
    }};
  }
};
const processStarted=Date.now();
const processNonce=nativeNonce();
function encode(values) {
  return Object.entries(values).map(([k,v])=>[k,String(v)].map(x=>encodeURIComponent(x).replace(/[!'()*]/g,c=>'%'+c.charCodeAt(0).toString(16).toUpperCase())).join('=')).join('&');
}
function sign(base, values, body64, playback) {
  Object.assign(DEVICE,values);
  const body=body64===null?null:Buffer.from(body64,'base64');
  const now=Date.now(), ts=Math.floor(now/1000);
  for(let i=0;i<128;i++) {
    const ticket=now+i;
    const query=encode({...values,...(playback?{}:{ts:String(ts)}),_rticket:String(ticket)}), url=base+'?'+query;
    if(branchOf(url,body,ts)!==0)continue;
    const headers={
      'User-Agent': playback?'com.phoenix.read/71532 (Linux; U; Android 9; SM-N9860; Build/PQ3A.190705.10241111;tt-ok/3.12.13.20)':'com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)',
      Accept:'application/json; charset=utf-8,application/x-protobuf',
      'x-ss-req-ticket':String(ticket),'sdk-version':'2','x-xs-from-web':'0','x-khronos':String(ts),
      'x-ladon':be32(ts).toString('base64'),'x-argus':le32(ts).toString('base64'),
      'x-gorgon':xGorgon(query,body,ts,Math.floor(Math.random()*65536)),
      'x-helios':helios(ts),'x-medusa':buildMedusa(url,body,ts)
    };
    if(!playback) Object.assign(headers,{'x-tt-request-tag':'t=0;n=0','passport-sdk-version':'50561','x-tt-dt':''});
    if(body) Object.assign(headers,{'Content-Type':'application/json; charset=utf-8','x-ss-stub':md5(body)});
    return JSON.stringify({url,headers});
  }
  throw new Error('无法生成请求签名');
}
globalThis.hgSM3 = value => sm3Bytes(Buffer.from(value)).toString('hex');
