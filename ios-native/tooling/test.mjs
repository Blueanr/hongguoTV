import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import vm from 'node:vm';
const context = vm.createContext({
  nativeHash: (name,value) => crypto.createHash(name).update(Buffer.from(value,'base64')).digest('base64'),
  nativeNonce: () => 'test-process-nonce',
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
