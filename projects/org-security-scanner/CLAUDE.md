# Org Security Scanner

## Overview
Salesforce security scanner app that detects 76+ vulnerabilities across 13 categories by querying org metadata, user permissions, and configuration entirely in-org. **Sandbox only.** No data leaves the Salesforce org.

## Tech Stack
- **Platform:** Salesforce SFDX, API v66.0
- **Backend:** Apex (class prefix: `SecScan`)
- **Frontend:** LWC + SLDS (component prefix: `security`)
- **Async:** Queueable chain (13 serial jobs, one per category) with `Database.AllowsCallouts`
- **Metadata config:** Custom Metadata Types (deploy with package - not Custom Settings)

## Key Constraints
- Sandbox-only: `startScan()` hard-guards `Organization.IsSandbox = true` at runtime
- No external callouts: all queries target the org's own Tooling API via same-org loopback
- Session ID captured synchronously in `@AuraEnabled` - `UserInfo.getSessionId()` returns null in async
- KEYSET pagination only (OFFSET capped at 2,000 by Salesforce)
- `with sharing` + `WITH USER_MODE` on all SOQL + `AccessLevel.USER_MODE` on all DML

## Categories (13)
UA, GU, SRA, SA, CAI, AA, LA, AGA, MS, FUE, CE, MON, HCB

## Deployment Order
1. Data model (objects + CMT types + 76 `SecurityCheckDef__mdt` records + `OrgSecurityScanner_Setting__mdt` Default record)
2. Apex foundation (SecScanException, SecScanApiResponse, SecScanEvidenceUtil, SecScanFindingDTO, SecScanToolingService, SecScanMetadataService, SecScanCategoryRunner)
3. 13 category runners
4. Orchestration (SecScanRunnerChain, SecScanOrchestrator)
5. Controllers (SecScanController, SecScanFindingsController)
6. Tests + SecScanTestDataFactory
7. Permission Set OrgSecurityScanner_Admin + Custom Tab
8-11. 16 LWC components (root: securityScanner)
12. Lightning App OrgSecurityScannerApp + Flexipage

## Files
- `technical-plan.md` - Full technical implementation plan (single source of truth)
- `Org Security Scanner - Technical Plan.docx` - Word export of the plan
- `plan_to_docx.py` - Script to regenerate the Word doc from the plan markdown
