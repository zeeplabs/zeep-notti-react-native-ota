#!/usr/bin/env node
// Packs both packages (core first, then the Expo adapter) into <outDir> and
// checks the tarballs before anything is published:
//   - the packed version equals the root (lockstep) version
//   - no `workspace:`, `link:` or `file:` specifier is left in any manifest
//   - the adapter has a resolvable range on the core that accepts this version
//   - the packages are built first (`pnpm run build`: bob -> lib/, plus the
//     core's Expo config plugin) and every tarball ships the files its
//     `main`/`types`/`exports` point at, and no tests/fixtures/mocks
// `pnpm pack` rewrites `workspace:` specifiers; `npm pack` would not. The
// tarballs are then published with `npm publish <tarball>` (npm does the OIDC
// trusted-publishing handshake). Prints one tarball path per line, in
// publish order.
'use strict';

const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const outDir = path.resolve(process.argv[2] || path.join(root, '.pack'));
const { version } = require(path.join(root, 'package.json'));

// Publish order matters: the adapter depends on the core.
const packages = ['react-native-notti-ota', 'react-native-notti-ota-expo'];
const dependencyFields = [
  'dependencies',
  'devDependencies',
  'peerDependencies',
  'optionalDependencies',
];

fs.rmSync(outDir, { recursive: true, force: true });
fs.mkdirSync(outDir, { recursive: true });

const tarballs = [];
for (const name of packages) {
  const cwd = path.join(root, 'packages', name);
  // Never pack stale or missing build output: rebuild lib/ (and plugin/build)
  // from src/ right before packing.
  execFileSync('pnpm', ['run', 'build'], {
    cwd,
    stdio: ['ignore', 'ignore', 'inherit'],
  });
  execFileSync('pnpm', ['pack', '--pack-destination', outDir], {
    cwd,
    stdio: ['ignore', 'ignore', 'inherit'],
  });
  const tarball = path.join(outDir, `${name}-${version}.tgz`);
  if (!fs.existsSync(tarball)) {
    throw new Error(`Expected ${tarball} after pnpm pack`);
  }
  const manifest = JSON.parse(
    execFileSync('tar', ['-xOzf', tarball, 'package/package.json'], {
      encoding: 'utf8',
    })
  );
  if (manifest.name !== name || manifest.version !== version) {
    throw new Error(
      `${tarball} holds ${manifest.name}@${manifest.version}, expected ${name}@${version}`
    );
  }
  const entries = new Set(
    execFileSync('tar', ['-tzf', tarball], { encoding: 'utf8' })
      .split('\n')
      .filter(Boolean)
      .map((entry) => entry.replace(/^package\//, ''))
  );
  const exported = [manifest.main, manifest.types];
  for (const target of Object.values(manifest.exports?.['.'] ?? {})) {
    if (target !== './src/index.ts') exported.push(target);
  }
  for (const target of exported) {
    const file = String(target).replace(/^\.\//, '');
    if (!entries.has(file)) {
      throw new Error(`${name}: "${target}" is not in the tarball`);
    }
  }
  const unwanted = [...entries].filter((entry) =>
    /(^|\/)(__tests__|__fixtures__|__mocks__)\//.test(entry)
  );
  if (unwanted.length > 0) {
    throw new Error(
      `${name}: test files in the tarball: ${unwanted.join(', ')}`
    );
  }
  for (const field of dependencyFields) {
    for (const [dep, range] of Object.entries(manifest[field] || {})) {
      if (/^(workspace|link|file):/.test(range)) {
        throw new Error(
          `${name}: ${field}.${dep} is "${range}" in the tarball`
        );
      }
    }
  }
  tarballs.push({ name, tarball, manifest });
}

const adapter = tarballs[1].manifest;
const coreRange = (adapter.peerDependencies || {})[packages[0]];
if (!coreRange) {
  throw new Error(`${packages[1]} has no peer dependency on ${packages[0]}`);
}
if (coreRange !== `^${version}`) {
  throw new Error(
    `${packages[1]} peer range on ${packages[0]} is "${coreRange}", expected "^${version}"`
  );
}

for (const { tarball } of tarballs) console.log(tarball);
