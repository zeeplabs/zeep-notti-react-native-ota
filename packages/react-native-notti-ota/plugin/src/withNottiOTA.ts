import { createHash, createPublicKey } from 'crypto';
import fs from 'fs';
import path from 'path';
import {
  AndroidConfig,
  withAndroidManifest,
  withInfoPlist,
  type ConfigPlugin,
  type InfoPlist,
} from '@expo/config-plugins';

export type NottiOTAPluginProps = {
  /** Notti App ID (UUID). */
  appId: string;
  /** Notti API base URL, for example `https://app.zeepnotti.app`. */
  baseUrl: string;
  /** The App's client key (public, device-restricted). */
  clientKey: string;
  /** Release channel, `[a-z0-9-]{1,32}`. */
  channel: string;
  /** Change it whenever native code changes. */
  runtimeVersion: string;
  /** 1 to 5 signing public keys, each the PEM printed by `notti ota keys generate`. */
  publicKeys: string[];
};

/** Native configuration keys, read by the iOS and Android SDK at launch. */
export const CONFIG_KEYS = {
  appId: 'NottiOTAAppId',
  baseUrl: 'NottiOTABaseUrl',
  clientKey: 'NottiOTAClientKey',
  channel: 'NottiOTAChannel',
  runtimeVersion: 'NottiOTARuntimeVersion',
  publicKeys: 'NottiOTAPublicKeys',
} as const;

export type NativeConfig = Record<
  (typeof CONFIG_KEYS)[keyof typeof CONFIG_KEYS],
  string
>;

const PREFIX = 'react-native-notti-ota';
const MAX_PUBLIC_KEYS = 5;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CHANNEL = /^[a-z0-9-]{1,32}$/;

function fail(message: string): never {
  throw new Error(`${PREFIX}: ${message}`);
}

function requiredString(props: Record<string, unknown>, name: string): string {
  const value = props[name];
  if (typeof value !== 'string' || value.trim() === '') {
    fail(`the "${name}" option is required and must be a non-empty string`);
  }
  return value.trim();
}

/**
 * Android reads a `<meta-data android:value>` that looks like a boolean, a number or a resource
 * reference as that type, so the SDK would see another value than iOS (`1.10` becomes 1.1).
 * Only plain strings and canonical 32-bit integers survive unchanged.
 */
export function androidReadsAsString(value: string): boolean {
  if (/^(true|false)$/i.test(value) || /^[@?]/.test(value)) return false;
  if (/^[-+]?0x[0-9a-f]+$/i.test(value)) return false;
  if (/^[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?[fF]?$/.test(value)) {
    return /^(0|[1-9]\d{0,9})$/.test(value) && Number(value) <= 2147483647;
  }
  return true;
}

/** `key_id:base64`, where base64 is the 65-byte uncompressed P-256 point of the SPKI PEM. */
export function publicKeyEntry(pem: string): string {
  let der: Buffer;
  try {
    const key = createPublicKey(pem);
    if (key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') {
      fail('every public key must be an ECDSA P-256 key');
    }
    der = key.export({ type: 'spki', format: 'der' });
  } catch (error) {
    if (error instanceof Error && error.message.startsWith(PREFIX)) throw error;
    fail(
      'every entry of "publicKeys" must be a public key PEM, as printed by `notti ota keys generate`'
    );
  }
  const point = der.subarray(der.length - 65);
  if (point[0] !== 0x04)
    fail('every public key must be an uncompressed P-256 point');
  const keyId = createHash('sha256')
    .update(point)
    .digest()
    .subarray(0, 8)
    .toString('hex');
  return `${keyId}:${point.toString('base64')}`;
}

/** Validates the plugin options and returns the native configuration they produce. */
export function resolveNativeConfig(props: unknown): NativeConfig {
  if (typeof props !== 'object' || props === null) {
    fail(
      'options are required: appId, baseUrl, clientKey, channel, runtimeVersion and publicKeys'
    );
  }
  const options = props as Record<string, unknown>;

  const appId = requiredString(options, 'appId');
  if (!UUID.test(appId)) fail('"appId" must be the Notti App ID (a UUID)');

  const rawBaseUrl = requiredString(options, 'baseUrl').replace(/\/+$/, '');
  let url: URL;
  try {
    url = new URL(rawBaseUrl);
  } catch {
    fail('"baseUrl" must be an http(s) URL');
  }
  if (!['http:', 'https:'].includes(url.protocol) || url.search || url.hash) {
    fail('"baseUrl" must be an http(s) URL without a query or fragment');
  }

  const clientKey = requiredString(options, 'clientKey');

  const channel = requiredString(options, 'channel');
  if (!CHANNEL.test(channel)) fail('"channel" must match [a-z0-9-]{1,32}');

  const runtimeVersion = requiredString(options, 'runtimeVersion');
  if (Buffer.byteLength(runtimeVersion, 'utf8') > 64) {
    fail('"runtimeVersion" must be at most 64 characters');
  }

  const keys = options.publicKeys;
  if (
    !Array.isArray(keys) ||
    keys.length < 1 ||
    keys.length > MAX_PUBLIC_KEYS
  ) {
    fail(`"publicKeys" must list 1 to ${MAX_PUBLIC_KEYS} public keys`);
  }
  const entries = keys.map((key) => {
    if (typeof key !== 'string')
      fail('every entry of "publicKeys" must be a string');
    return publicKeyEntry(key);
  });
  if (new Set(entries).size !== entries.length) {
    fail('"publicKeys" lists the same key twice');
  }

  const config: NativeConfig = {
    [CONFIG_KEYS.appId]: appId,
    [CONFIG_KEYS.baseUrl]: rawBaseUrl,
    [CONFIG_KEYS.clientKey]: clientKey,
    [CONFIG_KEYS.channel]: channel,
    [CONFIG_KEYS.runtimeVersion]: runtimeVersion,
    [CONFIG_KEYS.publicKeys]: entries.join(','),
  };
  for (const [key, value] of Object.entries(config)) {
    if (!androidReadsAsString(value)) {
      fail(
        `"${key}" value "${value}" would be read as a number or boolean on Android; use a value like "1.10.0"`
      );
    }
  }
  return config;
}

/**
 * Whether `name` resolves from `projectRoot` the way Node and Metro find a package: in a
 * `node_modules` of the project or of any parent directory (monorepo hoisting).
 */
export function isInstalled(name: string, projectRoot: string): boolean {
  let dir = path.resolve(projectRoot);
  while (true) {
    if (fs.existsSync(path.join(dir, 'node_modules', name, 'package.json'))) {
      return true;
    }
    const parent = path.dirname(dir);
    if (parent === dir) return false;
    dir = parent;
  }
}

/**
 * `expo-updates` takes over the same bundle hook, and on iOS it wins even when disabled, so it
 * cannot be installed at all (OTA-35). The Expo adapter is what connects the SDK to Expo.
 */
export function checkProject(projectRoot: string): void {
  if (isInstalled('expo-updates', projectRoot)) {
    fail(
      'expo-updates is installed. Notti Live updates and expo-updates both load the app bundle, so they cannot be used together, even with updates.enabled set to false. Remove expo-updates from the project.'
    );
  }
  if (!isInstalled('react-native-notti-ota-expo', projectRoot)) {
    fail(
      'react-native-notti-ota-expo is not installed. Expo projects need it to load Live updates: install it next to react-native-notti-ota.'
    );
  }
}

export function setInfoPlistConfig(
  plist: InfoPlist,
  config: NativeConfig
): InfoPlist {
  return { ...plist, ...config };
}

export function setManifestConfig(
  manifest: AndroidConfig.Manifest.AndroidManifest,
  config: NativeConfig
): AndroidConfig.Manifest.AndroidManifest {
  const app = AndroidConfig.Manifest.getMainApplicationOrThrow(manifest);
  for (const [name, value] of Object.entries(config)) {
    AndroidConfig.Manifest.addMetaDataItemToMainApplication(app, name, value);
  }
  return manifest;
}

const withNottiOTA: ConfigPlugin<NottiOTAPluginProps> = (config, props) => {
  const native = resolveNativeConfig(props);

  config = withInfoPlist(config, (plistConfig) => {
    checkProject(plistConfig.modRequest.projectRoot);
    plistConfig.modResults = setInfoPlistConfig(plistConfig.modResults, native);
    return plistConfig;
  });

  return withAndroidManifest(config, (manifestConfig) => {
    checkProject(manifestConfig.modRequest.projectRoot);
    manifestConfig.modResults = setManifestConfig(
      manifestConfig.modResults,
      native
    );
    return manifestConfig;
  });
};

export default withNottiOTA;
