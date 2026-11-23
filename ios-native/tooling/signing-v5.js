// SPDX-License-Identifier: GPL-3.0-only
// Port of origin/main ac3a1e2: Signer.kt, AesV3.kt and V5Constants.kt.
// Kept separate from the catalog/v3 implementation, including its device state.
const V5_MAGIC = Buffer.from('2d4b4fca49750d433fb5ae2c226dcc56', 'hex');
const V5_LICENSE = '646637794';
const V5_KEY = Buffer.from('b23c2a470a20d105dc3f8c4438f8272ed46d6c89ffdcdedd5108698d26e9489d', 'hex');
const V5_SBOX = Buffer.from(
  '53290fe9e51f316f90f74a7e034d367784ab49237cd0135cdc632c322fd3be0e2624a417ecd9151a7ff64f60730a87f9445ec6ada2f865d22b696c4188f24c0d' +
  'f37b75510b939f6bc2fe6883e68bc8c722181ba0bdb08c9871b50c9a16b46eea8eed20ba4b8a14e0fcf1468dbbef05a93e5a9d7dcf06898635c1fd99f5de287a' +
  '80c594daaab19b6279fbd75070cb52eb2555c456e39e7839853874e2f0013ac0b64742d8ca10e4b79c955de8b843ce4ed464a6a72ed508091c92e7b3eedd1e1d' +
  'd12afac321618fa3d65f9167c982f43d66a53c6a1997585b346dbf9672ff37cdbc073b2dae11453304df00815476b2a13fccdb30b957a8acafe1274002485912' +
  '38922563e36406d37a24100b7902a028044e218453c2a399199c9d13dc40c55ba67e502273850ebdc1a2e2188b8f2d9e3cb909b8c46a2a9f4a6dd93007eafa65' +
  'b7b3a881aa908cc74f0ad76bbbb58617c37012ca05a469fd44e62eecf1e4272ce860c0ae5eadf99b20d8f0234174006f3f110d7657d01645d4eff8f71471cbfe' +
  '1cb2f52648727bf3c9de55153e031b4d61757db63dbf7782eeafe9018a8891362fb14759ac32bab03b349aeb5a377c5156be4c8dfbe13a684bda39cf836697c8' +
  '94545fe0f2491acea9fc6252f4ff1e0fe72bd2df6e67a7f635e5bcc6d1a5dd951d89960887a18eb40c785cdb1f80ed42299333ab98cdd67f316cd54346585dcc' +
  'd759fb722789b08807cc0fda293f7e5e1819bb0353517020b31d3d00374952bea2c421e862040a9ec892a05b266b7a0d0cc316f483b81af39715657ffe32ad8d' +
  'e0c13077646035236ee5363e5f900e9a7cf850a81cd9960b6df73317226f99eaa6fff15cec34acb98246639b918ab2851466a7cdfc4ad1b52c2ae95a58d3734e' +
  '47ddd5b7560193f644ef9c408b7dee39b4d6aabf4de761e3252d4c7ba3843187745d55e6a5db05d42b45caed43c0c5d0b64bfa9d94a4a9d8f2f0e1a108dcfd28' +
  '8fd2bc1fc7bd675412138169cb09249875ba3b68cfb11180afae104fc9789571c6dfce02413886796ae21e3c488cc21b9f423a066c2eabf98e2fdeeb5776e4f5' +
  'd09a515ba58cbbab3e37b09fd4f6d9244df80512e84cd7956be301cf64f1429d58577cc241f3a2c655144f81aaf95a4e108da894b38970561ae9002619fbbac9' +
  '1fa922ed202bfc62cb08e0de2a7f3631435f8b47c8a3c563b4db4071ce74c46da6fa696a9e282d1e825d663b93bfd56c48dce1884bb10fccea063929f746443f' +
  'd830a4232e53da21a1f2d1bdfebc3a02c10a1b8ad31d04fd616590d272ac737e98eb33af60528716bee78ec0ee8699031177277d9cff32542c67caf5f4459168' +
  '1335ae0e178f3409a7803db83892dde5b9b7f0c750e24aef077badd678a09b850b84ec1597e4963cb5e675df1c0d6fb618496ecd76c35c798325590c2fb27a5e',
  'hex');

const V5_HASH_TABLE = [
  0xebb64faf,0x07aadcc2,0xcf3187bf,0xe01138ff,0x6d0bfcff,0x5a30a3be,0xb41ad638,0x34180eb8,
  0xf233eb6f,0xb1a584cc,0xccc30dc7,0x47d1db51,0xd55653de,0x70a84fa1,0x57473c12,0xf76f0288,
  0x2c077f0a,0xda0dcad0,0xfbb86f6c,0xfdc4cf00,0x688a020d,0xe676c6a6,0x8cd6338b,0x1a3c8d0e,
  0xcce8b06b,0x6ad0ed0b,0xa0522717,0xdc71ac83,0x2285db71,0xd5b4dda6,0x736f8650,0x6560306c,
  0x617ce2a6,0xe423417e,0x0a40e143,0x544e4032,0x88dffb2a,0x716c1ae0,0x4c467a88,0x05b23bb3,
  0xe1d0b866,0xbaa3dcb8,0xae3374d3,0xc3381a50,0x1702f75b,0xfe6da368,0xf0b4cf48,0x4e0ffbb8,
  0x72aad10d,0x26c53a3d,0xf2bce0f6,0xb4557581,0x4a257fdd,0x8c3182a2,0xab0b3b86,0x3d5dfb14,
  0x4f103634,0xd37b52d7,0x444eff16,0xeb0a33d1,0x6ca86f6e,0x00284ba7,0x08387cfa,0x5fb37586,
];

function v5Nibble(queryHash, bodyHash, ts) {
  return getIv(getIv(getIv(0x20230928, queryHash), bodyHash), le32(ts)) & 15;
}

function v5HashF13(queryHash, bodyHash, ts) {
  if (v5Nibble(queryHash, bodyHash, ts) !== 12) throw new Error('Unsupported v5 hash branch');
  const seed = 0x9d4a97c2, count = u32(seed + ts);
  const table = V5_HASH_TABLE.map(value => ror32(value, (count + 1) & 255));
  const shift = (count + 2) & 7;
  const pad = Buffer.from([0xfa,0x45,0x61,0xd7].map(x => ((x | (x << 8)) >> shift) & 255));
  const data = Buffer.concat([queryHash, bodyHash, le32(ts), pad, Buffer.from('00000000000001a0', 'hex')]);
  const schedule = [];
  for (let i = 0; i < 64; i += 4) schedule.push(data.readUInt32BE(i));
  for (let i = 0; i < 112; i++) {
    const x = schedule[i + 1], y = schedule[i + 14];
    schedule.push(u32(schedule[i] + schedule[i + 9] +
      (rol32(x,14) ^ rol32(x,25) ^ (x >>> 3)) +
      (rol32(y,13) ^ rol32(y,15) ^ (y >>> 10))));
  }
  const initial = [0x7aba4fc8,0x67166507,0x6403fa00,0x340f512f,984304912,3005047866,2874125293,2152413264]
    .map(value => ror32(value, count));
  const d = initial.slice();
  // Kotlin's chosen state: [96,1,3,4,0,6,5,2,0,7,7].
  for (let i = 0; i < 96; i++) {
    const base = seed + i;
    const n1 = ((d[4] ^ d[0]) & d[1]) ^ d[4];
    const n2 = rol32(d[1],26) ^ rol32(d[1],21) ^ rol32(d[1],7);
    const n4 = u32(schedule[base & 127] + n1 + n2 + table[base & 63] + d[6]);
    const n5 = rol32(d[3],30) ^ rol32(d[3],19) ^ rol32(d[3],10);
    const n6 = (d[3] & d[5]) | ((d[3] | d[5]) & d[2]);
    const old = d[7];
    d.unshift(d.pop());
    d[7] = u32(n5 + n6 + n4);
    d[0] = u32(old + n4);
  }
  const result = Buffer.concat(d.map((value, i) => be32(value + initial[i])));
  const folded = bxor(result.subarray(0,16), result.subarray(16));
  return Buffer.concat([folded, le32(sumMd5(folded) | 0x20)]);
}

// Protocol carrier, not standard AES: two custom rounds replace selected bits
// in the first 248 bytes, leaving the remaining envelope bytes untouched.
class V5Carrier {
  constructor(key, ts) {
    const variant = ts & 3;
    this.box = V5_SBOX.subarray(variant * 256, (variant + 1) * 256);
    this.con = [[2,0,3,1],[1,3,2,0],[3,2,1,0],[2,3,1,0]][variant];
    this.order = [
      [0,9,14,15,4,13,2,7,8,1,6,3,12,5,10,11],
      [0,9,14,11,4,13,2,3,8,1,6,15,12,5,10,7],
      [0,9,14,3,4,13,2,15,8,1,6,11,12,5,10,7],
      [0,9,14,15,4,13,2,3,8,1,6,11,12,5,10,7],
    ][variant];
    const initial = [0xbbb5de72,0xd4638d5b,0x92a5f73b,0x89f8a1c9][variant];
    const expanded = Buffer.concat([xorBytes(Buffer.concat(Array(4).fill(le32(initial))), key), Buffer.alloc(32)]);
    let rounds = 8;
    for (let i = 4; i < 12; i++) {
      const at = 4 * (i - 1);
      let [a,b,c,d] = expanded.subarray(at, at + 4);
      if ((i & 3) === 0) [a,b,c,d] = [((initial >> (rounds & 24)) ^ this.box[b]) & 255, this.box[c], this.box[d], this.box[a]];
      rounds += 2;
      [a,b,c,d].forEach((value,j) => { expanded[at + 4 + j] = value ^ expanded[at - 12 + j]; });
    }
    this.keys = Array.from({length:12}, (_,i) => Array.from(expanded.subarray(i * 4, i * 4 + 4)));
  }

  block(value) {
    let rows = matrix(value);
    const add = offset => {
      for (let i = 0; i < 4; i++) for (let j = 0; j < 4; j++) rows[i][j] ^= this.keys[offset + i][this.con[j]];
    };
    add(0);
    for (let round = 1; round <= 2; round++) {
      rows = rows.map(row => row.map(value => this.box[value]));
      rows = this.con.map(i => rows[i].slice());
      const before = rows.flat();
      rows = matrix(Buffer.from(this.order.map(i => before[i])));
      if (round === 1) {
        rows = rows.map(row => this.con.map(i => row[i]));
        aesMix(rows);
      }
      add(round * 4);
    }
    return Buffer.from(rows.flatMap((row,i) => row.map((value,j) => value ^ this.keys[4 + i][j])));
  }

  encrypt(source, iv) {
    if (source.length < 248) throw new Error('v5 carrier requires at least 248 bytes');
    const wire = [6,5,3,4,2,7,1,0], compact = [1,7,3,6,2,0,4,5];
    const plaintext = Buffer.alloc(32);
    for (let i = 0; i < 31; i++) for (let j = 0; j < 8; j++) {
      plaintext[i] |= ((source[i * 8 + j] >>> wire[j]) & 1) << compact[j];
    }
    plaintext[31] = 1;
    const first = this.block(bxor(plaintext.subarray(0,16), iv));
    const key = Buffer.concat([first, this.block(bxor(plaintext.subarray(16), first))]);
    const output = Buffer.from(source);
    for (let i = 0; i < 31; i++) for (let j = 0; j < 8; j++) {
      const at = i * 8 + j;
      output[at] = (output[at] & ~(1 << wire[j])) | (((key[i] >>> compact[j]) & 1) << wire[j]);
    }
    return Buffer.concat([key.subarray(31), output]);
  }
}

function v5Md5(bytes) { return crypto.createHash('md5').update(bytes).digest(); }

function v5Helios(ts, random) {
  const nonce = Math.floor(random() * 0x100000000);
  const ascii = Buffer.from(v5Md5(Buffer.concat([le32(nonce), Buffer.from('8662')])).toString('hex'));
  const words = Array.from({length:4}, (_,i) => ascii.readBigUInt64LE(i * 8));
  const table = [words[0]];
  let b0 = words.shift(), b8 = words.shift();
  for (let i = 0; i < 34; i++) {
    let next = BigInt.asUintN(64, ror64(b8,8) + b0) ^ BigInt(i);
    words.push(next);
    next ^= ror64(b0,61);
    table.push(next);
    b0 = next;
    b8 = words.shift();
  }
  const text = Buffer.from(`${ts}-${V5_LICENSE}-8662`);
  const padding = 16 - text.length % 16;
  const data = Buffer.concat([text, Buffer.alloc(padding, padding)]), output = [le32(nonce)];
  for (let at = 0; at < data.length; at += 16) {
    let a = data.readBigUInt64LE(at), b = data.readBigUInt64LE(at + 8);
    for (let i = 0; i < 34; i++) {
      b = BigInt.asUintN(64, table[i] ^ (a + ror64(b,8)));
      a = b ^ ror64(a,61);
    }
    const block = Buffer.alloc(16);
    block.writeBigUInt64LE(a); block.writeBigUInt64LE(b,8); output.push(block);
  }
  return Buffer.concat(output).toString('base64');
}

function v5Medusa(queryHash, bodyHash, ts, who, random, nonce, started) {
  const f13 = v5HashF13(queryHash, bodyHash, ts), flags = Buffer.alloc(8);
  const deviceInfo = proto([
    [1,1,'sint'],[2,2,'sint'],[3,'8662'],[4,who.device_id],[5,nonce],[6,'!noperm!'],
    [12,'Asia/Shanghai,8'],[13,'zh_CN'],[22,who.os_version],[25,started,'sint'],
    [30,who.device_type],[31,'HONOR'],[32,who.device_type],[34,'HONOR'],
  ]);
  const env = proto([[6,'v04.10.03.04-bugfix'],[8,who.channel],[12,deviceInfo,'message'],[14,who.version_name]]);
  const message = proto([
    [1,V5_MAGIC,'bytes'],[2,5,'sint'],[3,Math.floor(random() * 0x100000000),'sint'],
    [4,'8662'],[5,who.device_id],[6,V5_LICENSE],[7,who.version_name],
    [8,'v04.10.03-ml-android'],[9,0x040a0300,'sint'],[10,flags,'bytes'],[12,ts,'sint'],
    [13,f13,'bytes'],[14,queryHash.subarray(0,6),'bytes'],
    [15,proto([[1,1,'sint'],[2,1,'sint'],[3,1,'sint'],[5,1,'sint']]),'message'],
    [17,ts,'sint'],[20,'none'],[21,377,'sint'],[23,env,'message'],
    [24,'{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}'],
  ]);
  const r = Math.floor(random() * 0x100000000), [hash, seed] = keyHash(V5_KEY, r);
  const transformed = Buffer.concat([flags, xmxor(message,hash)]).reverse();
  for (let i = 0; i < transformed.length; i++) transformed[i] ^= seed[(~i) & 3];
  const check = 0x18000001 | ((queryHash[0] & 63) << 14) | ((f13[0] & 63) << 8);
  const packed = Buffer.concat([Buffer.from([0xca]), le32(Math.floor(random() * 0x100000000)), le32(check), transformed, Buffer.from([r >>> 16, r >>> 24])]);
  const encrypted = new V5Carrier(v5Md5(V5_KEY.subarray(0,16)), ts).encrypt(packed, v5Md5(V5_KEY.subarray(16)));
  const prefix = xorBytes(Buffer.concat([le32(5), V5_MAGIC]), le32(ts));
  return Buffer.concat([prefix, Buffer.from([r, r >>> 8, 0, 1]), encrypted]).toString('base64');
}

// Kotlin URLEncoder preserves '*', while encoding ! ' ( ); legacy encode() has
// different escaping, so v5 has its own encoder. Object insertion order is wire order.
function v5Encode(values) {
  const escape = value => encodeURIComponent(String(value)).replace(/[!'()]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase());
  return Object.entries(values).map(([key,value]) => escape(key) + '=' + escape(value)).join('&');
}

/** Return JSON {url, headers}, matching hgSign's JavaScriptCore bridge contract.
 * bodyBase64: empty string/null/undefined for GET, otherwise the exact transmitted bytes (gzip
 * is done by the caller). GET signs MD5(empty), but emits no body-related headers.
 * Optional deterministic options: now (ms), processStarted (ms), processNonce,
 * random (constant [0,1) or an array consumed in Kotlin signPlayback order).
 */
function signV5(base, values, bodyBase64, options = {}) {
  for (const key of ['device_id','version_name','os_version','device_type','channel']) {
    if (values[key] === undefined || values[key] === null) throw new Error('Missing v5 identity field: ' + key);
  }
  const now = options.now ?? Date.now(), ts = Math.floor(now / 1000);
  const body = bodyBase64 == null || bodyBase64 === '' ? null : Buffer.from(bodyBase64, 'base64');
  const bodyHash = v5Md5(body ?? Buffer.alloc(0));
  let randomAt = 0;
  const random = () => {
    const value = Array.isArray(options.random) ? options.random[randomAt++] : (options.random ?? Math.random());
    if (!(value >= 0 && value < 1)) throw new Error('Invalid or exhausted v5 random sequence');
    return value;
  };
  for (let offset = 0; offset < 1024; offset++) {
    const query = v5Encode({...values, _rticket:String(now + offset)}), queryHash = sm3(Buffer.from(query));
    if (v5Nibble(queryHash, bodyHash, ts) !== 12) continue;
    // Upstream consumes a Gorgon random before discarding that legacy header.
    random();
    const headers = {
      'x-khronos':String(ts),
      'x-helios':v5Helios(ts, random),
      'x-medusa':v5Medusa(queryHash, bodyHash, ts, values, random,
        options.processNonce ?? processNonce, options.processStarted ?? processStarted),
    };
    if (body !== null) Object.assign(headers, {'Content-Type':'application/json; charset=utf-8', 'x-ss-stub':bodyHash.toString('hex').toUpperCase()});
    return JSON.stringify({url:base + '?' + query, headers});
  }
  throw new Error('无法生成播放签名');
}
globalThis.hgSignV5 = signV5;
