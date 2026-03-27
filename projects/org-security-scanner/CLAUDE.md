# Org Security Scanner

## Overview
Salesforce security scanner app that detects 76+ vulnerabilities across 13 categories by querying org metadata, user permissions, and configuration entirely in-org. Supports **sandbox and production orgs**. No data leaves the Salesforce org. Distributed as an **Unlocked Package** (no namespace).

## Tech Stack
- **Platform:** Salesforce SFDX, API v66.0, Unlocked Package
- **Backend:** Apex (class prefix: `SecScan`)
- **Frontend:** LWC + SLDS (component prefix: `security`)
- **Async:** Queueable chain (13 serial jobs, one per category) with `Database.AllowsCallouts`
- **Metadata config:** Custom Metadata Types (deploy with package - not Custom Settings)

## Key Constraints
- Production supported: `startScan()` checks `AllowProductionScan__c` CMT flag (default false). If false and `IsSandbox = false`, throws `SecScanException` before scan begins. If true, sets `IsProductionScan__c = true`. LWC shows confirmation modal as a second gate.
- No external callouts: all queries target the org's own Tooling API via same-org loopback
- Session ID captured synchronously in `@AuraEnabled` - `UserInfo.getSessionId()` returns null in async. WARNING: production orgs with IP locking or HttpOnly will return INVALID_SESSION_ID. Named Credential pattern required before deploying to hardened orgs.
- KEYSET pagination only (OFFSET capped at 2,000 by Salesforce)
- Runner DML: `AccessLevel.SYSTEM_MODE` (system-generated data, not user input)
- Controller DML: `AccessLevel.USER_MODE` (user-initiated actions enforce FLS)
- `with sharing` + `WITH USER_MODE` on all controller SOQL

## Key Decisions
- `SeverityRank__c` is a **physical Number(1,0)** field set by `buildFinding()` - NOT a formula field. Mapping: Critical=1, High=2, Medium=3, Low=4, Info=5. Formula fields cannot be indexed and degrade ORDER BY at 9,000+ rows.
- `SecScanPostInstallHandler` auto-schedules nightly cleanup job on install/upgrade. No manual Execute Anonymous needed.
- `getScoreCounts()` on `SecScanFindingsController` drives both the live score ring AND the Left Panel severity counts after status changes.
- `CompletedCategories__c` on `SecurityScanRun__c` - each runner appends its code on success (mirrors `FailedCategories__c`). Powers the scan progress 13-item checklist.
- CSV export size guard is pre-emptive: `SELECT COUNT()` first, truncate text fields before building string (6MB sync heap limit - cannot check size after building).

## Categories (13)
UA, GU, SRA, SA, CAI, AA, LA, AGA, MS, FUE, CE, MON, HCB

## Deployment Order (compile-time deps - do not reorder)
1. Data model (objects + CMT types + 76 `SecurityCheckDef__mdt` records + `OrgSecurityScanner_Setting__mdt` Default record)
2. Apex foundation (`SecScanException`, `SecScanSessionExpiredException`, `SecScanApiResponse`, `SecScanEvidenceUtil`, `SecScanFindingDTO`, `SecScanToolingService`, `SecScanMetadataService`, `SecScanCategoryRunner`)
3. Apex orchestration (`SecScanRunnerChain`, `SecScanRunnerContinuation`, `SecScanOrchestrator`, `SecScanRetentionBatch`, `SecScanOrphanCleanupSchedulable`, `SecScanPostInstallHandler`, `SecScanPostUninstallHandler`) - **must deploy before runners**
4. 13 category runners (AA/LA call `new SecScanRunnerContinuation()` at compile time - Phase 3 must exist first)
5. Controllers (`SecScanController`, `SecScanFindingsController`)
6. Tests + `SecScanTestDataFactory`
7. Permission Set `OrgSecurityScanner_Admin` + Custom Tab
8-11. 16 LWC components (leaf -> mid -> top -> root order)
12. Lightning App `OrgSecurityScannerApp` + Flexipage
13. Package: `sf package version create` -> `sf package version promote`

## Files
- `technical-plan.md` (GitHub) - Full technical implementation plan (single source of truth)
- `Org Security Scanner - Technical Plan.docx` - Word export of the plan
