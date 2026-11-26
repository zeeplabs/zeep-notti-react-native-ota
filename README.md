# Notti Live updates for React Native

[![CI](https://github.com/zeeplabs/zeep-notti-react-native-ota/actions/workflows/ci.yml/badge.svg)](https://github.com/zeeplabs/zeep-notti-react-native-ota/actions/workflows/ci.yml)
[![npm version](https://img.shields.io/npm/v/react-native-notti-ota.svg)](https://www.npmjs.com/package/react-native-notti-ota)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](./CONTRIBUTING.md)
![Platforms](https://img.shields.io/badge/platform-Android%20%7C%20iOS-lightgrey.svg)

Ship JavaScript and asset fixes to your React Native app without a store release. Every update is signed with your own key, verified on the device before it is used, and rolled back automatically if it crashes or hangs on launch.

## Features

- **Signed updates**: every release is signed with your own key; the device verifies the signature and every file hash before using it.
- **Automatic rollback**: an update that crashes or hangs on launch is rolled back and blocked on that device.
- **Applied on the next cold start**: a running session never switches bundles.
- **Release channels and runtime versions**: target a release at the binaries it is compatible with.
- **Bare React Native and Expo**: native hooks for bare projects, and an Expo adapter plus config plugin with no `AppDelegate` or `MainApplication` edits.
- **Crash reporters keep working**: crash handlers are chained and always hand the crash on to the ones installed before them.

## Requirements

- React Native 0.83 or newer, New Architecture.
- Expo SDK 55 or newer (Expo projects). `expo-updates` must not be installed: it takes over the same bundle hook.
- Android 7.0 (API 24) or newer. iOS 15.1 or newer.
- A Notti App (App ID and client key) and a plan or license that includes Live updates.

## Status

Beta (0.x). The API may change between minor versions. Both packages are released together with the same version number.

## Quick start

**1. Install the SDK.**

```sh
# Bare React Native
npm install react-native-notti-ota
cd ios && pod install

# Expo (also remove expo-updates if you have it)
npx expo install react-native-notti-ota react-native-notti-ota-expo
```

**2. Create a signing key** with the [Notti CLI](https://github.com/zeeplabs/zeep-notti-cli) (`@notti/cli`), and register the printed public key in the Notti dashboard.

```sh
npm install --save-dev @notti/cli
npx notti ota keys generate --out notti-live-updates.private.pem
```

**3. Configure the app.** In Expo, add the config plugin to `app.json`:

```json
{
  "expo": {
    "plugins": [
      [
        "react-native-notti-ota",
        {
          "appId": "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f",
          "baseUrl": "https://app.zeepnotti.app",
          "clientKey": "your-client-key",
          "channel": "production",
          "runtimeVersion": "1.4.0",
          "publicKeys": ["-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----"]
        }
      ]
    ]
  }
}
```

Bare projects set the same values in `Info.plist` and `AndroidManifest.xml` and add one bundle hook per platform; see the [core package README](https://github.com/zeeplabs/zeep-notti-react-native-ota/tree/main/packages/react-native-notti-ota#readme). Self-hosted Notti: use your own `baseUrl`.

**4. Build and install a Release binary.** Live updates only act in Release builds; debug builds always load from Metro.

**5. Publish an update.** Change some JavaScript, then run once per platform from the project root:

```sh
export NOTTI_API_KEY=...          # the App REST key
export NOTTI_APP_ID=...           # the App ID
export NOTTI_OTA_PRIVATE_KEY=./notti-live-updates.private.pem

npx notti ota release --platform android --runtime-version 1.4.0 --channel production
npx notti ota release --platform ios --runtime-version 1.4.0 --channel production
```

`--runtime-version` and `--channel` must match the binary. Open the app, close it and open it again: the update is downloaded in the background and loaded on the next cold start.

## Packages

| Package | What it does |
| --- | --- |
| [`react-native-notti-ota`](https://github.com/zeeplabs/zeep-notti-react-native-ota/tree/main/packages/react-native-notti-ota#readme) | Native core (Android and iOS): picks the bundle at launch, checks for and downloads Live updates, verifies them, and rolls back broken ones. Includes the Expo config plugin. |
| [`react-native-notti-ota-expo`](https://github.com/zeeplabs/zeep-notti-react-native-ota/tree/main/packages/react-native-notti-ota-expo#readme) | Expo adapter: connects the core to Expo's supported bundle hooks. Only needed in Expo projects. |

Live updates are published with the Notti CLI (`notti ota release`). They are separate from the Notti push SDK ([`react-native-notti`](https://github.com/zeeplabs/zeep-notti-react-native)): you can use either one without the other.

## Clean-room rule

No code from CodePush, hot-updater, expo-updates or Revopush may be copied, adapted or added as a dependency, in any package, example or test. Their public documentation may be read to understand behaviour; the implementation here is written from the Notti specification and from the public APIs of React Native, Expo, Android and iOS only. Pull requests that bring in such code are rejected.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](./CONTRIBUTING.md) and the [code of conduct](./CODE_OF_CONDUCT.md) first. The repository layout, local development, native tests and the release process are described there and in [RELEASING.md](./RELEASING.md).

## Security

Do not report vulnerabilities in public issues. See [SECURITY.md](./SECURITY.md).

## License

MIT, see [LICENSE](./LICENSE).
