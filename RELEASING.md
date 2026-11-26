# Releasing

This repository publishes two npm packages, always at the **same version** (lockstep):

1. `react-native-notti-ota` (native core)
2. `react-native-notti-ota-expo` (Expo adapter, peer-depends on the core)

One tag `vX.Y.Z` releases both, core first. The root `package.json` version is the single source of truth.

Why lockstep: the adapter only works with the core it was built against, and the SDK reports one `sdk_version` to the Notti server. A single version number and a single tag removes the "which adapter goes with which core" question, and the adapter's peer range on the core is kept at `^X.Y.Z` automatically.

The flow is the same as `react-native-notti`: `pnpm release` bumps the version, writes `CHANGELOG.md` and creates the tag. Pushing the tag runs `.github/workflows/release.yml`, which publishes to npm through [trusted publishing (OIDC)](https://docs.npmjs.com/trusted-publishers), with no `NPM_TOKEN`, and then creates the GitHub Release from `CHANGELOG.md`. Do not publish from your machine after the first release and do not hand-write `chore: release` commits.

## What `pnpm release` changes

release-it bumps the root version, then the `after:bump` hook (`scripts/sync-versions.js`) copies it to:

- `packages/*/package.json` `version`
- the adapter's peer dependency on the core (`^X.Y.Z`)
- `OTAUpdater.swift` (`sdkVersion`), `OTAUpdater.kt` (`SDK_VERSION`) and the adapter's `android/build.gradle` `version`

CI fails if any of these drift (`node scripts/sync-versions.js --check`). Never edit the versions by hand.

## Regular release

1. Be on an up to date `main` with a clean working tree and CI green.
2. Run `pnpm release`. release-it computes the next version from the Conventional Commits since the last tag (you can override it at the prompt), prepends the entry to `CHANGELOG.md`, runs the sync hook, commits `chore: release X.Y.Z`, creates the tag `vX.Y.Z` and pushes both.
3. The tag triggers `Release`. It checks that the tag matches the root and both package versions, runs typecheck, builds both packages (`pnpm build`), packs them (see below), publishes the core and then the adapter with `npm publish <tarball> --access public`, and creates the GitHub Release.
4. Confirm both versions on npmjs.com.

Versions already on npm are skipped, so re-running a failed workflow (for example after the core was published and the adapter was not) is safe.

## How the packages are published

- The workflow runs `scripts/pack-packages.js`, which uses `pnpm pack` and then checks the tarballs: same version as the root, no `workspace:`, `link:` or `file:` specifier left in any manifest, and the adapter's peer range on the core equals `^X.Y.Z`. `pnpm pack` is used because it rewrites the adapter's `workspace:*` dev dependency on the core into the real version, while `npm pack` / `npm publish` from the package directory would publish `workspace:*` as-is.
- The tarballs are published with `npm publish <tarball>`, not `pnpm publish`, so the OIDC trusted-publishing handshake and provenance are done by the npm CLI itself.
- The publish job runs on Node 24 because trusted publishing needs npm 11.5.1 or newer (the npm bundled with Node 22 is 10.x).
- Native code is published as source (`android/`, `ios/`, the podspecs, the Expo module config). JavaScript is published pre-compiled: each package builds `lib/module` (ESM) and `lib/typescript` (declarations) with react-native-builder-bob (`pnpm build`), and `main`, `types` and `exports` point at `lib/`. `src/` is also shipped (needed by React Native codegen, source maps and the `source` export condition). The core also ships `plugin/build` (the compiled Expo config plugin). `scripts/pack-packages.js` runs each package's `build` right before `pnpm pack` and fails if `main`/`types`/`exports` targets are missing from a tarball or if `__tests__`, `__fixtures__` or `__mocks__` are included. Tests, example apps, fixtures, `ios/Tests` and `android/src/test` are not published.

## First publish (one time, by hand)

A Trusted Publisher can only be attached to a package that already exists on npm, so the first version of **each** package is published manually.

1. Be logged in to npm (`npm whoami`) as a maintainer allowed to create packages on the registry, with 2FA enabled.
2. From a clean checkout of `main`, with Node 22 or newer:

   ```sh
   pnpm install --frozen-lockfile
   pnpm typecheck && pnpm lint && pnpm test
   pnpm build
   node scripts/pack-packages.js .pack     # packs and validates both tarballs
   ```

   Inspect `tar -tzf .pack/*.tgz` if you want to double check the file lists.
3. Publish the core first, then the adapter:

   ```sh
   npm publish .pack/react-native-notti-ota-0.1.0.tgz --access public
   npm publish .pack/react-native-notti-ota-expo-0.1.0.tgz --access public
   ```

4. Set up a Trusted Publisher for each package (next section).
5. Tag the published commit so history and the GitHub Release line up:

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

   The workflow sees that both `0.1.0` packages are already on npm, skips the publish and creates the GitHub Release from the `0.1.0` section of `CHANGELOG.md`. It also gives release-it its first tag, so the next `pnpm release` only picks up newer commits.

## Trusted Publisher setup (npmjs.com)

Do this **once for each package**: `react-native-notti-ota` and `react-native-notti-ota-expo`. On npmjs.com open the package, then **Settings**, **Trusted Publisher**, choose **GitHub Actions** and fill in:

| Field | Value |
| --- | --- |
| Organization or user | `zeeplabs` |
| Repository | `zeep-notti-react-native-ota` |
| Workflow filename | `release.yml` |
| Environment | leave empty |

The workflow already has `id-token: write`. Once both packages have it, you can set **Publishing access** on each one to require 2FA and disallow tokens.
