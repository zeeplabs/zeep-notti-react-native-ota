# Live updates end-to-end flows

Local Notti (self-hosted mode, Postgres, Redis, MinIO) in `stack/`, the Notti CLI,
the example apps in Release, and Maestro.

```sh
cd e2e/stack
export NOTTI_E2E_LICENSE_PUBLIC_KEY=$(node license.js keys)   # test-only license signing key
NOTTI_SERVER_DIR=../../../../saas/zeep-notti docker compose up -d --build
cd ..
./setup.sh ultimate                 # admin, ultimate license fixture, MinIO storage, one App per example
./run.sh example-bare-083 android   # or ios; optional flow names after the platform
```

- Android: a booted emulator (`ANDROID_SERIAL`, default `emulator-5554`); the script runs `adb reverse` for ports 18080 (Notti) and 19000 (MinIO).
- iOS: a booted simulator.
- Flows: `publish crash hang headless tampered new-binary disable disable-all`. Results go to `results/<example>-<platform>.tsv` (flow, PASS/FAIL/NOT RUN, evidence) with the full log next to it.
- `./setup.sh free` sets up an install without a license: publishing must fail with `402 ota_not_in_plan`.
- `stack/Dockerfile.notti` adds one file to the server build so it trusts the locally generated license key. Never use this image outside a test stack.
