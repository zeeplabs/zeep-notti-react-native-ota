# Spikes (T31)

Two throwaway prototypes that gate the native work (design risks R9 and R10), plus the Hermes header check the CLI could not run. Run on 2026-11-25 on macOS (Xcode 27.2, JDK 17, Android emulator API 37).

## (a) Expo adapter autolinking on Expo 55 and 58 (R9)

**Prototype.** `packages/react-native-notti-ota-expo` with:

- `expo-module.config.json`: `apple.reactDelegateHandlers: ["NottiOtaReactDelegateHandler"]` and `android.packages: ["com.notti.ota.expo.NottiOtaExpoPackage"]`;
- Android: a `Package` whose `createReactNativeHostHandlers` returns a `ReactNativeHostHandler` that logs from `getJSBundleFile` and rethrows from `onReactInstanceException`;
- iOS: an `ExpoReactDelegateHandler` subclass that logs from `bundleURL(reactDelegate:)`.

The example apps depend on the packages through `link:`, like a customer install from npm.

**Finding 1: the podspec must sit in a subdirectory.** Expo autolinking only looks for `*.podspec` one level down (`expo-modules-autolinking` `findPodspecFiles`: "top-level directories"), so a podspec at the package root is silently ignored on iOS. It lives in `ios/NottiOtaExpo.podspec`.

**Finding 2: Expo's Android host swallows instance errors once a handler exists** (`expo/android/.../ExpoReactHostFactory.kt`, `handleInstanceException`: throws only when `hostHandlers.isEmpty()`). Identical in Expo 55 and 58. This confirms R12: the adapter must rethrow (OTA-37 AC8).

| Check | Expo 55 (RN 0.83.10) | Expo 58 (RN 0.88.1) |
| --- | --- | --- |
| `expo-modules-autolinking resolve --platform android` lists `NottiOtaExpoPackage` | yes | yes |
| `expo-modules-autolinking resolve --platform apple` lists `NottiOtaReactDelegateHandler` (pod `NottiOtaExpo`) | yes | yes |
| Generated `ExpoModulesProvider.swift` registers the handler | yes (`(packageName: "react-native-notti-ota-expo", handler: NottiOtaReactDelegateHandler.self)`) | see below |
| `ReactNativeHostHandler` interface | identical file in both versions | identical |
| Android Release APK builds with the adapter | yes | yes |
| Android Release run on the emulator calls `getJSBundleFile` | yes: `I NottiOta: Live updates: Expo bundle hook called (developer support: false)`, then `Running "main"` | yes, same log line |
| iOS Release (simulator) builds with the adapter | yes | see below |
| iOS Release run calls `bundleURL(reactDelegate:)` | **not confirmed**: the app crashes in UIKit before React starts, see "iOS 27 scene lifecycle" | see below |

**Bare apps do not link Expo.** `react-native config` in `example-bare-083` and `example-bare-088` autolinks only `react-native-safe-area-context` and `react-native-notti-ota`; neither has `expo-modules-core` in `node_modules`, and the bare 0.83 Release APK has no `expo` entry.

**iOS 27 scene lifecycle (new risk, not caused by the adapter).** The Expo 55 Release app built with the iOS 27 SDK stops with `EXC_BREAKPOINT` in `_UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption` while UIKit creates the first scene, before any React or adapter code runs (crash report `exampleexpo55-2026-11-25-163549.ips`). Apps built with the newest Xcode must adopt `UIScene`; the Expo 55 / RN 0.83 templates use the app-delegate lifecycle. This matters for the iOS launch monitor (T38, risk R11) and for the RN 0.83 / Expo 55 floor when customers build with Xcode 27. To confirm on a device or an older simulator runtime before T38.

**Result: no blocker for T32.** Android is confirmed on both Expo versions. On iOS the handler is registered by autolinking on Expo 55; the runtime call is still open because of the scene-lifecycle crash above, and needs a confirmation before T38/T42 (iOS phase 5b/5c).

## (b) iOS gzip + ustar extractor with `Compression` (R10)

**Prototype.** `spikes/ios-extractor/main.swift`, run with `swift spikes/ios-extractor/main.swift fixtures/ota`:

1. parses the gzip header (RFC 1952: magic, CM = 8, FEXTRA, FNAME, FCOMMENT, FHCRC) and the 8-byte trailer (CRC32, ISIZE);
2. inflates the raw deflate body with `compression_decode_buffer(..., COMPRESSION_ZLIB)` (Apple's `COMPRESSION_ZLIB` is raw deflate, no zlib header), then checks the CRC32 and ISIZE;
3. reads ustar headers (magic, header checksum, `prefix` + `name`, octal size, type flag), and rejects absolute paths, `..` segments, symbolic links, other entry types, unlisted files and SHA-256 mismatches against `files.json`.

**Evidence** (CLI fixtures copied from `zeep-notti-cli` commit `6e5626e`):

```
PASS absolute-path.tar.gz: reject: entry /tmp/escape.js is absolute
PASS path-traversal.tar.gz: reject: entry ../escape.js leaves the extraction directory
PASS symlink.tar.gz: reject: entry assets/link is a symbolic link
PASS tampered.tar.gz: reject: index.android.bundle does not match the sha256 in files.json
PASS unlisted-file.tar.gz: reject: entry extra.js is not listed in files.json
PASS valid.tar.gz: accept (3 files, 5632 tar bytes)
```

Ran on macOS; `Compression` and `CryptoKit` have the same API on iOS 15.1+.

**Findings for T37.**

- The buffer API needs the output size up front and the prototype takes it from ISIZE. ISIZE is attacker-influenced and only modulo 2^32, so T37 must use the streaming `compression_stream` API with a hard output cap (the manifest's total file size), not ISIZE.
- Verifying the archive SHA-256 before inflating (as the design orders it) makes the CRC32 check redundant; keep it as a cheap corruption check.

**Result: no blocker.**

## Hermes bytecode header (for the CLI and the device compatibility check)

Compiled `var a = 1; print(a + 1);` with the real `hermesc` (`-emit-binary`) from each version's `hermes-compiler` package, and read the embedded `index.android.bundle` from the Release APKs built by Gradle:

| React Native | `hermes-compiler` | First 12 bytes | Bytecode version |
| --- | --- | --- | --- |
| 0.83.10 | 0.14.1 | `c6 1f bc 03 c1 03 19 1f 60 00 00 00` | 96 |
| 0.88.1 | 260318099.0.5 | `c6 1f bc 03 c1 03 19 1f 63 00 00 00` | 99 |

- Magic: bytes 0 to 7 are `c6 1f bc 03 c1 03 19 1f` (the little-endian uint64 `0x1F1903C103BC1FC6`), the same in both versions.
- Version: bytes 8 to 11, little-endian uint32.

The CLI can validate the magic before reading the version; the Android verifier already requires it (`HermesHeader`).
