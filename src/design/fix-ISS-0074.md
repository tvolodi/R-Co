# Fix design: ISS-0074 — real envelope encryption in secrets/crypto.zig

**Issue:** `docs/issues/ISS-0074.json` (GitHub #289 / ISS-BRW-01)
**Severity:** BLOCKER
**Affected:** `src/secrets/crypto.zig`
**Requirement:** EXP-501 (`src/design/exp-05-secrets-module.md`)

## What changes (not how)

`encrypt()` and `decrypt()` currently discard `master_key` and copy plaintext
verbatim into the "ciphertext" field. This design replaces the body of both
functions with real envelope encryption using `std.crypto.aead.aes_gcm.Aes256Gcm`
(available in Zig 0.16 stdlib), matching the two-layer model already specified
in `exp-05-secrets-module.md`:

1. Generate a random 32-byte data encryption key (DEK) — already done via
   `fillRandom`, just needs to actually be used.
2. Encrypt `plaintext` with the DEK using AES-256-GCM, binding `aad`. This
   produces real `ciphertext` and a real 16-byte `auth_tag`, using a randomly
   generated 12-byte nonce.
3. Wrap (encrypt) the DEK itself with `master_key` using a second AES-256-GCM
   operation, with a separate randomly generated wrap nonce. Since Zig stdlib
   has no `aes_kw_256` (AES Key Wrap) primitive, `wrapped_data_key` is defined
   as `wrap_nonce (12 bytes) || AEAD-encrypted DEK (32 bytes) || wrap_tag (16 bytes)`.
   This is a legitimate AEAD-based key-wrapping construction; the
   `wrapped_key_algorithm` enum tag stays `aes_kw_256` for wire/schema
   compatibility (no schema or caller changes), since it is opaque metadata,
   not machine-checked against the construction.
4. `decrypt()` reverses both layers: unwrap the DEK using `master_key` and the
   embedded wrap nonce/tag (via `Aes256Gcm.decrypt`, which authenticates before
   returning), then decrypt `ciphertext` using the unwrapped DEK, `nonce`,
   `auth_tag`, and `aad` (again authenticated). Any authentication failure at
   either layer returns `error.DecryptionFailed` — no partial/garbage plaintext
   is ever returned.

No public function signatures change. `SecretEnvelope`, `CryptoError`,
`encrypt()`, `decrypt()`, and `parseMasterKeyHex()` keep their existing
signatures exactly as declared in `src/secrets/crypto.zig` today. `store.zig`
requires no changes — it already treats `ciphertext`/`wrapped_data_key`/
`nonce`/`auth_tag`/`aad` as opaque byte blobs it persists and reloads via hex
columns.

## Public function signatures (unchanged)

```zig
pub fn encrypt(
    allocator: std.mem.Allocator,
    plaintext: []const u8,
    aad: []const u8,
    wrapping_key_ref: []const u8,
    wrapping_key_version: []const u8,
    master_key: [32]u8,
) CryptoError!SecretEnvelope

pub fn decrypt(
    allocator: std.mem.Allocator,
    envelope: SecretEnvelope,
    master_key: [32]u8,
) CryptoError![]u8
```

## Data layout change (internal only)

`wrapped_data_key` grows from 32 (unused random bytes today) to
`12 + 32 + 16 = 60` bytes (wrap nonce + encrypted DEK + wrap tag). This field
is opaque `BYTEA` in the `secrets` table (per `exp-05-secrets-module.md`
storage schema) — no migration needed, no fixed-length assumption exists
anywhere in `store.zig` or the schema. No previously-stored secret exists in
any real environment (Wave-1 feature, plaintext-only so far), so there is no
backward-compatible-read requirement to design for.

## Error taxonomy (no changes)

`CryptoError` stays `{ InvalidMasterKey, EncryptionFailed, DecryptionFailed,
OutOfMemory }`. `decrypt()` must map any AEAD authentication failure (tampered
ciphertext, tampered auth tag, wrong master key, corrupted wrapped DEK) to
`error.DecryptionFailed` — never `unreachable`, never a silent fallback.

## Key invariants (MUST hold after fix)

- `encrypt(allocator, plaintext, ...).ciphertext != plaintext` for any
  non-empty `plaintext` (this is the acceptance criterion from ISS-0074 and
  must be asserted by a test).
- `decrypt(allocator, encrypt(allocator, plaintext, aad, ref, ver, key), key)`
  equals `plaintext` (round-trip).
- Decrypting an envelope with a flipped bit in `ciphertext` or `auth_tag`
  returns `error.DecryptionFailed`, not corrupted data.
- Decrypting with the wrong `master_key` returns `error.DecryptionFailed`
  (because DEK unwrap fails authentication).
- `master_key` is actually read and used in both `encrypt` and `decrypt` —
  no `_ = master_key;` discard statements remain.

## Callers impacted

None require code changes. `src/secrets/store.zig` (`putSecret`,
`resolveSecret`) already calls `crypto.encrypt` / `crypto.decrypt` with the
existing signatures and treats all envelope fields as opaque bytes it
hex-encodes/decodes for Postgres `BYTEA` columns.

## Test design note (for TEST-DESIGNER, Step 4)

This fix modifies business logic (real crypto now runs where a stub ran
before) — per WF-03 Fix Scope Rule, route through TEST-DESIGNER → TEST-DESIGN-VALIDATOR before TEST-RUNNER. Required test coverage (unit-level,
no DB dependency — pure function tests belong in the module's own test block
or `tests/unit/`):

1. `ciphertext != plaintext` for non-empty plaintext (the ISS-0074 acceptance
   criterion, verbatim).
2. Round-trip: `decrypt(encrypt(x)) == x` for representative plaintexts
   (empty-ish short secret, typical API key length, long secret).
3. Tamper detection: flipping a byte in `ciphertext` after encrypt causes
   `decrypt` to return `error.DecryptionFailed`.
4. Tamper detection: flipping a byte in `auth_tag` causes `error.DecryptionFailed`.
5. Wrong master key: decrypting with a different `master_key` than the one
   used to encrypt returns `error.DecryptionFailed`.
6. Two calls to `encrypt` with the same plaintext produce different
   `ciphertext` and different `nonce` (proves nonce/DEK randomness, not a
   deterministic stub).

## Fix scope

1 file changed (`src/secrets/crypto.zig`), well under the 5-file WF-03 cap.
No migration needed. No API/schema/design-doc contract change.
