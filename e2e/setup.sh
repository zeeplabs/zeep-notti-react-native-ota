#!/usr/bin/env bash
# Prepares the local e2e stack (e2e/stack): first admin, license fixture, MinIO
# storage, then one App per example with the Live updates signing key
# registered. Writes e2e/.env.local (gitignored) and e2e/.env.<example>.
# Usage: e2e/setup.sh [ultimate|free] [example...]   (free: no license installed)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
plan="${1:-ultimate}"
shift || true
examples=("$@")
[[ ${#examples[@]} -gt 0 ]] || examples=(example-bare-083 example-bare-088 example-expo-55 example-expo-58)
base="${NOTTI_E2E_BASE_URL:-http://localhost:18080}"
jar="$here/.cookies"
rm -f "$jar"

api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -m 30 -b "$jar" -c "$jar" -X "$method" -H 'Content-Type: application/json' -H "Origin: $base")
  [[ -n "$body" ]] && args+=(--data "$body")
  curl "${args[@]}" -w '\n%{http_code}' "$base$path"
}

expect() {
  local want="$1" out="$2"
  local code="${out##*$'\n'}"
  if [[ "$code" != "$want" ]]; then
    echo "unexpected HTTP $code (want $want): ${out%$'\n'*}" >&2
    exit 1
  fi
  printf '%s' "${out%$'\n'*}"
}

email="e2e-admin@example.test"
password="e2e-Password-123!"

setup_body=$(printf '{"token":"zn_boot_e2eLocalStackToken01","name":"E2E Admin","email":"%s","password":"%s","instance_name":"Notti e2e","public_url":"%s"}' "$email" "$password" "$base")
login_body=$(printf '{"email":"%s","password":"%s"}' "$email" "$password")
out=$(api POST /admin/setup "$setup_body")
code="${out##*$'\n'}"
if [[ "$code" != "201" ]]; then
  out=$(api POST /v1/auth/login "$login_body")
  expect 200 "$out" >/dev/null
fi

out=$(api GET /v1/auth/me)
company_id=$(expect 200 "$out" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).active_company_id||""))')
[[ -n "$company_id" ]] || { echo "could not resolve the company id" >&2; exit 1; }

if [[ "$plan" == "ultimate" ]]; then
  license_body=$(printf '{"code":"%s"}' "$(node "$here/stack/license.js" token ultimate)")
  out=$(api PUT "/v1/companies/$company_id/license" "$license_body")
  expect 200 "$out" >/dev/null
fi

AWS_ACCESS_KEY_ID=notti-e2e AWS_SECRET_ACCESS_KEY=notti-e2e-secret AWS_DEFAULT_REGION=us-east-1 \
  aws --endpoint-url http://localhost:19000 s3 mb s3://notti-ota-e2e >/dev/null 2>&1 || true
out=$(api PUT "/v1/companies/$company_id/media-settings" '{"endpoint":"http://localhost:19000","bucket":"notti-ota-e2e","access_key":"notti-e2e","secret_key":"notti-e2e-secret","region":"us-east-1","path_style":true,"public_acl":false,"public_base_url":"https://media.example.test","retention_days":30}')
expect 200 "$out" >/dev/null

key_file="$here/.signing.private.pem"
cli="${NOTTI_CLI:-$here/../../zeep-notti-cli/dist/cli.js}"
if [[ ! -f "$key_file" ]]; then
  node "$cli" ota keys generate --out "$key_file" >/dev/null
fi
public_pem=$(openssl pkey -in "$key_file" -pubout)
printf '%s\n' "$public_pem" > "$here/.signing.public.pem"
public_b64=$(openssl pkey -in "$key_file" -pubout -outform DER | tail -c 65 | base64)
key_body=$(node -e 'console.log(JSON.stringify({public_key:process.argv[1]}))' -- "$public_pem")

cat > "$here/.env.local" <<ENV
NOTTI_E2E_BASE_URL=$base
NOTTI_E2E_PLAN=$plan
NOTTI_E2E_COMPANY_ID=$company_id
NOTTI_OTA_PRIVATE_KEY=$key_file
NOTTI_E2E_PUBLIC_PEM_FILE=$here/.signing.public.pem
ENV
chmod 600 "$here/.env.local"

for example in "${examples[@]}"; do
  app_body=$(printf '{"company_id":"%s","name":"Live updates e2e %s"}' "$company_id" "$example")
  out=$(api POST /v1/apps "$app_body")
  app=$(expect 201 "$out")
  read -r app_id rest_key client_key < <(node -e 'const j=JSON.parse(process.argv[1]);console.log(j.id,j.rest_key,j.client_key)' -- "$app")
  out=$(api POST "/v1/apps/$app_id/ota/keys" "$key_body")
  key_id=$(expect 201 "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).key_id))')
  cat > "$here/.env.$example" <<ENV
NOTTI_APP_ID=$app_id
NOTTI_API_KEY=$rest_key
NOTTI_E2E_CLIENT_KEY=$client_key
NOTTI_E2E_KEY_ID=$key_id
NOTTI_E2E_PUBLIC_KEY="$key_id:$public_b64"
ENV
  chmod 600 "$here/.env.$example"
  echo "$example: app ${app_id:0:8}..., key_id $key_id"
done
echo "e2e stack ready: plan=$plan"
