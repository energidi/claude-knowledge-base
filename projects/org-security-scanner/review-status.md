# Org Security Scanner - Development Status

## Current Phase: Phase 1 - Data Model (IN PROGRESS)

Plan is COMPLETE and locked. All 76 check definitions with full Impact/Remediation text are finalized.
Plan file: `C:\Users\GidiAbramovich\.claude\plans\scalable-strolling-kahan.md`
GitHub: `https://github.com/energidi/claude-knowledge-base/tree/main/projects/org-security-scanner`
Latest commit: `b2aa897` - complete Impact/Remediation for all 76 checks

---

## Phase Status

| Phase | Status | Notes |
|---|---|---|
| Plan finalization | COMPLETE | 76 checks, full Impact/Remediation, all architecture decisions locked |
| Phase 1 - Data Model | IN PROGRESS | See checklist below |
| Phase 2 - Apex Foundation | Pending | |
| Phase 3 - Apex Orchestration | Pending | |
| Phase 4 - 13 Category Runners | Pending | |
| Phase 5 - Controllers | Pending | |
| Phase 6 - Tests | Pending | |
| Phase 7 - Permission Set + Tab | Pending | |
| Phase 8-11 - LWC (18 components) | Pending | |
| Phase 12 - App Shell | Pending | |

---

## Phase 1 Checklist

- [ ] `SecurityScanRun__c` object + 19 fields + OWD Private
- [ ] `SecurityFinding__c` object + 19 fields + OWD Private + field history on Status__c, AcknowledgedBy__c, AcknowledgedDate__c
- [ ] `SecurityCheckDef__mdt` type + 11 fields + 76 records (UA=7, GU=12, SRA=7, SA=10, CAI=8, AA=8, LA=3, AGA=5, MS=4, FUE=3, CE=2, MON=4, HCB=3)
- [ ] `OrgSecurityScanner_Setting__mdt` type + 14 fields + Default record

---

## Project Structure

```
force-app/main/default/
  objects/
    SecurityScanRun__c/
    SecurityFinding__c/
    SecurityCheckDef__mdt/
    OrgSecurityScanner_Setting__mdt/
  customMetadata/
    OrgSecurityScanner_Setting.Default.md-meta.xml
    SecurityCheckDef.UA_001.md-meta.xml  (x76)
```

---

## Key Technical Decisions (locked)

- KEYSET pagination (not OFFSET - Salesforce caps at 2,000)
- CMT for config (not Custom Setting - records deploy with package)
- Session ID captured synchronously in @AuraEnabled, passed through chain
- `with sharing` + `WITH USER_MODE` on all controller SOQL
- Runner DML uses `AccessLevel.SYSTEM_MODE`
- OWD Private for both objects; PS grants ViewAllRecords
- `SeverityRank__c` is physical Number(1,0) set by buildFinding() - Critical=1, High=2, Medium=3, Low=4, Info=5
- `SecScanRetentionBatch` scope=1 (not 200 - DML row limit on child deletes)
- `bulkUpdateFindingStatus` cap=5,000, allOrNone=false (partial failure summary)
- `@wire` requires cacheable=true; getCurrentScanFindings is imperative
- Score__c + Grade__c stored by finalizeScan() - frozen, no retroactive changes
- Production gate: `AllowProductionScan__c` CMT flag (default false) - server-side deny

---

## Deployment Phase Order

1. Data model (objects + CMT types + records) <- CURRENT
2. Apex Foundation (SecScanException, SecScanApiResponse, SecScanEvidenceUtil, SecScanFindingDTO, SecScanToolingService, SecScanMetadataService, SecScanCategoryRunner, SecScanConstants)
3. Apex Orchestration (SecScanRunnerChain, SecScanRunnerContinuation, SecScanOrchestrator, SecScanRetentionBatch, SecScanOrphanCleanupSchedulable, SecScanPostInstallHandler, SecScanPostUninstallHandler) - must deploy BEFORE runners
4. 13 category runners (AA/LA call SecScanRunnerContinuation at compile time - Phase 3 must exist)
5. Controllers (SecScanController, SecScanFindingsController)
6. Tests + SecScanTestDataFactory
7. Permission Set + Custom Tab
8-11. LWC (18 components - leaf to root order)
12. Lightning App + Flexipage
