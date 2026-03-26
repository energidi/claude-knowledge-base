---
name: Org Security Scanner - Project State
description: Current build state, pending phases, key decisions, and in-progress review fixes for the Org Security Scanner Salesforce app
type: project
---

The Org Security Scanner app plan has been through 7+ AI review rounds (Gemini x5+ + ChatGPT x2+). Still in planning phase - no code written yet, force-app directories are empty. Plan is still being patched from the latest Gemini review batch (10 issues, session ended mid-patch).

**Why:** Building a Salesforce security scanner that detects 76+ vulnerabilities across 13 categories using in-org Tooling API loopback + Queueable chain. Runs in sandbox and production. No external data egress.

**How to apply:** Resume at the in-progress plan patch (see "In-Progress Fixes" below), finish it, then start Phase 1 execution. Plan file is the source of truth.

## Plan File
`C:\Users\GidiAbramovich\.claude\plans\scalable-strolling-kahan.md`

## Project Root
`c:\Users\GidiAbramovich\Documents\Visual Studio Code\Salesforce Security App`
SFDX API v66.0, no namespace, force-app/main/default/* all empty.

## GitHub Target
`https://github.com/energidi/claude-knowledge-base/tree/main/projects/org-security-scanner`

---

## In-Progress Fixes (session ended mid-patch - resume here)

The latest Gemini review raised 10 issues. All assessed as valid. Fixes 1 (partial) through 10 need to be applied. Status:

### Issue 1 - @wire on non-cacheable methods (PARTIALLY APPLIED)
**Problem:** Plan listed `getScanRuns`, `getCurrentScanFindings`, `getFindingDetail` as `@wire` but also marked NOT cacheable. @wire requires cacheable=true.
**Fix decided:** `getScanRuns` + `getFindingDetail` -> cacheable=true + @wire + refreshApex() after mutations. `getCurrentScanFindings` -> imperative (paginated with complex state).
**What was done:** Wire vs Imperative section updated. Still need to update `@AuraEnabled` rule section to add: "All @wire methods must be cacheable=true. @wire on a non-cacheable method is a platform error." Also update the cacheable/non-cacheable annotations on `getScanRuns` and `getFindingDetail` in the Apex Controller Methods section (currently marked NOT cacheable - must change to cacheable=true).

### Issue 2 - Batch scope=200 DML bomb (NOT APPLIED)
**Problem:** SecScanRetentionBatch scope=200 means 200 runs x 500 findings = 100k child deletes per execute() - hits 10,000 DML row limit.
**Fix:** Change scope to 1. One run per execute() transaction. For extreme-volume runs (>9,500 findings), add safety note: delete children in chunks of 9,000 within execute().

### Issue 3 - Phase 3/4 compile-order circular dep (NOT APPLIED)
**Problem:** AA/LA runners (Phase 3) call `new SecScanRunnerContinuation(...)` (Phase 4). Won't compile. SecScanRunnerContinuation calls `new SecScanRunnerChain(...)` also Phase 4.
**Fix:** SecScanRunnerChain uses Type.forName() - no compile-time runner deps, can deploy early. New order:
- Phase 3: `SecScanRunnerChain` + `SecScanRunnerContinuation` (no runner deps at compile time)
- Phase 4: All 13 runners + `SecScanOrchestrator` + `SecScanRetentionBatch` + `SecScanOrphanCleanupSchedulable`
- Phase 5 (was 4): Controllers
Renumber all subsequent phases.

### Issue 4 - Runner Chain code snippet missing Cancelled check (NOT APPLIED)
**Problem:** Prose says chain checks Status__c for Cancelled at start of execute(). Code snippet doesn't show this.
**Fix:** Update the execute() snippet under "Runner Chain Pattern" to include the Cancelled guard at the top:
```apex
SecurityScanRun__c run = [SELECT Status__c FROM SecurityScanRun__c WHERE Id = :scanRunId LIMIT 1];
if (run.Status__c == 'Cancelled') {
    SecScanOrchestrator.finalizeScan(scanRunId);
    return;
}
```

### Issue 5 - RetentionBatch start() two-concern query undocumented (NOT APPLIED)
**Problem:** start() needs to return (a) completed runs beyond MaxScanRuns AND (b) orphaned Running/Cancelled runs >24h. Single QueryLocator can't express "NOT IN (top N by date)" without a two-step.
**Fix:** Document the two-step pattern in start():
1. Query top MaxScanRuns completed run IDs into Set<Id> keepIds
2. QueryLocator: WHERE (Id NOT IN :keepIds AND Status__c = 'Completed') OR (Status__c IN ('Running','Cancelled') AND StartedAt__c < :cutoff)

### Issue 6 - CSV column definition missing (NOT APPLIED)
**Problem:** exportFindingsCsv says RawEvidence excluded but never defines what IS included.
**Fix:** Add one line to the exportFindingsCsv description: "CSV columns (in order): CheckId, CheckName, Category, Severity, FindingType, Status, AffectedComponent, AffectedComponentType, Description, Impact, Remediation, AcknowledgedBy (user name not ID), AcknowledgedDate, SalesforceDocUrl. Header row uses field labels."

### Issue 7 - Missing SecScanOrphanCleanupSchedulableTest (NOT APPLIED)
**Fix:** Add `SecScanOrphanCleanupSchedulableTest.cls` to the test class list in the plan.

### Issue 8 - Null Score__c in History UI (NOT APPLIED)
**Problem:** Crashed scans never reach finalizeScan(), so Score__c/Grade__c/CompletedAt__c are null. History UI must handle null gracefully.
**Fix:** Add note to Scan History View section: "Null Score__c displays as '-' (not 0 or blank). Null Grade__c displays as '-'. Applies to crashed/orphaned runs that were cleaned up before completing."

### Issue 9 - getOrgInfo() sandbox conversion (SKIP - Gemini flagged as not a real bug)

### Issue 10 - Accessibility (NOT APPLIED)
**Fix:** Add an Accessibility section (or subsection under UI/UX) covering:
- Finding Detail Panel: `role="dialog"`, `aria-modal="true"`, `aria-label="Finding Detail"`, focus trap (Tab cycles within panel), Escape key closes panel, focus returns to triggering row on close
- Heatmap cells: `role="button"`, `aria-label="[Category name]: [count] findings"` (clickable divs need button role)
- Scan progress: `aria-live="polite"` region for progress updates so screen readers announce category completions
- Severity badges: `aria-label="Severity: Critical"` (color/icon alone is insufficient for screen readers)
- Minimum v1 requirement: dialog panel a11y is blocking; heatmap and badges are enhancement

---

## Deployment Phase Order (REVISED - not yet updated in plan)

After Issue 3 fix, the correct order is:
1. Data model XML
2. Apex Foundation (SecScanException, SecScanSessionExpiredException, SecScanApiResponse, SecScanEvidenceUtil, SecScanFindingDTO, SecScanToolingService, SecScanMetadataService, SecScanCategoryRunner)
3. SecScanRunnerChain + SecScanRunnerContinuation (must precede runners)
4. 13 category runners + SecScanOrchestrator + SecScanRetentionBatch + SecScanOrphanCleanupSchedulable
5. Controllers (SecScanController, SecScanFindingsController)
6. Tests + SecScanTestDataFactory + SecScanOrphanCleanupSchedulableTest
7. Permission Set + Custom Tab
8-11. 16 LWC components
12. Lightning App + Flexipage + push to GitHub

---

## Key Decisions Locked In

- KEYSET pagination (not OFFSET - Salesforce caps OFFSET at 2,000)
- CMT `OrgSecurityScanner_Setting__mdt` (not Custom Setting - records deploy with package)
- Session ID captured synchronously in `@AuraEnabled`, passed as constructor param through chain
- `with sharing` + `WITH USER_MODE` on all controller SOQL + `AccessLevel.USER_MODE` on controller DML
- Runner DML uses `AccessLevel.SYSTEM_MODE` (system-generated data, not user input)
- OWD Private for both objects; PS grants ViewAllRecords
- GU runner: max ~3 callouts total, all 15 checks run against in-memory Map
- Grade bands hardcoded in `secScanConstants.js` (A/B/C/D/F) - not admin-configurable
- `AcknowledgedBy__c` / `AcknowledgedDate__c` overwritten on every status change (tracks last actor)
- `CheckId__c` is NOT ExternalId; v2 uses composite `UniqueKey__c` for upsert
- `SecScanEvidenceUtil`: match-centered extraction (5,000 chars around regex match), then scrub, cap 10,000
- `if (!Test.isRunningTest())` guard in `SecScanRunnerChain`
- Count fields (TotalFindings, CriticalCount, etc.) are Number(6,0) - NOT Number(3,0) (overflows at 999)
- `bulkUpdateFindingStatus` cap = 5,000 (NOT 200 - 200 is trigger chunk size, not DML limit)
- nextRecordsUrl pagination: prefix org domain URL only, NOT getBaseUrl() (avoids double /services/data/ path)
- Detail panel visibility = CSS slds-hide toggle, NOT if:true/false (preserves scroll position)
- Mobile detail panel = full-screen overlay via CSS toggle
- Score__c + Grade__c stored on SecurityScanRun__c by finalizeScan() - prevents retroactive changes
- `SecScanRetentionBatch` scope = 1 (NOT 200 - scope=200 causes DML row limit on child deletes)
- Heap check: `Decimal.valueOf(Limits.getHeapSize()) / Limits.getLimitHeapSize() > 0.7` (integer division always returns 0)
- `SecScanOrphanCleanupSchedulable` fires nightly at 02:00 to clean crashed scans
- `@wire` requires cacheable=true; use refreshApex() after mutations; getCurrentScanFindings is imperative
- `SeverityRank__c` is a Formula field (not indexed) - v1 accepted debt, v2 = physical Number field
- IsProductionScan__c checkbox on SecurityScanRun__c; production confirmation modal is LWC-side only (v2 gap)
