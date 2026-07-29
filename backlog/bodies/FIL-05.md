> **Extends:** FIL-01, adding a time-limited download grant that carries no session.

> Attachment download SHALL be authorised by an HMAC-SHA256 signature over the payload `kid`, `exp`, `attachment_id`, `tenant_slug` joined by LF (`\n`) in exactly that order. `tenant_slug` SHALL be derived server-side from the authenticated session at signing time and re-derived from the session at verification time; a slug present in the URL, body, or a header is discarded. `kid` selects the signing key from the active key set. The platform issues `GET /api/v1/attachments/{attachment_id}/download?kid=<kid>&exp=<unix_seconds>&sig=<base64url>` with `exp = now + 300` seconds. Verification checks `exp` first and recomputes the signature second.

**Acceptance Criteria:**
- GIVEN a signed URL, WHEN the signature is recomputed at verification, THEN the payload is the four components joined by LF in the order `kid`, `exp`, `attachment_id`, `tenant_slug`; any reordering, omission, or alternate separator produces a different signature and HTTP 403 `signature_invalid`.
- GIVEN a link whose `exp` is in the past, WHEN it is followed, THEN the platform returns HTTP 403 `signature_invalid` without recomputing the signature and without reading the object.
- GIVEN a link with a modified `attachment_id` but the original `sig`, WHEN it is followed, THEN the platform returns HTTP 403 `signature_invalid` and streams no bytes.
- GIVEN a caller that appends `tenant_slug=vortex` to a link signed for `swiftroute`, WHEN the link is followed, THEN the query parameter is discarded, the slug is taken from the session, the signature verifies against `swiftroute`, and the vortex value has no effect on the outcome.
- GIVEN a signing key retired at time T, WHEN a link bearing that `kid` is followed before T plus 300 seconds, THEN it verifies; after T plus 300 seconds it returns HTTP 403 `signature_invalid`.
- Signed URLs are issued with a 300-second lifetime and carry no session cookie or bearer token.

**See:** FIL-01, FIL-02, FIL-06, IDN-05, XC-05
