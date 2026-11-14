import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import vm from 'node:vm';
const context = vm.createContext({
  nativeHash: (name,value) => crypto.createHash(name).update(Buffer.from(value,'base64')).digest('base64'),
  nativeNonce: () => 'test-process-nonce',
  nativeAES: (input,key,iv) => {
    const cipher=crypto.createCipheriv('aes-128-cbc',Buffer.from(key,'base64'),Buffer.from(iv,'base64'));
    return Buffer.concat([cipher.update(Buffer.from(input,'base64')),cipher.final()]).toString('base64');
  },
});
vm.runInContext(fs.readFileSync(new URL('../Resources/signer.js',import.meta.url),'utf8'),context);
for (const input of ['', 'abc', 'abcd'.repeat(16), '签名兼容性']) {
  assert.equal(context.hgSM3(input),crypto.createHash('sm3').update(input).digest('hex'));
}
const values = {device_id:'123456789',iid:'987654321',version_name:'7.3.9.32',aid:'8662'};
for (const playback of [true,false]) {
  const body = Buffer.from('{"video":"123"}');
  const signed = JSON.parse(context.hgSign('https://example.org/model',values,body.toString('base64'),playback));
  assert.equal(signed.headers['x-ss-stub'],crypto.createHash('md5').update(body).digest('hex').toUpperCase());
  assert.equal(new URL(signed.url).searchParams.get('device_id'),values.device_id);
  assert.ok(Buffer.from(signed.headers['x-medusa'],'base64').length > 100);
  assert.equal(new URL(signed.url).searchParams.has('ts'),!playback);
}
console.log('SM3 vectors and bundled signature smoke checks passed.');
const fixtures=JSON.parse(fs.readFileSync(new URL('../../kotlin-tv/core/src/test/resources/player-signing.json',import.meta.url),'utf8'));
for(const row of fixtures) {
  const actual=JSON.parse(context.hgPlayerHeaders(row.query,row.body===null?null:Buffer.from(row.body).toString('base64'),row.deviceId,row.now,Buffer.from(row.nonce,'hex').toString('base64')));
  const lower=o=>Object.fromEntries(Object.entries(o).map(([k,v])=>[k.toLowerCase(),v]));
  assert.deepEqual(lower(actual),lower(row.headers));
}
console.log(`Single-video signatures match all ${fixtures.length} independent Go reference fixtures.`);
