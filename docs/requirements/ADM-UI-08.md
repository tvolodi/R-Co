---
id: ADM-UI-08
title: Revoke token
stage: F5
priority: MUST
status: DRAFT
type: frontend
---

# ADM-UI-08 — Revoke token `[MUST]`

> A "Revoke" action on a token SHALL require a confirmation dialog and call `POST /tokens/:id/revoke`. Revoked tokens SHALL be visually struck through in the token list and marked with a revoked badge.

**See:** IDN-04 (`POST /tokens/:id/revoke` — immediate effect), API-09 (auth middleware checks revocation cache on every request), ADM-UI-06 (token list where revoked state is shown)
