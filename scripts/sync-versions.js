#!/usr/bin/env node
// Lockstep versioning: the root package.json version is the single source of
// truth (release-it bumps it). This runs in the release-it `after:bump` hook
// and copies that version to everything that carries it, so the published
// packages, the native SDK_VERSION constants and the pods/gradle metadata
// never drift:
//   - packages/*/package.json `version`
//   - the adapter's peer range on the core (^<version>)
//   - OTAUpdater.swift `sdkVersion` and OTAUpdater.kt `SDK_VERSION`
//   - the Expo adapter's android/build.gradle `version`
// Pass --check to fail instead of writing when something is out of sync.
'use strict';

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const check = process.argv.includes('--check');
const { version } = require(path.join(root, 'package.json'));
if (typeof version !== 'string' || !/^\d+\.\d+\.\d+/.test(version)) {
  throw new Error('root package.json has no valid version');
}

const CORE = 'react-native-notti-ota';
const EXPO = 'react-native-notti-ota-expo';
const stale = [];

function update(file, transform) {
  const target = path.join(root, file);
  const source = fs.readFileSync(target, 'utf8');
  const next = transform(source);
  if (next === source) return;
  stale.push(file);
  if (!check) fs.writeFileSync(target, next);
}

function replaceOnce(source, regex, replacement, label) {
  if (!regex.test(source)) throw new Error(`${label} not found`);
  return source.replace(regex, replacement);
}

for (const name of [CORE, EXPO]) {
  update(`packages/${name}/package.json`, (source) => {
    const pkg = JSON.parse(source);
    pkg.version = version;
    if (name === EXPO) {
      if (!pkg.peerDependencies || !pkg.peerDependencies[CORE]) {
        throw new Error(`${EXPO} must declare a peer dependency on ${CORE}`);
      }
      pkg.peerDependencies[CORE] = `^${version}`;
    }
    return JSON.stringify(pkg, null, 2) + '\n';
  });
}

update(`packages/${CORE}/ios/OTAUpdater.swift`, (source) =>
  replaceOnce(
    source,
    /static let sdkVersion = "[^"]*"/,
    `static let sdkVersion = "${version}"`,
    'sdkVersion in OTAUpdater.swift'
  )
);
update(
  `packages/${CORE}/android/src/main/java/com/notti/ota/OTAUpdater.kt`,
  (source) =>
    replaceOnce(
      source,
      /const val SDK_VERSION = "[^"]*"/,
      `const val SDK_VERSION = "${version}"`,
      'SDK_VERSION in OTAUpdater.kt'
    )
);
update(`packages/${EXPO}/android/build.gradle`, (source) =>
  replaceOnce(
    source,
    /^version = "[^"]*"/m,
    `version = "${version}"`,
    'version in expo build.gradle'
  )
);

if (check && stale.length > 0) {
  console.error(`Out of sync with root version ${version}:`);
  for (const file of stale) console.error(`  ${file}`);
  process.exit(1);
}
console.log(
  stale.length > 0
    ? `Synced ${stale.length} file(s) to ${version}`
    : `All files already at ${version}`
);
