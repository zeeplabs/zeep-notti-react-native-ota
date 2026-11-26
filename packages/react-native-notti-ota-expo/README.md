# react-native-notti-ota-expo

[![npm version](https://img.shields.io/npm/v/react-native-notti-ota-expo.svg)](https://www.npmjs.com/package/react-native-notti-ota-expo)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/zeeplabs/zeep-notti-react-native-ota/blob/main/LICENSE)
![Platforms](https://img.shields.io/badge/platform-Android%20%7C%20iOS-lightgrey.svg)
![Status: Beta](https://img.shields.io/badge/status-beta-orange.svg)

> **Beta (0.x).** Released together with `react-native-notti-ota`, with the same version number.

Expo adapter for [Notti Live updates](https://github.com/zeeplabs/zeep-notti-react-native-ota#readme). It connects [`react-native-notti-ota`](https://www.npmjs.com/package/react-native-notti-ota) to Expo's supported bundle hooks (an Expo module with a React delegate handler on iOS and a host handler on Android), so you do not edit `AppDelegate` or `MainApplication`.

Only needed in Expo projects. Bare React Native projects use `react-native-notti-ota` alone.

## Requirements

- Expo SDK 55 or newer, with prebuild or a development build (not Expo Go).
- `react-native-notti-ota` (same version as this package; both are released in lockstep).
- `expo-updates` must not be installed: it takes over the same bundle hook, and `expo prebuild` fails if it is present.

## Installation

```sh
npx expo install react-native-notti-ota react-native-notti-ota-expo
```

## Usage

The Expo config plugin is provided by `react-native-notti-ota`. Add it to your app config:

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

Then run `npx expo prebuild`. Live updates only act in Release builds. See the [`react-native-notti-ota` README](https://github.com/zeeplabs/zeep-notti-react-native-ota/tree/main/packages/react-native-notti-ota#readme) for how updates are verified and rolled back, and for every option.

Publish releases with the [Notti CLI](https://github.com/zeeplabs/zeep-notti-cli) (`notti ota keys generate`, `notti ota release`).

## Related

- [`react-native-notti-ota`](https://www.npmjs.com/package/react-native-notti-ota): the native core and the config plugin.
- [Notti CLI](https://github.com/zeeplabs/zeep-notti-cli) (`@notti/cli`).
- [`react-native-notti`](https://github.com/zeeplabs/zeep-notti-react-native): Notti push SDK, independent of Live updates.

## Contributing

Contributions are welcome: see [CONTRIBUTING.md](https://github.com/zeeplabs/zeep-notti-react-native-ota/blob/main/CONTRIBUTING.md) and the [code of conduct](https://github.com/zeeplabs/zeep-notti-react-native-ota/blob/main/CODE_OF_CONDUCT.md).

## Security

Do not report vulnerabilities in public issues: see [SECURITY.md](https://github.com/zeeplabs/zeep-notti-react-native-ota/blob/main/SECURITY.md).

## License

MIT, see [LICENSE](https://github.com/zeeplabs/zeep-notti-react-native-ota/blob/main/LICENSE).
