# Org Security Scanner - Development Status

## Current Phase: Phase 2 - Apex Foundation (IN PROGRESS)

Plan file: `C:\Users\GidiAbramovich\.claude\plans\scalable-strolling-kahan.md`
GitHub: `https://github.com/energidi/claude-knowledge-base/tree/main/projects/org-security-scanner`
Latest commit: `2e93d93` - Phase 1 complete (data model, 76 CMT records)

---

## Phase Status

| Phase | Status | Notes |
|---|---|---|
| Plan finalization | COMPLETE | 76 checks, full Impact/Remediation, all architecture decisions locked |
| Phase 1 - Data Model | COMPLETE | SecurityScanRun__c, SecurityFinding__c, SecurityCheckDef__mdt, OrgSecurityScanner_Setting__mdt, 76 records |
| Phase 2 - Apex Foundation | IN PROGRESS | See checklist below |
| Phase 3 - Apex Orchestration | Pending | |
| Phase 4 - 13 Category Runners | Pending | |
| Phase 5 - Controllers | Pending | |
| Phase 6 - Tests | Pending | |
| Phase 7 - Permission Set + Tab | Pending | |
| Phase 8-11 - LWC (18 components) | Pending | |
| Phase 12 - App Shell | Pending | |

---

## Phase 2 Checklist

- [ ] `SecScanException.cls` + meta
- [ ] `SecScanSessionExpiredException.cls` + meta
- [ ] `SecScanApiResponse.cls` (+ 5 typed inner DTOs) + meta
- [ ] `SecScanEvidenceUtil.cls` + meta
- [ ] `SecScanFindingDTO.cls` + meta
- [ ] `SecScanToolingService.cls` + meta
- [ ] `SecScanMetadataService.cls` + meta
- [ ] `SecScanCategoryRunner.cls` (abstract) + meta
- [ ] `SecScanConstants.cls` + meta

---

## Phase 1 Checklist (COMPLETE)

- [x] `SecurityScanRun__c` object + 19 fields + OWD Private
- [x] `SecurityFinding__c` object + 19 fields + OWD Private + field history on Status__c, AcknowledgedBy__c, AcknowledgedDate__c
- [x] `SecurityCheckDef__mdt` type + 11 fields + 76 records (UA=7, GU=12, SRA=7, SA=10, CAI=8, AA=8, LA=3, AGA=5, MS=4, FUE=3, CE=2, MON=4, HCB=3)
- [x] `OrgSecurityScanner_Setting__mdt` type + 14 fields + Default record

---

## Project Structure

```
force-app/main/default/
  objects/
    SecurityScanRun__c/    (19 fields)
    SecurityFinding__c/    (19 fields, history on 3 fields)
    SecurityCheckDef__mdt/ (11 fields)
    OrgSecurityScanner_Setting__mdt/ (14 fields)
  customMetadata/
    OrgSecurityScanner_Setting.Default.md-meta.xml
    SecurityCheckDef.UA_001.md-meta.xml  (x76)
  classes/                 <- Phase 2 target
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
- `SecScanEvidenceUtil`: SCRUB FIRST then TRUNCATE (never reversed)
- `buildFinding()` is the ONLY way to create findings - all runners must use it
- `SecScanRunnerChain`: @TestVisible chainEnabled=false replaces Test.isRunningTest() anti-pattern
- `finalizeScan()` must check Status__c before writing Completed - must not overwrite Cancelled

---

## Deployment Phase Order

1. Data model (objects + CMT types + records) - COMPLETE
2. Apex Foundation <- CURRENT
3. Apex Orchestration (must deploy BEFORE runners - compile-time dep)
4. 13 category runners (AA/LA call SecScanRunnerContinuation - Phase 3 must exist)
5. Controllers (SecScanController, SecScanFindingsController)
6. Tests + SecScanTestDataFactory
7. Permission Set + Custom Tab
8-11. LWC (18 components - leaf to root order)
12. Lightning App + Flexipage
