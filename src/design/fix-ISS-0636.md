# Fix design: ISS-0636 / GH-618

## Problem

`webhook.subscription_store.createSubscription` accepts a `CreateSubscriptionRequest`
with a `secret: ?[]const u8` field, but the `INSERT` only ever writes
`req.secret_ref orelse ""` — `req.secret` is read into the request struct and then
never referenced again anywhere in the function body. Any caller that supplies
`req.secret` (plaintext) without also pre-computing `secret_ref` gets a subscription
silently created with no `secret_ref`, so `dispatcher.zig`'s `secret_ref.len > 0` check
never signs outgoing webhook deliveries for it — signing is silently never activated.

`TC-EXT-02-INT-05` calls `createSubscription` directly (bypassing the HTTP layer) with
`.secret = "ext02-secret"` and expects the delivered webhook to carry a valid HMAC
signature. It currently fails: `signed_receiver.signature_seen == false`.

## Existing (correct) reference implementation

`src/api/routes/webhooks.zig`'s `handleCreateSubscription` already does the right thing,
but only at the HTTP route layer: when the request body has `secret` and no
`secret_ref`, it calls a local helper `storeWebhookSecret` (which wraps
`secrets.Store.putSecret` via `secrets.integration.webhook_keys.WebhookKeyOwner
.putWebhookHmacSecret`, namespace `"webhook"`, purpose `.webhook_hmac`, a
`subscription-<uuid>` generated name) to obtain a `secret_ref`/`key_id` pair, then
calls `store.createSubscription` with `secret = null, secret_ref = <that ref>`.

This means the HTTP path is unaffected by this bug (it already converts before
calling the store), but any other caller of `subscription_store.createSubscription`
that passes `req.secret` directly — like this integration test — hits the gap.

## Fix

Move the conversion into `subscription_store.createSubscription` itself, so it is
correct for every caller, not just the HTTP route:

1. In `createSubscription`, after `validateCreateRequest` and before acquiring the
   connection for the INSERT: if `req.secret` is non-null (and `req.secret_ref` is
   null — mirroring the HTTP layer's mutual-exclusion validation), call
   `secrets.Store.init` + `webhook_keys.WebhookKeyOwner.putWebhookHmacSecret` with the
   same config/namespace/purpose/name-generation convention `storeWebhookSecret` in
   `webhooks.zig` already uses, to obtain a real `secret_ref` / `key_id`.
2. Use the resulting `secret_ref`/`key_id` (instead of `req.secret_ref`/
   `req.secret_key_id`) in the INSERT and in the `rowToSubscription` /
   `secret_configured` computation.
3. If both `req.secret` and `req.secret_ref` are supplied, return
   `error.ValidationFailed` (mirrors the HTTP layer's `secret_conflict` check) —
   ambiguous input, reject rather than silently pick one.
4. `subscription_store.zig` gains two new imports: `secrets` (`../secrets/mod.zig`)
   and `webhook_keys` (`../secrets/integration/webhook_keys.zig`), plus `uuid`
   (`../util/uuid.zig`) for the generated secret name — matching what `webhooks.zig`
   already imports for the same purpose.
5. `src/api/routes/webhooks.zig`'s `handleCreateSubscription` is **not** changed. It
   still pre-converts and passes `secret = null, secret_ref = <ref>` — since
   `req.secret` is already null on that path, the new in-store conversion is a no-op
   for it. No double-conversion, no duplicate secret rows. (A follow-on simplification
   — deleting `storeWebhookSecret` from `webhooks.zig` and letting the route pass
   `req.secret` straight through — is a legitimate future cleanup but out of scope
   here: it would touch a working, already-tested HTTP path for no behavioural gain in
   this fix.)

## Acceptance criteria (from GH-618)

- `createSubscription` converts `req.secret` to `secret_ref` and persists it
- `TC-EXT-02-INT-05` passes

## Non-goals

- No change to `webhooks.zig`'s existing HTTP-layer conversion path.
- No change to `dispatcher.zig`'s resolution/signing logic — it already does the right
  thing once `secret_ref` is actually populated.
