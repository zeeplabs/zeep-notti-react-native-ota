#!/usr/bin/env bash
# Runs the CI jobs locally. Usage: scripts/ci-local.sh [js|android|ios|examples-android|examples-ios|all]
# IOS_SIMULATOR picks the simulator for the iOS unit tests (default: iPhone 17).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
target="${1:-all}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

run_js() {
  cd "$root"
  pnpm install --frozen-lockfile
  pnpm typecheck
  pnpm lint
  pnpm test
  pnpm build
}

run_android() {
  cd "$root/example-bare-083"
  pnpm install --ignore-workspace --frozen-lockfile
  cd android
  ./gradlew :react-native-notti-ota:testDebugUnitTest --console=plain
  cd "$root" && pnpm build
  cd "$root/example-expo-55"
  pnpm install --ignore-workspace --frozen-lockfile
  npx expo prebuild --platform android --clean --no-install
  cd android
  ./gradlew :react-native-notti-ota-expo:testReleaseUnitTest --console=plain
}

run_ios() {
  cd "$root/example-bare-083"
  pnpm install --ignore-workspace --frozen-lockfile
  bundle install
  bundle exec pod install --project-directory=ios
  cd "$root"
  xcodebuild test \
    -workspace example-bare-083/ios/NottiOtaBare083.xcworkspace \
    -scheme NottiOta-Unit-Tests \
    -destination "platform=iOS Simulator,name=${IOS_SIMULATOR:-iPhone 17}" \
    CODE_SIGNING_ALLOWED=NO
}

run_examples() {
  local platform="$1"
  cd "$root"
  pnpm install --frozen-lockfile
  pnpm build
  for example in example-bare-083 example-bare-088 example-expo-55 example-expo-58; do
    cd "$root/$example"
    pnpm install --ignore-workspace --frozen-lockfile
    pnpm "build:$platform"
  done
}

case "$target" in
  js) run_js ;;
  android) run_android ;;
  ios) run_ios ;;
  examples-android) run_examples android ;;
  examples-ios) run_examples ios ;;
  all)
    run_js
    run_android
    run_ios
    run_examples android
    run_examples ios
    ;;
  *)
    echo "unknown target: $target" >&2
    exit 2
    ;;
esac
