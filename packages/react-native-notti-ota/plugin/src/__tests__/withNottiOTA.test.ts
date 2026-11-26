import { afterEach, describe, expect, it } from '@jest/globals';
import { generateKeyPairSync } from 'crypto';
import fs from 'fs';
import os from 'os';
import path from 'path';
import type { AndroidConfig } from '@expo/config-plugins';
import type { ExpoConfig } from '@expo/config-types';
import withNottiOTA, {
  androidReadsAsString,
  checkProject,
  publicKeyEntry,
  resolveNativeConfig,
  setInfoPlistConfig,
  setManifestConfig,
} from '../withNottiOTA';

const fixtures = path.resolve(__dirname, '../../../../../fixtures/ota');
const fixturePem = fs.readFileSync(
  path.join(fixtures, 'public_key.pem'),
  'utf8'
);
const fixtureKeyId = fs
  .readFileSync(path.join(fixtures, 'key_id.txt'), 'utf8')
  .trim();

const props = {
  appId: '9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f',
  baseUrl: 'https://api.notti.test/',
  clientKey: 'ck_live',
  channel: 'production',
  runtimeVersion: '1.4.0',
  publicKeys: [fixturePem],
};

const projects: string[] = [];

function project(installed: string[]): string {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'notti-ota-plugin-'));
  projects.push(root);
  fs.writeFileSync(path.join(root, 'package.json'), '{"name":"app"}');
  for (const name of installed) {
    const dir = path.join(root, 'node_modules', name);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(
      path.join(dir, 'package.json'),
      JSON.stringify({ name, version: '1.0.0', main: 'index.js' })
    );
    fs.writeFileSync(path.join(dir, 'index.js'), '');
  }
  return root;
}

function emptyManifest(): AndroidConfig.Manifest.AndroidManifest {
  return {
    manifest: {
      $: { 'xmlns:android': 'http://schemas.android.com/apk/res/android' },
      application: [{ $: { 'android:name': '.MainApplication' } }],
    },
  } as AndroidConfig.Manifest.AndroidManifest;
}

function metaData(manifest: AndroidConfig.Manifest.AndroidManifest) {
  const items = manifest.manifest.application?.[0]?.['meta-data'] ?? [];
  return Object.fromEntries(
    items.map((item) => [item.$['android:name'], item.$['android:value']])
  );
}

type ModFn = (
  config: Record<string, unknown>
) => Promise<Record<string, unknown>>;

async function runMod(
  config: ExpoConfig,
  platform: 'ios' | 'android',
  mod: string,
  modResults: unknown,
  projectRoot: string
) {
  const mods = (
    config as unknown as { mods: Record<string, Record<string, ModFn>> }
  ).mods;
  const run = mods[platform]?.[mod];
  if (!run) throw new Error(`no ${platform}.${mod} mod`);
  return run({
    ...config,
    modResults,
    modRequest: {
      projectRoot,
      platformProjectRoot: path.join(projectRoot, platform),
      modName: mod,
      platform,
      introspect: false,
      nextMod: async (c: unknown) => c,
    },
  });
}

afterEach(() => {
  projects
    .splice(0)
    .forEach((root) => fs.rmSync(root, { recursive: true, force: true }));
});

describe('publicKeyEntry', () => {
  it('turns the CLI PEM into key_id:base64 with the CLI key_id', () => {
    const entry = publicKeyEntry(fixturePem);
    const [keyId, point] = entry.split(':');
    expect(keyId).toBe(fixtureKeyId);
    const bytes = Buffer.from(point ?? '', 'base64');
    expect(bytes).toHaveLength(65);
    expect(bytes[0]).toBe(4);
  });

  it('refuses another curve and garbage', () => {
    const { publicKey } = generateKeyPairSync('ec', {
      namedCurve: 'secp384r1',
    });
    const p384 = publicKey.export({ type: 'spki', format: 'pem' }).toString();
    expect(() => publicKeyEntry(p384)).toThrow(/P-256/);
    expect(() => publicKeyEntry('not a key')).toThrow(/public key PEM/);
  });
});

describe('resolveNativeConfig', () => {
  it('produces every NottiOTA key', () => {
    expect(resolveNativeConfig(props)).toEqual({
      NottiOTAAppId: props.appId,
      NottiOTABaseUrl: 'https://api.notti.test',
      NottiOTAClientKey: 'ck_live',
      NottiOTAChannel: 'production',
      NottiOTARuntimeVersion: '1.4.0',
      NottiOTAPublicKeys: publicKeyEntry(fixturePem),
    });
  });

  it('joins up to 5 keys with commas', () => {
    const others = Array.from({ length: 4 }, () =>
      generateKeyPairSync('ec', { namedCurve: 'prime256v1' })
        .publicKey.export({ type: 'spki', format: 'pem' })
        .toString()
    );
    const config = resolveNativeConfig({
      ...props,
      publicKeys: [fixturePem, ...others],
    });
    expect(config.NottiOTAPublicKeys.split(',')).toHaveLength(5);
  });

  it.each([
    ['no options', undefined, /options are required/],
    [
      'a missing appId',
      { ...props, appId: undefined },
      /"appId" option is required/,
    ],
    ['a non-UUID appId', { ...props, appId: 'app' }, /UUID/],
    ['a non-http baseUrl', { ...props, baseUrl: 'ftp://x.test' }, /http\(s\)/],
    [
      'a baseUrl with a query',
      { ...props, baseUrl: 'https://x.test/?a=1' },
      /query/,
    ],
    ['an empty clientKey', { ...props, clientKey: ' ' }, /clientKey/],
    ['an uppercase channel', { ...props, channel: 'Production' }, /channel/],
    [
      'a long runtimeVersion',
      { ...props, runtimeVersion: 'x'.repeat(65) },
      /64/,
    ],
    [
      'a float-looking runtimeVersion',
      { ...props, runtimeVersion: '1.10' },
      /Android/,
    ],
    ['a zero-padded channel', { ...props, channel: '007' }, /Android/],
    ['no public keys', { ...props, publicKeys: [] }, /1 to 5/],
    [
      '6 public keys',
      { ...props, publicKeys: Array(6).fill(fixturePem) },
      /1 to 5/,
    ],
    [
      'a repeated key',
      { ...props, publicKeys: [fixturePem, fixturePem] },
      /twice/,
    ],
    ['a non-string key', { ...props, publicKeys: [42] }, /string/],
  ])('fails on %s', (_name, options, message) => {
    expect(() => resolveNativeConfig(options)).toThrow(message);
  });
});

describe('androidReadsAsString', () => {
  it.each([
    '1.4.0',
    'production',
    '7',
    '2147483647',
    'ck_live',
    'https://x.test',
  ])('keeps %p', (value) => expect(androidReadsAsString(value)).toBe(true));

  it.each([
    '1.10',
    '1e5',
    '0x10',
    '007',
    '-1',
    'true',
    'FALSE',
    '@string/x',
    '2147483648',
  ])('refuses %p', (value) => expect(androidReadsAsString(value)).toBe(false));
});

describe('checkProject', () => {
  it('passes with the Expo adapter and without expo-updates', () => {
    expect(() =>
      checkProject(project(['react-native-notti-ota-expo']))
    ).not.toThrow();
  });

  it('fails when expo-updates is installed, even with the adapter', () => {
    const root = project(['react-native-notti-ota-expo', 'expo-updates']);
    expect(() => checkProject(root)).toThrow(/expo-updates is installed/);
  });

  it('finds packages hoisted to a parent node_modules', () => {
    const root = project(['react-native-notti-ota-expo', 'expo-updates']);
    const app = path.join(root, 'apps', 'mobile');
    fs.mkdirSync(app, { recursive: true });
    expect(() => checkProject(app)).toThrow(/expo-updates/);
  });

  it('fails when the Expo adapter is missing', () => {
    expect(() => checkProject(project([]))).toThrow(
      /react-native-notti-ota-expo is not installed/
    );
  });
});

describe('native config', () => {
  const native = resolveNativeConfig(props);

  it('writes every key to Info.plist and keeps the other entries', () => {
    expect(setInfoPlistConfig({ CFBundleName: 'App' }, native)).toEqual({
      CFBundleName: 'App',
      ...native,
    });
  });

  it('writes every key as application meta-data, once', () => {
    const manifest = setManifestConfig(
      setManifestConfig(emptyManifest(), native),
      native
    );
    expect(metaData(manifest)).toEqual(native);
    expect(manifest.manifest.application?.[0]?.['meta-data']).toHaveLength(6);
  });
});

describe('withNottiOTA', () => {
  it('fails at once on invalid options', () => {
    expect(() =>
      withNottiOTA({ name: 'app', slug: 'app' }, { ...props, channel: 'Bad' })
    ).toThrow(/channel/);
  });

  it('writes both platforms through the typed mods', async () => {
    const root = project(['react-native-notti-ota-expo']);
    const config = withNottiOTA({ name: 'app', slug: 'app' }, props);
    const ios = await runMod(config, 'ios', 'infoPlist', {}, root);
    const android = await runMod(
      config,
      'android',
      'manifest',
      emptyManifest(),
      root
    );

    expect(ios.modResults).toMatchObject(resolveNativeConfig(props));
    expect(
      metaData(android.modResults as AndroidConfig.Manifest.AndroidManifest)
    ).toEqual(resolveNativeConfig(props));
  });

  it('fails prebuild when expo-updates is installed', async () => {
    const root = project(['react-native-notti-ota-expo', 'expo-updates']);
    const config = withNottiOTA({ name: 'app', slug: 'app' }, props);
    await expect(runMod(config, 'ios', 'infoPlist', {}, root)).rejects.toThrow(
      /expo-updates/
    );
    await expect(
      runMod(config, 'android', 'manifest', emptyManifest(), root)
    ).rejects.toThrow(/expo-updates/);
  });
});
