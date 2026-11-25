# react-native-notti-ota

Notti Live updates for React Native: ship JavaScript and asset fixes without a store release. Every update is signed with your own key, verified on the device before it is used, and rolled back automatically if it crashes or hangs on launch.

Requirements: React Native 0.83 or newer (New Architecture), iOS 15.1+, Android 7.0 (API 24)+. Releases are published with the Notti CLI (`notti ota release`).

## How it works

- The native layer picks the bundle before any JavaScript runs: the newest verified update, or the bundle embedded in the binary.
- After the app shows its first content, the SDK checks for an update in the background, downloads it, verifies the signature and every file hash, and keeps it for the **next cold start**. A running session never switches bundles.
- A new update must show content for 3 seconds without a fatal error. Two failed launches (crash, or no content within 10 seconds) roll it back and block it on that device.
- Installing a new binary (store update, new build) discards every downloaded update.
- Debug builds always load from Metro; Live updates only act in Release builds.

## Configuration

Add these keys to `Info.plist` (iOS) and as `<meta-data>` in `AndroidManifest.xml` (Android). In an Expo project the config plugin writes them for you. Without them, or with any invalid value, Live updates stay off and the embedded bundle is used.

| Key | Value |
| --- | --- |
| `NottiOTAAppId` | Notti App ID (UUID) |
| `NottiOTABaseUrl` | Notti API base URL, for example `https://api.notti.app` |
| `NottiOTAClientKey` | The App's client key (public, device-restricted) |
| `NottiOTAChannel` | Release channel, `[a-z0-9-]{1,32}`, for example `production` |
| `NottiOTARuntimeVersion` | Your runtime version: change it whenever native code changes |
| `NottiOTAPublicKeys` | 1 to 5 signing public keys, comma-separated, each `key_id:base64` (the 65-byte uncompressed P-256 point, as printed by `notti ota keys generate`) |

On Android, a meta-data value that looks like a decimal number (`1.10`) is read as a float and refused; use `1.10.0` or another non-numeric form.

## Bare React Native

One change per platform. Use Live updates only in Release builds.

### iOS, React Native 0.83 to 0.87

In `AppDelegate.swift`, return the selected bundle from your `ReactNativeDelegate`:

```swift
import NottiOta

class ReactNativeDelegate: RCTDefaultReactNativeFactoryDelegate {
  override func bundleURL() -> URL? {
#if DEBUG
    RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
#else
    NottiOTA.bundleURL() ?? Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
  }
}
```

### iOS, React Native 0.88 and newer

The template starts React Native from `SceneDelegate.swift`, which is the factory delegate. Make the same change in its `bundleURL()`:

```swift
import NottiOta

class SceneDelegate: RCTDefaultReactNativeFactoryDelegate, UIWindowSceneDelegate {
  override func bundleURL() -> URL? {
#if DEBUG
    RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
#else
    NottiOTA.bundleURL() ?? Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
  }
}
```

Do not set a custom `bundleConfiguration` on the factory (React Native 0.84+): it takes precedence over `bundleURL()`. The SDK detects it and turns Live updates off for the session.

### Android

In `MainApplication.kt`, pass the selected bundle to the React host:

```kotlin
import com.notti.ota.NottiOta

override val reactHost: ReactHost by lazy {
  getDefaultReactHost(
    context = applicationContext,
    packageList = PackageList(this).packages,
    jsBundleFilePath = NottiOta.getJSBundleFile(applicationContext),
  )
}
```

### If the hook is missing

When the configuration is present but the app never asks the SDK for its bundle, the SDK logs an error at startup and reports `integration_missing` once per binary. When another bundle is loaded instead of the selected one, it reports `bundle_overridden` and turns Live updates off for that session. Both show in the Notti dashboard.

## Xcode 27 and the scene life cycle

Apps built with Xcode 27 (iOS 27 SDK) must adopt the `UIScene` life cycle, or UIKit stops them at launch, before React Native starts. React Native 0.88+ and Expo SDK 56+ templates already use a `SceneDelegate`. If your app was created from an older template (React Native 0.83 to 0.87, Expo SDK 55), adopt `UIScene` before building with Xcode 27, or move to a newer template.
