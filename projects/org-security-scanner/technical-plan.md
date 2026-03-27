# Org Security Scanner - Technical Implementation Plan

## Context

A new Salesforce Security Scanner app named **Org Security Scanner** is being built from a clean SFDX scaffold (API v66.0, no namespace, all force-app directories empty). The app detects 76+ security vulnerabilities across 13 categories by querying org metadata, user permissions, and configuration entirely in-org. It can be installed in **sandbox or production orgs**. No data leaves the Salesforce org. Only admins assigned the `OrgSecurityScanner_Admin` permission set can access and run the app. Scans are triggered manually by clicking "Run Security Check".

GitHub target: `https://github.com/energidi/claude-knowledge-base/tree/main/projects/org-security-scanner`

---

## Data Model

### Object Purposes

| Object | Type | Purpose |
|---|---|---|
| `SecurityScanRun__c` | Custom Object | Envelope record for one full scan execution. One record per button click. Tracks who ran it, when, duration, status, aggregate counts, and which categories failed. Parent of all findings from that run. |
| `SecurityFinding__c` | Custom Object | One record per detected issue instance. A check finding 5 problematic profiles creates 5 child records. Stores finding detail, remediation, evidence, and admin acknowledgement workflow. |
| `SecurityCheckDef__mdt` | Custom Metadata Type | Static registry of all 76 check definitions. Deploys with the package - no seed scripts. Queried at runtime so the UI can show "0 findings" for passing checks explicitly. |

---

### `SecurityScanRun__c` Fields

| Field Label | API Name | Type | Purpose |
|---|---|---|---|
| Scan Name | `Name` | Auto Number `SCAN-{0000}` | Unique human-readable identifier |
| Status | `Status__c` | Picklist: Pending / Running / Completed / Failed / Cancelled | Drives UI state machine and polling termination. Cancelled = admin requested stop; chain checks this before each category and halts without enqueuing next link. |
| Started By | `StartedBy__c` | Lookup(User) | Which admin initiated the scan |
| Started At | `StartedAt__c` | DateTime | Scan start timestamp for duration calculation |
| Completed At | `CompletedAt__c` | DateTime | Set by final Queueable job |
| Total Checks Run | `TotalChecksRun__c` | Number(3,0) | Should be 76 on full success |
| Total Findings | `TotalFindings__c` | Number(6,0) | Aggregate count across all severities. Number(3,0) overflows at 1,000 - with 13 categories x 9,000 cap = 117,000 max findings, Number(6,0) is required. |
| Critical Count | `CriticalCount__c` | Number(6,0) | Drives score ring color and header badge |
| High Count | `HighCount__c` | Number(6,0) | |
| Medium Count | `MediumCount__c` | Number(6,0) | |
| Low Count | `LowCount__c` | Number(6,0) | |
| Info Count | `InfoCount__c` | Number(6,0) | |
| Failed Categories | `FailedCategories__c` | LongTextArea(1000) | Comma-delimited category codes that threw exceptions (e.g. `AA,GU`). UI shows warning banner if non-empty. **No-comma rule:** all 13 CategoryCode values (UA, GU, SRA, SA, CAI, AA, LA, AGA, MS, FUE, CE, MON, HCB) must never contain a comma - comma is the delimiter. Enforced by convention; there is no platform constraint. Adding a category code with a comma would silently corrupt the parse. v2 refactor: multi-select picklist. |
| Completed Categories | `CompletedCategories__c` | LongTextArea(1000) | Comma-delimited category codes that completed successfully (e.g. `UA,GU,SRA`). Each runner appends its code on success - mirrors FailedCategories__c pattern. The scan progress view polls getScanRunStatus() which returns this field so the UI can render a 13-item checklist with completed categories ticked. Same no-comma rule applies. |
| Is Partial Scan | `IsPartialScan__c` | Checkbox | True if running user lacks PermissionsModifyAllData - some Tooling API results may be incomplete |
| Is Production Scan | `IsProductionScan__c` | Checkbox | True when the scan ran against a production org (`Organization.IsSandbox = false`). UI shows a red "PRODUCTION" badge on this run in history and the dashboard. |
| Error Details | `ErrorDetails__c` | LongTextArea(32768) | Full Apex exception text from failed runners for debugging |
| Org Id | `OrgId__c` | Text(18) | `UserInfo.getOrganizationId()` - identifies which org was scanned |
| Security Score | `Score__c` | Number(5,2) | Computed by `finalizeScan()`. Range 0-100 after deductions and floor applied. Stored as source of truth for history and export. LWC recalculates live for in-session status changes but stored value prevents retroactive score shifts when CMT deduction weights are later edited. |
| Security Grade | `Grade__c` | Text(1) | A/B/C/D/F computed from `Score__c` by `finalizeScan()`. Stored so historical grades do not retroactively change if grade thresholds ever change. |

---

### `SecurityFinding__c` Fields

| Field Label | API Name | Type | Purpose |
|---|---|---|---|
| Scan Run | `ScanRun__c` | Master-Detail(SecurityScanRun__c) | Links to parent. Master-Detail cascades delete of all findings when run is deleted. |
| Check Id | `CheckId__c` | Text(50) | Stable code like `UA-001`. **Not an ExternalId** - same CheckId appears across many runs and multiple times per run (one per affected component). Findings are always inserted, never upserted. Keyed by Salesforce record ID. If v2 introduces upsert/deduplication, a composite ExternalId field (e.g. `UniqueKey__c = ScanRunId + CheckId + AffectedComponent`) should be introduced rather than marking this field as ExternalId, which would be misleading given its non-unique nature. |
| Check Name | `CheckName__c` | Text(255) | Human-readable title shown in UI |
| Category | `Category__c` | Picklist (13 values) | Groups findings for heatmap and filter bar |
| Category Code | `CategoryCode__c` | Text(5) | Short code (UA, GU, SRA...) for programmatic grouping |
| Severity | `Severity__c` | Picklist: Critical / High / Medium / Low / Informational | Drives color coding and score deduction |
| Severity Rank | `SeverityRank__c` | Number(1,0) | Numeric severity proxy for deterministic severity-first KEYSET sort: Critical=1, High=2, Medium=3, Low=4, Informational=5. Physical field (not formula) - formula fields cannot be custom-indexed and ORDER BY on a formula against 9,000+ rows degrades sort performance. Set once at insert time by `buildFinding()`. Can receive a custom Salesforce index if needed at production volumes. |
| Finding Type | `FindingType__c` | Picklist: Automated / Recommendation | Automated = directly detected violation. Recommendation = admin must manually review. |
| Status | `Status__c` | Picklist: Open / Acknowledged / Remediated / Risk Accepted / False Positive | Admin workflow state. Remediated and False Positive excluded from score. |
| Affected Component | `AffectedComponent__c` | Text(255) | Name of the profile, user, class, flow, etc. that triggered the finding |
| Affected Component Type | `AffectedComponentType__c` | Picklist: Profile / User / ApexClass / ApexTrigger / LWC / AuraComponent / ConnectedApp / Flow / OrgSetting / CustomObject / Field / PermissionSet / StaticResource / Certificate / RemoteSite / ExperienceCloudSite / SharingRule / NamedCredential | Enables Setup navigation and icon selection. All types produced by the 13 runners must be in this list - an unmapped type causes the finding insert to fail. |
| Description | `Description__c` | LongTextArea(32768) | What was found and why it is a security risk (the "Risk" section shown to admins) |
| Impact | `Impact__c` | LongTextArea(32768) | Business and security consequences if this vulnerability is exploited or left unaddressed. Displayed as the "Impact" section in the finding detail panel. |
| Remediation | `Remediation__c` | LongTextArea(32768) | Step-by-step fix instructions (the "How to Fix" section shown to admins) |
| Raw Evidence | `RawEvidence__c` | LongTextArea(32768) | Scrubbed, truncated evidence dump. Processed by `SecScanEvidenceUtil`: max 10,000 chars, regex-scrubbed for password/token/key patterns. Never stores full raw Apex source bodies. |
| Acknowledged By | `AcknowledgedBy__c` | Lookup(User) | Which admin acknowledged - stored explicitly for fast SOQL filtering |
| Acknowledged Date | `AcknowledgedDate__c` | DateTime | Stored explicitly for the same reason |
| Acknowledgement Note | `AcknowledgementNote__c` | LongTextArea(1000) | Admin comment on acknowledgement or risk acceptance |
| Salesforce Doc URL | `SalesforceDocUrl__c` | URL | Link to official Salesforce Help or Security Guide article |

Category Picklist Values:
`User & Access`, `Guest User / Experience Cloud`, `Sharing & Record Access`, `Session & Auth`, `Connected Apps & Integrations`, `Apex & Automation`, `LWC & Aura`, `Agentforce & GenAI`, `Metadata & Secrets`, `File Upload & Execution`, `Certificates & Encryption`, `Monitoring`, `Health Check Baseline`

Note: `IsAcknowledged__c` is NOT included - it is redundant with `Status__c != 'Open'`. Derive acknowledgement state from Status.

### Org-Wide Defaults

| Object | OWD | Reason |
|---|---|---|
| `SecurityScanRun__c` | Private | Only admins with `OrgSecurityScanner_Admin` PS (ViewAllRecords) should see scan runs. No sharing rules needed. |
| `SecurityFinding__c` | Private | Master-Detail inherits parent sharing. ViewAllRecords on PS covers all findings. |

Private OWD is the least-privilege baseline. The Permission Set's ViewAllRecords grants visibility to authorized admins only. No sharing rules, no criteria-based sharing, no manual sharing.

### SOQL Indexing Strategy

| Field | Indexed? | Query Context | Verdict |
|---|---|---|---|
| `ScanRun__c` (MD) | Auto (Master-Detail) | Primary filter on all finding queries | Selective - all finding queries anchor on this |
| `Status__c` | Not auto (picklist) | Filter in `getCurrentScanFindings` | Acceptable - always combined with indexed `ScanRun__c` |
| `Severity__c` | Not auto (picklist) | Filter in `getCurrentScanFindings` | Acceptable - same reason |
| `Category__c` | Not auto (picklist) | Filter in `getCurrentScanFindings` | Acceptable - same reason |
| `CompletedAt__c` | Not auto | ORDER BY in retention query | Acceptable - retention query runs on max 10,000 records |
| `StartedAt__c` | Not auto | Orphan cleanup query | Acceptable - runs on Running status records only (tiny set) |

All finding queries use `ScanRun__c` as the leading predicate. The auto-indexed Master-Detail field ensures selectivity on every query. Secondary filter fields (Status, Severity, Category) are always ANDed with `ScanRun__c` - Salesforce will use the indexed field to narrow the result set first.

Custom index on `Status__c` is not needed for v1 sandbox volumes. If the app is promoted to production with large finding history, add a custom index on `Status__c` for the retention and reporting queries.

### Pagination Strategy

**v1 uses KEYSET pagination with severity-first composite sort.** OFFSET-based pagination is NOT used - Salesforce caps SOQL OFFSET at 2,000 rows. Sorting by `Id` alone buries Critical findings inserted late in the runner chain - unacceptable in a security app. Picklist alphabetical order (C/H/I/L/M) does not match severity order (C/H/M/L/I), so the `SeverityRank__c` formula field (1-5) is used for the sort key.

KEYSET pattern (composite sort on `SeverityRank__c` + `Id`):
`WHERE ScanRun__c = :runId AND (SeverityRank__c > :lastRank OR (SeverityRank__c = :lastRank AND Id > :lastSeenId)) ORDER BY SeverityRank__c ASC, Id ASC LIMIT :pageSize`
- First page: `lastRank = null` and `lastSeenId = null` (composite filter omitted)
- Subsequent pages: pass both `SeverityRank__c` and `Id` of the last record from the previous page
- Constant-time at any depth - no row-skipping overhead
- Controller signature: `getCurrentScanFindings(String scanRunId, String lastSeenId, Integer lastRank, Integer pageSize, String searchTerm)` (searchTerm = null for no text filter)
- LWC tracks both `lastSeenId` and `lastRank`
- `hasMore` returned when result size equals `pageSize`
- `FindingsPageDTO`: `List<SecurityFinding__c> findings`, `Boolean hasMore`, `String lastSeenId`, `Integer lastRank`

The data retention query in `SecScanOrchestrator` avoids OFFSET entirely - it fetches all completed runs and uses `List.subList()` to trim beyond `MaxScanRuns__c`. This is safe regardless of how high `MaxScanRuns__c` is set (OFFSET would break at values above 2,000).

---

### `SecurityCheckDef__mdt` Fields

| Field | Purpose |
|---|---|
| `CheckId__c` | Stable check code matching `SecurityFinding__c.CheckId__c` |
| `CheckName__c` | Human-readable name |
| `Category__c` / `CategoryCode__c` | Category grouping |
| `Severity__c` | Default severity |
| `FindingType__c` | Automated or Recommendation |
| `Description__c` | What the check detects (maps to `SecurityFinding__c.Description__c`) |
| `Impact__c` | Business/security consequences if exploited (maps to `SecurityFinding__c.Impact__c`) |
| `Remediation__c` | How to fix it (maps to `SecurityFinding__c.Remediation__c`) |
| `SalesforceDocUrl__c` | Salesforce documentation link |
| `IsActive__c` | Disables individual checks without code changes |

76 records deployed at installation. DeveloperName = CheckId with underscores (e.g. `UA_001`).

---

### `OrgSecurityScanner_Setting__mdt` Custom Metadata Type

Replaces all hardcoded configuration values. Deployed as metadata with a single record (`DeveloperName = Default`) - zero manual setup on fresh install. Admins can edit values in Setup > Custom Metadata Types without a code deploy.

**Why CMT over Custom Setting:** Custom Setting records are org data - they do not deploy with the package. Custom Metadata records are metadata - they deploy via SFDX source and are included in the package automatically.

| Field | API Name | Type | Default Record Value | Purpose |
|---|---|---|---|---|
| Max Scan Runs | `MaxScanRuns__c` | Number(3,0) | 5 | Retention policy: how many completed runs to keep |
| Critical Deduction | `ScoreDeductCritical__c` | Number(5,2) | 10 | Score points deducted per Critical finding |
| High Deduction | `ScoreDeductHigh__c` | Number(5,2) | 4 | Score points deducted per High finding |
| Medium Deduction | `ScoreDeductMedium__c` | Number(5,2) | 2 | Score points deducted per Medium finding |
| Low Deduction | `ScoreDeductLow__c` | Number(5,2) | 0.5 | Score points deducted per Low finding |
| Info Deduction | `ScoreDeductInfo__c` | Number(5,2) | 0.1 | Score points deducted per Informational finding |
| Critical Cap | `ScoreCriticalCap__c` | Number(5,2) | 40 | Max total deduction from Critical findings |
| High Cap | `ScoreHighCap__c` | Number(5,2) | 20 | Max total deduction from High findings |
| Medium Cap | `ScoreMediumCap__c` | Number(5,2) | 20 | Max total deduction from Medium findings |
| Low Cap | `ScoreLowCap__c` | Number(5,2) | 10 | Max total deduction from Low findings |
| Info Cap | `ScoreInfoCap__c` | Number(5,2) | 5 | Max total deduction from Informational findings |
| Score Floor | `ScoreFloor__c` | Number(3,0) | 5 | Minimum possible score |
| Allow Production Scan | `AllowProductionScan__c` | Checkbox | false | Server-side gate for production org scans. `startScan()` throws `SecScanException('Production scanning is disabled. Enable AllowProductionScan__c in OrgSecurityScanner_Setting__mdt to proceed.')` if `IsSandbox = false` AND this flag is false. Secure default = deny. Admin must explicitly opt in before any production scan. LWC confirmation modal is still shown but is now a second gate, not the only gate. |
| SRA-007 Score Threshold | `PortalHealthScoreThreshold__c` | Number(3,0) | 70 | Minimum acceptable Salesforce Security Health Check score for Experience Cloud portals. SRA-007 fires a finding when the native score is below this value. Configurable without a code deploy. |

**MaxScanRuns__c compliance note:** Default is 5 (appropriate for developer sandboxes with 200MB storage limits). Production orgs running weekly scans should set this to 10-30 depending on their compliance retention requirements. Many financial and healthcare orgs require 90-day minimum retention - set `MaxScanRuns__c` accordingly and document in your org's data retention policy. **There is no archive step when a run is deleted - admins must export via CSV before the retention limit is reached if long-term compliance records are needed.**

Read in Apex: `OrgSecurityScanner_Setting__mdt.getInstance('Default')`. Read in LWC via `@wire(getOrgSecuritySettings)` (returns `OrgSecuritySettingsDTO` - typed Apex inner class, not a plain map). Never hardcoded in JavaScript.

`OrgSecuritySettingsDTO` fields mirror `OrgSecurityScanner_Setting__mdt` exactly (all Decimal/Integer). Typed DTO prevents silent failures when field names change and makes test assertions explicit.

---

### Metadata Descriptions & Tooltips

**Standard:** Every custom object and custom field must have a `description` element populated in its metadata XML. This is the text shown in Setup and used by tools like OrgCheck and Salesforce Health Check to understand the purpose of each field. All `SecurityCheckDef__mdt` and `OrgSecurityScanner_Setting__mdt` fields must also have descriptions so admins editing records know what they are changing.

**Inline Help Text (tooltips):** The `inlineHelpText` element renders as a "?" icon next to the field in record pages and list views. Used on fields whose name or values may be ambiguous to an admin who did not build the app.

#### `SecurityScanRun__c` Object Description
"Records one complete execution of the Org Security Scanner. Created each time an admin clicks Run Security Check. Parent to all SecurityFinding__c records for that scan run. Automatically deleted when beyond the configured retention limit."

#### `SecurityScanRun__c` Field Tooltips

| Field | Inline Help Text |
|---|---|
| `Status__c` | Pending: scan is queued. Running: scan is in progress. Completed: all categories finished. Failed: scan could not complete. Cancelled: admin requested stop; scan halted at the next category boundary with partial results saved. |
| `IsPartialScan__c` | Checked when the scan was run by a user without a System Administrator profile. Some Tooling API queries may return incomplete results. Re-run as a System Administrator for full coverage. |
| `FailedCategories__c` | Comma-separated category codes (e.g. AA, GU) for categories that threw an exception during scanning. Findings for these categories may be missing from this run. |
| `TotalChecksRun__c` | Total number of individual security checks executed in this scan. Should be 76 on a full successful scan across all 13 categories. |
| `OrgId__c` | Salesforce Organization ID of the org that was scanned. Used to identify which environment this run belongs to when reviewing historical data. |

#### `SecurityFinding__c` Object Description
"One record per detected security issue, child of SecurityScanRun__c. Stores the check that fired, the affected component, business impact, step-by-step remediation, and the admin acknowledgement workflow state. Automatically deleted when the parent scan run is deleted."

#### `SecurityFinding__c` Field Tooltips

| Field | Inline Help Text |
|---|---|
| `CheckId__c` | Stable identifier for the security check that produced this finding (e.g. UA-001). The same check ID appears across multiple scan runs. Not unique per record - use the record ID to key findings. |
| `CategoryCode__c` | Short programmatic code for the finding category. Valid values: UA, GU, SRA, SA, CAI, AA, LA, AGA, MS, FUE, CE, MON, HCB. |
| `FindingType__c` | Automated: a policy violation was directly detected by querying org metadata. Recommendation: the check cannot be fully automated and requires manual admin review to confirm. |
| `Impact__c` | Business and security consequences if this vulnerability is exploited or left unaddressed. Displayed in an amber warning box in the finding detail panel to distinguish consequence from technical description. |
| `Status__c` | Open: unreviewed. Acknowledged: reviewed, action pending. Remediated: fix has been applied. Risk Accepted: admin has consciously accepted this risk. False Positive: confirmed not a real issue. Remediated and False Positive are excluded from the security score. |
| `RawEvidence__c` | Automatically scrubbed technical evidence captured at scan time. Passwords, tokens, and secret-pattern strings are masked with asterisks. For regex-based findings, captures up to 5,000 characters before and up to 5,000 characters after the match (10,000 total hard cap) so the actual violation is centered in the output. Never contains full raw Apex source bodies. |
| `AffectedComponentType__c` | The type of Salesforce component that triggered this finding. Used to display the correct icon and generate a Setup navigation link in the finding detail panel. |
| `AcknowledgementNote__c` | Admin comment explaining the rationale. Required when setting status to Risk Accepted or False Positive. |
| `AcknowledgedBy__c` | The admin who last changed the status away from Open. Stored explicitly for fast SOQL filtering - do not derive from audit history. |

#### `SecurityCheckDef__mdt` Object Description
"Static registry of all security check definitions. One record per check, deployed with the package. Queried at scan runtime to populate findings and to display checks with zero findings explicitly in the UI. Set IsActive__c to false to disable a check without a code deploy."

#### `OrgSecurityScanner_Setting__mdt` Object Description
"Configuration settings for the Org Security Scanner. Edit the Default record in Setup > Custom Metadata Types to tune score sensitivity or change the scan run retention limit. Changes take effect on the next scan - no code deploy required."

#### `OrgSecurityScanner_Setting__mdt` Field Tooltips

| Field | Inline Help Text |
|---|---|
| `MaxScanRuns__c` | Maximum number of completed scan runs to retain. When exceeded, the oldest run and all its findings are automatically deleted. Default: 5 (sandbox). Increase for production compliance requirements. |
| `AllowProductionScan__c` | Server-side gate. Must be checked (true) before startScan() will proceed in a production org. Default: unchecked (false). Edit this record to enable production scanning. |
| `PortalHealthScoreThreshold__c` | Minimum acceptable Salesforce Security Health Check score for Experience Cloud portals. SRA-007 fires when the native score is below this value. Default: 70. |
| `ScoreDeductCritical__c` | Score points deducted for each Critical finding before the cap is applied. Default: 10. |
| `ScoreDeductHigh__c` | Score points deducted for each High finding before the cap is applied. Default: 4. |
| `ScoreDeductMedium__c` | Score points deducted for each Medium finding before the cap is applied. Default: 2. |
| `ScoreDeductLow__c` | Score points deducted for each Low finding before the cap is applied. Default: 0.5. |
| `ScoreDeductInfo__c` | Score points deducted for each Informational finding before the cap is applied. Default: 0.1. |
| `ScoreCriticalCap__c` | Maximum total score deduction from Critical findings combined. Default: 40. |
| `ScoreHighCap__c` | Maximum total score deduction from High findings combined. Default: 20. |
| `ScoreMediumCap__c` | Maximum total score deduction from Medium findings combined. Default: 20. |
| `ScoreLowCap__c` | Maximum total score deduction from Low findings combined. Default: 10. |
| `ScoreInfoCap__c` | Maximum total score deduction from Informational findings combined. Default: 5. |
| `ScoreFloor__c` | Minimum possible security score regardless of finding count. Default: 5. |

---

### ERD

```
SecurityScanRun__c (1)
    |-- Master-Detail --
    SecurityFinding__c (many)

SecurityCheckDef__mdt          [static registry, no FK, queried at runtime]
OrgSecurityScanner_Setting__mdt [config CMT, single Default record, deployed with package]
```

---

## Apex Architecture

### Governor Limit Strategy

76 checks use Tooling API REST callouts + standard SOQL. A single transaction cannot handle all categories.

Solution: **Queueable chain** - 13 jobs (one per category), chained sequentially. `Database.AllowsCallouts` on each Queueable. Max callouts per job: ~12 (GU category, worst case) - within the 100-callout limit. All findings from one category bulk-inserted in a single DML statement.

Known constraint: Salesforce allows only one child Queueable per executing job - the chain is inherently serial. No parallelism is possible without losing callout support. This is an accepted platform limitation for v1. A metadata-driven generic runner (v2) could reduce the 13 classes.

**Retry logic (v1 accepted gap):** If a Tooling API callout fails within a runner (network timeout, 503, etc.), the runner's `catch(Exception e)` logs the failure and the chain continues to the next category. There is no per-callout retry within a runner job. This is intentional for v1 - retry loops risk hitting the 100-callout limit. The admin can re-run the full scan to recover. A targeted category retry (v2) would require storing runner state between jobs.

---

### Class Hierarchy

```
force-app/main/default/classes/

SecScanException.cls              - Custom exception (extends Exception)
SecScanSessionExpiredException.cls - Extends SecScanException. Thrown by SecScanToolingService
                                    when HTTP 401 or INVALID_SESSION_ID is detected. Caught
                                    specifically in SecScanRunnerChain to produce a targeted
                                    "Session expired - re-run scan" error message rather than
                                    a generic runner failure.
SecScanApiResponse.cls            - Standardized @AuraEnabled response envelope
                                    { Boolean success, Object data, String errorMessage }
                                    All controllers return this - never raw types or exceptions.
                                    The `data` field uses typed inner DTOs for complex payloads
                                    (FindingsPageDTO, ScanStatusDTO, OrgSecuritySettingsDTO)
                                    rather than raw Object or Map<String,Object>.
                                    Simple scalar returns (Id, Integer) use Object directly.
SecScanEvidenceUtil.cls           - Context-aware evidence extraction before writing to RawEvidence__c.
                                    Operation order: SCRUB FIRST, THEN TRUNCATE. The scrub runs on
                                    the full input string before any truncation is applied. If the
                                    order is reversed, a credential at position 9,500 in a 15,000
                                    char body falls in the truncated region and the scrub never runs.
                                    Steps in order:
                                    1. Regex-scrub on full input: mask secrets with asterisks.
                                       Scrub patterns are declared as a public static final Map<String,String>
                                       (pattern -> replacement) so they are auditable and testable:
                                         password\s*=\s*\S+   -> password=***
                                         passwd\s*=\s*\S+     -> passwd=***
                                         pwd\s*=\s*\S+        -> pwd=***
                                         secret\s*=\s*\S+     -> secret=***
                                         api_key\s*=\s*\S+    -> api_key=***
                                         client_secret\s*=\s*\S+ -> client_secret=***
                                         Bearer\s+\S+         -> Bearer ***
                                         token\s*=\s*\S+      -> token=***
                                         credentials\s*=\s*\S+ -> credentials=***
                                       These are keyword-based, case-insensitive. Not entropy-based.
                                       Extend this list as new patterns are identified.
                                    2. Match-centered extraction on scrubbed output: capture up to
                                       5,000 chars before the match and up to 5,000 chars after the
                                       match (10,000 total), ensuring the actual violation is centered.
                                       If no match offset (non-regex findings): take first 10,000 chars.
                                    3. Hard cap at 10,000 chars total after extraction.
                                    Never stores raw Apex source bodies.
SecScanFindingDTO.cls             - Data transfer model used by runners
                                    Fields mirror SecurityFinding__c exactly:
                                    String checkId, checkName, category, categoryCode,
                                    severity, findingType, affectedComponent,
                                    affectedComponentType, description, impact,
                                    remediation, rawEvidence, salesforceDocUrl
                                    Populated by buildFinding() in base class only
SecScanToolingService.cls         - Tooling API REST calls only (/services/data/v66.0/tooling/)
                                    Receives sessionId as parameter - never calls getSessionId()
                                    Paginates via nextRecordsUrl
                                    CRITICAL - nextRecordsUrl pagination: Tooling API returns nextRecordsUrl
                                    as a root-relative path (e.g. /services/data/v66.0/tooling/query/01g...-2000).
                                    When following pages, construct the URL as:
                                      URL.getOrgDomainUrl().toExternalForm() + nextRecordsUrl
                                    NOT getBaseUrl() + nextRecordsUrl - that would double-append
                                    /services/data/v66.0/tooling/ and produce a 404.
                                    Checks Limits.getHeapSize() before each page
                                    HTTP 401 / INVALID_SESSION_ID detection: if response body contains
                                    'INVALID_SESSION_ID' or HTTP status = 401, throw a typed
                                    SecScanSessionExpiredException (extends SecScanException) so callers
                                    can distinguish token expiry from runner logic failures.
                                    SecScanRunnerChain.catch() logs "Session expired - re-run scan" when
                                    this exception type is caught, rather than a generic error message.
SecScanMetadataService.cls        - Metadata API SOAP calls only (/services/Soap/m/66.0)
                                    Used where Tooling API has no equivalent
                                    (FileUploadAndDownloadSecuritySettings, etc.)
                                    Parses XML via Dom.Document
                                    Used by: SecScanRunnerFileUpload, SecScanRunnerHealthCheck
                                    Error handling: SOAP faults are not HTTP errors - parse the
                                    <faultcode> and <faultstring> elements from the response body.
                                    Dom.Document.load() can throw XmlException on malformed XML -
                                    wrap in try/catch and rethrow as SecScanException.
                                    HttpRequest.setTimeout(30000) on all callouts (30s max).
SecScanCategoryRunner.cls         - Abstract base class
                                    execute(Id scanRunId, String sessionId)
                                    saveFindings() - single bulk insert, MAX 9,000 rows
                                    buildFinding() - enforced builder, all runners must use this
SecScanRunnerChain.cls            - Generic Queueable chain (Queueable + AllowsCallouts)
                                    Carries sessionId as constructor field through all 13 links
                                    Checks SecurityScanRun__c.Status__c at start of execute() -
                                    if Cancelled, calls SecScanOrchestrator.finalizeScan() to
                                    store score/counts from completed categories, then halts
                                    (does not enqueue next link). Score reflects only completed
                                    categories; Cancelled status tells the admin it is partial.
                                    try/catch per runner - one failure does not abort chain
                                    Catches SecScanSessionExpiredException specifically, logs
                                    "Session expired - re-run scan. If this recurs, your org's
                                    session timeout may be shorter than the scan duration.
                                    Consider increasing the session timeout or using Named
                                    Credential configuration (v2)." and marks remaining categories failed.
                                    Appends failed category code to FailedCategories__c on error.
                                    logError() appends to ErrorDetails__c using format:
                                    "[CategoryCode] ExceptionType: message\nStackTrace\n---\n"
                                    Before appending, checks current field length. If appending
                                    would exceed 32,000 chars (safe margin below 32,768 limit),
                                    appends "[truncated - additional errors omitted]" and stops.
                                    Appends completed category code to CompletedCategories__c on
                                    success (after runner.execute() returns without exception).
                                    ANTI-PATTERN AVOIDED: does NOT use Test.isRunningTest() in
                                    production code. Uses @TestVisible Boolean chainEnabled = true.
                                    Tests set chainEnabled = false before calling execute() to prevent
                                    chained enqueue without diverging production behavior.
SecScanOrchestrator.cls           - Entry point Queueable
                                    Does NOT create SecurityScanRun__c. The record is created
                                    by SecScanController.startScan() as the first step of the
                                    insert-first concurrency guard (Status__c = 'Pending').
                                    SecScanOrchestrator receives the already-created runId and
                                    sessionId as constructor parameters.
                                    execute(): (1) update SecurityScanRun__c Status__c = 'Running',
                                    StartedAt__c = Datetime.now(); (2) enqueue SecScanRunnerChain
                                    with the full runner class list and index 0.
SecScanRetentionBatch.cls         - Database.Batchable, scope 1 (NOT 200 - scope=200 means 200 runs
                                    per execute() transaction; at 100 findings/run = 20,000 child deletes,
                                    exceeding the 10,000 DML row limit. scope=1: one run + its children
                                    per transaction, safe at any realistic finding volume)
                                    Triggered by finalizeScan() after scan completes AND by nightly scheduler
                                    start(): query SecurityScanRun__c records beyond MaxScanRuns__c limit
                                    Also prunes orphaned Running/Cancelled runs older than 24h in same start()
                                    execute(): explicitly delete child SecurityFinding__c first, then parent
                                    Decoupled from scan execution - DML row limit cannot block a new scan
                                    (Inline cascade-delete of 5 runs x 2,500+ findings = 12,500 DML rows,
                                    exceeding the 10,000 Apex DML limit - this batch pattern avoids that)
SecScanOrphanCleanupSchedulable.cls - Schedulable wrapper. Fires SecScanRetentionBatch nightly.
                                    Handles runs that never reached finalizeScan() (scan crashed before
                                    the final Queueable executed). Without this, stuck Running runs
                                    accumulate indefinitely. Scheduled automatically by
                                    SecScanPostInstallHandler on package install/upgrade.
SecScanPostInstallHandler.cls     - Implements InstallHandler. Runs on fresh install AND upgrade.
                                    On install: System.schedule('SecScan Nightly Cleanup',
                                        '0 0 2 * * ?', new SecScanOrphanCleanupSchedulable()).
                                    On upgrade: abort existing job first (query CronTrigger for
                                    name = 'SecScan Nightly Cleanup'), then reschedule - prevents
                                    duplicate scheduled jobs across package upgrades.
                                    Returns silently on failure (cannot throw from InstallHandler -
                                    a thrown exception rolls back the install).
SecScanPostUninstallHandler.cls   - Implements UninstallHandler. Aborts the scheduled job on
                                    package removal. Queries CronTrigger by name and calls
                                    System.abortJob(). Silent on failure (job may already be absent).
SecScanRunnerContinuation.cls     - Heap-safe continuation Queueable for AA and LA runners
                                    Constructor: (Id scanRunId, List<String> runners, Integer currentIndex,
                                    String sessionId, Integer pageOffset)
                                    execute() MUST check Status__c for Cancelled first (same pattern as
                                    SecScanRunnerChain). Without this check, a cancelled scan that triggered
                                    a continuation still processes all remaining Tooling API pages (30+ seconds
                                    of wasted callouts and DML in large orgs) before the next chain link
                                    checks and halts. Guard: query Status__c; if Cancelled, call
                                    finalizeScan() and return without enqueueing the next chain link.
                                    Resumes Tooling API paging from pageOffset, saves additional findings,
                                    then calls System.enqueueJob(new SecScanRunnerChain(scanRunId, runners,
                                    currentIndex + 1, sessionId)) to resume the main chain
                                    CRITICAL: must carry the full runner list and currentIndex - without
                                    this, the chain terminates after the heap-overflow category

13 Category Runners (each extends SecScanCategoryRunner):
  SecScanRunnerUserAccess.cls         - UA  - 7 checks
  SecScanRunnerGuestUser.cls          - GU  - 15 checks (most API-intensive)
                                        CRITICAL: all 15 checks must operate on data fetched
                                        in bulk - never one Tooling API call per profile per check.
                                        Pattern: one query fetches all Guest profiles + permissions,
                                        load into memory as Map<Id, Map<String,Object>>,
                                        run all 15 checks against the in-memory collection.
                                        Maximum callouts for GU: ~3 (profiles, settings, experience).
                                        Per-profile queries would exceed the 100-callout limit.
  SecScanRunnerSharingAccess.cls      - SRA - 7 checks
  SecScanRunnerSessionAuth.cls        - SA  - 12 checks
  SecScanRunnerConnectedApps.cls      - CAI - 8 checks
  SecScanRunnerApexAutomation.cls     - AA  - 8 checks
  SecScanRunnerLwcAura.cls            - LA  - 3 checks
  SecScanRunnerAgentforce.cls         - AGA - 5 checks
  SecScanRunnerMetadataSecrets.cls    - MS  - 4 checks
  SecScanRunnerFileUpload.cls         - FUE - 3 checks (uses SecScanMetadataService)
  SecScanRunnerCertEncryption.cls     - CE  - 2 checks
  SecScanRunnerMonitoring.cls         - MON - 4 checks
  SecScanRunnerHealthCheck.cls        - HCB - 3 checks (uses SecScanMetadataService)

Apex Controllers (with sharing + WITH USER_MODE):
  SecScanController.cls             - startScan, getScanRuns, getScanRunStatus, cancelScan, exportFindingsCsv
  SecScanFindingsController.cls     - getCurrentScanFindings, getFindingDetail, updateFindingStatus, bulkUpdateFindingStatus

SecScanTestDataFactory.cls        - Shared test utility. Single source of truth for
                                    creating SecurityScanRun__c and SecurityFinding__c
                                    test records. All test classes use this - never
                                    construct records inline. Field changes require
                                    updating one file only.

Tests:
  SecScanOrchestratorTest.cls
  SecScanToolingServiceTest.cls
  SecScanMetadataServiceTest.cls          - SOAP fault parsing, malformed XML, timeout handling
  SecScanRunnerUserAccessTest.cls         - UA
  SecScanRunnerGuestUserTest.cls          - GU
  SecScanRunnerSharingAccessTest.cls      - SRA
  SecScanRunnerSessionAuthTest.cls        - SA
  SecScanRunnerConnectedAppsTest.cls      - CAI
  SecScanRunnerApexAutomationTest.cls     - AA
  SecScanRunnerLwcAuraTest.cls            - LA
  SecScanRunnerAgentforceTest.cls         - AGA
  SecScanRunnerMetadataSecretsTest.cls    - MS
  SecScanRunnerFileUploadTest.cls         - FUE
  SecScanRunnerCertEncryptionTest.cls     - CE
  SecScanRunnerMonitoringTest.cls         - MON
  SecScanRunnerHealthCheckTest.cls        - HCB
  SecScanControllerTest.cls
  SecScanFindingsControllerTest.cls
  SecScanCategoryRunnerTest.cls           - enforces buildFinding() normalization contract
  SecScanRetentionBatchTest.cls           - verifies old runs deleted, findings cascade-deleted
  SecScanOrphanCleanupSchedulableTest.cls - schedule the job, verify it appears in CronTrigger, unschedule. Minimal coverage sufficient for deployment.
  SecScanPostInstallHandlerTest.cls       - simulate fresh install and upgrade contexts. Verify job scheduled on install. Verify old job aborted and new job created on upgrade (no duplicate CronTrigger entries).
  SecScanPostUninstallHandlerTest.cls     - verify scheduled job is aborted. Silent on already-absent job.

Testing strategy for private runner methods: annotate private detection methods with @TestVisible.
Runner tests call the public execute() method for integration-level coverage and the @TestVisible
methods directly for isolated unit assertions. Do not test private methods only through execute() -
granular assertions on individual checks are not possible through the public surface alone.
```

---

### Critical: Session ID Must Be Captured Synchronously

`UserInfo.getSessionId()` returns `null` in all async Apex (Queueable, Batch, Future). It must be captured in `SecScanController.runSecurityScan()` (synchronous) and passed as a `String sessionId` constructor parameter down the entire chain. Never stored in any record.

**Known risk - session type mismatch:** Lightning Experience session tokens are not the same as API session tokens. Salesforce evaluates IP restrictions, HttpOnly flags, and session level security when a request hits the Tooling API. A Lightning-scoped token hitting the Tooling API is a cross-context use that Salesforce session security is specifically designed to prevent in locked-down orgs. Production orgs with standard security hardening (IP locking, "Lock sessions to the IP address from which they originated," "Require HttpOnly attribute," Enhanced Domains with API restrictions) will return `INVALID_SESSION_ID` immediately. This is not a rare edge case - it is the expected behavior in most well-secured orgs. Security administrators - the primary users of this app - are the most likely people to work in hardened orgs. The v1 build targets developer sandboxes; the Named Credential pattern below must be implemented before deploying to hardened orgs or production.

**Known risk - AsyncApexJob serialization:** When `System.enqueueJob(new SecScanOrchestrator(runId, sessionId))` is called, Salesforce serializes the Queueable object - including all constructor fields including `sessionId` - and stores it in AsyncApexJob internal state in the database. This serialized state is platform-managed and not directly readable via standard SOQL against AsyncApexJob, but it does represent a stored credential for the duration of the scan. The session ID is never stored in any custom record, but the AsyncApexJob serialization is a separate concern. **Risk posture:** the session ID is short-lived (it expires after the Queueable chain completes or the session times out), the data is not readable via standard queries, and the app targets developer sandboxes in v1. The Named Credential pattern (v2) eliminates this concern entirely by removing the session ID from the chain. This risk must be re-evaluated before any production deployment.

**Fallback if INVALID_SESSION_ID occurs - Named Credential pattern (v2):**
- Create a Self-Referencing Connected App with OAuth 2.0 JWT Bearer Flow
  - **Required OAuth scope:** `api`, `refresh_token`. Do NOT use `full` or `all` - least-privilege principle applies to Connected App scopes.
  - **Permitted Users policy:** "Admin approved users are pre-authorized" with `OrgSecurityScanner_Admin` PS listed. Do NOT use "All users may self-authorize."
- Create a Named Credential pointing to the org's own domain: `callout:OrgSecurityScanner_NC`
- Store the JWT private key in a Salesforce Certificate (not in code or metadata). The certificate has an expiration date - add the certificate's thumbprint and expiry to the `OrgSecurityScanner_Setting__mdt` Default record description so admins know when to rotate. The `CE` runner checks certificate expiry - optionally add a check for the scanner's own certificate if registered in `OrgSecurityScanner_Setting__mdt`.
- Update `SecScanToolingService` to use `callout:OrgSecurityScanner_NC/services/data/v66.0/tooling/` instead of building the URL from session ID
- Eliminates brittle session ID passing entirely, removes AsyncApexJob serialization concern, works regardless of org security policies.
- Requires one additional setup step on first install (Connected App + Named Credential + certificate upload).

```apex
// SecScanController.startScan() - synchronous
String sessionId = UserInfo.getSessionId(); // valid here only
System.enqueueJob(new SecScanOrchestrator(runId, sessionId));

// SecScanRunnerChain - carries sessionId through every link
System.enqueueJob(new SecScanRunnerChain(scanRunId, runners, currentIndex + 1, sessionId));

// SecScanToolingService - receives it as parameter
public static Map<String, Object> queryTooling(String soql, String sessionId) { ... }
```

---

### URL Resolution with Defensive Fallback

```apex
private static final String API_VERSION = 'v66.0'; // single constant, easy to update

private static String getBaseUrl() {
    String url = URL.getOrgDomainUrl() != null
        ? URL.getOrgDomainUrl().toExternalForm()
        : URL.getSalesforceBaseUrl().toExternalForm();
    return url + '/services/data/' + API_VERSION + '/tooling/';
}
```

`getOrgDomainUrl()` is preferred (My Domain). Falls back to `getSalesforceBaseUrl()` (instance URL) if My Domain is not propagated. No Remote Site Settings needed - same-org loopback.

---

### Runner Chain Pattern

```apex
// SecScanRunnerChain.execute()
public void execute(QueueableContext ctx) {
    // Cancellation check - must be first. Admin may have cancelled while this job was queued.
    SecurityScanRun__c run = [SELECT Status__c FROM SecurityScanRun__c WHERE Id = :scanRunId LIMIT 1];
    if (run.Status__c == 'Cancelled') {
        // finalizeScan() computes Score__c, Grade__c, and aggregate counts from whatever categories ran.
        // CRITICAL: finalizeScan() must NOT set Status__c = 'Completed' if current status is Cancelled.
        // It must check status before writing: if (currentStatus != 'Cancelled') { run.Status__c = 'Completed'; }
        // Without this guard, finalizeScan() overwrites Cancelled -> Completed, contradicting the cancel test assertion.
        SecScanOrchestrator.finalizeScan(scanRunId);
        return;
    }

    // @TestVisible flag replaces Test.isRunningTest() anti-pattern.
    // Tests set chainEnabled = false before calling execute().
    // Production code never references Test class.
    @TestVisible private Boolean chainEnabled = true;

    SecScanCategoryRunner runner =
        (SecScanCategoryRunner) Type.forName(runners[currentIndex]).newInstance();
    try {
        runner.execute(scanRunId, sessionId);
        appendCompletedCategory(scanRunId, runners[currentIndex]);
    } catch (Exception e) {
        logError(scanRunId, runners[currentIndex], e); // appends to FailedCategories__c
    }

    if (currentIndex + 1 < runners.size()) {
        if (chainEnabled) {
            System.enqueueJob(new SecScanRunnerChain(scanRunId, runners, currentIndex + 1, sessionId));
        } else {
            // Test context: chainEnabled = false, finalize directly for test assertions
            SecScanOrchestrator.finalizeScan(scanRunId);
        }
    } else {
        SecScanOrchestrator.finalizeScan(scanRunId); // sets Completed, updates counts
    }
}
```

---

### DML Row Cap Per Category

`SecScanCategoryRunner` base class enforces:

```apex
private static final Integer MAX_FINDINGS_PER_CATEGORY = 9000;
```

Before each `findings.add()`, check `findings.size() < MAX_FINDINGS_PER_CATEGORY`. If cap reached, append one synthetic finding:
- `CheckId__c = categoryCode + '-CAP'`
- `Severity__c = 'Informational'`
- `Description__c = 'Maximum findings limit reached. Remediate existing findings and rescan.'`

Then `saveFindings()` normally. Stays under the 10,000 DML row limit.

---

### Heap Size Management

`SecScanRunnerApexAutomation` and `SecScanRunnerLwcAura` query Apex source bodies. Pattern:
- Page size = 200 records per Tooling API call, follow `nextRecordsUrl`
- Before each page: check `Decimal.valueOf(Limits.getHeapSize()) / Limits.getLimitHeapSize() > 0.7`
  (`Limits.getHeapSize()` returns an Integer - integer division always produces 0 regardless of actual heap usage; cast to Decimal first)
- If heap > 70%: save findings so far, enqueue `SecScanRunnerContinuation(scanRunId, runners, currentIndex, sessionId, pageOffset)`, then stop current job
- `SecScanRunnerContinuation.execute()` resumes paging from `pageOffset`, saves additional findings, then enqueues `new SecScanRunnerChain(scanRunId, runners, currentIndex + 1, sessionId)` to hand off to the next category
- **Critical**: the continuation carries the full `runners` array and `currentIndex` - without these, the chain terminates after the heap-overflow category and all subsequent categories (e.g. MS, FUE, CE, MON, HCB) are never executed
- Each class body parsed and immediately discarded - never accumulated in memory

---

### Key Check Logic by Category

| Category | API Used | Detection Approach | Heap Guard |
|---|---|---|---|
| UA | Standard SOQL | `SELECT Id FROM PermissionSet WHERE PermissionsModifyAllData=true` | No - SOQL only, no large body fetches |
| GU | Tooling API | `SELECT Id,PermissionsApiEnabled FROM Profile WHERE UserType='Guest'` | No - bulk in-memory Map, no body fetches. Max ~3 callouts. **Note:** GU loads all Guest profiles + permission data into a `Map<Id, Map<String,Object>>`. In orgs with 100+ Guest profiles (unusual but possible in large Experience Cloud deployments), heap pressure can build. No continuation pattern exists for GU in v1 - if heap overflows, the entire GU category fails. Monitor in scale testing; if GU fails in large orgs, add a heap check before each profile batch and a GU-specific continuation. |
| SRA | Standard SOQL + Tooling | OWD via `EntityDefinition`, ScopeRule vs RestrictionRule | No - metadata queries only |
| SA | Tooling API | `SELECT SessionTimeout,RequireHttpOnly,EnableClickjackNonsetupUser,EnableCsrfOnGet,LockSessionsToDomain FROM SecuritySettings` | No - small result set |
| CAI | Tooling API | `SELECT IncludesSessionId FROM WorkflowOutboundMessage WHERE IncludesSessionId=true` | No - metadata queries only |
| AA | Tooling API body scan | `SELECT Name,Body FROM ApexClass` + regex (Informational severity only - heuristic) | **Yes** - fetches Apex source bodies. Continuation pattern if heap > 70%. |
| LA | Tooling API | Scan LightningComponentBundle source for `lwc:dom="manual"` | **Yes** - fetches LWC source. Continuation pattern if heap > 70%. |
| AGA | Tooling API | `SELECT IsConfirmationRequired FROM GenAiFunctionDefinition WHERE IsConfirmationRequired=false` | No - small metadata result |
| MS | Standard SOQL on `__mdt` | SOQL on custom metadata records directly - NOT Metadata API. Inspect field names for Token/Key/Password/Secret patterns. | No - CMT field names only, no bodies |
| FUE | `SecScanMetadataService` SOAP | `FileUploadAndDownloadSecuritySettings` - not in Tooling API SOQL, requires SOAP Metadata API call. Note: SOAP Metadata API requires the running user to have View Setup and Configuration or Modify All Data. If the user lacks this permission, the SOAP call returns a SOAP fault - caught and logged as category failure. | No - single SOAP call |
| CE | Standard SOQL | `SELECT ExpirationDate FROM Certificate WHERE ExpirationDate <=:Date.today().addDays(30)` | No - small result |
| MON | Tooling API | EventMonitoringSettings and EventLogFile presence | No - small metadata queries |
| HCB | `SecScanMetadataService` SOAP | SecurityHealthCheck score and high-risk settings. Reads Salesforce's native Health Check score via SOAP. SRA-007 threshold (`PortalHealthScoreThreshold__c`) compared against the native score - finding fires if below threshold. Same Metadata API permission note as FUE applies. | No - single SOAP call |

---

### Regex-Based Checks - Severity Cap

AA checks that use regex on Apex source (hardcoded secrets, debug PII logging) are heuristic - high false positive/negative rate. These must:
- Be capped at `Severity__c = 'Informational'` - never Critical or High
- Include in description: "This is a heuristic check. Manual code review required to confirm."
- Never be the sole basis for a high-severity score deduction

---

### Finding Builder Normalization

All 13 runners must use `buildFinding()` from the base class exclusively. No inline record construction. `buildFinding()` enforces:
- `ScanRun__c` always set
- `Severity__c` always a valid picklist value
- `FindingType__c` always set
- `RawEvidence__c` always passed through `SecScanEvidenceUtil.scrub()` first
- `Description__c`, `Impact__c`, and `Remediation__c` always populated - if blank (e.g. admin accidentally cleared a CMT field), `buildFinding()` sets a fallback: `"No description available - check SecurityCheckDef__mdt record [CheckId]"`. This produces a visible finding that points directly at the data problem rather than crashing the entire category with a cryptic runner failure.
- `Severity__c` fallback: if blank or not in the valid picklist set, `buildFinding()` sets `Severity__c = 'Low'`. A blank Severity__c causes a picklist validation failure on insert, crashing the entire category DML. Default Low is safe - it produces a visible finding without inflating the score.
- `FindingType__c` fallback: if blank, `buildFinding()` sets `FindingType__c = 'Automated'`. A blank FindingType__c produces an incomplete finding row in the UI and may break filtering.

Enforced by `SecScanCategoryRunnerTest`.

---

### Data Retention Policy

Developer sandboxes: 200MB storage limit. Retention cleanup runs in `SecScanRetentionBatch` (Database.Batchable), triggered by `finalizeScan()` after the scan completes. A nightly `SecScanOrphanCleanupSchedulable` (Schedulable) also fires `SecScanRetentionBatch` independently - this handles orphaned runs that never reached `finalizeScan()` (e.g. scan crashed before the final Queueable ran). Without the scheduler, stuck Running runs from a crash would never be cleaned up.

**Why Batchable, not inline:** Salesforce cascade deletes on Master-Detail do NOT count toward the Apex DML row limit - the platform handles them implicitly. However, the Batchable pattern is still required for a different reason: before/after delete triggers on `SecurityFinding__c` fire on cascade-deleted records. If a trigger performs SOQL or DML (even indirectly via process builders, flows, or workflow rules), those operations run in the calling transaction. Deleting 5 runs x 2,500+ findings inline means thousands of trigger executions in one transaction - exhausting SOQL limits, CPU time, or other limits the trigger code consumes. The Batchable processes each run in its own transaction, isolating trigger overhead per run. Explicit child deletion first (before parent) is retained for clarity and trigger control.

```apex
// SecScanRetentionBatch - execute() per old SecurityScanRun__c record
public void execute(Database.BatchableContext ctx, List<SecurityScanRun__c> scope) {
    Set<Id> runIds = new Map<Id, SecurityScanRun__c>(scope).keySet();
    delete [SELECT Id FROM SecurityFinding__c WHERE ScanRun__c IN :runIds]; // explicit child delete
    delete scope; // parent delete - no cascade DML surprise
}

// SecScanOrchestrator.finalizeScan() responsibilities (called from SecScanRunnerChain after last runner,
// or from SecScanRunnerChain/SecScanRunnerContinuation on Cancelled):
//
// 1. CRITICAL guard: query current Status__c first. Only set Status__c = 'Completed' if
//    current status is NOT 'Cancelled'. A cancelled scan must remain Cancelled.
//
// 2. Set CompletedAt__c = Datetime.now().
//
// 3. TotalChecksRun__c = count of SecurityCheckDef__mdt WHERE IsActive__c = true.
//    Uses active check count, not hardcoded 76 - reflects disabled checks accurately.
//    Admin can see "73 of 76 checks ran" if 3 were disabled.
//
// 4. Aggregate counts by severity from SecurityFinding__c WHERE ScanRun__c = :runId.
//    Five aggregate SOQL queries (one per severity) - safe, within Queueable limits.
//    Sets CriticalCount__c, HighCount__c, MediumCount__c, LowCount__c, InfoCount__c,
//    TotalFindings__c.
//
// 5. Compute Score__c and Grade__c from CMT deduction weights applied to the counts.
//    Score = max(ScoreFloor, 100 - capped deductions). Exclude Remediated/False Positive
//    from live counts before computing (query with Status__c NOT IN ('Remediated','False Positive')).
//    0 findings = Score 100, Grade A.
//
// 6. Update the SecurityScanRun__c record (single DML).
//
// 7. Trigger SecScanRetentionBatch.

// SecScanOrchestrator.finalizeScan() - after setting Status = Completed
OrgSecurityScanner_Setting__mdt settings = OrgSecurityScanner_Setting__mdt.getInstance('Default');
Integer maxRuns = settings != null && settings.MaxScanRuns__c != null ? (Integer) settings.MaxScanRuns__c : 5;
Database.executeBatch(new SecScanRetentionBatch(maxRuns), 1);
// scope=1 is required: scope=200 means execute() receives 200 runs at once.
// At 100 findings/run: 200*100 = 20,000 child deletes in one transaction - exceeds 10,000 DML row limit.
// scope=1: one run + its children per transaction. Safe at any realistic finding volume.

// SecScanOrphanCleanupSchedulable.execute() - nightly at 02:00, same call
// Handles runs that crashed before reaching finalizeScan() - without this, stuck Running runs
// accumulate indefinitely since finalizeScan() is never called on a crashed scan.
// System.schedule('SecScan Nightly Cleanup', '0 0 2 * * ?', new SecScanOrphanCleanupSchedulable());
// - Register once at installation (Execute Anonymous or post-install script).

// SecScanRetentionBatch.start() - two-step pattern (required - cannot express in one QueryLocator):
// Step 1: Imperative SOQL to build the keep-set (N most recent completed runs).
//   SOQL does not support NOT IN (SELECT ... ORDER BY ... LIMIT N) as a subquery.
//   Must query the IDs to keep first, then exclude them in the QueryLocator.
//
//   List<SecurityScanRun__c> recent = [SELECT Id FROM SecurityScanRun__c
//       WHERE Status__c = 'Completed' ORDER BY CompletedAt__c DESC LIMIT :maxRuns];
//   Set<Id> keepIds = new Map<Id, SecurityScanRun__c>(recent).keySet();
//
// Step 2: Return QueryLocator combining both cleanup concerns:
//   return Database.getQueryLocator([
//       SELECT Id FROM SecurityScanRun__c
//       WHERE (Status__c = 'Completed' AND Id NOT IN :keepIds)
//          OR (Status__c IN ('Running', 'Cancelled') AND StartedAt__c < :cutoff)
//   ]);
// This single QueryLocator handles both: completed runs beyond the retention limit,
// and orphaned/cancelled runs older than 24h. The developer must NOT assume this
// is a simple single-condition query - the two-step is mandatory.
```

UI shows on History tab: "Storing X of [MaxScanRuns] max runs. Oldest auto-deleted."

**Concurrent batch note:** `Database.executeBatch(new SecScanRetentionBatch(maxRuns), 1)` runs asynchronously. If a second scan completes quickly after the first (within the 5-minute cooldown), the retention batch from scan 1 may still be queued or running when scan 2's batch is enqueued. Salesforce Flex Queue handles concurrent batches sequentially - scan 2's retention may wait behind scan 1's. This is acceptable: retention is not time-critical and asynchronous queuing is the expected behavior. No guard against concurrent batch instances is needed.

**Scheduled job user context:** `SecScanOrphanCleanupSchedulable` runs as the user who scheduled it (the installing admin via `SecScanPostInstallHandler`). If that user's account is later deactivated, the job fails silently. **Recommended practice:** create a dedicated integration user (e.g. `orgsecscanner@yourorg.com`) with only the `OrgSecurityScanner_Admin` Permission Set and no other access. Use this user to manually schedule the job via Execute Anonymous if the post-install handler fails, or after re-installing to an org with a different admin. This prevents both the deactivated-admin failure mode and limits the blast radius of a compromised admin account.

---

### Additional Checks (Health Check Gap Analysis)

Beyond the original 76:

- **SA-010** CSRF Protection disabled (`SecuritySettings.EnableCsrfOnGet / EnableCsrfOnPost`)
- **SA-011** Session Domain Locking disabled (`SecuritySettings.LockSessionsToDomain`)
- **SA-012** Device Activation SMS not enforced
- **SA-013** Delegated Authentication misconfigured on sensitive profiles
- **GU-016** Experience Cloud "Let guest users see other members" enabled
- **GU-017** Enhanced Personal Information Masking (EPIM) not configured when member visibility is on
- **SRA-006** Sharing Sets with broad access on Experience Cloud
- **SRA-007** Portal Health Check native score below threshold

---

## Security Controls on the App Itself

- All controllers: `with sharing` (record-level) + `WITH USER_MODE` on all SOQL (object + field level). `with sharing` alone does not enforce CRUD or FLS.
  - Example: `[SELECT Id, Description__c FROM SecurityFinding__c WHERE ScanRun__c = :id WITH USER_MODE]`
- **Runner DML (system-generated data):** `Database.insert(findings, AccessLevel.SYSTEM_MODE)`. Runners are trusted system processes - they produce findings, they do not relay user input. `USER_MODE` on runner inserts silently drops fields if the running admin's PS is missing any field permission, producing incomplete findings with no error.
- **Controller DML (user-initiated actions):** `Database.update/insert(records, AccessLevel.USER_MODE)`. Controllers that process admin actions (`updateFindingStatus`, `bulkUpdateFindingStatus`) enforce FLS correctly.
- Where `WITH USER_MODE` would strip needed fields on reads: `Security.stripInaccessible(AccessType.READABLE, records)`
- **WITH USER_MODE graceful degradation**: Any admin summary query (e.g. aggregate counts, scan run list) that would fail silently if the running user lacks field access must wrap the query in a try/catch `QueryException`. On catch: return a partial result with a flag (e.g. `isPartialData: true`) rather than throwing. The UI displays a non-blocking warning. Controllers that are read-only views (getScanRuns, getScanRunStatus) must not throw on access gaps - only writes (updateFindingStatus) may throw.
- **Dynamic SOQL bind safety**: No controller or runner ever concatenates user-supplied input into a SOQL string. All variable predicates use Apex bind variables (`:variable`). The only dynamic SOQL in the codebase is in `SecScanFindingsController` for optional filters (category, severity, status). These are built via a whitelist approach: each accepted filter value is validated against a hardcoded `Set<String>` of allowed values before appending to the WHERE clause. **Field names in the WHERE clause are always hardcoded string literals - never sourced from user input.** Unknown values are rejected and `SecScanApiResponse.errorMessage` is populated with `'Invalid filter value'` so the LWC can display a non-blocking warning. Silently dropping invalid values is avoided because it would widen results without any indication to the caller.
- **`searchTerm` input cap:** `getCurrentScanFindings` caps `searchTerm` at 100 characters before processing. A 32KB search pattern produces a 32KB LIKE clause - heap and CPU concern on a call that runs frequently. `String.escapeSingleQuotes()` is applied after the cap. **Performance note:** SOQL LIKE with `%term%` on Text(255) fields does not use indexes. The `ScanRun__c` predicate narrows the result set first, but at 9,000+ findings the secondary LIKE scan within the partition is not instant. Document in the UI tooltip: "Search may be slow on large result sets."
- `startScan()` concurrency guard: **v1 uses insert-first pattern** (promotes the v2 fix to v1 - the original FOR UPDATE approach has a DoS gap). `startScan()` is the sole creator of `SecurityScanRun__c` records - `SecScanOrchestrator` receives the already-created `runId` and only updates the status to `Running`. Pattern: (1) insert the `SecurityScanRun__c` record with `Status__c = 'Pending'`. (2) Query `SELECT COUNT() FROM SecurityScanRun__c WHERE Status__c IN ('Pending','Running') FOR UPDATE`. (3) If count > 1, delete the just-inserted record and throw `SecScanException('A scan is already in progress')`. (4) Otherwise: capture session ID, enqueue `SecScanOrchestrator(runId, sessionId)`. The orchestrator's `execute()` updates the record to `Running`, sets `StartedAt__c`, and enqueues the first `SecScanRunnerChain`. The FOR UPDATE in step 2 locks the counted rows, preventing two concurrent inserts from both proceeding. Without this, a burst of concurrent API calls could flood the Flex Queue (100-job limit), saturating the org's async processing capacity.
- `startScan()` reads `[SELECT IsSandbox FROM Organization LIMIT 1]`. If `IsSandbox = false`: checks `AllowProductionScan__c` on `OrgSecurityScanner_Setting__mdt` - if false (default), throws `SecScanException('Production scanning is disabled. Enable AllowProductionScan__c in OrgSecurityScanner_Setting__mdt.')`. If `AllowProductionScan__c = true`: sets `IsProductionScan__c = true` on the new run record. The LWC confirmation modal is a second gate, not the only gate. Secure default is deny.
- `startScan()` validates running user has `OrgSecurityScanner_Admin` Permission Set (defense-in-depth)
- `startScan()` checks `PermissionsModifyAllData` on the running user's profile as a proxy for full metadata visibility. If false: does not block but sets `IsPartialScan__c = true`. UI shows: "Running as a user without full metadata visibility - some Tooling API results may be incomplete." Note: this is not an exact System Administrator role check - it is a practical proxy for whether the session will return complete Tooling API results.
- `updateFindingStatus()` validates finding is accessible to current user before updating
- No `System.debug` in production code paths
- No user-controlled input in Tooling API SOQL strings
- Session ID never persisted to any record

---

## Permission Set

**API Name**: `OrgSecurityScanner_Admin`

| Grant | Detail |
|---|---|
| Object: `SecurityScanRun__c` | Read, Create, Edit, Delete, ViewAllRecords |
| Object: `SecurityFinding__c` | Read, Create, Edit, Delete, ViewAllRecords |
| Object: `ContentVersion` | Create, Read - required for `exportFindingsCsv` to create the CSV file |
| Object: `ContentDocumentLink` | Create, Read - required to link the export file to the scan run record |
| Tab: `OrgSecurityScanner` | Visible |
| App: `OrgSecurityScannerApp` | Access |

Does NOT grant `ModifyAllData`, `ViewAllData`, or any system permissions. The Tooling API calls use the running user's session - full results require a System Administrator.

**Why ContentVersion/ContentDocumentLink:** `exportFindingsCsv` creates a ContentVersion (the CSV file) and a ContentDocumentLink (linking it to the SecurityScanRun__c record). Without these grants, the export fails with a FIELD_CUSTOM_VALIDATION_EXCEPTION or INSUFFICIENT_ACCESS error. These objects are not granted by default in locked-down orgs. The error state table covers this failure - the root cause is missing PS grants.

**Why not Permission Set Group:** A Permission Set Group combines multiple permission sets for users with different needs. This app has one audience (security admins) and one PS. No grouping is needed. If a future v2 adds a read-only auditor role (view findings but not run scans), a second PS + PSG would be the correct pattern.

---

## App & Navigation Structure

- **Lightning App**: `OrgSecurityScannerApp` - single tab, visible in App Launcher
- **Custom Tab**: `OrgSecurityScanner` - shield icon, points to Flexipage
- **Flexipage**: `OrgSecurityScannerApp_Page` - AppPage, single region, contains root LWC `securityScanner`

---

## UI/UX Design

### Overview

Single-page application. No full page reloads. Three views (Dashboard, Findings Explorer, History) in a tab strip. Persistent left panel always visible. Slide-in right detail panel on finding click. All styling: SLDS only - no external CSS frameworks.

### Page Layout

```
[ Global Salesforce Header ]
[ App Header Bar - 72px: shield icon, title, score ring, Run button, last scan chips ]
[ Tab Strip - 44px: Dashboard | Findings (N) | History ]
[ Content Area ]
  |-- [ Left Panel - 260px fixed sticky, collapsible ]
  |-- [ Right Panel - flex grow, scrollable ]
        |-- Dashboard: heatmap (13 cells) + recent findings + scan stats
        |-- Findings Explorer: filter bar + findings list
        |-- History: scan list
[ Slide-in Detail Panel - 45% width, overlays right on finding click ]
[ Scan Progress View: replaces right panel while scan is running ]
```

### App States

| State | Behavior |
|---|---|
| Initializing | Page skeleton shown from LWC mount until all three @wire calls resolve (getScanRuns, getOrgInfo, getOrgSecuritySettings). Render the structural layout (header bar outline, tab strip, left panel, content area) as grey shimmer placeholder blocks using SLDS `slds-is-loading` shimmer pattern. Prevents blank-screen flash and layout shift when data arrives. Transition to the appropriate state when all wires resolve. |
| No scan yet | Empty state illustration + CTA. Tab strip disabled. Onboarding context below illustration (4 bullets): "Checks 76 security configurations across 13 categories. Read-only - makes no changes to your org. Typical scan time: 2-5 minutes. Results stored in-org, auto-deleted after [MaxScanRuns__c] scans." Last value read from `getOrgSecuritySettings()`. |
| Production org | Persistent red banner across the top: "PRODUCTION ORG - changes to finding status will affect your live org." `IsProductionScan__c` badge shown in header. |
| Scan running | Button replaced by spinner "Scan Running...". Progress view shown - renders a 13-item checklist of all categories: completed (green tick), failed (red X), **in-progress (animated spinner - the category currently running)**, remaining (grey). The in-progress category is derived as: the first category NOT in `completedCategories` AND NOT in `failedCategories`. This gives the admin a "currently scanning: Guest User" signal and makes the progress view feel alive even as polling slows. A "Last checked: N seconds ago" timestamp appears beside the checklist. Tab strip disabled. Adaptive polling: starts 2s, backs off to 5s after 20s, to 10s after 60s. `clearInterval` on Completed/Failed/Cancelled. v2: replace with `Scan_Progress__e` Platform Event + `lightning/empApi`. |
| Scan complete | Toast notification. Dashboard activates. Left panel populates. |
| Failed categories | Warning banner: "Some categories failed to scan: AA, GU. Results may be incomplete." |
| Partial scan | Warning banner: "Running as a user without full metadata visibility - results may be incomplete." |
| Scan cancelled | Amber banner: "Scan was cancelled after [N] of 13 categories. Results are partial." Dashboard shows findings from completed categories. Score ring displays the partial score computed by finalizeScan(). Run button re-enabled immediately - cancelled scans do NOT consume the 5-minute cooldown (admin intentionally stopped the scan and should be able to re-run immediately). |
| Viewing history | Amber banner "Viewing Historical Data". Status actions disabled. |

### App Header Bar

- Left: `utility:shield` icon + "Org Security Scanner" + "Salesforce Org Security Analysis"
- Right: Score Ring (SVG arc, 0-100, grade A-F) + "Run Security Check" button (`variant="brand"`) + "Export CSV" icon button (`utility:download`, placed left of Run button). Export exports all findings for the current scan (not filtered subset - the CSV is a compliance artifact). Export button shows a spinner during generation. On success: toast "CSV exported - [Download]" where Download opens the ContentDocument. On failure: show error toast per the error states table. Export button is disabled during a running scan and when no scan exists.
- Score Ring: clicking or hovering the ring shows an `slds-popover` score breakdown. Content: "Starting score: 100. Critical: -[N] ([count] x [deduct], cap [cap]). High: -[N]. Medium: -[N]. Low: -[N]. Info: -[N]. Excluded: [R+FP count] Remediated/False Positive. Final: [score] (Grade [letter])." Values computed from `getScoreCounts()` result and `getOrgSecuritySettings()` CMT weights - both already in the LWC. Helps admins explain the score to stakeholders.
- Center: Last scan chips (timestamp, operator, finding count)
- Click button: `lightning-modal` confirmation before scan starts. If `getOrgInfo().isSandbox = false`, the modal shows a red production warning: "You are about to scan a PRODUCTION org. This is read-only but may surface sensitive configuration details. Proceed?" with a red "Scan Production" confirm button. Sandbox confirmation is the standard neutral modal.
- 5-minute cooldown with countdown, starting from scan completion/failure detection (not from button click). If the scan takes 8 minutes, the cooldown expires during the scan and the button is available immediately on completion. Cancelled scans bypass the cooldown entirely - the admin should be able to re-run immediately after cancelling.

### Security Score Formula

Deduction weights and caps are read from `OrgSecurityScanner_Setting__mdt` (Default record) - never hardcoded. Default behavior: start at 100. Deductions (capped): Critical -10 (max -40), High -4 (max -20), Medium -2 (max -20), Low -0.5 (max -10), Info -0.1 (max -5). Floor: 5. Remediated/False Positive excluded.

`finalizeScan()` computes `Score__c` and `Grade__c` and stores them on `SecurityScanRun__c` - these are the authoritative values for history and export. Storing them prevents retroactive score shifts when CMT deduction weights are later edited.

**Live score after status changes:** The LWC does NOT recalculate score from in-memory `allFindings[]`. Findings are paginated at 100 per page - `allFindings[]` only contains loaded pages. Calculating score from a partial array produces a wrong result (e.g. admin loads 100 of 400 findings, marks 3 Critical as Remediated - score recalculated from 100 findings, missing 300 High/Medium/Low findings on pages 2-4).

Instead: after every `updateFindingStatus` or `bulkUpdateFindingStatus`, the LWC calls `getScoreCounts(String scanRunId)` - a lightweight `@AuraEnabled(cacheable=false)` method that returns `{ criticalOpen, highOpen, mediumOpen, lowOpen, infoOpen }` (counts of findings where `Status__c NOT IN ('Remediated','False Positive')`). The LWC applies the CMT deduction formula to these server-side counts. No full page reload required, no in-memory array iteration.

`getScoreCounts()` is added to `SecScanFindingsController`. It is NOT used to update `Score__c` on the run record - that value is frozen by `finalizeScan()` and only reflects the state at scan completion (correct behavior - prevents retroactive changes).

Grades: A = 90-100, B = 75-89, C = 60-74, D = 45-59, F = 0-44.

**Note:** Grade band thresholds are intentionally hardcoded in `secScanConstants.js` as fixed product policy. They are not admin-configurable via `OrgSecurityScanner_Setting__mdt`. Only numeric deduction weights and caps are configurable. This is a deliberate design decision - grade definitions should be consistent across all installs.

### Severity Colors

Colors use SLDS design tokens via CSS custom properties defined in the root component's CSS file (`securityScanner.css`). Never hardcoded as hex values in JavaScript or inline styles.

```css
/* securityScanner.css - single source of truth for severity colors */
:host {
    --color-critical: var(--lwc-colorTextError, #c23934);
    --color-high: var(--lwc-colorTextWarning, #dd7a01);
    --color-medium: var(--lwc-colorTextDefault, #f4bc25);
    --color-low: var(--lwc-colorBorderNeutral, #54698d);
    --color-info: var(--lwc-colorTextWeakest, #b0adab);
    --color-pass: var(--lwc-colorTextSuccess, #2e844a);
}
```

Child components inherit via CSS cascade. JavaScript uses `data-severity` attributes on elements; CSS handles coloring via `[data-severity="critical"]` selectors.

| Severity | SLDS Token (fallback hex) | Icon |
|---|---|---|
| Critical | `--lwc-colorTextError` (`#c23934`) | `utility:error` |
| High | `--lwc-colorTextWarning` (`#dd7a01`) | `utility:warning` |
| Medium | `--lwc-colorTextDefault` (`#f4bc25`) | `utility:info` |
| Low | `--lwc-colorBorderNeutral` (`#54698d`) | `utility:low_priority` |
| Informational | `--lwc-colorTextWeakest` (`#b0adab`) | `utility:info_alt` |
| Pass | `--lwc-colorTextSuccess` (`#2e844a`) | `utility:check` |

Color is never the sole indicator - icon always accompanies it (accessibility).

**WCAG contrast requirement:** `--color-medium` (`#f4bc25` yellow) on a white background produces a contrast ratio of ~1.7:1 - WCAG AA requires 4.5:1 for normal text and 3:1 for large text. Both fail. Fix:
- Severity label text (e.g. "Medium") always uses `--lwc-colorTextDefault` (dark grey), never the severity color. Only the dot/badge background uses the severity color token.
- Heatmap amber cells ("1-3 findings"): use dark text (`--lwc-colorTextDefault`) on the amber background, not white text. Amber background with white text also fails contrast.
- `--color-medium` is acceptable as a background color with dark foreground text or as an icon fill where the icon is large enough to meet the 3:1 large-text threshold. It must not be used as foreground text color on white.

### Left Panel (Persistent, 260px, collapsible)

Width reduced from 320px to 260px. At 1366px viewport (common in government/NGO), the Salesforce nav (~220px) + 320px left panel + 45% detail panel (~515px) leaves only ~311px for the findings list - unusable. At 260px the findings list retains ~371px with the detail panel open, which is workable. The panel has a collapse toggle arrow on its right edge; when collapsed it renders as a 40px icon strip so admins working in the detail panel can recover full width. Collapsed state is component-level only and resets to expanded on page reload. `localStorage` is not used - it is namespace-scoped under LWS and blocked by CSP in some enterprise orgs, causing a silent failure. Cross-session persistence is not worth the compatibility risk for a convenience toggle.

- **Severity Breakdown**: 5 rows - colored dot + label + `lightning-progress-bar` + count. Click filters Findings Explorer. Counts are driven by `getScoreCounts()` results after any status change (not the `SecurityScanRun__c` parent record counts, which are frozen at scan completion). On initial load, derive from the parent record counts; after any `updateFindingStatus` / `bulkUpdateFindingStatus`, refresh from `getScoreCounts()`.
- **Quick Stats**: 3-tile grid - Open / Critical / Pending Recommendations. Each clickable. Same data source rule as Severity Breakdown.
- **Trend vs Previous**: Table comparing this scan vs the previous scan, delta arrows color-coded. Data source: `getScanRuns()` already returns the full scan list. The LWC selects the most recent Completed run with the same `OrgId__c` as the current run (handles sandbox refresh - do not compare across orgs). Columns: per-severity count delta and score delta. Null-safe: first scan has no previous - render "No previous scan" placeholder. No new Apex method required.
- **Category Coverage**: "X of 13 categories have findings" + progress bar.

### Dashboard View

**Category Heatmap (13 cells, CSS Grid 4-5 columns):**
- Each cell: SLDS icon + CategoryCode as primary label (UA, GU, SRA, SA, CAI, AA, LA, AGA, MS, FUE, CE, MON, HCB) + count badge + small text status label beneath count (PASS / WARN / FAIL). The text label ensures the cell is readable without color perception (color-vision deficiency accessibility). PASS = 0 findings, WARN = 1-9 findings, FAIL = 10+ findings or any Critical finding present. Full category name rendered as `title` attribute tooltip on hover and as `aria-label` for screen readers. Short codes ensure uniform cell width - long names like "Connected Apps & Integrations" (31 chars) overflow at common grid cell widths.
- Background: 0 findings = green, 1-3 = light amber, 4-9 = medium amber, 10+ = light red
- Critical present = `2px solid var(--color-critical)` border (uses CSS custom property from root)
- Text label always uses `--lwc-colorTextDefault` (dark grey) regardless of cell background color
- Click fires `categoryselect` event

**Below heatmap (2 columns):**
- Recent Findings: 5 most recent Critical/High - clickable to open detail panel
- Scan Statistics: checks run, passed, failed, duration, operator

### Findings Explorer

**Filter Bar:**
- Search box (debounced 300ms) - see text search spec below
- Category dropdown
- Severity 5-button toggle (C/H/M/L/I)
- Type toggle (Automated / Recommendation)
- Status multi-select
- Clear Filters (visible when any filter active)
- Active filter pills row

**Filter change rule:** When any filter value changes (category, severity, status, or search term), the LWC must reset `lastSeenId = null`, `lastRank = null`, and clear `allFindings[]` before calling `getCurrentScanFindings`. The KEYSET cursor values reference a specific finding by rank + ID in the unfiltered result set. Reusing a stale cursor with a different filter set produces skipped records or wrong results (e.g. cursor from finding #200 unfiltered points to a finding that does not exist in the "Guest User" filtered subset).

**Text search spec (Issue 3):** Search runs server-side via dynamic SOQL `LIKE` clause added to `getCurrentScanFindings`. Fields searched: `CheckName__c` (Text 255) and `AffectedComponent__c` (Text 255) only. `Description__c` is excluded from SOQL search - LIKE on a 32KB LongTextArea performs a full table scan even within the ScanRun__c predicate; at 9,000+ findings this is unacceptably slow. Clause: `AND (CheckName__c LIKE :searchPattern OR AffectedComponent__c LIKE :searchPattern)` where `searchPattern = '%' + String.escapeSingleQuotes(term) + '%'`. As a secondary pass, the LWC filters loaded records client-side against `Description__c` for admins who expect description matching. `getCurrentScanFindings` signature gains an optional `String searchTerm` parameter (null = no text filter).

**Findings List:**
- Static sort label above list: "Sorted by severity - Critical first" (no sort control in v1; the KEYSET query enforces `SeverityRank__c ASC, Id ASC`)
- Severity group headers: a thin grey divider with label between severity groups ("Critical - 8 findings", "High - 15 findings", etc.). Template `if:true` checks if the current row's `SeverityRank__c` differs from the previous row and renders the divider. CSS only - no new component or state required. Static labels, not collapsible sections.
- `template:for:each` over `<ul>` with standard scroll (no virtual scroll in v1)
- Paginated: 100 findings per page, "Load More" button at bottom
- Each row: Type icon | Severity badge | Category | Check Name | Affected Component | Status badge | Row action menu (`utility:threedots`). At 1366px viewport with left panel (260px) + Salesforce nav (220px), the findings list has ~886px. Column widths: Type icon 32px, Severity badge 80px, Category 80px, Check Name min 200px (truncate with ellipsis + `title` tooltip on overflow), Affected Component min 200px (same), Status badge 100px, Row action 40px. Total ~732px, leaving ~154px flex buffer. Truncation is required on both text columns - do not wrap, it disrupts row height consistency.
- Automated findings: 3px solid blue left border
- Recommendation findings: 3px solid purple left border + "ACTION REQUIRED" badge when Open
- Row actions: **View Details** and **Acknowledge** execute immediately (safe, non-destructive). **Mark Remediated**, **Mark False Positive**, and **Accept Risk** open the detail panel's Status tab with the target status pre-selected - they do NOT execute in one click. This enforces the note requirement for Risk Accepted/False Positive and prevents accidental score changes from a mis-click.

### Finding Detail Panel

**Decision: Slide-in right panel** (not modal) - keeps list visible for sequential browsing. 45% width. Full-screen on mobile. Panel visibility controlled by CSS class toggle (`slds-hide`) on both the panel and the findings list - never by `if:true/false` conditional rendering. Conditional rendering destroys the DOM and resets browser scroll position; CSS toggle preserves it.

**Accessibility (required for v1):**
- Panel root element: `role="dialog"` + `aria-modal="true"` + `aria-label="Finding Detail"`
- On open: move focus to the Close button (first focusable element in panel)
- Focus trap: Tab and Shift+Tab cycle within the panel while it is open; focus must not reach elements behind the overlay
- Escape key closes panel and returns focus to the finding row that triggered the open
- On close: return focus to the triggering row in the findings list
- Heatmap cells: each clickable `<div>` must have `role="button"` + `tabindex="0"` + `aria-label="[Category]: [N] findings"` (divs are not keyboard-accessible by default)
- Severity badges: `aria-label="Severity: Critical"` on each badge (color + icon alone is insufficient for screen readers)
- Scan progress region: `aria-live="polite"` on the progress container so screen readers announce category completions

**Header:** Close X | Prev/Next navigation "Finding 3 of [TotalFindings__c]" | Check Name | Severity badge | Type pill. The denominator uses `TotalFindings__c` from the parent `SecurityScanRun__c` - not `allFindings[].length`, which changes as the admin loads more pages. When the admin reaches the last loaded finding before all pages are fetched, show "Load more findings to continue" in place of the Next button instead of disabling it silently.

**Tab 1 - Details:**
- Category, Affected Component (linked if navigable via `NavigationMixin`)
- **Risk** section (from `Description__c`): what was detected and why it matters. Shown in full - no truncation. At 45% panel width (~600px on 1440px screen), even 800-char descriptions render as ~10 lines within the scrollable panel. Impact and Remediation have distinct visual containers (amber box, shade box) that clearly delimit the end of Description - no ambiguity without truncation. Add truncation in v2 only if CMT descriptions exceed 2,000 characters.
- **Impact** section (from `Impact__c`): business and security consequences if left unaddressed. Displayed in an amber `slds-box slds-theme_warning` panel so it is visually distinct.
- **How to Fix** section (from `Remediation__c`): step-by-step remediation instructions in `slds-box slds-theme_shade`.
- Amber alert box for Recommendation-type findings ("Manual review required - this check cannot be automated")
- Evidence block (`<pre>` monospace, collapsible) for Automated findings
- Salesforce Doc link (if present): "Official Documentation" button at bottom

**Tab 2 - Status:**
- Status change form showing only valid next-states (state machine enforced - render only allowed transitions as radio buttons, never all 5 values)
- Allowed transitions:
  - Open -> Acknowledged, Remediated, Risk Accepted, False Positive
  - Acknowledged -> Remediated, Risk Accepted, False Positive
  - Remediated -> Open (reopen if fix was reverted)
  - Risk Accepted -> Open (revoke acceptance)
  - False Positive -> Open (reconsider classification)
- Note field (required for Risk Accepted and False Positive - Save button disabled until note is entered for these two transitions)
- **Submit button debounce:** After clicking Save, disable the status form buttons for the duration of the `updateFindingStatus` call + `refreshApex` cycle (typically 1-2 seconds). Without this, rapid Prev/Next + Save clicks produce near-simultaneous Apex calls - each triggers its own `refreshApex` on `getFindingDetail`, causing a flicker storm and potentially hitting the 25 concurrent long-running requests per user limit in some Salesforce editions.
- `AcknowledgedBy__c` and `AcknowledgedDate__c` set on every save where status transitions away from Open. Overwritten on each subsequent change (e.g. Open -> Acknowledged -> Risk Accepted updates both fields each time). Tracks the last admin who acted, not the first. This is intentional - the full change history is available via Salesforce field history tracking. `Status__c`, `AcknowledgedBy__c`, and `AcknowledgedDate__c` must all have field history tracking enabled on `SecurityFinding__c`.

### Scan History View

- List of past `SecurityScanRun__c`: date, operator, finding counts by severity, status
- Production runs show a red "PROD" badge; sandbox runs show a grey "SANDBOX" badge
- Click to view in historical mode (banner warning, status changes disabled)
- Shows "Storing X of [MaxScanRuns__c] max runs. Oldest auto-deleted." (value read from `OrgSecurityScanner_Setting__mdt`)
- Null-safe score rendering: if `Score__c` is null (scan crashed before `finalizeScan()` ran), display "-" for both score and grade. Never display 0 or blank - that implies a scan completed with a zero score, which is misleading. Failed/crashed scans show Status badge "Failed" with no score column values.

### Mobile (Salesforce Mobile App)

- Below 768px: left panel collapses to top horizontal strip
- Below 768px: heatmap shifts to 2-column grid
- Below 768px: finding row shows Type + Severity + Name only
- Below 768px: detail panel = full-screen overlay. Implemented via CSS class toggle (`slds-hide` / remove) on the findings list, NOT `if:true/false` conditional rendering. `if:true/false` destroys and recreates the DOM, resetting native browser scroll position to the top. CSS visibility toggle keeps the list DOM alive and preserves scroll position so the admin returns to finding #85 after closing the overlay, not to finding #1. **Memory note:** when the admin has loaded 5+ pages (500+ findings), keeping all finding rows in the DOM on mobile creates memory pressure. If mobile performance degrades in testing, v2 mitigation: store `window.scrollY` before toggling `if:true/false`, restore it in `renderedCallback` after re-render. This eliminates the large hidden DOM at the cost of a brief scroll-restore flash.
- Below 768px: Add a visible "Back to findings" text link directly below the Close X button in the detail panel. Minimum 44x44px touch target per WCAG 2.1. Sized for thumb tap. Renders in addition to (not replacing) the Close X.
- Below 768px: Device back button support - push a fake history entry (`history.pushState`) when the detail panel opens; listen for `popstate` to trigger the panel close handler. Android back button and iOS swipe-back then close the panel naturally. Swipe-to-dismiss gesture is v2 (complex in LWC shadow DOM). **CSP caveat:** some enterprise Content Security Policies block `history.pushState` calls in Salesforce Lightning. Test in the target org's CSP environment before relying on this pattern. Fallback: the "Back to findings" text link handles the close action in all environments regardless of `pushState` support.
- SLDS responsive grid: `slds-large-size`, `slds-medium-size`, `slds-size` classes

---

## LWC Shared Constants Module

**`secScanConstants` (LWC utility module, no template)** - single source of truth for all string constants used across LWC components. Prevents magic strings scattered across 15 components.

```js
// force-app/main/default/lwc/secScanConstants/secScanConstants.js
export const SEVERITY = { CRITICAL: 'Critical', HIGH: 'High', MEDIUM: 'Medium', LOW: 'Low', INFO: 'Informational' };
export const STATUS   = { OPEN: 'Open', ACKNOWLEDGED: 'Acknowledged', REMEDIATED: 'Remediated', RISK_ACCEPTED: 'Risk Accepted', FALSE_POSITIVE: 'False Positive' };
export const CATEGORY_CODE = { UA: 'UA', GU: 'GU', SRA: 'SRA', SA: 'SA', CAI: 'CAI', AA: 'AA', LA: 'LA', AGA: 'AGA', MS: 'MS', FUE: 'FUE', CE: 'CE', MON: 'MON', HCB: 'HCB' };
export const FINDING_TYPE  = { AUTOMATED: 'Automated', RECOMMENDATION: 'Recommendation' };
export const SCAN_STATUS   = { PENDING: 'Pending', RUNNING: 'Running', COMPLETED: 'Completed', FAILED: 'Failed', CANCELLED: 'Cancelled' };
export const SCORE_GRADE   = [ { min: 90, label: 'A' }, { min: 75, label: 'B' }, { min: 60, label: 'C' }, { min: 45, label: 'D' }, { min: 0, label: 'F' } ];
```

All LWC components import from this module. No picklist value string is ever repeated inline.

---

## LWC Component Architecture (v1 - 16 Components)

```
securityScanner (root - owns all state)
├── securityScannerHeader
│   ├── securityScoreRing           (SVG arc, purely presentational)
│   └── scanRunMetadata             (timestamp, operator, count chips)
├── securityScannerTabs             (Dashboard / Findings / History tabs)
│   ├── securityDashboard
│   │   ├── securityCategoryHeatmap
│   │   │   └── securityCategoryCell (x13)
│   │   └── securityRecentFindings
│   ├── securityFindingsExplorer
│   │   ├── securityFilterBar       (pure input - emits filterchange event, owns no state)
│   │   └── securityFindingsList    (standard scroll, 100/page)
│   └── securityScanHistory
├── securityLeftPanel
│   └── securitySeverityBreakdown   (severity rows + quick stats)
├── securityFindingDetail           (slide-in panel, 2 tabs)
│   └── securityStatusChangeForm
└── securityScanProgress            (shown while scan runs)
```

Deferred to v2: `securityScanComparison`, `securityCategoryDetail`, `securityFindingTimeline`, `securityStatusWorkflow` diagram, `securityBulkActionBar`, virtual scroll, inline row acknowledge expansion, Platform Event subscription.

### State & Data Flow

Root `securityScanner` owns all state: `currentScanId`, `scanStatus`, `activeView`, `selectedFindingId`, `selectedFindingIndex`, `isHistoricalView`, `allFindings[]`, `hasMore`.

`selectedFindingIndex` is the 0-based index of the currently viewed finding within `allFindings[]`. Used by `previousfinding` and `nextfinding` handlers. When `selectedFindingIndex` equals `allFindings[].length - 1` AND `hasMore = true`, the detail panel shows "Load more findings to continue" in place of the Next button - the root passes this computed `isLastLoadedFinding` boolean as a prop to `securityFindingDetail`.

Mutations: child fires event -> root handles -> calls Apex -> updates `allFindings[]` immutably -> all children re-render from props. No child mutates data directly. After status mutations, also calls `getScoreCounts()` to refresh both (1) the live score ring and (2) the Left Panel severity breakdown and Quick Stats - these come from `getScoreCounts()` results after any status change, not from the `SecurityScanRun__c` parent record counts which are set once by `finalizeScan()` and never updated. The parent record counts represent the "at scan completion" snapshot; live counts come from `getScoreCounts()`.

### LWC Events

Two event categories with different propagation rules:

**Cross-branch events (root-bound):** `bubbles: true, composed: true`. Used when a deeply nested component (e.g. `securityFindingsList`, 4 levels deep) needs to reach the root `securityScanner`. In LWC, each component has its own shadow root - `composed: true` is required to pierce each shadow boundary. Without it, the event stops at the nearest boundary. This is Salesforce's documented behavior.

**Direct parent-child events:** `bubbles: false, composed: false`. Used when a component only needs its immediate parent to respond (e.g. `securityStatusChangeForm` -> `securityFindingDetail`). Adding `composed: true` to these unnecessarily widens the API surface and creates DOM coupling - if the tree structure changes, root listeners may receive events they should not.

**v2:** Migrate cross-branch events to Lightning Message Service (LMS) via `@salesforce/messageChannel`. LMS decouples sender and receiver entirely - no DOM traversal dependency.

Root calls `event.stopPropagation()` on all handled cross-branch events.

| Event | Fired By | Payload |
|---|---|---|
| `runscan` | securityScannerHeader | none |
| `filterchange` | securityFilterBar | `{ filters }` |
| `findingselect` | securityFindingsList | `{ findingId }` |
| `categoryselect` | securityCategoryHeatmap | `{ categoryName }` |
| `severityfilterselect` | securitySeverityBreakdown | `{ severity }` |
| `statuschange` | securityFindingDetail | `{ findingId, newStatus, note }` |
| `closedetail` | securityFindingDetail | none |
| `previousfinding` / `nextfinding` | securityFindingDetail | none |
| `viewhistoricalscan` | securityScanHistory | `{ scanRunId }` |
| `returntocurrentscan` | securityLeftPanel | none |

### Wire vs Imperative

**`@wire` (cacheable=true only):** `getScanRuns` (reactive, refreshApex() after runSecurityScan), `getFindingDetail` (reactive to `selectedFindingId`, refreshApex() after updateFindingStatus), `getOrgSecuritySettings` (static config), `getOrgInfo` (static org info)

**Imperative:** `getCurrentScanFindings` (paginated with complex lastSeenId/lastRank state - @wire cannot manage "load more" accumulation), `getScoreCounts` (called after every status mutation - drives both live score ring AND Left Panel severity counts), `runSecurityScan`, `getScanRunStatus` (polled), `updateFindingStatus`, `bulkUpdateFindingStatus`, `cancelScan`, `exportFindingsCsv`

**Rule:** All `@wire` methods must be `cacheable=true`. Use `refreshApex()` after mutations to clear LDS cache. Non-cacheable methods must be called imperatively - `@wire` on a non-cacheable method is a platform error. The stale-cache concern for `getScanRuns` and `getFindingDetail` is resolved by explicit `refreshApex()` calls after mutations, not by avoiding cache.

**`refreshApex()` success guard:** Only call `refreshApex()` when `SecScanApiResponse.success === true`. If `runSecurityScan()` fails (concurrency guard, permission error, etc.), do NOT call `refreshApex()` on `getScanRuns` - a failed scan should not trigger a list refresh that might display stale or confusing intermediate state. LWC error handler: check `response.success` first; on false, display `response.errorMessage` as an error toast without refreshing any wire.

**Post-scan completion sequence (when polling detects `Status = 'Completed'` or `'Failed'` or `'Cancelled'`):**
1. `clearInterval(this._pollInterval)` - stop polling immediately.
2. `refreshApex(this._scanRunsWire)` - adds the completed run to history list and updates header chips.
3. Call `getScoreCounts(this.currentScanId)` imperatively - updates live score ring and Left Panel severity counts.
4. Call `getCurrentScanFindings` imperatively (first page, null cursor) - auto-loads findings into Findings Explorer.
5. Switch `activeView` to `'dashboard'` if currently on the scan progress view.
6. Show toast: "Scan complete - [N] findings detected." For `Failed`: amber toast "Scan failed - [N] categories could not complete." For `Cancelled`: amber toast "Scan cancelled after [N] categories."
7. Start 5-minute cooldown timer.
On `Failed` or `Cancelled`: same sequence except step 4 only runs if `TotalFindings__c > 0`.

**`disconnectedCallback` (required - prevents memory leak and ghost Apex calls):**
`securityScanner` root must implement `disconnectedCallback()` to clean up:
```js
disconnectedCallback() {
    if (this._pollInterval) {
        clearInterval(this._pollInterval);
        this._pollInterval = undefined;
    }
}
```
Without this, navigating away from the app while a scan is running leaves the `setInterval` firing against a destroyed component, making repeated `getScanRunStatus` Apex calls indefinitely.

**SVG score ring implementation note:** `securityScoreRing` uses SVG `stroke-dasharray` / `stroke-dashoffset` for the arc animation - not a canvas element. Canvas is not supported in LWC shadow DOM without workarounds. Test score ring at score=0 (full empty arc) and score=100 (full filled arc) - edge cases can produce NaN dashoffset or invisible arcs if the math is not null-safe.

**ContentDocumentId -> download URL:** `exportFindingsCsv` returns a `ContentDocumentId` in `SecScanApiResponse.data`. The LWC constructs the download URL as:
```js
const downloadUrl = `/sfc/servlet.shepherd/document/download/${contentDocumentId}?operationContext=S1`;
```
The `operationContext=S1` parameter ensures the correct content-disposition headers for a file download. The LWC renders this as an `<a href={downloadUrl} target="_blank">` inside the success toast - admins click it to download. Do NOT use `NavigationMixin` for file downloads - it does not support binary content disposition.

### Apex Controller Methods

**@AuraEnabled rule:** Every method called by LWC must be annotated `@AuraEnabled(cacheable=true)` or `@AuraEnabled(cacheable=false)`. Never omit the annotation and never omit the `cacheable` parameter - the default (`cacheable=false`) is implicit but must be explicit for readability. **Critical:** `cacheable=true` methods cannot perform DML. If DML is added to a cacheable method, Salesforce throws at runtime (not compile time). Only read-only methods are ever marked cacheable.

**Cacheable rule:** Methods that return org configuration or static data = `cacheable=true`. Methods that return live scan/finding state = `cacheable=true` only when used with `@wire` AND `refreshApex()` is called after every mutation that affects the result. Without explicit `refreshApex()`, do not use `cacheable=true` on live-state methods - stale LDS cache causes stale UI that is hard to reproduce. Imperative calls are always `cacheable=false`.

**`SecScanController`:**
- `runSecurityScan()` - NOT cacheable (mutation). Validates PS, concurrency guard, checks sysadmin flag, reads `Organization.IsSandbox`, captures `sessionId`, enqueues orchestrator. Sets `IsProductionScan__c = true` on the new run if `IsSandbox = false`. Returns `SecScanApiResponse<Id>`.
- `getOrgInfo()` - **cacheable=true**. Returns `{ isSandbox: Boolean, orgId: String, orgName: String }`. Org type does not change mid-session. Called on LWC init to drive production warning modal and persistent banner.
- `getScanRuns()` - **cacheable=true**. Returns list of `SecurityScanRun__c` with counts. Used with `@wire`. Stale-cache concern is resolved by explicit `refreshApex()` after `runSecurityScan` - do not mark non-cacheable to work around this, as `@wire` requires `cacheable=true`.
- `getOrgSecuritySettings()` - **cacheable=true**. Returns `OrgSecurityScanner_Setting__mdt.getInstance('Default')` field values as `OrgSecuritySettingsDTO` (typed inner class). CMT values do not change during a session.
- `getScanRunStatus(String scanRunId)` - **NOT cacheable** (polled). Returns `{ status, failedCategories, completedCategories, isPartialScan }`. `SecScanApiResponse`. `completedCategories` is the value of `CompletedCategories__c` - used by the scan progress view to tick completed categories in the 13-item checklist.
- `cancelScan(String scanRunId)` - NOT cacheable (mutation). Before updating, queries current `Status__c`. If already in a terminal state (`Completed`, `Failed`, `Cancelled`), returns `SecScanApiResponse` with `errorMessage = 'Scan has already completed and cannot be cancelled.'` - no DML performed. If status is `Pending` or `Running`, sets `Status__c = 'Cancelled'`. The running Queueable chain cannot be aborted externally - each `SecScanRunnerChain.execute()` checks `Status__c` at the start of its transaction; if Cancelled, it skips the current category and does not enqueue the next link. The scan halts at the next category boundary, not immediately.
- `exportFindingsCsv(String scanRunId)` - NOT cacheable (mutation). Generates CSV from findings. Creates `ContentVersion` with the CSV body. Creates `ContentDocumentLink` with `ShareType = 'I'` (Inferred from parent) and `Visibility = 'InternalUsers'`. Returns `ContentDocumentId`. Never returns raw String. CSV columns (in order): `CheckId`, `CheckName`, `Category`, `Severity`, `FindingType`, `Status`, `AffectedComponent`, `AffectedComponentType`, `Description`, `Impact`, `Remediation`, `AcknowledgedBy` (user name, not ID), `AcknowledgedDate`, `SalesforceDocUrl`. Header row uses field labels. `RawEvidence__c` excluded (too large, scrubbed - admins use the detail panel for evidence). CSV encoding: RFC 4180 compliant - fields containing commas, double quotes, or newlines are enclosed in double quotes; double quotes within field values are escaped as two consecutive double quotes (`""`). `Description__c`, `Impact__c`, and `Remediation__c` will contain commas and newlines - naive comma-joining corrupts the file. **Size guard - pre-emptive, not post-build:** The synchronous Apex heap limit is 6MB. Building a large CSV string and then checking its length is too late - the heap already crashed. Guard must run BEFORE building: count findings via `SELECT COUNT()`. If count > 3000 (conservative threshold - 3000 x ~2KB average = ~6MB), truncate `Description__c`, `Impact__c`, and `Remediation__c` to 500 chars each for all findings before building any string. Append `[truncated - see detail panel for full text]` to each truncated field. Document this in the ContentVersion `Description` field: "Text columns truncated - finding count exceeded safe export threshold." At typical v1 volumes (under 1,000 findings) this guard will never fire.

**`SecScanFindingsController`:**
- `getCurrentScanFindings(String scanRunId, String lastSeenId, Integer lastRank, Integer pageSize, String searchTerm)` - **NOT cacheable**. KEYSET paginated (default 100), severity-first composite sort. Both `lastSeenId` and `lastRank` = null for first page. `searchTerm` = null for no text filter. Returns `SecScanApiResponse<FindingsPageDTO>` where `FindingsPageDTO` has `List<SecurityFinding__c> findings`, `Boolean hasMore`, `String lastSeenId`, `Integer lastRank`.
- `getScoreCounts(String scanRunId)` - **NOT cacheable**. Returns `{ criticalOpen, highOpen, mediumOpen, lowOpen, infoOpen }` - live counts of findings where `Status__c NOT IN ('Remediated','False Positive')`. Called after every `updateFindingStatus` / `bulkUpdateFindingStatus` so the LWC can recalculate the live score from server-side counts rather than from the partial in-memory `allFindings[]`. Without this, paginated findings cause a wrong live score (score computed from 100 loaded findings, not the actual 400).
- `getFindingDetail(String findingId)` - **cacheable=true**. Single finding all fields. Used with `@wire` (reactive to `selectedFindingId`). `refreshApex()` called after `updateFindingStatus` handles staleness. Must not be marked non-cacheable - `@wire` requires `cacheable=true`.
- `updateFindingStatus(String findingId, String status, String note)` - NOT cacheable (mutation). Server-side validates the status transition using a static final Map. The transition map is hardcoded (not CMT-driven) - status transitions are a security boundary and must be immutable and auditable:
  ```apex
  private static final Map<String, Set<String>> ALLOWED_TRANSITIONS = new Map<String, Set<String>>{
      'Open'          => new Set<String>{'Acknowledged','Remediated','Risk Accepted','False Positive'},
      'Acknowledged'  => new Set<String>{'Remediated','Risk Accepted','False Positive'},
      'Remediated'    => new Set<String>{'Open'},
      'Risk Accepted' => new Set<String>{'Open'},
      'False Positive'=> new Set<String>{'Open'}
  };
  ```
  If invalid: return `SecScanApiResponse` with `errorMessage = 'Invalid status transition from [current] to [requested]'` - do not throw, return typed error so the LWC can display it non-destructively. LWC must handle `success=false` and show the error message inline without resetting the status form. Returns updated record on success.
- `bulkUpdateFindingStatus(List<String> findingIds, String status, String note)` - NOT cacheable (mutation). Cap: throws `SecScanException` if `findingIds.size() > 5000`. Returns count. (200 was wrong - that is the trigger chunk size, not the DML row limit. Salesforce synchronous DML supports up to 10,000 rows. 5,000 is a practical LWC payload ceiling to avoid HTTP timeout on very large selections.)

---

## Maintainability Patterns

### How to Add a New Check (within an existing category)

1. Add a `SecurityCheckDef__mdt` record: set `CheckId__c`, `CheckName__c`, `Category__c`, `CategoryCode__c`, `Severity__c`, `FindingType__c`, `Description__c`, `Impact__c`, `Remediation__c`, `SalesforceDocUrl__c`, `IsActive__c = true`.
2. Add a private detection method to the corresponding `SecScanRunner*.cls`.
3. Call `buildFinding()` with the result and add to the findings list.
4. Add a test case in the runner's test class using `SecScanTestDataFactory`.
5. Deploy. No other files change.

### How to Add a New Category (v1 - requires code change)

1. Create `SecScanRunner[Name].cls` extending `SecScanCategoryRunner`.
2. Add `SecurityCheckDef__mdt` records for all checks in the new category.
3. Add the new class name to the runner list in `SecScanRunnerChain`.
4. Add the category code to `CATEGORY_CODE` in `secScanConstants.js`.
5. Add the category picklist value to `SecurityFinding__c.Category__c`.
6. Add a test class.
7. Known improvement (v2): externalize runner class list to `SecurityCheckDef__mdt` so step 3 becomes a metadata deploy only.

### How to Disable a Check Without a Deploy

Set `SecurityCheckDef__mdt.IsActive__c = false` on the target record via Setup > Custom Metadata Types. No code change, no deploy required. The runner queries `WHERE IsActive__c = true` on startup.

### How to Tune Score Sensitivity

Edit the `Default` record of `OrgSecurityScanner_Setting__mdt` in Setup > Custom Metadata Types. Change deduction weights or caps. No code deploy required - changes take effect on next scan.

### Known Coupling Points (v1 accepted limitations)

| Coupling | Impact | v2 Fix |
|---|---|---|
| Runner class names hardcoded in `SecScanRunnerChain` | Adding a category requires code deploy | Store runner class name in `SecurityCheckDef__mdt.RunnerClass__c` |
| 13 separate runner classes | New category = new class + chain update | Metadata-driven generic runner reads checks from `__mdt` |
| Polling interval constants in LWC | Changing polling behavior requires code deploy | Move to `OrgSecurityScanner_Setting__mdt` |
| `Test.isRunningTest()` removed from production code | Replaced with `@TestVisible Boolean chainEnabled` flag. Tests set `chainEnabled = false` before calling `execute()`. Eliminates test-production code divergence. | No v2 fix needed - already resolved in v1. |
| `SeverityRank__c` as physical field | `buildFinding()` stamps a physical `Number(1,0) SeverityRank__c` field based on the severity string. The formula field approach was replaced in v1: formula fields cannot be custom-indexed; ORDER BY on an unindexed formula against 9,000+ findings per run degrades sort performance. Physical field can receive a custom index and is set once at insert time by `buildFinding()` - no formula computation at query time. The explicit mapping in `buildFinding()`: Critical=1, High=2, Medium=3, Low=4, Informational=5. No formula field needed. |

---

## Deployment Sequence

| Phase | Components | Reason |
|---|---|---|
| 1 - Data Model | `SecurityCheckDef__mdt` (type + 76 records), `OrgSecurityScanner_Setting__mdt` (type + Default record), `SecurityScanRun__c` (+ all fields), `SecurityFinding__c` (+ all fields) | Apex classes reference these - must exist first |
| 2 - Apex Foundation | `SecScanException`, `SecScanSessionExpiredException`, `SecScanApiResponse`, `SecScanEvidenceUtil`, `SecScanFindingDTO`, `SecScanToolingService`, `SecScanMetadataService`, `SecScanCategoryRunner` | All runners extend/use these |
| 3 - Apex Orchestration | `SecScanRunnerChain`, `SecScanRunnerContinuation`, `SecScanOrchestrator`, `SecScanRetentionBatch`, `SecScanOrphanCleanupSchedulable`, `SecScanPostInstallHandler`, `SecScanPostUninstallHandler` | Must deploy together in one unit before runners. `SecScanRunnerChain` calls `SecScanOrchestrator.finalizeScan()` and `SecScanOrchestrator.startScan()` calls `SecScanRunnerChain` - mutual reference, safe when deployed together. `SecScanRunnerContinuation` calls `new SecScanRunnerChain(...)` - all in same unit. AA/LA runners call `new SecScanRunnerContinuation(...)` at compile time - this class must exist before runners deploy. Deploying Chain and Continuation in Phase 4 (after runners) causes a compile error in Phase 3 runners. Post-install/uninstall handlers reference `SecScanOrphanCleanupSchedulable` - same unit. |
| 4 - Apex Runners | All 13 `SecScanRunner*.cls` | Extend `SecScanCategoryRunner` (Phase 2). AA/LA runners call `new SecScanRunnerContinuation(...)` (Phase 3 - exists). All compile-time dependencies satisfied. |
| 5 - Apex Controllers | `SecScanController`, `SecScanFindingsController` | Reference all objects and orchestrator |
| 6 - Apex Tests | All `*Test.cls` + `SecScanOrphanCleanupSchedulableTest` | Reference everything above |
| 7 - Config | `OrgSecurityScanner_Admin` Permission Set, `OrgSecurityScanner` Tab | Reference objects |
| 8 - LWC Leaves | `securityScoreRing`, `scanRunMetadata`, `securityCategoryCell`, `securitySeverityBreakdown`, `securityStatusChangeForm`, `securityScanProgress` | No child LWC dependencies |
| 9 - LWC Mid | `securityCategoryHeatmap`, `securityRecentFindings`, `securityFindingsList`, `securityFindingDetail`, `securityLeftPanel`, `securityFilterBar` | Use leaf components |
| 10 - LWC Top | `securityDashboard`, `securityFindingsExplorer`, `securityScanHistory`, `securityScannerHeader` | Use mid components |
| 11 - LWC Root | `securityScanner`, `securityScannerTabs` | Orchestrates everything |
| 12 - App Shell | `OrgSecurityScannerApp_Page` Flexipage, `OrgSecurityScannerApp` Lightning App | References LWC and tab |

---

## Package Configuration

**Type:** Unlocked Package (no namespace). Installable via URL. CMT records, Permission Set, and all metadata deploy with the package. Subscriber org data (`SecurityScanRun__c`, `SecurityFinding__c` records) is preserved on upgrade.

### `sfdx-project.json`

```json
{
  "packageDirectories": [
    {
      "path": "force-app",
      "default": true,
      "package": "OrgSecurityScanner",
      "versionName": "v1.0",
      "versionNumber": "1.0.0.NEXT",
      "definitionFile": "config/project-scratch-def.json"
    }
  ],
  "name": "OrgSecurityScanner",
  "namespace": "",
  "sourceApiVersion": "66.0",
  "packageAliases": {}
}
```

`packageAliases` is populated by `sf package create` and `sf package version create` - commit the updated `sfdx-project.json` after each command.

### `config/project-scratch-def.json`

```json
{
  "orgName": "Org Security Scanner Dev",
  "edition": "Developer",
  "features": ["EnableSetPasswordInApi", "Agentforce"],
  "settings": {
    "securitySettings": {
      "sessionSettings": {
        "sessionTimeout": "TwentyFourHours"
      }
    },
    "lightningExperienceSettings": {
      "enableLightningExperience": true
    }
  }
}
```

**Feature notes:**
- `Agentforce` - required for the AGA runner tests (`GenAiFunctionDefinition` Tooling API objects do not exist without this feature)
- `EnableSetPasswordInApi` - required to set passwords on test users programmatically in Apex tests
- `sessionTimeout: TwentyFourHours` - prevents session expiry during long test runs
- Tooling API and `ContentVersion`/`ContentDocumentLink` are available in all Developer Edition scratch orgs by default - no feature flag needed

### Package Lifecycle Commands

```bash
# 1. Create the package (one-time)
sf package create --name "OrgSecurityScanner" --package-type Unlocked --path force-app --target-dev-hub <DevHub>

# 2. Create a new version
sf package version create --package "OrgSecurityScanner" --installation-key-bypass --wait 20 --target-dev-hub <DevHub>

# 3. Promote to released (required before installing in production)
sf package version promote --package "OrgSecurityScanner@1.0.0-1" --target-dev-hub <DevHub>

# 4. Install in a target org
sf package install --package "OrgSecurityScanner@1.0.0-1" --target-org <alias> --wait 10
```

### Post-Install Behavior
`SecScanPostInstallHandler` runs automatically after `sf package install`. It schedules the nightly cleanup job - no manual Execute Anonymous step required. On upgrade, it aborts the existing scheduled job and reschedules to prevent duplicates.

**Silent failure gap:** `InstallHandler` cannot throw - a thrown exception rolls back the entire package install. If the scheduler call fails (e.g., Schedulable limit already hit, or an unexpected error), the failure is silent and the admin has no feedback. **Mitigation:** the app's Settings/Status panel (accessible from the app header "Settings" icon or a dedicated tab) shows a "Scheduled Job Status" indicator. On load, it queries `[SELECT Id, State FROM CronTrigger WHERE CronJobDetail.Name = 'SecScan Nightly Cleanup' LIMIT 1]`. If no result: shows "Nightly cleanup job not scheduled - orphaned runs will accumulate. Contact your admin or run the manual schedule command." If found: shows "Active" with next fire time. Admin can see this without navigating to Setup > Scheduled Jobs.

**CI/CD deployment note:** The 12-phase manual deployment sequence documents compile-time dependencies for partial or manual deploys. In a CI/CD pipeline that runs `sf project deploy start` against the full `force-app/` directory, Salesforce compiles all classes in a single transaction - mutual references between `SecScanRunnerChain` and `SecScanOrchestrator` are resolved automatically. The phased sequence is the correct order for manual phased deploys, not a constraint on automated full-project deploys.

### Uninstall Behavior
`SecScanPostUninstallHandler` aborts the scheduled job before package removal. `SecurityScanRun__c` and `SecurityFinding__c` data is deleted when the objects are removed (subscriber must export first if needed).

---

## GitHub & CLAUDE.md

**GitHub push (execution phase):**
1. Clone `energidi/claude-knowledge-base` to `C:/Users/GidiAbramovich/AppData/Local/Temp/claude-kb-deploy`
2. Copy `force-app/` into `projects/org-security-scanner/`
3. Create `projects/org-security-scanner/CLAUDE.md`
4. Stage, commit, push

**CLAUDE.md contents:** App name, tech stack (SFDX v66.0, Apex + LWC + SLDS), sandbox and production support, no external callouts, class prefix `SecScan`, LWC prefix `security`, deployment order constraint, 76 checks across 13 categories.

---

## Error States and Admin Messaging

When something fails, the admin needs to know what happened and what to do next - not just that something went wrong.

| Error Condition | Root Cause | Admin-Visible Message | Recovery Action |
|---|---|---|---|
| Session expired mid-chain | Short org session timeout; 13 Queueables can take 5-15 min. Lightning session tokens default to 2h but org policy can set as low as 15 min. Also fires in hardened orgs (IP locking, HttpOnly) where Lightning tokens are rejected by Tooling API. | Banner: "Scan failed - session expired. Re-run the scan. If this recurs, your org's session timeout may be shorter than the scan duration, or your org's security settings restrict Tooling API access from Lightning sessions. Increase session timeout or use Named Credential configuration (v2) to eliminate this dependency." `FailedCategories__c` shows which categories failed. | Re-run scan. For persistent failures in production: Named Credential (v2) is required. |
| Scan already running | Concurrency guard fired (FOR UPDATE hit an existing Pending/Running run) | Toast error: "A scan is already in progress. Wait for it to complete or cancel it first." | Wait or click Cancel. |
| Runner category failed | Apex exception in one runner (not session expiry) | Warning banner: "Categories failed to scan: AA, GU. Results may be incomplete." `ErrorDetails__c` shows stack trace. | Re-run scan. If persistent, check `ErrorDetails__c` for root cause. |
| Scan cancelled mid-run | Admin clicked Cancel; chain halts at next category boundary | Banner: "Scan cancelled. Findings from completed categories are saved." | Re-run to get full results. |
| Partial scan (no ModifyAllData) | Running user lacks full metadata visibility | Warning banner: "Running as a user without full metadata visibility - some results may be incomplete." | Re-run as System Administrator for full coverage. |
| Production org warning | `Organization.IsSandbox = false` | Red persistent banner: "PRODUCTION ORG - scanning read-only but surface results may contain sensitive configuration details." | Admin acknowledged via confirmation modal before scan started. |
| No scan run yet | First install, no scans run | Empty state: "No scans yet. Click Run Security Check to get started." CTA button. | Click Run Security Check. |
| Heap overflow in AA/LA | Large org with 1,000+ Apex classes | No admin-visible error - continuation Queueable resumes transparently. If continuation also overflows, runner logs partial-category warning. | Visible only if both the runner and continuation exceed heap. Rare in practice. |
| SOAP Metadata API failure (FUE/HCB) | SOAP fault or malformed XML response | Category appears in `FailedCategories__c`. `ErrorDetails__c` includes SOAP faultcode + faultstring. | Check Setup for the specific settings manually. |
| ContentDocumentLink creation fails on export | Insufficient sharing on run record | Toast error: "Export failed - could not attach file to scan run. Contact your admin." | Check that running user has Edit on SecurityScanRun__c via Permission Set. |
| Bulk status update exceeds 5,000 findings | Admin selects an unusually large set in one operation | Toast error: "Bulk update is limited to 5,000 findings at a time. Select fewer findings and try again." | Select 5,000 or fewer findings and retry. |
| `getScoreCounts()` failure | QueryException or unexpected error in counts query | Display stored `Score__c` and `Grade__c` from the run record as fallback. Append a non-blocking note near the score ring: "Live score unavailable - showing score at scan completion." Do not block the UI. | Refresh the page to retry. If persistent, check `SecurityFinding__c` field access on the Permission Set. |
| `getOrgInfo()` failure | QueryException or permission issue on LWC init | Toast warning: "Unable to determine org type. Proceed with caution." Treat as production: show the red persistent banner as the safe default. Do not silently assume sandbox - missing the production warning is a worse outcome than a false positive warning. | Refresh the page. If persistent, verify the running user has Read on `Organization` (standard object, always accessible to authenticated users - persistent failure indicates an unusual org restriction). |

**UI principle:** Every error state shows (1) what happened, (2) which categories are affected if applicable, (3) what the admin should do next. Generic "An error occurred" messages are not acceptable.

---

## Verification Plan

### Positive Tests
| Step | Expected |
|---|---|
| Deploy Phases 1-2 | `sf project deploy start` compiles with zero errors |
| Run `SecScanOrchestratorTest` | `SecurityScanRun__c` created, transitions Pending -> Running -> Completed, `TotalChecksRun__c` = 76 |
| Run all 13 runner tests | Each inserts >= 1 `SecurityFinding__c` with correct `CheckId__c`, `Category__c`, `Severity__c`, non-blank `Description__c` and `Remediation__c` |
| Trigger full scan via UI | All 13 category codes appear in findings, heatmap renders 13 cells |
| Production scan | Mock `Organization.IsSandbox = false`; `IsProductionScan__c = true` on run, red "PROD" badge visible in history, production warning modal shown before scan starts |
| `getOrgInfo()` sandbox | Mock `Organization.IsSandbox = true`; verify `isSandbox = true` returned, no production banner shown |
| `getOrgInfo()` production | Mock `Organization.IsSandbox = false`; verify `isSandbox = false` returned, persistent red banner shown, confirmation modal uses production variant |
| Acknowledge finding | `Status__c` = Acknowledged, `AcknowledgedBy__c` and `AcknowledgedDate__c` set |
| Export findings | `ContentVersion` record created, linked to `SecurityScanRun__c`, CSV readable |
| Paginated fetch (KEYSET) | `getCurrentScanFindings(runId, null, null, 10, null)` returns 10 rows ordered by `SeverityRank__c ASC, Id ASC` and `hasMore=true`; second call passing `lastSeenId` and `lastRank` from previous page returns next 10 rows; final page returns `hasMore=false`. Verify Critical findings appear before Informational findings across pages. |
| `getScoreCounts()` after status change | Mark 1 Critical finding as Remediated. Call `getScoreCounts(runId)`. Verify `criticalOpen` = original Critical count - 1. Mark as False Positive instead - verify same result. Mark as Acknowledged - verify `criticalOpen` unchanged (Acknowledged is not excluded from score). |
| `getScoreCounts()` after bulk status change | Create 10 findings (5 Critical, 5 High). Bulk-update all 10 to Remediated via `bulkUpdateFindingStatus`. Call `getScoreCounts(runId)`. Verify `criticalOpen` = originalCritical - 5, `highOpen` = originalHigh - 5. Validates aggregate counts are correct after bulk DML, including partial-failure edge case if FLS drops some records. |

### Negative Tests
| Step | Expected |
|---|---|
| Run scan without Permission Set | `SecScanException` thrown before enqueue |
| Runner throws exception | `FailedCategories__c` populated, remaining chain continues |
| Category hits 9,000 cap | Synthetic cap-finding inserted, no governor exception |
| Non-sysadmin runs scan | `IsPartialScan__c = true`, UI warning banner displayed |
| Production scan with `AllowProductionScan__c = false` (default) | `SecScanException('Production scanning is disabled...')` thrown before enqueue regardless of LWC modal state |
| Production scan with `AllowProductionScan__c = true` | Scan proceeds, `IsProductionScan__c = true` set on run record |
| Invalid status transition via API | Call `updateFindingStatus` with `Remediated -> Acknowledged` (not in allowed map). Verify: returns `SecScanApiResponse.success = false`, `errorMessage = 'Invalid status transition from Remediated to Acknowledged'`, no DML performed. |
| Bulk update exceeds 5,000 | Pass `findingIds` with 5,001 entries to `bulkUpdateFindingStatus`. Verify `SecScanException` thrown with "Bulk update is limited to 5,000 findings at a time." |
| `searchTerm` exceeds 100 chars | Pass 150-char search term to `getCurrentScanFindings`. Verify term is silently capped to 100 chars before processing - no error thrown, results match truncated pattern. |
| `buildFinding()` called with blank `Severity__c` | Verify `buildFinding()` sets `Severity__c = 'Low'` and insert succeeds without picklist validation error. |
| `buildFinding()` called with blank `FindingType__c` | Verify `buildFinding()` sets `FindingType__c = 'Automated'`. |
| `cancelScan()` on already-Completed scan | Call `cancelScan()` on a run with `Status__c = 'Completed'`. Verify: returns `success = false`, `errorMessage` contains "already completed", no DML performed, run remains `Completed`. |
| `cancelScan()` on Pending/Running scan | Verify `Status__c` transitions to `Cancelled` successfully. |
| `finalizeScan()` with disabled checks | Set 3 `SecurityCheckDef__mdt` records to `IsActive__c = false`. Run scan. Verify `TotalChecksRun__c = 73` (not 76). |
| `finalizeScan()` with 0 findings | Run scan that produces 0 findings. Verify `Score__c = 100`, `Grade__c = 'A'`, `TotalFindings__c = 0`. |
| `finalizeScan()` status guard on Cancelled run | Set `Status__c = 'Cancelled'` before calling `finalizeScan()`. Verify status remains `Cancelled` after finalizeScan - NOT overwritten to `Completed`. |
| `ErrorDetails__c` overflow protection | Simulate 6 runner failures each with a 6,000-char stack trace. Verify `ErrorDetails__c` does not exceed 32,768 chars and ends with truncation marker. |
| `disconnectedCallback` polling cleanup | Mount the component, trigger a scan (starts polling). Unmount the component. Verify no further `getScanRunStatus` Apex calls are made after unmount. |

### Async Chain Tests
| Step | Expected |
|---|---|
| All 13 jobs complete | 13 `AsyncApexJob` records show Completed status |
| Final job | Sets `Status__c = Completed` and `CompletedAt__c` |
| Error in middle category | Chain continues, failed code in `FailedCategories__c` |
| Cancel scan mid-chain | Set `Status__c = 'Cancelled'` after 3 categories complete. Verify: chain halts at next execute(), `finalizeScan()` called, `Score__c` reflects only completed categories (not null, not zero), `FailedCategories__c` is empty (no errors - clean stop), `Status__c` remains `Cancelled` (finalizeScan must not overwrite to Completed on a Cancelled run). |

### Scale Tests
| Step | Expected |
|---|---|
| Org with 200+ Apex classes | `SecScanRunnerApexAutomation` completes without heap exception. Assert: number of `AsyncApexJob` records for AA = 1 + N continuations. Assert: `CompletedCategories__c` includes AA after all continuations complete. Assert: total finding count for AA equals findings across all pages (no truncation). |
| 500+ findings | Paginated load works, UI loads page by page |
| 6th scan triggered | 5-run retention policy deletes oldest run before new run created |

### Security Tests
| Step | Expected |
|---|---|
| Debug logs after scan | Zero `setEndpoint()` calls to external URLs |
| `RawEvidence__c` scrub-then-truncate | In `SecScanRunnerApexAutomation` test: create a mock Apex class body containing a known credential pattern (e.g. `password=SuperSecret123`) at position 9,500 in a 15,000-char body. Run runner. Assert: `RawEvidence__c` for that finding does not contain `SuperSecret123` (scrubbed), is <= 10,000 chars (truncated), and the credential at position 9,500 was scrubbed (proving scrub ran before truncation, not after). |
| `RawEvidence__c` content | No raw Apex source stored - `SecScanEvidenceUtil` truncation confirmed |
| Non-sysadmin scan | `IsPartialScan__c = true`, warning shown |
| Tooling API failure simulation | Runner logs error, chain continues, category in `FailedCategories__c` |
| LWC event propagation | `findingselect` from `securityFindingsList` (4 levels deep) reaches root `securityScanner` |
| `WITH USER_MODE` access failure | Remove `SecurityFinding__c` Read from PS mid-test; `getCurrentScanFindings` returns `isPartialData: true` and does not throw |
| Invalid session handling | Simulate Tooling API 401 response; runner logs error, appends category to `FailedCategories__c`, chain continues |
| Partial-scan path | Run scan as non-sysadmin profile user; `IsPartialScan__c = true`, warning banner visible in UI |
| Builder bypass prevention | Attempt to insert `SecurityFinding__c` inline (not via `buildFinding()`) in a runner test; `SecScanCategoryRunnerTest` assertion fails, confirming the contract is enforced |

---

## Threat Model & Security Classification

This section must be included in the admin guide distributed with the app.

### What This App Produces

Scan results (`SecurityFinding__c` records) are security reconnaissance data. A finding showing "Profile: System Administrator has Modify All Data + API Enabled + no MFA" is exactly the data an insider threat or a compromised admin account would want. Treat scan results with the same sensitivity as penetration test reports.

### Who Should Have the Permission Set

`OrgSecurityScanner_Admin` should be assigned to security administrators only - not all sysadmins, not helpdesk admins, not developers. If a developer needs to review findings, export a CSV and share via a secure channel rather than granting PS access.

### What a Compromised OrgSecurityScanner_Admin Exposes

A compromised admin account with this PS gives an attacker: a complete list of every security vulnerability in the org, with affected component names (profile names, user names, class names), remediation steps, and historical trend data. Restrict PS assignment accordingly.

### Scan History Classification

Historical scan runs should be classified as confidential security documentation. CSV exports should follow the org's document classification policy. Exports contain user names and component names that may be personally identifiable under GDPR for EU users - apply appropriate handling.

### Recommended Nightly Job Setup

The nightly cleanup job (`SecScan Nightly Cleanup`) runs as the user who installed the package (the installing admin). If that account is deactivated, the job silently fails and orphaned runs accumulate. Recommended practice: after installation, create a dedicated integration user (`orgsecscanner@yourorg.com`) with only the `OrgSecurityScanner_Admin` PS, verify the scheduled job exists in Setup > Scheduled Jobs, and if needed re-schedule using that user's context via Execute Anonymous.

---

## Appendix: AI & Data Cloud Readiness

### v1 Scope
The AGA runner (`SecScanRunnerAgentforce`) reads Agentforce configuration metadata (GenAiFunctionDefinition, GenAiPlanner, etc.) to detect security misconfigurations. It does NOT call any LLM API or interact with the Einstein Trust Layer itself. The app has no Agentforce agent of its own.

### Einstein Trust Layer - v2 Consideration
If a future version exposes scan findings to an Agentforce agent (e.g., "explain this finding" or "suggest remediation"), the following applies:
- `RawEvidence__c` may contain configuration data (profile names, class names, setting values). It must be masked in the Trust Layer context before being sent to an LLM.
- `SecScanEvidenceUtil` already regex-scrubs secrets from `RawEvidence__c` at write time. In a v2 Agentforce integration, a second scrub pass should run before injecting evidence into any prompt context.
- Topic and Action limits (Salesforce recommends max 15 topics / 15 actions per agent) do not apply to v1.

### Data Quality for AI
Finding text (Description, Impact, Remediation) is populated from `SecurityCheckDef__mdt` records - controlled, structured content. No user-generated free text is fed into findings except `AcknowledgementNote__c`, which is never sent to any AI model.

### i18n - v2 Gap
v1 is English-only. All LWC UI strings are hardcoded in templates and JavaScript. All 76 CMT check definitions contain English-only Description, Impact, and Remediation text. v2 consideration: extract LWC UI strings to Custom Labels for Translation Workbench support. CMT check definitions remain English in v1 - multi-language support would require per-locale CMT record sets or a Translation Workbench extension point.
