# Business Process Maps

This directory contains structured process maps for all business processes
running on the BPM Platform.

## Structure

```
docs/processes/
├── system/          — Platform-wide admin and infrastructure processes
│   ├── tenant-onboarding.md
│   └── process-definition-lifecycle.md
├── swiftroute/      — SwiftRoute Ltd (logistics)
│   ├── shipment-approval.md
│   └── incident-reporting.md
├── vortex/          — Vortex Manufacturing GmbH (ISO 9001 production)
│   ├── production-order.md
│   └── supplier-quality-deviation.md
└── meridian/        — Meridian Capital AG (BaFin-regulated lending)
    ├── loan-origination.md
    └── compliance-review.md
```

## Map Schema

Each process map contains:

| Section | Content |
|---------|---------|
| **Summary** | One-sentence description, process ID, owning tenant |
| **Roles** | Actors with their responsibilities in this process |
| **Inputs** | Data or events that start the process |
| **Steps** | Ordered steps with actor, action, decision, and outcome |
| **Business Rules** | Thresholds, gates, and hard constraints |
| **Outputs** | Final state, artefacts, and side effects |
| **SLAs & Escalations** | Timers and escalation paths |
| **Error / Exception Paths** | What happens when steps fail |

## System Processes

| Process | File | Description |
|---------|------|-------------|
| Tenant Onboarding | [system/tenant-onboarding.md](system/tenant-onboarding.md) | Provision a new tenant: DB schema, Keycloak realm, admin user |
| Process Definition Lifecycle | [system/process-definition-lifecycle.md](system/process-definition-lifecycle.md) | Create, publish, and retire process definitions |

## SwiftRoute Ltd — Logistics

| Process | File | Description |
|---------|------|-------------|
| Shipment Approval | [swiftroute/shipment-approval.md](swiftroute/shipment-approval.md) | Dispatcher → Ops Manager → CEO co-sign (above €500) |
| Incident Reporting | [swiftroute/incident-reporting.md](swiftroute/incident-reporting.md) | Driver reports incident → ops assessment + finance estimate |

## Vortex Manufacturing GmbH — ISO 9001 Production

| Process | File | Description |
|---------|------|-------------|
| Production Order | [vortex/production-order.md](vortex/production-order.md) | Planner → Production Manager → CEO (above €10,000) |
| Supplier Quality Deviation | [vortex/supplier-quality-deviation.md](vortex/supplier-quality-deviation.md) | Quarantine → Classification → 8D corrective action (ISO 9001) |

## Meridian Capital AG — Regulated Lending

| Process | File | Description |
|---------|------|-------------|
| Loan Origination | [meridian/loan-origination.md](meridian/loan-origination.md) | 3-track parallel assessment → L1/L2 approval → committee vote (above €500,000) |
| Compliance Review | [meridian/compliance-review.md](meridian/compliance-review.md) | KYC/AML → manual review → BaFin notification on SLA breach |
