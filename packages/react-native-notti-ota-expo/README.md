# react-native-notti-ota-expo

Expo adapter for [Notti Live updates](https://github.com/zeeplabs/zeep-notti-react-native-ota). It connects [`react-native-notti-ota`](../react-native-notti-ota) to Expo's supported bundle hooks (an Expo module with a React delegate handler on iOS and a host handler on Android), so you do not edit `AppDelegate` or `MainApplication`.

Only needed in Expo projects. Bare React Native projects use `react-native-notti-ota` alone.

## Requirements

- Expo SDK 55 or newer, with prebuild or a development build (not Expo Go).
- `react-native-notti-ota` (same version as this package; both are released in lockstep).
- `expo-updates` must not be installed: it takes over the same bundle hook, and `expo prebuild` fails if it is present.

## Installation

```sh
npx expo install react-native-notti-ota react-native-notti-ota-expo
```

## Configuration

The Expo config plugin is provided by `react-native-notti-ota`. Add it to your app config:

```json
{
  "expo": {
    "plugins": [
      [
        "react-native-notti-ota",
        {
          "appId": "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f",
          "baseUrl": "https://api.notti.app",
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

Then run `npx expo prebuild`. Live updates only act in Release builds. See the [`react-native-notti-ota` README](../react-native-notti-ota/README.md) for how updates are verified and rolled back, and for every option.

## License

MIT
