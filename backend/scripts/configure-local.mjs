import { mkdir, chmod, lstat, open } from 'node:fs/promises';
import { constants } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const gatewayBaseURL = process.env.PINPIN_GATEWAY_URL;
const accessToken = process.env.PINPIN_ACCESS_TOKEN;
if (!gatewayBaseURL) throw new Error('Set PINPIN_GATEWAY_URL to your own HTTPS gateway URL.');
let parsed;
try { parsed = new URL(gatewayBaseURL); }
catch { throw new Error('PINPIN_GATEWAY_URL must be an HTTPS base URL.'); }
if (parsed.protocol !== 'https:' || !parsed.hostname || parsed.username || parsed.password
    || gatewayBaseURL.includes('?') || gatewayBaseURL.includes('#')
    || /^https:\/\/[^/]*@/i.test(gatewayBaseURL)) {
  throw new Error('PINPIN_GATEWAY_URL must use HTTPS without credentials, query, or fragment.');
}
if (!accessToken || !/^[\x21-\x7e]+$/.test(accessToken)) {
  throw new Error('Set PINPIN_ACCESS_TOKEN to a valid application access token locally.');
}
const folder = join(homedir(), 'Library/Application Support/PinPin');
await mkdir(folder, { recursive: true, mode: 0o700 });
if (!(await lstat(folder)).isDirectory()) throw new Error('PinPin configuration directory must be a regular directory.');
await chmod(folder, 0o700);
const file = join(folder, 'gateway.json');
// O_NOFOLLOW prevents a pre-existing link from redirecting a secret write elsewhere.
const handle = await open(file, constants.O_WRONLY | constants.O_CREAT | constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o600);
try {
  if (!(await handle.stat()).isFile()) throw new Error('PinPin configuration must be a regular file.');
  await handle.chmod(0o600);
  await handle.truncate(0);
  await handle.writeFile(JSON.stringify({ gatewayBaseURL, accessToken }));
} finally { await handle.close(); }
console.log('PinPin gateway configured in a private file (mode 0600).');
