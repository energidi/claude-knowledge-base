# Org Security Scanner - Development Status

## Current Phase: Phase 4 - Category Runners (IN PROGRESS)

Plan file: `C:\Users\GidiAbramovich\.claude\plans\scalable-strolling-kahan.md`
GitHub: `https://github.com/energidi/claude-knowledge-base/tree/main/projects/org-security-scanner`
Latest commit: `38ed7ea` - Phase 2 complete (Apex Foundation)

---

## Phase Status

| Phase | Status | Notes |
|---|---|---|
| Plan finalization | COMPLETE | 76 checks, full Impact/Remediation, all architecture decisions locked |
| Phase 1 - Data Model | COMPLETE | SecurityScanRun__c, SecurityFinding__c, SecurityCheckDef__mdt, OrgSecurityScanner_Setting__mdt, 76 records |
| Phase 2 - Apex Foundation | COMPLETE | 9 classes: SecScanException, SecScanSessionExpiredException, SecScanApiResponse (5 DTOs), SecScanConstants, SecScanEvidenceUtil, SecScanFindingDTO, SecScanToolingService, SecScanMetadataService, SecScanCategoryRunner |
| Phase 3 - Apex Orchestration | COMPLETE | 7 classes: SecScanOrchestrator, SecScanRunnerChain, SecScanRunnerContinuation, SecScanRetentionBatch, SecScanOrphanCleanupSchedulable, SecScanPostInstallHandler, SecScanPostUninstallHandler |
| Phase 4 - 13 Category Runners | IN PROGRESS | See checklist below |
| Phase 5 - Controllers | Pending | |
| Phase 6 - Tests | Pending | |
| Phase 7 - Permission Set + Tab | Pending | |
| Phase 8-11 - LWC (18 components) | Pending | |
| Phase 12 - App Shell | Pending | |

---

## Phase 4 Checklist

- [ ] `SecScanRunnerUserAccess.cls` (UA - 7 checks)
- [ ] `SecScanRunnerGuestUser.cls` (GU - 12 checks)
- [ ] `SecScanRunnerSharingAccess.cls` (SRA - 7 checks)
- [ ] `SecScanRunnerSessionAuth.cls` (SA - 10 checks)
- [ ] `SecScanRunnerConnectedApps.cls` (CAI - 8 checks)
- [ ] `SecScanRunnerApexAutomation.cls` (AA - 8 checks, heap guard + continuation)
- [ ] `SecScanRunnerLwcAura.cls` (LA - 3 checks, heap guard + continuation)
- [ ] `SecScanRunnerAgentforce.cls` (AGA - 5 checks)
- [ ] `SecScanRunnerMetadataSecrets.cls` (MS - 4 checks)
- [ ] `SecScanRunnerFileUpload.cls` (FUE - 3 checks, SOAP Metadata API)
- [ ] `SecScanRunnerCertEncryption.cls` (CE - 2 checks)
- [ ] `SecScanRunnerMonitoring.cls` (MON - 4 checks)
- [ ] `SecScanRunnerHealthCheck.cls` (HCB - 3 checks, SOAP Metadata API)

---

## Phase 2 + 3 Checklist (COMPLETE)

Phase 2 - Apex Foundation (9 classes):
- [x] SecScanException, SecScanSessionExpiredException
- [x] SecScanApiResponse (FindingsPageDTO, ScanStatusDTO, OrgSecuritySettingsDTO, OrgInfoDTO, ScoreCountsDTO)
- [x] SecScanConstants, SecScanEvidenceUtil, SecScanFindingDTO
- [x] SecScanToolingService, SecScanMetadataService, SecScanCategoryRunner (abstract, without sharing)

Phase 3 - Apex Orchestration (7 classes):
- [x] SecScanOrchestrator (finalizeScan: score/grade/counts, Cancelled guard, retention trigger)
- [x] SecScanRunnerChain (@TestVisible chainEnabled, session expiry path, CompletedCategories append)
- [x] SecScanRunnerContinuation (IResumable interface, heap-split for AA/LA)
- [x] SecScanRetentionBatch (scope=1, explicit child delete, two-step QueryLocator)
- [x] SecScanOrphanCleanupSchedulable
- [x] SecScanPostInstallHandler (abort-then-reschedule on upgrade, silent on failure)
- [x] SecScanPostUninstallHandler

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
- `SecScanRunnerContinuation.IResumable` interface - AA and LA implement this for heap-safe pagination
