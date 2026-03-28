# Org Security Scanner - Development Status

## Current Phase: ALL PHASES COMPLETE

Plan file: `C:\Users\GidiAbramovich\.claude\plans\scalable-strolling-kahan.md`
GitHub: `https://github.com/energidi/claude-knowledge-base/tree/main/projects/org-security-scanner`
Latest commit: Phase 12 complete (Lightning App + Flexipage)

---

## Phase Status

| Phase | Status | Notes |
|---|---|---|
| Plan finalization | COMPLETE | 76 checks, full Impact/Remediation, all architecture decisions locked |
| Phase 1 - Data Model | COMPLETE | SecurityScanRun__c, SecurityFinding__c, SecurityCheckDef__mdt, OrgSecurityScanner_Setting__mdt, 76 records |
| Phase 2 - Apex Foundation | COMPLETE | 9 classes: SecScanException, SecScanSessionExpiredException, SecScanApiResponse (5 DTOs), SecScanConstants, SecScanEvidenceUtil, SecScanFindingDTO, SecScanToolingService, SecScanMetadataService, SecScanCategoryRunner |
| Phase 3 - Apex Orchestration | COMPLETE | 7 classes: SecScanOrchestrator, SecScanRunnerChain, SecScanRunnerContinuation, SecScanRetentionBatch, SecScanOrphanCleanupSchedulable, SecScanPostInstallHandler, SecScanPostUninstallHandler |
| Phase 4 - 13 Category Runners | COMPLETE | All 13 runners written (76 checks total) |
| Phase 5 - Controllers | COMPLETE | SecScanController, SecScanFindingsController, SecScanTestDataFactory |
| Phase 6 - Tests | COMPLETE | 25 test classes (all phases covered) |
| Phase 7 - Permission Set + Tab | COMPLETE | OrgSecurityScanner_Admin PS + OrgSecurityScanner tab |
| Phase 8-11 - LWC (18 components) | COMPLETE | All 18 LWC components written including root securityScanner |
| Phase 12 - App Shell | COMPLETE | OrgSecurityScannerApp Lightning App + OrgSecurityScannerApp_Page Flexipage |

---

## Phase 4 Checklist (COMPLETE)

- [x] `SecScanRunnerUserAccess.cls` (UA - 7 checks: UA-001 to UA-007)
- [x] `SecScanRunnerGuestUser.cls` (GU - 12 checks: GU-001 to GU-012)
- [x] `SecScanRunnerSharingAccess.cls` (SRA - 7 checks: SRA-001 to SRA-007)
- [x] `SecScanRunnerSessionAuth.cls` (SA - 10 checks: SA-001 to SA-010)
- [x] `SecScanRunnerConnectedApps.cls` (CAI - 8 checks: CAI-001 to CAI-008)
- [x] `SecScanRunnerApexAutomation.cls` (AA - 8 checks, heap guard + continuation via IResumable)
- [x] `SecScanRunnerLwcAura.cls` (LA - 3 checks, heap guard + continuation via IResumable)
- [x] `SecScanRunnerAgentforce.cls` (AGA - 5 checks: AGA-001 to AGA-005)
- [x] `SecScanRunnerMetadataSecrets.cls` (MS - 4 checks: MS-001 to MS-004)
- [x] `SecScanRunnerFileUpload.cls` (FUE - 3 checks, SOAP Metadata API)
- [x] `SecScanRunnerCertEncryption.cls` (CE - 2 checks: CE-001 to CE-002)
- [x] `SecScanRunnerMonitoring.cls` (MON - 4 checks: MON-001 to MON-004)
- [x] `SecScanRunnerHealthCheck.cls` (HCB - 3 checks, SOAP Metadata API)

---

## Phase 5 Checklist (COMPLETE)

- [x] `SecScanController.cls` (startScan, getOrgInfo, getScanRuns, getOrgSecuritySettings, getScanRunStatus, cancelScan, exportFindingsCsv)
- [x] `SecScanFindingsController.cls` (getCurrentScanFindings, getScoreCounts, getFindingDetail, updateFindingStatus, bulkUpdateFindingStatus)
- [x] `SecScanTestDataFactory.cls` (shared test utility - deployed with controllers, used in Phase 6)

## Phase 6 Checklist (COMPLETE)

- [x] `SecScanApiResponseTest.cls`
- [x] `SecScanEvidenceUtilTest.cls`
- [x] `SecScanCategoryRunnerTest.cls`
- [x] `SecScanRunnerChainTest.cls`
- [x] `SecScanRunnerContinuationTest.cls`
- [x] `SecScanOrchestratorTest.cls`
- [x] `SecScanRetentionBatchTest.cls` (includes schedulable test)
- [x] `SecScanPostInstallHandlerTest.cls` (includes uninstall handler test)
- [x] `SecScanControllerTest.cls`
- [x] `SecScanFindingsControllerTest.cls`
- [x] `SecScanToolingServiceTest.cls`
- [x] `SecScanMetadataServiceTest.cls`
- [x] `SecScanRunnerUserAccessTest.cls`
- [x] `SecScanRunnerGuestUserTest.cls`
- [x] `SecScanRunnerSharingAccessTest.cls`
- [x] `SecScanRunnerSessionAuthTest.cls`
- [x] `SecScanRunnerConnectedAppsTest.cls`
- [x] `SecScanRunnerApexAutomationTest.cls`
- [x] `SecScanRunnerLwcAuraTest.cls`
- [x] `SecScanRunnerAgentforceTest.cls`
- [x] `SecScanRunnerMetadataSecretsTest.cls`
- [x] `SecScanRunnerFileUploadTest.cls`
- [x] `SecScanRunnerCertEncryptionTest.cls`
- [x] `SecScanRunnerMonitoringTest.cls`
- [x] `SecScanRunnerHealthCheckTest.cls`

## Phase 7 Checklist (COMPLETE)

- [x] `OrgSecurityScanner_Admin` Permission Set metadata
- [x] `OrgSecurityScanner` Custom Tab metadata

## Phase 8-11 Checklist (LWC - IN PROGRESS)

### Service Module
- [x] `secScanConstants` (JS-only service module)

### Phase 8 - LWC Leaves (no child LWC dependencies)
- [x] `securityScoreRing`
- [x] `scanRunMetadata`
- [x] `securityCategoryCell`
- [x] `securitySeverityBreakdown`
- [x] `securityStatusChangeForm`
- [x] `securityScanProgress`

### Phase 9 - LWC Mid
- [x] `securityCategoryHeatmap`
- [x] `securityRecentFindings`
- [x] `securityFindingsList`
- [x] `securityFindingDetail`
- [x] `securityLeftPanel`
- [x] `securityFilterBar`

### Phase 10 - LWC Top
- [x] `securityDashboard`
- [x] `securityFindingsExplorer`
- [x] `securityScanHistory`
- [x] `securityScannerHeader`

### Phase 11 - LWC Root
- [x] `securityScanner` (root orchestrator - all state, polling, wire adapters, event bus)
- [x] `securityScannerTabs` (previously completed)

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
- CSV export: pre-emptive COUNT guard before building string (6MB sync heap limit)
- SOQL injection prevention: searchTerm capped at 100 chars + escapeSingleQuotes()
- Status transitions: server-side ALLOWED_TRANSITIONS map (immutable, not CMT-driven)
