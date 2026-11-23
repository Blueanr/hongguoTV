// Independent Python reference vectors, synthetic material/session values only.
import fs from 'node:fs';
import crypto from 'node:crypto';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import {deflateSync,inflateSync} from 'node:zlib';
const fixture=JSON.parse(fs.readFileSync(new URL('fixtures/drama-session.json',import.meta.url)));
const context=vm.createContext({Buffer,
  nativeSessionAES:(input,key,iv,encrypt,ecb)=>{
    const cipher=(encrypt?crypto.createCipheriv:crypto.createDecipheriv)(ecb?'aes-128-ecb':'aes-128-cbc',Buffer.from(key,'base64'),ecb?null:Buffer.from(iv,'base64'));
    return Buffer.concat([cipher.update(Buffer.from(input,'base64')),cipher.final()]).toString('base64');
  },
  nativeSessionZip:(input,inflate)=>(inflate?inflateSync:deflateSync)(Buffer.from(input,'base64'),{maxOutputLength:65536}).toString('base64'),
  nativeHash:(name,input)=>crypto.createHash(name).update(Buffer.from(input,'base64')).digest('base64'),nativeNonce:()=>''});
const vendor=fs.readFileSync(new URL('../../server/vendor/hongguo.cjs',import.meta.url),'utf8');
vm.runInContext(fs.readFileSync(new URL('runtime.js',import.meta.url),'utf8')+'\n'+vendor.slice(vendor.indexOf('function md5('),vendor.indexOf('async function signedAppGet'))+'\n'+fs.readFileSync(new URL('signing-v5.js',import.meta.url),'utf8')+'\n'+fs.readFileSync(new URL('drama-session.js',import.meta.url),'utf8'),context);
const m={common:Buffer.from(fixture.common,'hex'),inner:Buffer.from(fixture.inner,'hex')},nonce=Buffer.from(fixture.nonce,'hex');
for(const row of fixture.rows)assert.equal(context.dsEncrypt(Buffer.from(row.plain,'hex'),m,nonce,42).toString('hex'),row.encrypted);
assert.deepEqual(JSON.parse(JSON.stringify(context.dsExchangeResponse(Buffer.from(fixture.response,'hex'),m))),{token:'synthetic-session-token',status:200});
const corrupt=Buffer.from(fixture.response,'hex');corrupt[corrupt.length-1]^=1;
assert.throws(()=>context.dsExchangeResponse(corrupt,m));
assert.throws(()=>context.dsFields(Buffer.from([0x0a,0xff])));
assert.equal(context.dsGorgon('a=1&b=%20',Buffer.from('payload'),1795480000,12345,Buffer.from([4,5])),fixture.gorgon);
console.log('SDI encryption, response validation and Gorgon match independent Python vectors.');
