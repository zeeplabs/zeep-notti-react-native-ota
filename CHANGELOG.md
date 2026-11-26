# Changelog

# 0.1.0 (2026-11-26)

First release (beta). `react-native-notti-ota` and `react-native-notti-ota-expo` are versioned and released together (lockstep): both always carry the same version.

### Features

* **react-native-notti-ota:** native core for Android and iOS. Picks the bundle at launch, checks for and downloads Live updates in the background, verifies the signed manifest and archive on the device, applies a new release on the next cold start and rolls back automatically a release that crashes or hangs on launch.
* **react-native-notti-ota-expo:** Expo adapter that connects the core to Expo's supported bundle hooks. Only needed in Expo projects.
* Expo config plugin (`app.plugin.js`) shipped with the core.

### Notes

* Beta: the API may change in 0.x minor versions.
* Requires React Native 0.83 or newer (New Architecture), and Expo SDK 55 or newer for the adapter. `expo-updates` must not be installed.
* Releases are published with the Notti CLI (`@notti/cli`, `notti ota release`).
