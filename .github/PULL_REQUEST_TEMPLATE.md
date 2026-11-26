## Summary

<!-- What does this PR change, and why? Link any related issue. -->

## Type of change

- [ ] `fix` — bug fix
- [ ] `feat` — new feature
- [ ] `refactor` — no behavior change
- [ ] `docs` — documentation only
- [ ] `test` — tests only
- [ ] `chore` — tooling/CI/build

## Checklist

- [ ] Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/en) (`fix:`, `feat:`, …) — enforced by commitlint on commit.
- [ ] `pnpm typecheck && pnpm lint && pnpm test` pass locally.
- [ ] If native code changed: the Android (`./gradlew :react-native-notti-ota:testDebugUnitTest`) and/or iOS unit tests pass locally — see [CONTRIBUTING.md](../CONTRIBUTING.md).
- [ ] Added/updated tests for the behavior this PR changes.
- [ ] Updated the README/docs if this changes public API or configuration.
- [ ] For a public-API, update verification or rollback change: discussed with maintainers first (open an issue before a large PR).
- [ ] No code copied or adapted from CodePush, hot-updater, expo-updates or Revopush (clean-room rule).

## Platforms affected

- [ ] Android
- [ ] iOS
- [ ] JS/TS
- [ ] Expo config plugin
- [ ] Expo adapter (`react-native-notti-ota-expo`)

## How was this tested?

<!-- Unit tests added, and/or manual test via an example app. Do not paste real keys, tokens or user data. -->
