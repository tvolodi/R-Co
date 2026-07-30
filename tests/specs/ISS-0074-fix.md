# Test spec: ISS-0074 fix — real envelope encryption in secrets/crypto.zig

**Issue:** `docs/issues/ISS-0074.json` (GitHub #289 / ISS-BRW-01)
**Design:** `src/design/fix-ISS-0074.md`
**Module under test:** `src/secrets/crypto.zig` (pure — no DB, no network)
**Test file:** `tests/unit/crypto_iss0074_test.zig`

All test cases are pure unit tests (no `BPM_TEST_DB_URL` needed); `encrypt`/
`decrypt` do not touch the database.

| ID | Case | Assertion |
|---|---|---|
| TC-ISS-0074-01 | Ciphertext is not plaintext | `encrypt(...).ciphertext != plaintext` (byte-for-byte) for a non-empty plaintext — the literal acceptance criterion from the issue |
| TC-ISS-0074-02 | Round trip | `decrypt(encrypt(x)) == x` for a short secret, a typical API-key-length secret, and a long (~4KB) secret |
| TC-ISS-0074-03 | Round trip with empty plaintext | `decrypt(encrypt(""))` succeeds and returns a zero-length slice (edge case, not excluded by design) |
| TC-ISS-0074-04 | Tamper detection: ciphertext | Flipping one byte of `ciphertext` after `encrypt` causes `decrypt` to return `error.DecryptionFailed` |
| TC-ISS-0074-05 | Tamper detection: auth_tag | Flipping one byte of `auth_tag` after `encrypt` causes `decrypt` to return `error.DecryptionFailed` |
| TC-ISS-0074-06 | Tamper detection: wrapped_data_key | Flipping one byte of `wrapped_data_key` after `encrypt` causes `decrypt` to return `error.DecryptionFailed` |
| TC-ISS-0074-07 | Wrong master key rejected | Decrypting a valid envelope with a different `master_key` than the one used to encrypt returns `error.DecryptionFailed` |
| TC-ISS-0074-08 | Non-determinism | Two `encrypt` calls with identical plaintext/aad/key produce different `ciphertext` and different `nonce` (proves real randomness, not a deterministic stub) |
| TC-ISS-0074-09 | AAD binding | Decrypting a valid envelope after mutating the `aad` bytes passed to `decrypt`'s AEAD call (i.e. envelope.aad tampered) returns `error.DecryptionFailed` |
| TC-ISS-0074-10 | No plaintext master-key discard | `master_key` is read in both directions: covered implicitly by TC-07 (wrong key changes outcome) — no direct static assertion needed since Zig would compile-error on a genuinely unused required parameter only if marked `_ =`, which no longer appears in source (confirmed by code review, not a runtime test) |

All MUST-level assertions (01, 02, 04, 05, 07) map directly to the ISS-0074 acceptance criteria. No `error.SkipZigTest` is used anywhere in this file.
