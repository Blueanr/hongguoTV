// Bundle only the pinned, local arithmetic implementation. No server or web view runs on iOS.
import fs from 'node:fs';
import { build } from 'esbuild';
const root = new URL('../', import.meta.url);
const vendor = fs.readFileSync(new URL('../server/vendor/hongguo.cjs', root), 'utf8');
const constants = vendor.slice(vendor.indexOf('const DEVICE ='), vendor.indexOf('const SELECTOR_GROUPS'));
const arithmetic = vendor.slice(vendor.indexOf('function md5('), vendor.indexOf('async function signedAppGet'));
// Match the current Kotlin signer: nonce and process start are stable per runtime, identity is registered.
const patched = arithmetic
  .replaceAll("'Ai6svO3PyrwDOUSmO6ZcResxu'", 'processNonce')
  .replaceAll("'AXYQOS6n2m60x1fVZHIrH3iol'", 'processNonce')
  .replaceAll(/17283880166(?:35|37)/g, 'processStarted')
  .replaceAll('255.24993896484375', '0').replaceAll('35.58599090576172', '0')
  .replaceAll('3.467449188232422', '0').replaceAll('255.1754913330078', '0').replaceAll('42.17544174194336', '0');
const shim = fs.readFileSync(new URL('runtime.js', import.meta.url), 'utf8');
fs.mkdirSync(new URL('Resources', root), { recursive: true });
for (const [source,name] of [
  [new URL('../LICENSE',root),'LICENSE.txt'],
  [new URL('NOTICE.md',root),'NOTICE.txt'],
  [new URL('../server/vendor/NOTICE.md',root),'Vendor-NOTICE.txt'],
  [new URL('../server/vendor/LICENSE.drpys',root),'Vendor-LICENSE.txt'],
  [new URL('node_modules/buffer/LICENSE',import.meta.url),'Buffer-LICENSE.txt'],
]) fs.copyFileSync(source,new URL('Resources/' + name,root));
await build({
  stdin: { contents: `import { Buffer } from 'buffer';\n${shim}\n${constants}\n${patched}\nglobalThis.hgSign = sign;`, resolveDir: new URL('.', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1') },
  bundle: true, format: 'iife', platform: 'neutral', target: 'safari15', tsconfigRaw: {},
  outfile: new URL('Resources/signer.js', root).pathname.replace(/^\/([A-Za-z]:)/, '$1'),
});
