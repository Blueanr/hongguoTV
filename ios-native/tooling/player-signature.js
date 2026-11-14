// SPDX-License-Identifier: GPL-3.0-only
// Port of kotlin-tv/core/PlayerSignature.kt. Independent Go fixture parity is checked by test.mjs.
// Argus/Simon origin: tr4cex/TikTok-Encryption (MIT); see kotlin-tv/NOTICE.md.
globalThis.hgPlayerHeaders = function(query, body64, deviceId, now, nonce64) {
  const body=body64===null?null:Buffer.from(body64,'base64'), nonce=Buffer.from(nonce64,'base64');
  const ts=Math.floor(now/1000), digest=b=>crypto.createHash('md5').update(b).digest();
  const hex=s=>Buffer.from(s,'hex'), u=x=>BigInt.asUintN(64,x);
  const rr=(x,n)=>u((x>>BigInt(n))|(x<<BigInt(64-n))), rl=(x,n)=>rr(x,64-n);
  const le=x=>{const b=Buffer.alloc(8);b.writeBigUInt64LE(u(x));return b;};
  const pad=b=>Buffer.concat([b,Buffer.alloc(16-b.length%16,16-b.length%16)]);
  function fields(rows) {
    return Buffer.concat(rows.map(([tag,value])=> {
      if(typeof value==='number'||typeof value==='bigint')return Buffer.concat([varint(BigInt(tag)<<3n),varint(value)]);
      const b=Buffer.isBuffer(value)?value:Buffer.from(value);
      return Buffer.concat([varint((BigInt(tag)<<3n)|2n),varint(b.length),b]);
    }));
  }
  const input=Buffer.concat([digest(query).subarray(0,4),body?digest(body).subarray(0,4):Buffer.alloc(4),Buffer.alloc(4),hex('00060b1c'),be32(ts)]);
  const gkey=hex('44b9b9d9a4aef9fca493aa757ca3c2c4a496938f');
  for(let i=0;i<input.length;i++)input[i]^=gkey[i];
  for(let i=0;i<input.length;i++)input[i]=reverseBits((((input[i]<<4)|(input[i]>>>4))&255)^input[(i+1)%input.length])^0xeb;
  function ladon() {
    const salt=nonce.subarray(2,6), ascii=Buffer.from(digest(Buffer.concat([salt,Buffer.from('8662')])).toString('hex'));
    const queue=[ascii.readBigUInt64LE(16),ascii.readBigUInt64LE(24)],keys=[];
    let left=ascii.readBigUInt64LE(0),right=ascii.readBigUInt64LE(8);
    for(let i=0;i<34;i++){keys.push(left);const next=u(rr(right,8)+left)^BigInt(i);queue.push(next);left=next^rl(left,3);right=queue.shift();}
    const data=pad(Buffer.from(`${ts}-1611921764-8662`)),out=[salt];
    for(let at=0;at<data.length;at+=16){let a=data.readBigUInt64LE(at),b=data.readBigUInt64LE(at+8);for(const k of keys){b=k^u(a+rr(b,8));a=b^rl(a,3);}out.push(le(a),le(b));}
    return Buffer.concat(out).toString('base64');
  }
  function argus() {
    const nested=fields([[1,1],[2,1],[3,1],[7,3348294860]]),environment=fields([[1,'25053RT47C'],[2,'16'],[3,'update_64'],[4,2147483648]]);
    const message=fields([[1,0x40401252],[2,2],[3,nonce.readUInt32LE(6)&0x7fffffff],[4,'8662'],[5,deviceId],[6,'1611921764'],[7,'7.3.5.32'],[8,'v04.07.01-ml-android'],[9,135135744],[10,Buffer.alloc(8)],[11,0],[12,ts*2],[13,sm3(body?digest(body):Buffer.alloc(16)).subarray(0,6)],[14,sm3(Buffer.from(query)).subarray(0,6)],[15,nested],[16,Buffer.alloc(0)],[20,'none'],[21,738],[23,environment],[25,2]]);
    const secret=hex('ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c'),derived=sm3(Buffer.concat([secret,hex('3ccc567b'),secret]));
    const keys=Array.from({length:4},(_,i)=>derived.readBigUInt64LE(i*8));
    for(let i=4;i<72;i++){const x=rr(keys[i-1],3)^keys[i-3];keys.push(u(~keys[i-4])^x^rr(x,1)^((0x3dc94c3a046d678bn>>BigInt((i-4)%62))&1n)^3n);}
    const blocks=pad(message),out=[];
    for(let at=0;at<blocks.length;at+=16){let a=blocks.readBigUInt64LE(at),b=blocks.readBigUInt64LE(at+8);for(const k of keys){const next=a^(rl(b,1)&rl(b,8))^rl(b,2)^k;a=b;b=next;}out.push(le(a),le(b));}
    const mask=hex('d04ffdffd04ffdff'),scrambled=Buffer.concat(out);for(let i=0;i<scrambled.length;i++)scrambled[i]^=mask[i%8];
    const container=Buffer.concat([hex('a6e783ee7001100918'),Buffer.concat([mask,scrambled]).reverse(),hex('567b')]);
    const encrypted=Buffer.from(nativeAES(container.toString('base64'),digest(secret.subarray(0,16)).toString('base64'),digest(secret.subarray(16,32)).toString('base64')),'base64');
    return Buffer.concat([hex('3ccc'),encrypted]).toString('base64');
  }
  const headers={'X-Gorgon':Buffer.concat([hex('8404401c0000'),input]).toString('hex'),'X-Khronos':String(ts),'X-SS-Req-Ticket':String(now),'X-Argus':argus(),'X-Ladon':ladon()};
  if(body)headers['X-SS-STUB']=digest(body).toString('hex').toUpperCase();
  return JSON.stringify(headers);
};
