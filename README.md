# Notti Live updates for React Native

[![CI](https://github.com/zeeplabs/zeep-notti-react-native-ota/actions/workflows/ci.yml/badge.svg)](https://github.com/zeeplabs/zeep-notti-react-native-ota/actions/workflows/ci.yml)
[![npm version](https://img.shields.io/npm/v/react-native-notti-ota.svg)](https://www.npmjs.com/package/react-native-notti-ota)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](./CONTRIBUTING.md)
![Platforms](https://img.shields.io/badge/platform-Android%20%7C%20iOS-lightgrey.svg)

Ship JavaScript and asset fixes to your React Native app without a store release. Every update is signed with your own key, verified on the device before it is used, and rolled back automatically if it crashes or hangs on launch.

This repository holds two packages:

| Package | What it does |
| --- | --- |
| [`react-native-notti-ota`](packages/react-native-notti-ota) | Native core (Android and iOS): picks the bundle at launch, checks for and downloads Live updates, verifies them, and rolls back broken ones. |
| [`react-native-notti-ota-expo`](packages/react-native-notti-ota-expo) | Expo adapter: connects the core to Expo's supported bundle hooks. Only needed in Expo projects. |

Live updates are published with the Notti CLI (`notti ota release`). They are separate from the Notti push SDK (`react-native-notti`): you can use either one without the other.

## Requirements

- React Native 0.83 or newer, New Architecture.
- Expo SDK 55 or newer (Expo projects). `expo-updates` must not be installed: it takes over the same bundle hook.
- Android 7.0 (API 24) or newer. iOS 15.1 or newer.

## Status

Beta (0.x). The API may change between minor versions. Both packages are released together with the same version number.

## Repository layout

| Path | Contents |
| --- | --- |
| `packages/react-native-notti-ota` | Core package (Kotlin, Swift, TypeScript) |
| `packages/react-native-notti-ota-expo` | Expo adapter (Kotlin, Swift) |
| `example-bare-083`, `example-bare-088` | Bare React Native apps at the oldest and newest supported versions |
| `example-expo-55`, `example-expo-58` | Expo apps at the oldest and newest supported SDKs |
| `fixtures/ota` | Signed manifest and archives produced by the Notti CLI, shared by the Android and iOS tests |
| `docs/spikes.md` | Results of the integration spikes |

## Development

Use Node 22 and pnpm.

```sh
pnpm install
pnpm typecheck && pnpm lint && pnpm test
```

Each example app is a standalone project linked to the packages:

```sh
cd example-bare-083 && pnpm install --ignore-workspace
cd android && ./gradlew :react-native-notti-ota:testDebugUnitTest
```

`scripts/ci-local.sh` runs the same commands as CI.

## Clean-room rule

No code from CodePush, hot-updater, expo-updates or Revopush may be copied, adapted or added as a dependency, in any package, example or test. Their public documentation may be read to understand behaviour; the implementation here is written from the Notti specification and from the public APIs of React Native, Expo, Android and iOS only. Pull requests that bring in such code are rejected.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](./CONTRIBUTING.md) and the [code of conduct](./CODE_OF_CONDUCT.md) first.

## Security

Do not report vulnerabilities in public issues. See [SECURITY.md](./SECURITY.md).

## License

MIT, see [LICENSE](./LICENSE).
