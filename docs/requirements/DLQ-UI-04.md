---
id: DLQ-UI-04
title: Discard action
stage: F6
priority: MUST
status: DRAFT
type: frontend
---

# DLQ-UI-04 — Discard action `[MUST]`

> A "Discard" button SHALL show a confirmation dialog before calling `POST /dlq/:id/discard`. If the DLQ item is tied to an active instance, the dialog SHALL warn that discarding will cancel the associated instance.

**See:** EXT-03 (`POST /dlq/:id/discard`), EE-08 (cancel instance — triggered by discard if source is active instance), DLQ-UI-02 (detail panel where button lives)
