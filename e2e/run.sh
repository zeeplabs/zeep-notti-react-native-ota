#!/usr/bin/env bash
# Live updates end-to-end matrix for one example on one platform, against the
# local stack (e2e/stack, prepared by e2e/setup.sh) and the Notti CLI.
#
# Usage: e2e/run.sh <example> <android|ios> [flow...]
#   flows (default: all, in this order): publish crash hang headless tampered
#   new-binary disable disable-all
#
# Env: NOTTI_CLI (path to the CLI's dist/cli.js), ANDROID_SERIAL (emulator),
# IOS_SIMULATOR_UDID (booted simulator), E2E_SKIP_BUILD=1 to reuse the last build.
# Writes results/<example>-<platform>.tsv: flow, PASS/FAIL, evidence.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
example="$1"
platform="$2"
shift 2
flows=("$@")
[[ ${#flows[@]} -gt 0 ]] || flows=(publish crash hang headless tampered new-binary disable disable-all)

set -a
# shellcheck disable=SC1091
source "$here/.env.local"
# shellcheck disable=SC1090
source "$here/.env.$example"
set +a

cli="${NOTTI_CLI:-$root/../zeep-notti-cli/dist/cli.js}"
dir="$root/$example"
results="$here/results"
mkdir -p "$results"
out="$results/$example-$platform.tsv"
: > "$out"
log="$results/$example-$platform.log"
: > "$log"

case "$example" in
  example-bare-*) kind=bare; runtime=1.0.0; name="NottiOtaBare${example#example-bare-}" ;;
  example-expo-*) kind=expo; runtime=1.4.0; name="" ;;
  *) echo "unknown example $example" >&2; exit 2 ;;
esac
pkg="com.notti.ota.example.${example#example-}"
pkg="${pkg//-/}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
adb="$ANDROID_HOME/platform-tools/adb"
serial="${ANDROID_SERIAL:-emulator-5554}"
udid="${IOS_SIMULATOR_UDID:-booted}"

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$log" >&2; }
record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$out"; say "RESULT $1 $2 $3"; }

# ---- API -------------------------------------------------------------------

api() {
  curl -sS -m 30 -X "$1" -H "Authorization: Bearer $NOTTI_API_KEY" -H 'Content-Type: application/json' \
    ${3:+--data "$3"} "$NOTTI_E2E_BASE_URL/v1/apps/$NOTTI_APP_ID$2"
}

# Prints "applied=1 rolled_back=0 ... | rolled_back:crash=1" for a release.
events_of() {
  api GET "/ota/releases/$1" | jq -r '
    ([.counts | to_entries[] | select(.value > 0) | "\(.key)=\(.value)"] | join(" ")) + " | " +
    ([(.reasons // {}) | to_entries[] | .key as $t | .value | to_entries[] | "\($t):\(.key)=\(.value)"] | join(" "))'
}

count_of() {
  api GET "/ota/releases/$1" | jq -r --arg t "$2" --arg r "${3:-}" \
    'if $r == "" then (.counts[$t] // 0) else ((.reasons[$t] // {})[$r] // 0) end'
}

set_enabled() {
  api PATCH "/ota/releases/$1" "{\"enabled\":$2}" | jq -r '.enabled'
}

# Publishes the example with variant.js set to $1; prints the release id.
publish() {
  local variant="$1"
  printf "// Rewritten by the e2e flows before each \`notti ota release\`.\nexport const VARIANT = '%s';\n" "$variant" > "$dir/variant.js"
  local result
  result=$(cd "$dir" && node "$cli" ota release --platform "$platform" --runtime-version "$runtime" \
    --base-url "$NOTTI_E2E_BASE_URL" 2>>"$log" | tee -a "$log" | sed -n 's/^Live update published: release \([0-9a-f-]*\).*/\1/p')
  printf "// Rewritten by the e2e flows before each \`notti ota release\`.\nexport const VARIANT = 'embedded';\n" > "$dir/variant.js"
  [[ -n "$result" ]] || { say "publish $variant failed"; return 1; }
  say "published $variant as ${result:0:8}"
  printf '%s' "$result"
}

# ---- device ----------------------------------------------------------------

maestro_device() { if [[ "$platform" == android ]]; then echo "$serial"; else xcrun simctl list devices booted -j | jq -r '[.devices[][] | select(.state=="Booted")][0].udid'; fi; }

expect_variant() {
  if maestro --device "$(maestro_device)" test -e APP_ID="$pkg" -e VARIANT="$1" "$here/flows/expect-variant.yaml" >>"$log" 2>&1; then
    return 0
  fi
  say "maestro: variant $1 not visible"
  return 1
}

stop_app() {
  if [[ "$platform" == android ]]; then "$adb" -s "$serial" shell am force-stop "$pkg"
  else xcrun simctl terminate "$udid" "$pkg" >/dev/null 2>&1 || true; fi
}

launch_raw() {
  stop_app
  if [[ "$platform" == android ]]; then
    "$adb" -s "$serial" shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  else
    xcrun simctl launch "$udid" "$pkg" >/dev/null 2>&1
  fi
}

is_alive() {
  if [[ "$platform" == android ]]; then
    [[ -n "$("$adb" -s "$serial" shell pidof "$pkg" | tr -d '\r')" ]]
  else
    xcrun simctl spawn "$udid" launchctl list 2>/dev/null | grep "UIKitApplication:$pkg" | awk '{print $1}' | grep -qv '^-$'
  fi
}

ios_state() {
  [[ "$platform" == ios ]] || return 0
  local data
  data=$(xcrun simctl get_app_container "$udid" "$pkg" data 2>/dev/null) || return 0
  jq -c '{stable: (.stable.release_id // null | if . then .[0:8] else . end), pending: (.pending.release_id // null | if . then .[0:8] else . end),
    failed_count, interrupted_count, blocklist: [.blocklist[]?[0:8]]}' "$data/Library/Application Support/NottiOTA/state.json" 2>/dev/null
}

app_path() {
  if [[ "$platform" == android ]]; then echo "$dir/android/app/build/outputs/apk/release/app-release.apk"
  else
    local scheme="$name"
    [[ -n "$scheme" ]] || scheme="$(basename "$dir"/ios/*.xcworkspace .xcworkspace)"
    echo "$dir/ios/build/e2e/Build/Products/Release-iphonesimulator/$scheme.app"
  fi
}

build() {
  [[ "${E2E_SKIP_BUILD:-}" == 1 ]] && return 0
  say "building $example for $platform (Release)"
  printf "// Rewritten by the e2e flows before each \`notti ota release\`.\nexport const VARIANT = 'embedded';\n" > "$dir/variant.js"
  if [[ "$kind" == expo ]]; then
    (cd "$dir" && npx expo prebuild --platform "$platform" --no-install >>"$log" 2>&1) || return 1
    if [[ "$platform" == ios ]]; then (cd "$dir/ios" && pod install >>"$log" 2>&1) || return 1; fi
  fi
  if [[ "$platform" == android ]]; then
    (cd "$dir/android" && ./gradlew assembleRelease --console=plain \
      -PnottiOtaAppId="$NOTTI_APP_ID" -PnottiOtaBaseUrl="$NOTTI_E2E_BASE_URL" -PnottiOtaClientKey="$NOTTI_E2E_CLIENT_KEY" \
      -PnottiOtaPublicKeys="$NOTTI_E2E_PUBLIC_KEY" -PnottiOtaRuntimeVersion="$runtime" >>"$log" 2>&1)
  else
    local scheme="$name"
    [[ -n "$scheme" ]] || scheme="$(basename "$dir"/ios/*.xcworkspace .xcworkspace)"
    (cd "$dir/ios" && xcodebuild -workspace "$scheme.xcworkspace" -scheme "$scheme" -configuration Release \
      -sdk iphonesimulator -derivedDataPath build/e2e CODE_SIGNING_ALLOWED=NO \
      NOTTI_OTA_APP_ID="$NOTTI_APP_ID" NOTTI_OTA_BASE_URL="$NOTTI_E2E_BASE_URL" NOTTI_OTA_CLIENT_KEY="$NOTTI_E2E_CLIENT_KEY" \
      NOTTI_OTA_PUBLIC_KEYS="$NOTTI_E2E_PUBLIC_KEY" NOTTI_OTA_RUNTIME_VERSION="$runtime" NOTTI_OTA_CHANNEL=production \
      build >>"$log" 2>&1)
  fi
}

install_fresh() {
  if [[ "$platform" == android ]]; then
    "$adb" -s "$serial" uninstall "$pkg" >/dev/null 2>&1
    "$adb" -s "$serial" install "$(app_path)" >>"$log" 2>&1
    "$adb" -s "$serial" reverse tcp:18080 tcp:18080 >/dev/null
    "$adb" -s "$serial" reverse tcp:19000 tcp:19000 >/dev/null
  else
    xcrun simctl uninstall "$udid" "$pkg" >/dev/null 2>&1
    xcrun simctl install "$udid" "$(app_path)"
  fi
}

# Reinstalls the same build as a new binary: Android updates the install time,
# iOS gets a new CFBundleVersion (both are part of the binary identity).
install_new_binary() {
  if [[ "$platform" == android ]]; then
    "$adb" -s "$serial" install -r "$(app_path)" >>"$log" 2>&1
  else
    local copy="$results/new-binary-$example.app"
    rm -rf "$copy" && cp -R "$(app_path)" "$copy"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%s)" "$copy/Info.plist"
    codesign --force --sign - "$copy" >>"$log" 2>&1
    xcrun simctl install "$udid" "$copy"
  fi
}

settle() { sleep "${1:-8}"; }

# ---- flows -----------------------------------------------------------------

v1="" crash_id="" hang_id="" v2="" stable_variant="embedded"

flow_publish() {
  install_fresh || { record publish FAIL "install failed"; return; }
  v1=$(publish v1) || { record publish FAIL "publish failed"; return; }
  expect_variant embedded || { record publish FAIL "first cold start did not show the embedded bundle"; return; }
  settle 8
  expect_variant v1 || { record publish FAIL "second cold start did not run v1"; return; }
  settle 6
  stop_app
  expect_variant v1 || { record publish FAIL "third cold start did not keep v1"; return; }
  settle 4
  local applied
  applied=$(count_of "$v1" applied)
  stable_variant=v1
  if [[ "$applied" -ge 1 ]]; then record publish PASS "v1 ${v1:0:8} shown on the 2nd cold start; API: $(events_of "$v1"); ios_state=$(ios_state)"
  else record publish FAIL "v1 shown but API applied=$applied"; fi
}

failing_release() {
  local flow="$1" variant="$2" reason="$3" wait_s="$4" id
  id=$(publish "$variant") || { record "$flow" FAIL "publish failed"; return 1; }
  expect_variant "$stable_variant" || { record "$flow" FAIL "the stable bundle did not show before the download"; return 1; }
  settle 8
  local alive=()
  for attempt in 1 2; do
    launch_raw
    sleep "$wait_s"
    if is_alive; then alive+=("$attempt:alive"); else alive+=("$attempt:dead"); fi
    say "$variant launch $attempt: state=$(ios_state)"
    stop_app
  done
  expect_variant "$stable_variant" || { record "$flow" FAIL "the stable bundle did not come back after 2 failed launches (${alive[*]})"; set_enabled "$id" false >/dev/null; return 1; }
  settle 6
  local rolled
  rolled=$(count_of "$id" rolled_back "$reason")
  if [[ "$rolled" == 0 && "$reason" == any-failure ]]; then
    rolled=$(( $(count_of "$id" rolled_back crash) + $(count_of "$id" rolled_back watchdog) ))
  fi
  set_enabled "$id" false >/dev/null
  if [[ "$rolled" -ge 1 ]]; then
    record "$flow" PASS "${variant} ${id:0:8}: launches ${alive[*]}; back on $stable_variant; API: $(events_of "$id"); ios_state=$(ios_state)"
  else
    record "$flow" FAIL "${variant} ${id:0:8}: launches ${alive[*]}; API rolled_back:$reason=$rolled ($(events_of "$id"))"
  fi
  printf '%s' "$id"
}

# iOS: in a bare app a JS error while the bundle loads is logged as "Unhandled JS Exception:
# [runtime not ready]" and does not reach RCTFatal (RN 0.83+ bridgeless, Release), so the watchdog
# catches it; the Expo host does call the fatal handler (crash). Either reason is a rollback.
flow_crash() {
  if [[ "$platform" == ios ]]; then crash_id=$(failing_release crash crash any-failure 13)
  else crash_id=$(failing_release crash crash crash 6); fi
}
flow_hang() { hang_id=$(failing_release hang hang watchdog 13); }

flow_headless() {
  if [[ "$platform" != android || "$kind" != bare ]]; then
    record headless "NOT RUN" "headless start harness exists only in the bare Android examples (E2EHeadlessReceiver)"
    return
  fi
  v2=$(publish v2) || { record headless FAIL "publish failed"; return; }
  expect_variant "$stable_variant" || { record headless FAIL "stable bundle not shown"; return; }
  settle 8
  stop_app
  for i in 1 2 3; do
    "$adb" -s "$serial" shell am broadcast -f 0x20 -n "$pkg/.E2EHeadlessReceiver" >>"$log" 2>&1
    sleep 4
    say "headless start $i: process alive=$(is_alive && echo yes || echo no)"
    "$adb" -s "$serial" shell am force-stop "$pkg"
  done
  expect_variant v2 || { record headless FAIL "after 3 headless starts the pending v2 did not run"; return; }
  settle 6
  stop_app
  expect_variant v2 || { record headless FAIL "v2 not kept"; return; }
  settle 4
  local applied rolled
  applied=$(count_of "$v2" applied); rolled=$(count_of "$v2" rolled_back)
  stable_variant=v2
  if [[ "$applied" -ge 1 && "$rolled" == 0 ]]; then record headless PASS "3 headless starts with v2 ${v2:0:8} pending counted nothing: v2 then applied; API: $(events_of "$v2")"
  else record headless FAIL "API applied=$applied rolled_back=$rolled"; fi
}

flow_tampered() {
  if [[ -z "$v2" ]]; then
    v2=$(publish v2) || { record tampered FAIL "publish v2 failed"; return; }
    expect_variant "$stable_variant"; settle 8
    expect_variant v2 || { record tampered FAIL "v2 not applied first"; return; }
    settle 6; stable_variant=v2
  fi
  local id key
  id=$(publish v3) || { record tampered FAIL "publish failed"; return; }
  key=$(AWS_ACCESS_KEY_ID=notti-e2e AWS_SECRET_ACCESS_KEY=notti-e2e-secret AWS_DEFAULT_REGION=us-east-1 \
    aws --endpoint-url http://localhost:19000 s3api list-objects-v2 --bucket notti-ota-e2e --prefix "ota/apps/$NOTTI_APP_ID/" \
    --query 'sort_by(Contents,&LastModified)[-1].Key' --output text)
  local tmp="$results/tamper.tar.gz"
  AWS_ACCESS_KEY_ID=notti-e2e AWS_SECRET_ACCESS_KEY=notti-e2e-secret AWS_DEFAULT_REGION=us-east-1 \
    aws --endpoint-url http://localhost:19000 s3 cp "s3://notti-ota-e2e/$key" "$tmp" >/dev/null
  printf '\x00' | dd of="$tmp" bs=1 seek=4096 conv=notrunc 2>/dev/null
  AWS_ACCESS_KEY_ID=notti-e2e AWS_SECRET_ACCESS_KEY=notti-e2e-secret AWS_DEFAULT_REGION=us-east-1 \
    aws --endpoint-url http://localhost:19000 s3 cp "$tmp" "s3://notti-ota-e2e/$key" >/dev/null
  say "tampered one byte of the stored archive of ${id:0:8}"
  expect_variant "$stable_variant" || { record tampered FAIL "stable not shown"; return; }
  settle 8
  expect_variant "$stable_variant" || { record tampered FAIL "the tampered release ran"; set_enabled "$id" false >/dev/null; return; }
  settle 6
  local failed applied
  failed=$(count_of "$id" verification_failed); applied=$(count_of "$id" applied)
  set_enabled "$id" false >/dev/null
  if [[ "$failed" -ge 1 && "$applied" == 0 ]]; then record tampered PASS "v3 ${id:0:8} archive tampered in MinIO: never ran, $stable_variant kept; API: $(events_of "$id")"
  else record tampered FAIL "API verification_failed=$failed applied=$applied ($(events_of "$id"))"; fi
}

flow_new_binary() {
  expect_variant "$stable_variant" || { record new-binary FAIL "stable $stable_variant not shown before reinstall"; return; }
  stop_app
  install_new_binary || { record new-binary FAIL "reinstall failed"; return; }
  if expect_variant embedded; then
    record new-binary PASS "after installing a new binary the first cold start ran the embedded bundle (was $stable_variant); ios_state=$(ios_state)"
  else
    record new-binary FAIL "after reinstall the embedded bundle did not run"
  fi
  settle 8
  expect_variant "$stable_variant" >/dev/null 2>&1 || true
  settle 6
}

flow_disable() {
  local current_id previous
  if [[ "$stable_variant" == v2 ]]; then current_id="$v2"; previous=v1; else
    record disable "NOT RUN" "needs v1 and v2 published (run publish and headless or tampered first)"; return; fi
  [[ -n "$v1" ]] || { record disable "NOT RUN" "v1 missing"; return; }
  expect_variant v2 || { record disable FAIL "v2 not running before disable"; return; }
  [[ "$(set_enabled "$current_id" false)" == false ]] || { record disable FAIL "PATCH enabled=false failed"; return; }
  stop_app
  expect_variant v2 || { record disable FAIL "v2 not shown after disable"; return; }
  settle 8
  expect_variant "$previous" || { record disable FAIL "previous release v1 did not run after disabling v2"; return; }
  settle 6
  stable_variant=v1
  record disable PASS "v2 ${current_id:0:8} disabled: next cold starts ran v1 ${v1:0:8} again; API v1: $(events_of "$v1"); ios_state=$(ios_state)"
}

flow_disable_all() {
  [[ -n "$v1" ]] || { record disable-all "NOT RUN" "v1 missing"; return; }
  expect_variant "$stable_variant" || { record disable-all FAIL "$stable_variant not running"; return; }
  for id in "$v1" "$v2"; do [[ -n "$id" ]] && set_enabled "$id" false >/dev/null; done
  stop_app
  expect_variant "$stable_variant" || { record disable-all FAIL "not shown after disabling"; return; }
  settle 8
  expect_variant embedded || { record disable-all FAIL "embedded bundle did not come back"; return; }
  settle 6
  local reverted
  reverted=$(count_of "$v1" reverted_to_embedded server)
  if [[ "$reverted" -ge 1 ]]; then record disable-all PASS "every release disabled: next cold start ran the embedded bundle; API v1: $(events_of "$v1")"
  else record disable-all PARTIAL "embedded bundle ran, but no reverted_to_embedded:server event on v1 (count $reverted)"; fi
}

disable_leftovers() {
  local id
  for id in $(api GET "/ota/releases?limit=100" | jq -r --arg p "$platform" '.items[] | select(.platform == $p and .enabled) | .id'); do
    set_enabled "$id" false >/dev/null
  done
}

disable_leftovers
build || { record build FAIL "Release build failed, see $log"; exit 1; }
record build PASS "Release build $(basename "$(app_path)")"
for flow in "${flows[@]}"; do
  say "== $flow"
  "flow_${flow//-/_}"
done
cat "$out"
