# Live updates test fixtures

Copied unchanged from `zeep-notti-cli` (`fixtures/ota/`, branch `feat/ota-cli`, commit `6e5626e`). Do not edit by hand: re-export them from the CLI repo.

| File | Contents |
| --- | --- |
| `manifest.json` | Format v1 manifest, signed as raw bytes |
| `manifest.sig` | ECDSA P-256 / SHA-256 signature over `manifest.json`, DER |
| `public_key.pem` | The signing public key (SPKI) |
| `key_id.txt` | `key_id` of that key |
| `files.json` | Files listed in the manifest |
| `index.json` | Expected outcome, SHA-256 and size of each archive |
| `archives/valid.tar.gz` | The archive `manifest.json` describes |
| `archives/tampered.tar.gz` | One file changed after hashing |
| `archives/path-traversal.tar.gz` | Entry `../escape.js` |
| `archives/absolute-path.tar.gz` | Entry `/tmp/escape.js` |
| `archives/symlink.tar.gz` | Symbolic link entry `assets/link` |
| `archives/unlisted-file.tar.gz` | Entry `extra.js` missing from the manifest |
