# Contributing

Contributions are always welcome, no matter how large or small!

We want this community to be friendly and respectful to each other. Please follow it in all your interactions with the project. Before contributing, please read the [code of conduct](./CODE_OF_CONDUCT.md).

## Development workflow

This project is a monorepo managed using [pnpm workspaces](https://pnpm.io/workspaces) (see [`pnpm-workspace.yaml`](./pnpm-workspace.yaml)). It contains:

- [`packages/react-native-notti-ota`](./packages/react-native-notti-ota): the native core (Kotlin, Swift, TypeScript) and the Expo config plugin.
- [`packages/react-native-notti-ota-expo`](./packages/react-native-notti-ota-expo): the Expo adapter (Kotlin, Swift).
- `example-bare-083`, `example-bare-088`: bare React Native apps at the oldest and newest supported versions.
- `example-expo-55`, `example-expo-58`: Expo apps at the oldest and newest supported SDKs.
- `fixtures/ota`: signed manifest and archives shared by the Android and iOS tests.
- `e2e/` and `spikes/`: end-to-end flows and integration spikes (see [`docs/spikes.md`](./docs/spikes.md)).

Make sure you have the Node.js version from [`.nvmrc`](./.nvmrc) and [pnpm](https://pnpm.io/installation) installed. Install the workspace dependencies from the root directory:

```sh
pnpm install
```

> Since the project relies on pnpm workspaces, don't use `npm`/`yarn` for development.

The example apps are standalone projects (not part of the workspace) that link the local packages, so install each one you want to run with `--ignore-workspace`:

```sh
cd example-bare-083
pnpm install --ignore-workspace
pnpm start      # Metro
pnpm android    # or: pnpm ios
```

The Expo examples use `pnpm prebuild` (`expo prebuild --clean`) and `pnpm build:android` / `pnpm build:ios`. Live updates only act in Release builds, so use the `build:android` / `build:ios` scripts of the example apps to exercise them. JavaScript changes in the packages are picked up by the examples; native changes require rebuilding the app.

Make sure your code passes TypeScript:

```sh
pnpm typecheck
```

To check for linting errors, run the following:

```sh
pnpm lint
```

To fix formatting errors, run the following:

```sh
pnpm lint --fix
```

Remember to add tests for your change if possible. Run the JS/TS unit tests by:

```sh
pnpm test
```

### Native tests

Most of the logic lives natively (Kotlin and Swift), so a change to `android/` or `ios/` needs its own native test run, not just `pnpm test`. For example, for the core on Android:

```sh
cd example-bare-083
pnpm install --ignore-workspace
cd android && ./gradlew :react-native-notti-ota:testDebugUnitTest
```

[`scripts/ci-local.sh`](./scripts/ci-local.sh) runs the same commands as CI (`js`, `android`, `ios`, `examples-android`, `examples-ios` or `all`). The CI workflow is [`.github/workflows/ci.yml`](./.github/workflows/ci.yml).

### Commit message convention

We follow the [conventional commits specification](https://www.conventionalcommits.org/en) for our commit messages:

- `fix`: bug fixes, e.g. fix crash due to deprecated method.
- `feat`: new features, e.g. add new method to the module.
- `refactor`: code refactor, e.g. migrate from class components to hooks.
- `docs`: changes into documentation, e.g. add usage example for the module.
- `test`: adding or updating tests, e.g. add integration tests.
- `chore`: tooling changes, e.g. change CI config.

The repository configures [lefthook](https://github.com/evilmartians/lefthook) (see [`lefthook.yml`](./lefthook.yml)) to run ESLint and `tsc` on commit and [commitlint](https://commitlint.js.org/) on the commit message.

### Versioning and releases

Both packages are always released at the same version (lockstep), from a single `vX.Y.Z` tag. Do not bump versions by hand: `pnpm release` does it. Maintainers: the full process is described in [`RELEASING.md`](./RELEASING.md).

### Clean-room rule

No code from CodePush, hot-updater, expo-updates or Revopush may be copied, adapted or added as a dependency. See the [README](./README.md#clean-room-rule).

### Sending a pull request

> **Working on your first pull request?** You can learn how from this _free_ series: [How to Contribute to an Open Source Project on GitHub](https://app.egghead.io/playlists/how-to-contribute-to-an-open-source-project-on-github).

When you're sending a pull request:

- Prefer small pull requests focused on one change.
- Verify that `pnpm typecheck`, `pnpm lint`, `pnpm test` and any native tests you touched are passing.
- Review the documentation to make sure it looks good.
- Follow the [pull request template](./.github/PULL_REQUEST_TEMPLATE.md) when opening a pull request.
- For pull requests that change the public API, the update verification or the rollback behavior, discuss with maintainers first by opening an issue.
- Report security issues privately, as described in [SECURITY.md](./SECURITY.md), not in a public issue or pull request.
