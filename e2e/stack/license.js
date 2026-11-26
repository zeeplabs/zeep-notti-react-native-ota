// Generates the e2e license signing key and signs license fixtures for the
// local stack. Usage:
//   node license.js keys                 -> writes .license-key.json, prints the public key
//   node license.js token <ultimate|free-expired> -> prints a signed token
const { generateKeyPairSync, createPrivateKey, sign } = require('node:crypto');
const { existsSync, readFileSync, writeFileSync } = require('node:fs');
const { join } = require('node:path');
const { Buffer } = require('node:buffer');

const keyFile = join(__dirname, '.license-key.json');
const [command, plan] = process.argv.slice(2);

if (command === 'keys') {
  if (!existsSync(keyFile)) {
    const { publicKey, privateKey } = generateKeyPairSync('ed25519');
    const raw = publicKey.export({ format: 'der', type: 'spki' }).subarray(-32);
    writeFileSync(
      keyFile,
      JSON.stringify({
        publicKey: raw.toString('base64'),
        privateKey: privateKey.export({ format: 'pem', type: 'pkcs8' }),
      }),
      { mode: 0o600 }
    );
  }
  console.log(JSON.parse(readFileSync(keyFile, 'utf8')).publicKey);
} else if (command === 'token') {
  const { privateKey } = JSON.parse(readFileSync(keyFile, 'utf8'));
  const now = Math.floor(Date.now() / 1000);
  const features = {
    apps: 9999999,
    mau_limit: 9999999,
    users: 9999999,
    ota_releases_per_month: 100,
  };
  const claims = {
    org: 'e2e-org',
    product: 'notti-selfhosted',
    plan: 'ultimate',
    ref: 'e2e',
    iat: now,
    exp: now + 30 * 86400,
    renewal_due_at: now + 30 * 86400,
    trial: false,
    features,
  };
  if (plan === 'no-ota') delete claims.features.ota_releases_per_month;
  else if (plan !== 'ultimate') throw new Error(`unknown plan ${plan}`);
  const payload = Buffer.from(JSON.stringify(claims)).toString('base64url');
  const signature = sign(
    null,
    Buffer.from(payload),
    createPrivateKey(privateKey)
  );
  console.log(`${payload}.${signature.toString('base64url')}`);
} else {
  console.error('usage: node license.js keys | token <ultimate|no-ota>');
  process.exit(2);
}
