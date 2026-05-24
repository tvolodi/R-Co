# WF02-idn04-20260524 Test Design Report

Requirement: IDN-04
Agent: TEST-DESIGNER
Status: COMPLETE

## Delivered artifacts

- tests/specs/IDN-04.md
- tests/integration/idn04_api_token_management_test.zig
- tests/integration/main_test.zig
- tests/unit/test_api08_auth.zig

## Coverage summary

- TC-IDN-04-01: token issuance returns one-time secret and DB stores hash only
- TC-IDN-04-02: create token with past expires_at returns 422
- TC-IDN-04-03: revocation is idempotent and reflected in list status metadata
- TC-IDN-04-04a/04b: auth middleware rejects revoked and expired tokens with 401
- TC-IDN-04-05a/05b: auth middleware uses role claims and rejects invalid claims
- TC-IDN-04-06: create/list/revoke token endpoints are PLATFORM_ADMIN-only

## Validation

- zig build --summary all test: PASS
- BPM_TEST_DB_URL=postgres://bpm:bpm@localhost:5433/bpm_test zig build --summary all test-integration -- --test-filter IDN-04: PASS

## Notes

- IDN-04 auth middleware behavior is covered in DB-backed API-08 unit tests to keep module wiring consistent while still validating runtime middleware decisions against real database rows.
