---
name: sf-review-architecture
description: Salesforce technical architecture review against 6 pillars. Flags Critical/High/Medium risks with exact fix recommendations. Rejects the design as incomplete on any Critical finding. Use when user says "review architecture", "architecture review", "technical review", or runs /sf-review-architecture.
allowed-tools: Read, Glob, Grep
metadata:
  author: Gidi Abramovich
  version: 1.0.0
---

# Salesforce Technical Architecture Review Skill

Reviews any Salesforce technical design against 6 mandatory pillars.
Detects Salesforce projects automatically via `sfdx-project.json`.

## What It Checks

1. Data Architecture - object model, field types, LDV strategy, cascade delete safety
2. Security Model - OWD, sharing rules, Permission Sets, FLS/CRUD enforcement, SOQL injection
3. Async & Governor Limits - heap, CPU, callout, DML bulkification, Queueable chain design
4. Integration Safety - Named Credentials, QueryMore, HTTP 414 handling, retry strategy
5. Query Strategy - IN chunking, indexed fields, Selector pattern, SOQL injection
6. Failure Handling - Savepoint/rollback, failure DML isolation, Platform Event safety

## References

- `references/architecture-pillars.md` - Full checklist per pillar with Salesforce-specific rules
