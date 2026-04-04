# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Implementation Gate (Non-Negotiable)

**Do not write, generate, or modify any code or metadata files until the user explicitly says to proceed.**

This applies to every phase and every artifact - Apex classes, LWC components, object metadata, static resources, test classes, config files, and any other deployable file. Design discussions, plan updates, and CLAUDE.md edits are permitted. Code is not.

---

## Project Overview

MetaMapper is an open-source, 100% native Salesforce application that maps reachable metadata dependencies using the Tooling API. For each component it discovers, it stores one representative path - the first path found during traversal. It targets enterprise/LDV orgs where synchronous Governor Limits are a hard constraint. All runtime data stays within the Salesforce trust boundary - no external APIs, no CDN calls.

---

## Commands

### Salesforce CLI (sf)

```bash
# Authenticate
sf org login web --alias <alias>

# Create scratch org
sf org create scratch --definition-file config/project-scratch-def.json --alias metamapper-dev --duration-days 7

# Deploy to org
sf project deploy start --source-dir force-app --target-org <alias>

# Deploy single component
sf project deploy start --source-dir force-app/main/default/classes/DependencyQueueable.cls --target-org <alias>
sf project deploy start --source-dir force-app/main/default/lwc/metaMapperGraph --target-org <alias>

# Run Apex tests
sf apex run test --target-org <alias> --result-format human --code-coverage --wait 10

# Run a single test class
sf apex run test --target-org <alias> --class-names DependencyQueueableTest --result-format human --wait 10

# Execute anonymous Apex
sf apex run --target-org <alias> --file scripts/apex/<script>.apex

# Open org
sf org open --target-org <alias>

# Check default org
sf org display
```

### npm Scripts

```bash
npm run lint                  # ESLint on all LWC/Aura JS
npm run test                  # Run LWC Jest unit tests
npm run test:unit:watch       # Jest in watch mode
npm run test:unit:coverage    # Jest with coverage report
npm run prettier              # Format all source files (Apex, JS, HTML, XML, etc.)
npm run prettier:verify       # Check formatting without writing
```

> Pre-commit hooks (husky + lint-staged) auto-run Prettier, ESLint, and Jest on staged files. Do not bypass with `--no-verify`.

---

## Architecture

### Processing Model

The core challenge: enterprise org metadata trees are too large for synchronous Apex (10s CPU, 6MB heap). The solution is a **Queueable chain + Custom Object state machine**:

1. User submits a search via the LWC - an `@AuraEnabled` controller creates a `Metadata_Scan_Job__c` record and inserts the root `Metadata_Dependency__c`, then enqueues `DependencyQueueable`.
2. Each `DependencyQueueable` execution queries a batch of unprocessed nodes (`Is_Processed__c = false`), calls the Tooling API via Named Credential, inserts new child nodes, marks current nodes processed, and checks limit proximity.
3. When the remaining callout budget drops below a safe threshold, it self-enqueues a fresh instance and exits. The guardrail uses a **remaining-callout budget** model (not percentage alone): reserve explicit headroom for QueryMore follow-ups, Flow status validation, and retry splits. Chain when `remaining < headroom`; see Limit Guardrails section below.
4. When no unprocessed nodes remain, the job transitions to `Completed` and fires notifications.

### Tooling API Callout (Loopback Auth)

Direct Tooling API calls from within async Apex require a **Named Credential loopback**:
- Connected App + Auth Provider configured in the org
- Named Credential `MetaMapper_Tooling_API` authorized once by admin post-install
- Callout target: `callout:MetaMapper_Tooling_API/services/data/v66.0/tooling/query/?q=...`
- These three config items cannot be source-tracked; setup instructions live in `setup/SETUP.md`

### Cycle Detection (Two-Tier)

A single global visited set incorrectly flags shared/diamond dependencies (node B reachable via A→B and C→B) as circular. These are valid repeated references, not cycles. Two separate concerns must be separated:

**Tier 1 - Global deduplication (`processedIds`):**
After the Tooling API returns dependency results for the current batch, query the DB scoped to only those returned IDs:
`SELECT Metadata_Id__c FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :jobId AND Metadata_Id__c IN :currentResultIds`
Rows returned = number of already-inserted matches within `currentResultIds` (bounded by the result set size, not by the IN list size). This avoids the full-table scan that would occur when querying all previously inserted nodes. If a result is already in this set, **skip insertion entirely** (deduplication). Do NOT mark as circular.

> **Why not query all nodes upfront?** At 10k-20k nodes a full-scan query consumes a large portion of the 6MB async heap before any Tooling API work begins. Scoping to `currentResultIds` limits the dedup query to matches within the current callout's result set only.

**Tier 2 - True ancestry cycle detection (`Ancestor_Path__c`):**
Each `Metadata_Dependency__c` stores a pipe-delimited `Ancestor_Path__c` field: the chain of ancestor `Metadata_Id__c` values from root to this node.

- **Root node:** `Ancestor_Path__c = ''` (empty string, not null). This ensures the first child path is built as `'' + '|' + rootId = '|rootId'`, which is handled by trimming the leading pipe, OR by initializing root as `Ancestor_Path__c = rootId` and children as `parentPath + '|' + parentId`.
- **Correct path-building:** `child.Ancestor_Path__c = (String.isBlank(parent.Ancestor_Path__c) ? '' : parent.Ancestor_Path__c + '|') + parent.Metadata_Id__c`. This avoids a leading delimiter on first-level children.
- **Cycle check:** use delimiter-safe containment: `('|' + parent.Ancestor_Path__c + '|').contains('|' + newNodeId + '|')`. A raw `String.contains(id)` is vulnerable to false positives where one 18-char ID is a substring of another. The delimiter-wrapped form is the authoritative check.
- **Circular node path:** Keep the **full `Ancestor_Path__c`** on circular nodes - do NOT set to null. The path is most valuable precisely when a cycle is found (debugging, export). Mark `Is_Circular__c = true`, `Is_Processed__c = true`. Append the cycle-closing segment to `Dependency_Context__c` as `{"cycleClosesAt": "<parentMetadataId>"}` for UI visualization.
- **CPU consideration:** `String.contains()` on a long Ancestor_Path__c string inside an inner loop is CPU-intensive for deep trees. Check `Limits.getCpuTime()` against the guardrail threshold **inside the node-processing loop**, not only at the batch boundary.

> **Ancestor_Path__c capacity:** At 18 chars/ID + 1 delimiter, a depth-1,500 path would be ~28,500 chars - within the Long Text 32768 limit. Deeper trees are unrealistic in practice.

### Cancellation

`DependencyQueueable` checks `Status__c` as the first operation in `execute()`. If `Status__c = 'Cancelled'`, it exits immediately without enqueuing a successor. The `cancelJob(String jobId)` `@AuraEnabled` method in `DependencyJobController` sets `Status__c = 'Cancelled'` (WITH USER_MODE). The LWC Cancel button calls this method. Queueables that are already enqueued will check on entry and terminate cooperatively - there is no force-kill mechanism in Salesforce.

### Async Context Guard

`createJob()` in `DependencyJobController` must only be invoked from a synchronous Lightning context (LWC `@AuraEnabled` call). If called from an already-async context (e.g., a Copilot Action, a Batch finish handler), `System.enqueueJob()` inside a Queueable that is itself inside a Queueable will exceed Salesforce's nested async restrictions in certain governor contexts.

Guard: `DependencyJobController.createJob()` should validate `!System.isQueueable() && !System.isBatch() && !System.isFuture()` and throw a descriptive exception if called from an unsupported async context. Document this constraint in `setup/SETUP.md`.

### Concurrency Guard

Multiple admins running simultaneous large scans compete for the Salesforce flex queue and Tooling API, creating risk of `ConcurrentPerOrgLongTxn` errors and HTTP timeout cascades.

`createJob()` must check active Queueable count before accepting a new job:

```
Integer activeQueueables = [
    SELECT COUNT() FROM AsyncApexJob
    WHERE JobType = 'Queueable'
    AND ApexClass.Name = 'DependencyQueueable'
    AND Status IN ('Processing', 'Preparing')
];
Integer maxConcurrent = (Integer) settings.Max_Concurrent_Jobs__c; // default 2
if (activeQueueables >= maxConcurrent) {
    throw new DependencyJobException(
        'Another MetaMapper scan is already running. Wait for it to complete before starting a new one.'
    );
}
```

`Max_Concurrent_Jobs__c` is a new `MetaMapper_Settings__mdt` field (Number, default 2). The LWC surfaces the rejection as a user-friendly banner: "A scan is already in progress. MetaMapper runs one scan at a time to avoid impacting org performance."

> **Why 2?** One active + one in-flight is the pragmatic limit for orgs under normal load. Admins can raise to 3-5 for orgs with a large flex queue allocation and fast metadata trees.

> **Advisory note:** The count check is not an atomic lock - two simultaneous `createJob()` calls could both pass the threshold before either Queueable is enqueued. For an admin tool this race window is near-zero in practice, but the design acknowledges it. `ApexClass.Name = 'DependencyQueueable'` is required for query selectivity on LDV orgs where `AsyncApexJob` can hold millions of rows. Route this query through `DependencyJobSelector.countActiveQueueables()` to keep SOQL centralized.

### Live Progress (Platform Events)

`DependencyQueueable` publishes **exactly one** `Dependency_Scan_Status__e` event per Queueable execution - after the final DML commit of that execution, not after each inner batch loop iteration. The `metaMapperProgress` LWC subscribes via `lightning/empApi` on mount and unsubscribes on destroy - no polling. Do not publish events inside a try-catch that swallows the exception.

> **Why one event per execution?** Salesforce enforces a daily org-wide Platform Event delivery limit (50,000 for Standard Volume). At 50 nodes per Queueable execution, a 10,000-node job generates ~200 executions = ~200 events - well within limits. Publishing per inner batch loop (e.g., once per IN-chunk callout) would multiply this by 5-10x and could exhaust the org's daily allocation during concurrent admin scans.

**Dynamic Platform Event degradation (auto-protect against limit exhaustion):**
`DependencyNotificationService.publishProgress()` must check the org's remaining daily PE allocation before each publish. If the org has consumed >80% of its daily limit, suppress the event automatically and fall back to polling - without requiring admin intervention:

```
// In DependencyNotificationService.publishProgress():
List<OrgLimit> limits = OrgLimits.getMap().values(); // query platform limits
// Find 'DailyDeliveredPlatformEvents' in OrgLimits map
// If (used / limit) >= 0.80: skip publish, log to Error_Status_Message__c
```

This is additive to `Disable_Platform_Events__c` - the CMDT switch remains for proactive admin control, while the runtime check provides automatic degradation. When auto-degraded, set `Disable_Platform_Events__c = true` on the CMDT Default record so all subsequent executions in the same day also skip publishing without re-checking limits on every call. **Append to `Error_Status_Message__c`** when auto-suppress fires: `"[timestamp] Platform Events suppressed - org daily delivery limit >80% consumed. Progress updates switched to polling."` so admins have visibility without needing debug logs.

**CMDT mutation path:** `DependencyNotificationService` writes the flag via `Metadata.Operations.enqueueDeployment()` (async, does not consume a DML statement). If the deployment call itself fails (e.g. insufficient metadata deployment permissions), the suppression flag is NOT persisted - but the event is still skipped for the current execution. On the next execution, the OrgLimits check will run again and attempt the write again. The suppression notice is appended to `Error_Status_Message__c` regardless of whether the CMDT write succeeds, ensuring admin visibility is never gated on metadata deployment access.

### Graph Visualization

`metaMapperGraph` loads Apache ECharts from the `ECharts` Static Resource (no CDN). It receives a flat `Metadata_Dependency__c` list and builds the ECharts `graph` series client-side, using `Parent_Dependency__c` to derive edge links. Node color is keyed to `Metadata_Type__c`.

> **Static Resource build**: use `echarts/dist/echarts.min.js` (core minified build, ~1.0-1.2MB) sourced from the npm package. Do **not** use the full bundle - it includes maps and 3D features and risks exceeding Salesforce's 5MB static resource hard limit.

> **Dark mode**: register a Salesforce-compatible dark theme via `echarts.registerTheme('sfDark', { backgroundColor: '#1B1B1B', textStyle: { color: '#FFFFFF' }, ... })`. Apply when `document.body.classList.contains('slds-theme_inverse')`. Use `slds-theme_inverse` detection, not a manual preference flag.

### Security Model

- OWD: `Metadata_Scan_Job__c` = Private (users see only their own jobs)
- All Apex DML/SOQL uses `WITH USER_MODE` or `AccessLevel.USER_MODE` - FLS and CRUD enforced at runtime
- Permission Set `MetaMapper_Admin` grants CRUD on both custom objects, Named Credential principal access, and LWC/controller access

### Data Lifecycle

`DependencyCleanupBatch` runs nightly at 02:00 via `DependencyCleanupScheduler`. It hard-deletes closed jobs older than `MetaMapper_Settings__mdt.Retention_Hours__c`.

**Lifecycle rule (critical):**
- Only delete jobs where `Status__c IN ('Completed', 'Failed', 'Cancelled')` AND `Closed_At__c < :DateTime.now().addHours(-retentionHours)`. Never delete `Initializing` or `Processing` jobs - a long-running in-progress scan must not be destroyed by the cleanup window.
- `Closed_At__c` (DateTime field on `Metadata_Scan_Job__c`) is stamped by the Queueable engine the moment a job transitions to Completed, Failed, or Cancelled. Using `CreatedDate` would incorrectly target long-running jobs still in progress.

**Cascade delete DML trap (critical):**
Master-Detail cascade deletion counts child record deletes against the 10,000 DML row limit of the batch `execute()` transaction. A job with 15,000 nodes would cause `System.LimitException: Too many DML rows` on the first delete call. An inner `while (!nodes.isEmpty())` loop inside `execute()` compounds this risk in LDV orgs - 80k+ node jobs can exceed CPU or trigger "Too many DML statements" from customer triggers firing on every 2,000-node delete within the same transaction.

**Fix: two-class chained cleanup pattern.**

`DependencyCleanupBatch` discovers expired jobs; `DependencyNodeCleanupBatch` handles the actual deletion.

**`DependencyCleanupBatch`** (job discovery):
- `start()`: returns QueryLocator for closed jobs where `Closed_At__c < threshold`
- `execute(scope)`: no DML - accumulates job IDs
- `finish()`: fires one `DependencyNodeCleanupBatch(jobId)` per job found. Each fires as a separate batch transaction with its own DML budget.
- Batch size: 10 (multiple jobs per discovery pass is safe since execute() does no DML)

**`DependencyNodeCleanupBatch`** (node + job deletion):
- Constructor: accepts a single `jobId`
- `start()`: `SELECT Id FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :jobId`
- `execute(scope)`: `delete scope;` - scope is already `<= Cleanup_Chunk_Size__c`
- `finish()`: `delete [SELECT Id FROM Metadata_Scan_Job__c WHERE Id = :jobId];`
- Batch size: `Cleanup_Chunk_Size__c` (default 2,000)

**Chunk size: `Cleanup_Chunk_Size__c` in `MetaMapper_Settings__mdt` (default 2,000).** Do NOT use 9,000. MetaMapper is deployed into customer orgs where managed packages, record-triggered Flows, or Apex Triggers may fire on delete events for any Custom Object. A chunk of 9,000 leaves only 1,000 DML rows for customer automation - insufficient for orgs with non-trivial delete handlers. 2,000 provides 8,000 rows of headroom for customer triggers while keeping each transaction practical.

> Each `DependencyNodeCleanupBatch` `execute()` call deletes exactly one chunk of 2,000 nodes in its own transaction - no inner loops, no compounding DML risk regardless of total node count.

---

## Data Model

### Metadata_Scan_Job__c
| Field | Type | Notes |
|---|---|---|
| `Target_Metadata_Type__c` | Picklist | CustomField, ValidationRule, Flow, ApexClass, ApexTrigger, WorkflowRule, etc. |
| `Target_API_Name__c` | Text 255 | Developer Name of the target metadata |
| `Target_Object__c` | Text 255 | Optional - populated by typeahead for field-scoped searches |
| `Active_Flows_Only__c` | Checkbox | Default true - drops inactive Flow versions |
| `Status__c` | Picklist | Initializing, Processing, Completed, Failed, **Cancelled**, **Paused** |
| `Error_Status_Message__c` | Long Text 32768 | Full exception on failure |
| `Components_Analyzed__c` | Number | Running counter for progress bar |
| `Result_Summary__c` | Long Text 32768 | JSON map of `{MetadataType: count}` - populated on Completed |
| `Closed_At__c` | DateTime | Stamped when Status transitions to Completed, Failed, or Cancelled. Cleanup batch uses this field - never CreatedDate - to avoid deleting in-progress jobs. |
| `Processing_Cycle_Count__c` | Number | Incremented each time the Queueable self-chains. If this value increases by N (configurable in CMDT) without a corresponding increase in `Components_Analyzed__c`, the engine is hot-looping on a pathological node and pauses with a user-facing warning. |
| `Scan_Summary_Text__c` | Long Text 32768 | Plain-English summary populated after job Completed by `ScanSummaryQueueable`. Derived from `Result_Summary__c`. Example: "This scan found 42 dependencies, including 3 active Flows and 5 Apex classes." Enables Agentforce Actions to consume job results without parsing JSON. Null until Completed. Populated asynchronously - LWC should poll `getJobStatus()` until this field is non-null before rendering the Summary Card. |

> **Visited_IDs__c removed.** A Long Text 131072 field caps at ~5,957 IDs (22 chars/ID with JSON formatting). Enterprise orgs can easily exceed this, causing `StringException` and crashing the Queueable chain. Cycle detection is instead performed via two-tier logic (see Cycle Detection below).

### Metadata_Dependency__c
| Field | Type | Notes |
|---|---|---|
| `Metadata_Scan_Job__c` | Master-Detail | Cascade delete |
| `Parent_Dependency__c` | Lookup (self) | Builds hierarchical tree |
| `Metadata_Id__c` | Text 18 | Exact 18-char Tooling API ID |
| `Metadata_Type__c` | Text 50 | e.g. ApexClass, CustomField, Flow |
| `Metadata_Name__c` | Text 255 | Human-readable API name |
| `Dependency_Depth__c` | Number | Depth from root (0 = root target) |
| `Is_Processed__c` | Checkbox | Engine flag: false = pending child traversal |
| `Is_Circular__c` | Checkbox | True only when this node's `Metadata_Id__c` appears in its own `Ancestor_Path__c` (true ancestry cycle) |
| `Is_Dynamic_Reference__c` | Checkbox | True if reference cannot be statically analyzed (e.g. dynamic Apex string) - flagged in UI |
| `Dependency_Context__c` | Long Text 32768 | JSON "pills" - contextual metadata per type (see below) |
| `Discovery_Source__c` | Picklist | `ToolingAPI` or `Supplemental` - tracks how the node was discovered |
| `Ancestor_Path__c` | Long Text 32768 | Pipe-delimited ancestor `Metadata_Id__c` chain from root to this node - used for true cycle detection |
| `Supplemental_Confidence__c` | Number (3,0) | 0-100 confidence score for supplemental nodes only. Regex/XML matches are inherently fuzzy; score reflects match certainty. Nodes below 70 display a warning badge in the UI. Null for ToolingAPI nodes. |
| `Deduplication_Key__c` | Text 80 (External ID, Unique) | Composite key: `JobId + ':' + Metadata_Id__c`. Used for upsert to prevent duplicate nodes from race conditions in concurrent Queueable chains. Text 80 provides headroom for future scoping additions beyond the current 37-char minimum. |
| `Ancestor_Hash_Prefixes__c` | Long Text 32768 | Concatenated 6-char base64url hashes of ancestor `Metadata_Id__c` values. Used as a hash shortcut for cycle detection before invoking `String.contains()` on the full `Ancestor_Path__c`. Algorithm: for each ancestor ID, take the first 6 chars of its base64url-encoded SHA-256 hash, concatenate all hashes into this field. If `Ancestor_Hash_Prefixes__c.contains(shortHash)` is true, validate conclusively against `Ancestor_Path__c` before marking circular. Reduces CPU on deep trees by skipping the full string scan on most nodes. **Field must be Long Text 32768 - Text 255 overflows at depth >42 (255 / 6 chars = 42 hashes max), causing a silent `StringException` on upsert.** |

### Dependency_Context__c (Pills) by Metadata Type

All `Dependency_Context__c` payloads include a root `"v": 1` version key. The LWC renders unknown keys as plain text with a fallback label rather than failing. Handlers must increment `"v"` when the payload schema changes - the LWC version check gate is the only compatibility contract.

| Type | JSON shape |
|---|---|
| ApexClass / ApexTrigger | `{"v": 1, "isWrite": true}` - whether the class writes to the target field/object |
| Flow | `{"v": 1, "activeVersions": 3, "isActive": true}` |
| WorkflowRule | `{"v": 1, "isActive": true, "triggerType": "onInsertOrUpdate"}` |
| CustomField | `{"v": 1, "parentObject": "Account", "parentType": "CustomObject"}` |
| Report | `{"v": 1, "filterUsage": ["filter", "grouping", "column"]}` |

`Result_Summary__c` also carries a version key at root: `{"v": 1, "ApexClass": 5, "Flow": 3}`. LWC stat tile ignores unknown keys rather than failing.

---

## Key Apex Classes

**Interfaces (Dependency Injection / testability):**

| Interface | Contract |
|---|---|
| `IMetadataDependencyService` | `fetchDependencies(List<String> ids, DependencyOptions opts)`, `buildContextData(Metadata_Dependency__c node)`, `computeScore(String handlerType, String matchBasis)` |
| `IDependencyTypeHandler` | `List<Metadata_Dependency__c> findSupplemental(Id jobId, List<Metadata_Dependency__c> nodes)` |
| `INotificationService` | `publishProgress(String jobId, String status, Integer count, String msg)`, `sendCompletion(String jobId, String userId)` |
| `ISettingsProvider` | `MetaMapper_Settings__mdt getSettings()` - read once per transaction, cached in a `static` variable. The cache must be `static` (not instance-level) so that supplemental handlers calling `getSettings()` independently within the same Apex transaction reuse the same record and do not each burn a SOQL query. |

**Selectors (all SOQL centralized here):**

| Selector | Key Methods |
|---|---|
| `DependencyJobSelector` | `getByIdForEngine(String jobId)` - minimal fields for engine; `getClosedJobsBefore(DateTime threshold)` - for cleanup; `countActiveQueueables()` - scoped `AsyncApexJob` count for concurrency guard (includes `ApexClass.Name = 'DependencyQueueable'` filter) |
| `DependencyNodeSelector` | `nextUnprocessed(String jobId, Integer lim)` - ordered fetch; `dedupForResults(String jobId, Set<String> ids)` - scoped dedup query; `listByJob(String jobId)` - for export |

**Classes:**

| Class | Role |
|---|---|
| `DependencyJobController` | `@AuraEnabled` (USER_MODE): `createJob()` with async guard + concurrency guard + preflight check, `getObjectList()`, `getJobStatus()`, `getNodeHierarchy()`, `cancelJob()`, `resumeJob(String jobId, Integer overrideBatchSize)` - passes transient batch override to Queueable (does not write CMDT). Delegates to services - no SOQL/DML directly. |
| `MetadataDependencyService` (implements `IMetadataDependencyService`) | Tooling API SOQL formatting, character-budget chunking, QueryMore, Active Flows filter, `buildContextData()`, `computeScore()`. **Heap pre-check rule (critical):** must check `Limits.getHeapSize()` BEFORE calling `JSON.deserializeUntyped()` on the raw HTTP response body - `Limits.getHeapSize()` is delayed and does not reflect the memory cost of the pending deserialization. If the raw response body string length exceeds 500,000 characters (~500KB), split the batch in half and re-query rather than deserializing the full payload. |
| `DependencyTypeHandlerFactory` | `IDependencyTypeHandler getHandler(String metadataType)` - returns correct handler or no-op default |
| `CustomFieldHandler` | Supplemental: WorkflowFieldUpdate (95), ValidationRule regex (65), FlexiPage XML (60), CMT lookups (85), Lookup relationships (95). **Regex safety rule:** all regex patterns must be non-backtracking (no nested quantifiers). Before each regex call, check `Limits.getCpuTime() / Limits.getLimitCpuTime() >= 0.60` - if true, skip the field, log a diagnostic notice to `Error_Status_Message__c`, and continue. ValidationRule formula fields in complex orgs can be 10,000+ characters; unbounded backtracking patterns will hit the CPU limit and fail the Queueable. |
| `ApexClassHandler` | Supplemental: CMT references (85); flags `Is_Dynamic_Reference__c` |
| `FlowHandler` | Supplemental: QuickActionDefinition, subflows, WebLink URLs |
| `DependencyQueueable` | Async engine. Constructor: `DependencyQueueable(String jobId, Boolean activeFlowsOnly, Integer overrideBatchSize)` - `overrideBatchSize` is null for normal execution; set to half of `Scan_Batch_Size__c` when `resumeJob()` triggers after a hot-loop pause. Savepoint/catch; cancel check; CMDT read via `ISettingsProvider`; hot-loop detection; pre-batch + mid-loop seven-limit guardrail; scoped dedup + upsert by `Deduplication_Key__c`; two-tier cycle detection; callouts; HTTP 414/431 reactive split-and-retry (halves batch, retries both halves as separate callouts, does not fail job - logs restart to `Error_Status_Message__c`); handlers; one PE event per execution (suppressed if `Disable_Platform_Events__c`); self-chain. **DML bulkification rule (critical):** child nodes discovered during the result-processing loop are accumulated in a `List<Metadata_Dependency__c>` and upserted in a single bulk statement after the loop completes (or before a mid-loop self-chain fires). Never upsert per-node inside the loop. |
| `DependencyNotificationService` (implements `INotificationService`) | `publishProgress()` - one event per execution; checks org daily PE allocation via `OrgLimits` before publishing (auto-suppresses and flips `Disable_Platform_Events__c` if >80% consumed - appends suppression notice to `Error_Status_Message__c` for admin visibility); `sendCompletionNotification()`; enqueues `ScanSummaryQueueable` at job Completed (does NOT build AI summary inline - see below). |
| `ScanSummaryQueueable` | Lightweight one-shot Queueable enqueued by the final `DependencyQueueable` execution (via `DependencyNotificationService.sendCompletionNotification()`). Reads `Result_Summary__c`, builds the plain-English `Scan_Summary_Text__c` string, and updates the Job record. Offloaded to avoid adding string-templating CPU/heap cost to the final engine transaction. |
| `DependencyCleanupBatch` | Job discovery batch. `start()` = closed jobs past retention threshold. `execute()` = no DML. `finish()` = fires one `DependencyNodeCleanupBatch` per job. Batch size 10. |
| `DependencyNodeCleanupBatch` | Node + job deletion batch. Constructor accepts `jobId`. `start()` = QueryLocator for child nodes. `execute()` = `delete scope`. `finish()` = delete parent job. Batch size = `Cleanup_Chunk_Size__c` (default 2,000). No inner loops - each transaction is one chunk only. |
| `DependencyCleanupScheduler` | Schedules cleanup at 02:00 |
| `ToolingApiHealthCheck` | Setup-only Apex class: verifies Tooling API reachability via Named Credential. Called by pre-flight LWC check on page load. |

### Type Handler Pattern
Every `IDependencyTypeHandler` implementation follows the same contract:
- Receives the current batch of `Metadata_Dependency__c` records of its type
- Executes supplemental queries (Tooling API, SOQL, Metadata API) to find dependencies **not** returned by `MetadataComponentDependency`
- Returns additional `Metadata_Dependency__c` records to be inserted with `Discovery_Source__c = 'Supplemental'`
- Sets `Is_Dynamic_Reference__c = true` on nodes that cannot be statically resolved

---

## Hot-Loop Backoff Detection

If `DependencyQueueable` self-chains repeatedly without processing any new nodes (e.g. a single pathological node saturates every guardrail before children can be inserted), the engine must detect and break the loop.

**Detection logic:**
- On each self-chain, increment `Processing_Cycle_Count__c` on the Job and compare `Components_Analyzed__c` to the previous value stored in a transient variable.
- If `Processing_Cycle_Count__c` increases by `Stall_Detection_Threshold__c` (default 5) without any change in `Components_Analyzed__c`, transition Job to `Status__c = 'Paused'` (new status value), set `Error_Status_Message__c` with diagnostic context, and publish a `Dependency_Scan_Status__e` warning event.
- The LWC surfaces this as a user-visible warning: "MetaMapper paused because it encountered a component with extremely deep or wide dependencies. You can resume at a slower speed or with current settings."

> `Status__c` gains a `Paused` value. `DependencyJobController` exposes a `resumeJob(String jobId, Integer overrideBatchSize)` method. When the LWC calls `resumeJob`, it passes a suggested batch size (half of the current `Scan_Batch_Size__c` CMDT value). The Queueable uses this transient override for the resumed run only - it does NOT write back to CMDT. This eliminates the friction of requiring an admin to manually navigate to CMDT settings before retrying. The LWC pause banner displays: "Scan paused. [Resume at a slower speed] or [Resume with current settings]."

---

## Key LWC Components

| Component | Role |
|---|---|
| `metaMapperApp` | Root shell; owns `jobId` state; switches between input, progress, and results views. Runs pre-flight Named Credential health check on mount; shows setup error state if check fails. |
| `metaMapperInput` | Metadata type picklist, API name text input, typeahead object lookup (debounced 300ms, queries `EntityDefinition`), "Active Flows Only" checkbox with tooltip explanation. Shows estimated node complexity preview when available. Validates required fields before enabling submit. |
| `metaMapperProgress` | `lightning-progress-bar` + human-readable status label ("Analyzing metadata...", "Paused - limit reached", "Cancelling..."). Subscribes to `Dependency_Scan_Status__e` via `lightning/empApi`; falls back to `getJobStatus()` polling if `Disable_Platform_Events__c = true`. When polling fallback is active, shows persistent info label: "Live updates paused - refreshing every few seconds." Displays elapsed time. Cancel button transitions to disabled "Cancelling..." spinner on click; shows confirmation modal before cancelling. |
| `metaMapperResults` | Tab container: "Tree View" and "Graph View" sharing filter state. **AI Summary card** at top (visible when `Status__c = Completed`): displays `Scan_Summary_Text__c` with "Copy" button and "Ask Copilot" quick action. Stats tile (type counts from `Result_Summary__c`). Hosts export controls. |
| `metaMapperTree` | Virtual-rendered SLDS tree with search, type filter, level filter, and confidence filter. Supports collapse/expand per branch. Keyboard navigable. |
| `metaMapperGraph` | ECharts force-directed graph. Node click: opens component in Salesforce Setup. Right-click: "Copy API Name". Hover: tooltip with `Dependency_Context__c` pills in plain English. Node selection: click selects node and populates the **Node Details Panel** (sidebar). "Expand All" guard: shows modal warning if node count > 1,000. Persistent sidebar legend. "Focus path to root". Graph toolbar search (quick-find: highlights matching nodes without affecting Tree). "?" keyboard shortcut legend. Type filter + level slider. ECharts theme registered for Salesforce dark mode (`slds-theme_inverse`). |
| `metaMapperNodeDetail` | Sidebar panel (right side of results screen). Renders full node data when a node is selected in either Tree or Graph: `Metadata_Name__c`, `Metadata_Type__c`, `Dependency_Depth__c`, `Discovery_Source__c`, `Supplemental_Confidence__c`, all `Dependency_Context__c` pills in plain English, `Ancestor_Path__c` rendered as breadcrumb, `Is_Circular__c` / `Is_Dynamic_Reference__c` flags with explanations. "Open in Setup" button (primary action). "Copy Link" button generates a deep-link URL (`[current URL]?jobId=[jobId]&nodeId=[Metadata_Id__c]`) and copies to clipboard. Closes when selection is cleared. |
| `metaMapperExport` | Primary export: CSV ("Download as CSV") and JSON ("Download Complete Hierarchy (for developers)"). Default filename: `MetaMapper_[Target_API_Name]_[YYYYMMDD]_[HHmm]`. Advanced export (collapsible): package.xml ("Download Deployment Manifest"). No server round-trip. |

---

## UX Design Specification

### What MetaMapper Helps You Do

MetaMapper answers a single question that Salesforce Setup cannot: **"If I change or delete this component, what else will break?"** It traces every dependency of a metadata component - Apex classes, Flows, Validation Rules, Field Updates, page layouts, and more - and maps the full chain to any depth. Instead of manually cross-referencing Setup pages, running change sets blind, or discovering broken automation after deployment, you start a scan, wait a few minutes, and get a complete, explorable dependency map. The results are yours to filter, export, and share. Everything runs inside your org; nothing leaves the Salesforce trust boundary.

### Pre-Flight Check + First-Time Onboarding
On `metaMapperApp` mount, call `ToolingApiHealthCheck.verify()` via `@AuraEnabled`. Block the input form entirely until the check resolves. Three distinct failure states (not a single generic error):

| Failure type | Detected by | UI message | Action link |
|---|---|---|---|
| Named Credential not authorized | HTTP 401 from health check callout | "MetaMapper needs one-time setup. An admin must authorize the Tooling API connection." | Link to `setup/SETUP.md` |
| Current user lacks permission | HTTP 403 or FIELD_CUSTOM_VALIDATION_EXCEPTION on Job insert | "You don't have access to MetaMapper. Ask your admin to assign you the MetaMapper Admin permission set." | No link; text only |
| Tooling API temporarily unreachable | HTTP 5xx or callout timeout | "MetaMapper cannot reach the Tooling API right now. This may be a temporary org issue." | "Retry" button that re-runs the health check |

Do not collapse all three into a single "setup required" message - each requires a different user action and a different responsible party (admin vs user vs wait).

**First-time guided tour:** After the Named Credential health check passes for the first time (detected via a `localStorage` flag `metaMapper_tourSeen_v1`), show a one-time `lightning-modal` walkthrough with three slides:
1. "Reading the graph" - explains the legend, node colors, and border shapes.
2. "Warning badges" - explains `Is_Dynamic_Reference__c`, `Supplemental_Confidence__c < 70`, and `Is_Circular__c` badges.
3. "Supplemental results" - explains that some dependencies are found via secondary queries and may require manual verification.

User can dismiss at any time. "Don't show again" checkbox persists the `localStorage` flag (`metaMapper_tourSeen_v1`). Tour will not reappear on the same browser after dismissal. It will reappear on a different browser or after clearing browser storage - this is acceptable behaviour for a localStorage-based flag. Bump the version suffix (e.g. `_v2`) on major UX changes to force the tour to re-display for all existing users.

### Input Screen (`metaMapperInput`)

| Element | Behavior |
|---|---|
| Metadata Type picklist | Required; shows supported types only |
| API Name input | Required; placeholder: "e.g. Account.My_Field__c"; inline validation on blur |
| Target Object typeahead | Required only when type is `CustomField`; shows validation message if omitted |
| "Active Flows Only" checkbox | Default checked; tooltip: "When checked, inactive Flow versions are excluded from results. This reduces scan scope but may miss deprecated dependencies." |
| Complexity preview | After API Name is entered, show: "Estimated scan scope: [Small / Medium / Large / Very Large] based on historical averages for this metadata type." (non-blocking, best-effort) |
| Submit button | Disabled until required fields valid; label "Analyze Dependencies" |

### Progress Screen (`metaMapperProgress`)

**Status labels (human-readable, not Status__c API values):**

| Status__c value | UI label |
|---|---|
| Initializing | "Setting up your analysis..." |
| Processing | "Analyzing metadata... [N] components found so far" |
| Paused | "Analysis paused - encountered a complex component. You can resume at a slower speed or with current settings." |
| Cancelled | "Analysis cancelled. Partial results are available below." |
| Completed | "Analysis complete. [N] components found." |
| Failed | "Analysis failed. [error summary]. See details for diagnostics." |

**Cancel interaction:**
1. User clicks "Cancel" - show confirmation modal: "Stop the analysis? The job will stop at the next checkpoint. Partial results already found will remain available."
2. On confirm: button transitions to disabled "Cancelling..." with spinner; calls `cancelJob()`
3. LWC waits for `Dependency_Scan_Status__e` with `Status__c = 'Cancelled'` before re-enabling UI

### Graph View (`metaMapperGraph`)

**Node visual language (SLDS-compliant, not color-only):**

| Node type | Color | Icon | Shape indicator |
|---|---|---|---|
| Is_Circular__c | Type color | `utility:rotate` | Dashed border |
| Is_Dynamic_Reference__c | Type color | `utility:warning` | Solid border (no tilde prefix) |
| Discovery_Source__c = Supplemental | Type color | `utility:info` | [S] badge |
| Supplemental_Confidence__c < 70 | Type color | `utility:error` | Red badge; click opens popover |
| Normal node | Type color | Type-specific icon | Solid border |

**Interactions:**
- **Click:** opens component in Salesforce Setup in new tab
- **Right-click:** context menu with "Copy API Name", "Focus path to root", "Collapse subtree"
- **Hover:** SLDS tooltip with this exact template: `[Metadata_Name__c] ([Metadata_Type__c]) | [plain-English pill rendering] | [Confidence: N% - verify manually]` where pill rendering maps `Dependency_Context__c` keys to human sentences (e.g. `isWrite: true` -> "Writes to this field"; `activeVersions: 3` -> "3 active versions"; `cycleClosesAt: X` -> "Cycle closes at X"). Never render raw JSON in the tooltip.
- **"Expand All" guard:** if `Components_Analyzed__c > 1,000`, clicking "Expand All" shows modal: "This graph contains [N] nodes. Expanding all levels may slow or freeze your browser. Consider using the Level Filter or exporting to CSV instead."
- **"Focus path to root":** highlights the direct ancestor chain from selected node to root; dims all other nodes. A **"Clear Focus"** button appears in the graph toolbar while focus is active - do not rely on "click anywhere" alone as the only dismissal affordance.
- **Persistent legend:** always-visible sidebar listing all node types with color swatch + icon + label
- **Graph toolbar search:** lightweight search box on the graph toolbar (Ctrl+K shortcut). Placeholder text: "Search nodes in this graph..." Inline note below the input: "(Search applies to Graph view only)". Highlights matching nodes in the graph canvas without filtering them out. Does not affect Tree View (Tree-local search remains separate). Clears with Esc.
- **"?" keyboard shortcut legend:** small "?" icon button in graph toolbar. Opens a popover listing: `Ctrl+K` = Search graph, `Shift+?` = Open keyboard legend (global), `Esc` = Clear focus / search, arrow keys = traverse nodes, `Enter` = Open in Setup, right-click = Context menu. `Shift+?` works even when focus is inside the graph canvas. Rendered as an SLDS popover, not a modal.
- **Node Details Panel:** selecting a node (single click) populates the `metaMapperNodeDetail` sidebar panel with full node data. "Open in Setup" is the primary action button in the panel, not triggered by the click itself. This separates selection (inspect) from navigation (open Setup).
- **Spanning tree notice:** a dismissible info badge is shown in the persistent graph legend: "Showing the first-discovered path to each component. A node reachable via multiple paths appears once." Dismissed via a close icon; state persisted in `localStorage` key `metaMapper_spanningTreeNotice_v1`. Does not reappear after dismissal on the same browser.
- **Large graph performance warning:** when `Components_Analyzed__c > 8,000`, show a persistent banner above the graph canvas: "Large graph detected ([N] components). For best performance, use Tree View or apply filters to reduce scope." Banner includes a "Switch to Tree View" button that activates the Tree tab directly. Banner is dismissible. Does not affect Tree View.
- **ECharts dark mode:** register a Salesforce-compatible dark theme using `echarts.registerTheme('sfDark', {...})` with SLDS dark background token (`#1B1B1B`) and text token (`#FFFFFF`). Apply theme when `document.body.classList.contains('slds-theme_inverse')`.

**Confidence badge popover (Supplemental nodes with score < 70):**
Plain-English explanation by handler:
- ValidationRule regex: "This dependency was found by scanning the text of a Validation Rule formula. The match may include false positives from comments or cross-object references. Verify manually before making changes."
- FlexiPage XML: "This dependency was found by parsing Lightning page XML. The match is version-sensitive and may not reflect all configurations."

### Tree View (`metaMapperTree`)

| Feature | Behavior |
|---|---|
| Rendering | Virtual (only visible rows rendered); handles 10,000+ nodes without freeze |
| Search | Full-text search on `Metadata_Name__c`; highlights matches; clears with X |
| Filters | Type multi-select, Level range slider, Confidence threshold, Is_Circular, Is_Dynamic, Source |
| Collapse/Expand | Per branch; keyboard navigable (arrow keys, Enter, Space) |
| Node action | Click opens in Salesforce Setup |

### Tree/Graph Synchronization Rules

The Tree View and Graph View share the same underlying data set. These rules govern their coordination:

| Interaction | Tree View | Graph View |
|---|---|---|
| Type filter changed | Hides/shows rows of that type | Hides/shows nodes of that type |
| Level filter changed | Collapses/shows depth | Dims/hides nodes beyond level |
| Node selected (click) in Tree | Node highlighted in tree | Corresponding node highlighted in graph (same `Metadata_Id__c`) |
| Node selected (click) in Graph | Corresponding row scrolled into view and highlighted in tree | Node highlighted |
| "Focus path to root" triggered in Graph | Tree scrolls to root; ancestor chain nodes highlighted | Ancestor chain highlighted; others dimmed |
| Tab switched (Tree -> Graph) | Focus state in Tree clears | Graph renders with same filter state as Tree |
| Tab switched (Graph -> Tree) | Tree renders with same filter state as Graph | Focus state in Graph clears |
| Search applied in Tree | Tree filters rows | Graph is NOT affected (search is Tree-only) |

> Filters (type, level) are shared state owned by `metaMapperResults`. Search is Tree-local state. Selection and focus are transient and clear on tab switch.

### Empty and Error States

| Scenario | UI |
|---|---|
| Job completed with zero results | Empty state illustration + "No dependencies found for [API name]. This metadata type may not have trackable dependencies, or the component may not exist." |
| Job failed mid-way | Error banner with collapsed detail: "[error summary]" + "View full error" expander showing `Error_Status_Message__c`. "Start a new scan" button. |
| `getNodeHierarchy()` loading | Skeleton loader (3 rows of shimmer) in both Tree and Graph tabs while results load. Do not show empty state during loading. |
| Job status = Paused | Warning banner (not error): "Scan paused - encountered a complex component." + "[Resume at a slower speed]" button (calls `resumeJob()` with half batch size) + "[Resume with current settings]" button (calls `resumeJob()` with current batch size). |
| Concurrency rejection | Toast notification: "A scan is already in progress. Wait for it to complete before starting a new one." |

### Responsive Behavior

| Viewport | Behavior |
|---|---|
| >= 1280px (desktop) | Full layout: sidebar legend + graph canvas + filter panel all visible |
| 1024px - 1279px (tablet landscape) | Sidebar legend collapses into a toggle button; filter panel moves to a collapsible drawer |
| < 1024px (tablet portrait / mobile) | **Default landing view is Tree View.** Graph tab is present but shows "For best results, use a desktop browser" banner when selected. Graph is pan-only with reduced node labels. Node Details Panel becomes a full-screen modal with an explicit "Close" button in the header. |

MetaMapper is a **desktop-first application**. The responsive behaviour on tablet and mobile is graceful degradation, not full feature parity. Do not invest implementation effort in making the graph fully interactive on mobile - Tree View is the intentional primary interface on small viewports. On viewports < 1024px, render the Tree View tab as the active default; the Graph tab remains accessible but is a secondary choice.

Use Salesforce responsive design tokens and the SLDS grid system. Do not hard-code pixel widths.

### Accessibility

- All color distinctions reinforced by SLDS icon + shape (not color alone)
- Contrast ratios: all palette colors verified WCAG AA against white and Salesforce dark backgrounds before implementation
- ARIA labels on all interactive graph elements; `role="tree"` on tree view
- Keyboard navigation: Tab to focus graph container; arrow keys to traverse nodes; Enter to open in Setup
- Screen reader: every node badge includes `aria-label` in plain English (e.g. "Warning: low confidence supplemental match")
- Color-blind safe: icon + border shape carry meaning independent of hue
- Dynamic content updates (progress counter, status label) use `aria-live="polite"` so screen readers announce changes without interrupting user input

### Results Screen - AI Summary Card

When `Status__c = Completed`, display a prominent card at the top of the Results screen (above both tabs):

| Element | Detail |
|---|---|
| Card title | "Scan Summary" |
| Body | `Scan_Summary_Text__c` text verbatim (e.g. "This scan found 42 dependencies: 3 active Flows, 5 Apex classes...") |
| "Copy" button | Copies `Scan_Summary_Text__c` to clipboard |
| "Ask Copilot" button | Opens Einstein Copilot with `Scan_Summary_Text__c` pre-populated. Conditionally rendered: shown only if Copilot is enabled in the org. If Copilot is unavailable, show helper text "Einstein Copilot not available in this org." in place of the button (do not hide silently). |
| Card height | Compact by default - collapsed height shows the first two sentences of `Scan_Summary_Text__c` followed by an ellipsis. Full text revealed by a "Show more" inline toggle. Prevents the card from pushing Tree/Graph tabs below the fold on smaller laptops. |

The card is not shown for Failed, Cancelled, or Paused jobs. For Paused jobs, a warning banner replaces it.

### Export Hierarchy

**Primary exports (prominent placement):**
- "Download as CSV" - flat row-per-node, for analysis in Excel / Sheets. Default filename: `MetaMapper_[Target_API_Name]_[YYYYMMDD]_[HHmm].csv`
- "Download Complete Hierarchy (for developers)" - nested tree with all `Dependency_Context__c` pills. Tooltip: "Contains all dependency data including context fields. Useful for scripting, auditing, or custom tooling." Default filename: `MetaMapper_[Target_API_Name]_[YYYYMMDD]_[HHmm].json`

**Advanced exports (collapsible "Advanced" section):**
- "Download Deployment Manifest" - package.xml, developer artifact; tooltip: "Use this to deploy or retrieve the components found in this scan using Salesforce CLI or VS Code. Includes only components from this scan (managed packages excluded)."

### Settings UI (CMDT labels)

When surfacing `MetaMapper_Settings__mdt` fields in any admin UI, use human-readable labels:

| Field API name | UI label | Help text |
|---|---|---|
| `Retention_Hours__c` | "Keep completed jobs for" | "Jobs older than this are automatically deleted. Minimum 1 hour. Recommended: 72+ hours for diagnostic use." |
| `Scan_Batch_Size__c` | "Analysis speed (standard)" | "How many metadata components to analyze per processing step. Lower this if you see timeout errors." |
| `Flow_Scan_Batch_Size__c` | "Analysis speed (Flow jobs)" | "Lower batch size used when 'Active Flows Only' is enabled, because each Flow requires an extra check." |
| `Dml_Reserve_Rows__c` | "Safety margin (DML rows)" | "Advanced: number of database rows to reserve as a safety buffer. Increase for orgs with very connected metadata." |
| `Disable_Platform_Events__c` | "Disable live progress updates" | "Turn on if your org is hitting real-time event limits. Progress will refresh every few seconds instead." |
| `Stall_Detection_Threshold__c` | "Pause after N stuck retries" | "If the analysis retries this many times without finding new components, it pauses and alerts you." |
| `Max_Concurrent_Jobs__c` | "Max concurrent scans" | "How many MetaMapper scans can run at the same time. Default 2. Raise only for orgs with large async capacity." |
| `Cleanup_Chunk_Size__c` | "Cleanup chunk size (Advanced)" | "Records deleted per database transaction during cleanup. Default 2,000. Lower this value if you see 'Too many DML statements' errors from other automation during cleanup." |

**Admin-only controls (Settings UI):**
- "Reset First-Time Tour" button: clears the `metaMapper_tourSeen_v1` localStorage flag for the current browser session. Useful for admins demoing the tour to new team members. Implemented as a client-side JS action - no Apex required.

---

## Query Strategy

### IN Clause Chunking
Start with batches of **100 IDs** as a safe default, but split is driven by **estimated query character length**, not a fixed count. The Tooling API REST endpoint embeds SOQL in the URL - URI length depends on the IDs themselves, encoding, and the surrounding SOQL string. If estimated URL length exceeds 8KB, halve the batch before sending. 100 IDs is the starting estimate; the dynamic check is authoritative.

### QueryMore
Tooling API results exceeding 2,000 rows return a `nextRecordsUrl`. `MetadataDependencyService` must follow `nextRecordsUrl` iteratively until `done = true` before returning results to the Queueable. Each follow-up counts against the callout budget.

**Cursor expiration risk:** Tooling API query cursors typically expire after ~15 minutes. If a complex node causes the Queueable to self-chain and the chained job waits in the Salesforce Flex Queue during high org utilization, the cursor may expire before the next execution resumes QueryMore. `MetadataDependencyService` must wrap each `nextRecordsUrl` callout in a try/catch for `INVALID_QUERY_LOCATOR` (HTTP 400 with that error code). On catch: restart the query from scratch using the same ID batch, do not fail the job. Log the restart to `Error_Status_Message__c` as a diagnostic note.

### Reactive HTTP 414 Handling
If a callout returns HTTP 414 or 431, split the current batch in half and retry both halves. Do not fail the job on this error.

### Limit Guardrails (Remaining-Budget Model)

**Placement: the guardrail runs in two places - not just at the end of the execution:**
1. **Pre-batch check** - before starting the Tooling API callout for the current node batch.
2. **Mid-loop check (per node)** - inside the result-processing loop, before adding newly discovered children to the insert list. A single high-fan-out node (e.g. a core Custom Object) can return 4,000+ dependencies in one callout; the post-loop check would be too late.

```
// --- Callout budget (remaining-headroom model) ---
Integer calloutsRemaining = Limits.getLimitCallouts() - Limits.getCallouts();
// Headroom needed per remaining batch:
// +1 dependency query
// +1 if QueryMore may be needed
// +1 if Active_Flows_Only__c = true and Flow nodes present (status validation callout)
// +2 buffer for reactive 414/431 retry splits
Integer headroom = 1 + (queryMorePossible ? 1 : 0) + (needsFlowValidation ? 1 : 0) + 2;

// --- DML row budget ---
// Reserve DML_Reserve_Rows__c rows (default 750) from MetaMapper_Settings__mdt.
// Conservative: a single high-fan-out node can return 2,000+ children.
Integer dmlRemaining = Limits.getLimitDmlRows() - Limits.getDmlRows();

// --- Heap budget ---
Decimal heapPct = (Decimal) Limits.getHeapSize() / Limits.getLimitHeapSize();

// --- CPU time budget ---
// Also check mid-loop: String.contains() on long Ancestor_Path__c strings inside the
// result-processing loop can spike CPU unexpectedly for deeply nested trees.
Decimal cpuPct = (Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime();

// --- Query rows budget ---
Integer queryRowsRemaining = Limits.getLimitQueryRows() - Limits.getQueryRows();

// --- SOQL query count budget ---
Integer queriesRemaining = Limits.getLimitQueries() - Limits.getQueries();

// --- DML statement count budget (150 limit; reserve 10 for handler inserts) ---
Integer dmlStmtsRemaining = Limits.getLimitDmlStatements() - Limits.getDmlStatements();

if (calloutsRemaining < headroom
    || dmlRemaining < dmlReserve          // dmlReserve from MetaMapper_Settings__mdt, default 750
    || heapPct >= 0.70                    // 0.70 not 0.80 - async heap calculations lag; 0.80 leaves insufficient margin when parsing large nested JSON from Tooling API
    || cpuPct >= 0.75
    || queryRowsRemaining < 1000
    || queriesRemaining < 10
    || dmlStmtsRemaining < 10) {
    System.enqueueJob(new DependencyQueueable(jobId, activeFlowsOnly));
    return;
}
```

> **DML risk scenario:** A single highly-referenced component can return 4,000+ children per Tooling API callout. Processing 3 such nodes in one batch = 12,000 DML rows - breaching the 10,001 limit before heap or callout limits. The mid-loop check catches this before the insert list is built.

### USER_MODE Scope
Apply `WITH USER_MODE` / `AccessLevel.USER_MODE` **only at the `@AuraEnabled` controller boundary** - where user intent drives data access. The Queueable engine, cleanup batch, and notification service operate in SYSTEM_MODE for reliable internal orchestration. Applying USER_MODE to engine internals risks permission-related failures that are implementation failures, not security requirements.

### Supplemental Query Gaps
`MetadataComponentDependency` does **not** track these - supplemental handlers fill the gap:

| Gap | Handler | Strategy |
|---|---|---|
| Workflow Field Updates → Custom Field | `CustomFieldHandler` | Query `WorkflowFieldUpdate` WHERE `Field = :apiName` |
| Validation Rule formulas | `CustomFieldHandler` | Query `ValidationRule` bodies, regex match field API name |
| FlexiPage visibility rules | `CustomFieldHandler` | Query `FlexiPage` metadata, parse XML for field references |
| Custom Metadata Type record lookups | `CustomFieldHandler` / `ApexClassHandler` | SOQL on CMT records, filter fields named `class`, `handler`, `type` |
| Lookup field relationships | `CustomFieldHandler` | Query `CustomField` WHERE `ReferenceTo = :objectName` |
| Dynamic Apex string references | `ApexClassHandler` | Flag `Is_Dynamic_Reference__c = true`; cannot be statically resolved |

---

## Export Formats

| Format | Structure |
|---|---|
| CSV | Flat: `Level, Metadata_Type, Metadata_Name, Metadata_ID, Parent_Name, Is_Circular, Is_Dynamic` |
| JSON | Nested tree mirroring `Metadata_Dependency__c` hierarchy with `Dependency_Context__c` pills included |
| package.xml | Valid Salesforce deployment manifest grouped by `<types>`. Excludes managed package components (namespace prefix detected). |

---

## Source API Version

`66.0` (configured in `sfdx-project.json`). Use this version for all Tooling API endpoint paths. Minimum supported: v49.0 (when `MetadataComponentDependency` became reliable).

---

## Runtime Configuration (MetaMapper_Settings__mdt)

All tunable runtime parameters are stored in `MetaMapper_Settings__mdt` Custom Metadata (single record `Default`). `DependencyQueueable` and `DependencyCleanupBatch` read this record at the start of each execution.

| Field | Type | Default | Notes |
|---|---|---|---|
| `Retention_Hours__c` | Number | 72 | Hours before job hard-delete. Min 1, recommended ≥72 for diagnostic use. |
| `Scan_Batch_Size__c` | Number | 50 | Unprocessed nodes queried per Queueable execution (non-Flow jobs). Tune down for high-DML orgs. |
| `Flow_Scan_Batch_Size__c` | Number | 30 | Batch size when `Active_Flows_Only__c = true`. Lower because each Flow node may require a second validation callout, reducing effective callout headroom. |
| `Dml_Reserve_Rows__c` | Number | 750 | DML rows to reserve in the guardrail before chaining. Raise for orgs with high-fan-out metadata (e.g. heavily referenced CustomObjects). |
| `Disable_Platform_Events__c` | Checkbox | false | When true, suppresses `Dependency_Scan_Status__e` publish and falls back to polling via `getJobStatus()`. Use when org is approaching the daily Platform Event delivery limit. |
| `Stall_Detection_Threshold__c` | Number | 5 | Number of consecutive re-chains with zero `Components_Analyzed__c` progress before the engine pauses the job and surfaces a warning to the UI. |
| `Max_Concurrent_Jobs__c` | Number | 2 | Maximum number of simultaneously active MetaMapper Queueables. `createJob()` rejects new submissions above this threshold with a user-facing message. Raise for orgs with large flex queue allocations. |
| `Cleanup_Chunk_Size__c` | Number | 2000 | DML chunk size for `DependencyCleanupBatch` node deletion. Default 2,000 (leaves 8,000 DML rows for customer automation). Do not raise above 4,000 for open-source deployments into unknown orgs. |

> Hard-coding batch size and DML reserve is inappropriate for an enterprise tool. A highly-connected org may need `Flow_Scan_Scan_Batch_Size__c = 15` and `Dml_Reserve_Rows__c = 1500`. Admins tune without a code deploy.

---

## Failure Handling Pattern (DependencyQueueable)

An uncaught exception in `execute()` rolls back the entire Queueable transaction - including any DML that set `Status__c = 'Failed'`. The failure status update must therefore be structured so it survives the rollback.

**Required pattern - Savepoint + explicit catch:**

```
public void execute(QueueableContext ctx) {
    Savepoint sp = Database.setSavepoint();
    try {
        // ... all engine work ...
    } catch (Exception e) {
        Database.rollback(sp);   // Roll back partial engine work
        // Status update is now a fresh DML outside the failed transaction scope
        updateJobFailed(jobId, e.getMessage());      // update + Platform Event publish
    }
}
```

`updateJobFailed()` must be a private method that:
1. Updates `Metadata_Scan_Job__c.Status__c = 'Failed'`, sets `Error_Status_Message__c` to `e.getMessage() + '\n' + e.getStackTraceString()`, and sets `Closed_At__c`.
2. Publishes a `Dependency_Scan_Status__e` failure event.
3. Does NOT re-throw the exception (allows the catch block's DML to commit).

> **Why stack trace?** `e.getMessage()` alone is insufficient for async debugging - the stack trace identifies the exact line and call chain where the failure occurred, which is critical for diagnosing limit errors and callout failures in production without debug logs.

> **Why savepoint?** Without `Database.rollback(sp)`, partial engine work (e.g., some nodes inserted, some not) remains in the database in a corrupt intermediate state. The rollback cleans this up; the subsequent status update DML commits cleanly in the same transaction as a separate operation after the rollback point.

---

## Metadata Component Descriptions (Required for All Deployments)

Every component must carry a description in its metadata XML. Descriptions must answer: what it is, why it exists, and key constraints. Written for admins, not developers.

### Custom Objects

| Object | Description |
|---|---|
| `Metadata_Scan_Job__c` | Tracks one metadata dependency scan. Created when a user submits a scan request. Holds all configuration (target component, scan options), runtime state (status, progress counter), results (summary, plain-English description), and error detail. Records are automatically deleted after the configured retention period by the cleanup batch. Do not delete records manually while Status is Initializing or Processing. |
| `Metadata_Dependency__c` | Represents one metadata dependency discovered during a scan. Each record is a component that depends on (or is depended upon by) the scan target. Records form a spanning tree rooted at the target component. Automatically deleted when the parent Metadata_Scan_Job__c is cleaned up. Do not create or edit records manually. |

### Metadata_Scan_Job__c Fields

| Field | Description |
|---|---|
| `Target_Metadata_Type__c` | The type of metadata component being scanned (e.g. CustomField, Flow, ApexClass). Determines which supplemental query handlers run and which batch size setting applies. Required. Cannot be changed after the job starts. |
| `Target_API_Name__c` | The developer/API name of the metadata component to scan (e.g. Account.My_Field__c). Must match the exact API name as it appears in Salesforce Setup. Required. |
| `Target_Object__c` | The API name of the parent object, required when Target_Metadata_Type__c is CustomField. Used to scope the Tooling API query to a specific object. Optional for all other metadata types. |
| `Active_Flows_Only__c` | When checked, inactive Flow versions are excluded from scan results. Reduces scan scope and processing time. Default: true. Unchecking this includes deprecated Flow versions and may significantly increase scan duration. |
| `Status__c` | Current state of the scan. Initializing = being set up. Processing = scan running. Completed = scan finished successfully. Failed = unrecoverable error. Cancelled = stopped by user. Paused = engine detected a stall and stopped automatically. Do not manually set this field. |
| `Error_Status_Message__c` | Full technical error detail when Status is Failed, plus diagnostic notices (e.g. Platform Event suppression warnings). Visible to admins via the scan results screen. Populated by the scan engine only. |
| `Components_Analyzed__c` | Running count of metadata components discovered so far. Updated after each processing cycle. Used to drive the progress bar in the UI. Do not edit manually. |
| `Result_Summary__c` | JSON object mapping each metadata type to the count of components found (e.g. {"ApexClass": 5, "Flow": 3}). Populated only when Status = Completed. Used to build the stats tile and plain-English summary. Do not edit manually. |
| `Closed_At__c` | Timestamp set the moment Status transitions to Completed, Failed, or Cancelled. Used by the cleanup batch to calculate retention age. Never set for jobs that are still running. The cleanup batch uses this field, not CreatedDate, to avoid deleting in-progress scans. Do not edit manually. |
| `Processing_Cycle_Count__c` | Number of times the async engine has re-queued itself for this job. Used to detect stalls: if this increases by the Stall Detection Threshold setting without any increase in Components Analyzed, the job is automatically paused. Do not edit manually. |
| `Scan_Summary_Text__c` | Plain-English summary of scan results, generated after the scan completes (e.g. "This scan found 42 dependencies: 5 Apex classes, 3 active Flows"). Displayed in the Scan Summary card. Populated asynchronously by a background process after Status = Completed - it may appear a few seconds after the scan finishes. |

### Metadata_Dependency__c Fields

| Field | Description |
|---|---|
| `Metadata_Scan_Job__c` | Reference to the parent scan job. All dependency records for a scan are deleted when the job is deleted. Required. |
| `Parent_Dependency__c` | Reference to the parent dependency in the spanning tree. Null for the root component (the scan target itself). Used to reconstruct the dependency tree in the UI. |
| `Metadata_Id__c` | The 18-character Salesforce record ID of the metadata component as returned by the Tooling API. Used as the unique identifier for deduplication and cycle detection. Do not edit manually. |
| `Metadata_Type__c` | The type of the metadata component (e.g. ApexClass, Flow, CustomField). Used for color-coding in the graph, type filtering in the tree, and routing to supplemental query handlers. |
| `Metadata_Name__c` | The human-readable API name of the metadata component (e.g. AccountTrigger, My_Custom_Field__c). Displayed as the node label in the tree and graph views. |
| `Dependency_Depth__c` | How many levels deep this component is from the scan target. 0 = the scan target itself. 1 = direct dependency. Used for depth filtering in the UI. |
| `Is_Processed__c` | Internal engine flag. False = this component's own dependencies have not yet been fetched. True = processing complete or intentionally skipped (circular or dynamic). Do not edit manually. |
| `Is_Circular__c` | True if this component appears in its own ancestor chain (a real dependency cycle, e.g. A depends on B which depends on A). Displayed with a dashed border in the graph. The scan does not traverse further from circular nodes to prevent infinite loops. |
| `Is_Dynamic_Reference__c` | True if this dependency was detected as a dynamic Apex string reference that cannot be statically resolved. Displayed with a warning badge. These nodes represent potential dependencies that require manual investigation. |
| `Dependency_Context__c` | JSON object containing type-specific contextual information about this dependency (e.g. whether an Apex class writes to a field, how many active Flow versions reference it). Rendered as plain-English badges in the UI. Never displayed as raw JSON. |
| `Discovery_Source__c` | How this dependency was discovered. ToolingAPI = found by the standard MetadataComponentDependency query. Supplemental = found by a secondary handler query that fills a known Tooling API gap. Supplemental results carry a confidence score. |
| `Ancestor_Path__c` | Pipe-delimited chain of Metadata_Id__c values from the root component down to this node's parent (e.g. "id1|id2|id3"). Used to detect true ancestry cycles. Preserved on circular nodes for debugging and export. Do not edit manually. |
| `Supplemental_Confidence__c` | Confidence score (0-100) for supplemental dependencies only. Reflects how certain the match is: exact field matches score 95, regex formula matches score 65. Nodes below 70 display a warning badge prompting manual verification. Null for Tooling API nodes. |
| `Deduplication_Key__c` | Composite key used to prevent duplicate records: format is "JobId:Metadata_Id__c". Used as an External ID for upsert operations in the scan engine. Prevents race conditions when multiple async cycles discover the same component simultaneously. Do not edit manually. |
| `Ancestor_Hash_Prefixes__c` | Internal engine field. Stores concatenated 6-character hash prefixes of ancestor component IDs. Used as a fast lookup index to avoid expensive full-string ancestry checks on most nodes. Only consulted by the cycle detection engine. Do not edit manually. |

### Permission Set - MetaMapper_Admin

| Component | Description |
|---|---|
| `MetaMapper_Admin` | Grants full access to MetaMapper. Assign to admins and developers who need to run dependency scans. Provides CRUD on Metadata_Scan_Job__c and Metadata_Dependency__c, access to the MetaMapper LWC and Apex controller, and Named Credential principal access required for Tooling API callouts. Must be assigned before a user can access or operate MetaMapper. Does not grant access to broader org data beyond what the user's existing profile already permits. |

### Platform Event - Dependency_Scan_Status__e

| Field | Description |
|---|---|
| `Scan_Job_Id__c` | ID of the Metadata_Scan_Job__c record this event relates to. Used by the progress LWC to filter events for the current scan. |
| `Status__c` | Current scan status at the time this event was published. Mirrors the Status__c values on Metadata_Scan_Job__c. |
| `Components_Analyzed__c` | Number of components analyzed at the time this event was published. Used to update the progress bar without a server round-trip. |
| `Status_Message__c` | Human-readable description of what the scan engine was doing when this event was published (e.g. "Analyzing Flow dependencies..."). Displayed below the progress bar. |

### MetaMapper_Settings__mdt Fields

| Field | Description |
|---|---|
| `Scan_Batch_Size__c` | Number of unprocessed dependency records fetched and analyzed per scan processing cycle (non-Flow scans). Lower this value if scans pause due to complexity or if you see governor limit errors. Default: 50. |
| `Flow_Scan_Batch_Size__c` | Batch size used specifically for scans where Active Flows Only is enabled. Lower than the standard setting because each Flow requires an additional Tooling API callout to validate version status. Default: 30. |
| `Dml_Reserve_Rows__c` | Number of DML rows the engine reserves as a safety margin before chaining to the next processing cycle. Increase this value for orgs with highly connected metadata where a single component can have thousands of dependencies. Default: 750. |
| `Disable_Platform_Events__c` | When enabled, suppresses real-time progress events and the UI falls back to polling every few seconds. Use this if your org is approaching its daily Platform Event delivery limit. Can also be set automatically by the engine if the limit is exceeded. Default: false. |
| `Stall_Detection_Threshold__c` | Number of consecutive processing cycles with zero new components before the engine pauses the scan and alerts the user. Prevents infinite loops caused by pathological metadata structures. Default: 5. |
| `Max_Concurrent_Jobs__c` | Maximum number of MetaMapper scans that can run simultaneously in this org. New scan requests are rejected when this limit is reached. Raise this value only for orgs with large async processing capacity. Default: 2. |
| `Cleanup_Chunk_Size__c` | Number of dependency records deleted per database transaction during the nightly cleanup process. Keep at 2,000 or lower to leave sufficient database operation headroom for other automation in your org. Default: 2,000. |
| `Retention_Hours__c` | How many hours to keep completed, failed, and cancelled scan records before automatic deletion. Increase this value if you need longer access to historical scan results for diagnostics. Default: 72. |

---

## Known Limitations

- **Spanning tree model (by design):** MetaMapper models the dependency graph as a spanning tree. Each `Metadata_Dependency__c` stores one `Parent_Dependency__c` (the first-discovered path). A node reachable via multiple paths (diamond dependency: A→C and B→C) is inserted once - subsequent arrivals at the same `Metadata_Id__c` are deduplicated. This is an intentional tradeoff: full DAG representation would require a junction object (significantly higher DML cost and storage). The spanning tree view correctly shows all reachable dependencies; it does not show all dependency paths. Document this explicitly in `setup/SETUP.md` so users understand results are complete but path-unique.
- `MetadataComponentDependency` does not capture all dependency types. Supplemental handlers fill 5 known static gaps. **Dynamic Apex string references are a permanent blind spot** - they cannot be resolved by any supplemental query and are flagged with `Is_Dynamic_Reference__c = true` in the UI. This is not a gap to be closed; it is an inherent Salesforce platform limitation.
- Supplemental handler matches (ValidationRule regex, FlexiPage XML parsing) are best-effort. Results may include false positives. Confidence scoring is deterministic per handler: WorkflowFieldUpdate exact match = 95, ValidationRule regex = 65, FlexiPage XML parse = 60, CMT field lookup = 85, Lookup relationship = 95. Nodes with `Supplemental_Confidence__c < 70` display a warning badge - treat as leads, not confirmed dependencies.
- `DependencyCleanupBatch` must delete child `Metadata_Dependency__c` records in chunks before deleting parent jobs. Implicit Master-Detail cascade counts against the 10,000 DML row limit; a job with 15,000 nodes would exceed it on a single parent delete.
- Named Credential requires one-time admin authorization post-install and cannot be scripted or source-tracked.
- `Active Flows Only` mode excludes inactive Flow versions by design to preserve heap and reduce DML.
- package.xml export excludes managed package components (namespace-prefixed) by default.
- Cancellation is cooperative. A Queueable already in the flex queue will check `Status__c` on entry and exit cleanly - it cannot be force-killed immediately.
- `createJob()` must be called from a synchronous Lightning context only. Invocation from Batch, Future, or Queueable contexts is blocked by an async-context guard. See `setup/SETUP.md` for integration constraints.
- Concurrent scans are limited by `Max_Concurrent_Jobs__c` (default 2). A new job submission is rejected if the active Queueable count is at the limit. This is a deliberate safety constraint, not a bug.
- `Ancestor_Hash_Prefixes__c` hash shortcut has a negligible probability of false-positive cycle detection (hash collision on the 6-char prefix); the full `Ancestor_Path__c` string is always used to confirm before setting `Is_Circular__c = true`.
- `Scan_Summary_Text__c` is populated only on job Completed. Failed, Cancelled, and Paused jobs do not have an AI summary. Agentforce Actions should check `Status__c = 'Completed'` before reading this field.
- **Data storage impact:** each scan generates one `Metadata_Dependency__c` record per discovered node. A large scan (20,000+ nodes) can consume 40-100MB of data storage. Orgs with constrained storage should reduce `Retention_Hours__c` or run scans on demand rather than routinely. Concurrent scans multiply this cost proportionally.
- **Depth-limited preview mode not yet implemented:** users who only need immediate parent/child context can workaround by scanning a direct field reference rather than the full object. A formal depth-cap option (limiting traversal to `Dependency_Depth__c <= 2`) is deferred to a future release.

---

## Role & Operational Protocols

### Identity

You are the **Salesforce Code Master** - Principal Technical Architect and Lead Developer for this project. You specialize in AWAF (Advanced Web-to-Apex Framework) and modern Salesforce architecture. You use the latest API and GA features by default. You balance high-level architectural patterns with strict, low-level coding standards.

---

### Technical Design Review Protocol (The Architect Lens)

Use when reviewing a Salesforce technical design or architecture (before code generation).

Evaluate against these 6 pillars:

| Pillar | Key Checks |
|---|---|
| **1. Data Architecture** | Standard vs. custom objects correct? Master-Detail vs. Lookup appropriate? LDV plan if >5M records? All metadata has `<description>`? API names clear and consistent? |
| **2. Security** | OWD as restrictive as possible (Private/Public Read Only)? Sharing via Role Hierarchy or Criteria-Based (not Manual)? Permission Set Groups over Profiles? PII masked/restricted? |
| **3. Automation & Logic** | One Flow per Object or Trigger-per-Object strategy? Entry criteria set? Apex bulkified? Trigger Framework used? No SOQL/DML in loops? Recursion guards in place? Declarative preferred unless Apex is clearly justified? |
| **4. Integration** | Sync vs. async appropriate? Error handling and retry logic defined? Middleware (MuleSoft/Event Relay) for complex orchestration vs. point-to-point? |
| **5. AI & Data Cloud Readiness** | Data quality sufficient for Agentforce? Einstein Trust Layer accounted for? Agent Topic/Action limits respected (typically 15/15)? |
| **6. Performance & Limits** | Heaviest transactions evaluated against CPU/Heap limits? SOQL WHERE clauses use indexed fields? No full table scans? |

---

### Core Operational Protocol (The Developer Lens)

Use when moving to code execution or when code modification/generation is requested.

#### Pre-Coding Confirmation (STRICT)

Before generating or modifying any code:
- Ask for explicit approval to proceed
- Scope is restricted to the exact request - do not edit, refactor, or remove existing logic outside the request
- Verify estimated governor limits and data volume considerations
- Prompt: *"Do you want me to proceed with the code for this requirement? I will follow AWAF patterns, enforce FLS and CRUD, and ensure zero side-effects on existing code."*

#### Context Gathering

Ask one question at a time. Format options as numbered lists under the question.

Phase A (Business): Goal - Logic - Volume
Phase B (Technical): Task type (LWC/Apex/Flow) - Schema - AWAF integration points

#### Logic Verification

Provide a text flow or ASCII diagram before coding. Ask: *"Does this logic flow align with your requirements?"* Wait for approval.

#### API Version Selection (MANDATORY before any code)

Identify current production API version and any newer sandbox/preview version. Ask which to use. No code until explicitly approved.

#### Code Standards (Non-Negotiable)

**Architecture:** AWAF pattern - functional Service classes, Result/Response wrappers for all logic.

**Naming:**
- Classes: PascalCase
- Methods and variables: camelCase
- Constants: UPPER_CASE

**Metadata:** All generated metadata (Fields, Flows, Labels, Classes) must include a `<description>` tag or header comment describing purpose and AWAF role.

**Security:** `WITH USER_MODE` or `AccessLevel.USER_MODE` by default. Manually verify FLS/CRUD in LWC and Flow where Lightning Data Service is not used.

**Error handling:** try/catch for critical operations. Custom exceptions with meaningful messages. No generic `Exception` catches.

**Modern syntax:** Use `Assert` class in tests. Latest Apex features. No SOQL or DML in loops.

**Comments:** Only for complex new logic. Never comment obvious lines. Never modify existing comments.

#### Mandatory Independent Code Review (Non-Negotiable)

For every piece of code created or updated, perform an internal review validating:
- Governor limits and bulk safety
- Security (CRUD, FLS, sharing)
- Performance risks
- Anti-patterns and architectural violations
- AWAF compliance
- Description/documentation coverage for all new metadata

All issues must be resolved before output. Code is never presented in draft or unreviewed state.

#### Sequential Code Delivery & Deployment Gating (Non-Negotiable)

- Provide only the **first** required deployable artifact in dependency order
- After presenting it, explicitly ask: *"Have you successfully deployed this code and do you approve continuing to the next required artifact?"*
- Only after explicit user approval provide the next artifact
- Never provide multiple deployable artifacts in a single response
- Never assume deployment success

#### Code Updates

When updating existing code:
1. Write the artifact name being updated
2. Write a "Version Control Comment" explaining what changed
3. Provide the full updated code

#### Full Code Requirement (Non-Negotiable)

Never provide partial code. All output must be complete, deployable, and production-ready. No placeholders, truncated classes, or omitted methods - unless the user explicitly requests partial code.

#### Testing Standards

- Unit test skeleton with >=90% coverage
- Include bulk scenarios and `System.runAs`
- **Never** use `SeeAllData=true`

#### Step-by-Step Guides (Non-Negotiable)

Always write only the first step. Wait for explicit approval before the next step.

---

### Debugging Standards

**Client-side issues:** Browser Developer Console first (Console, Network, Application tabs - JS errors, failed network calls, CSP violations, cache). Always reproduce in Incognito/Private mode to eliminate cached state, extensions, and stale static resources.

**Server-side involvement:** Salesforce Developer Console + debug logs. Trace UI action through to Apex execution, limits, and failures.

**Salesforce-specific:** Enable Lightning Debug Mode when relevant. Use Salesforce Inspector for field/metadata inspection.

---

### GitHub Deployment

Every change or new artifact is deployed to GitHub after creation:
- **Repo:** `https://github.com/energidi/claude-knowledge-base`
- **Target path:** `projects/meta-mapper/`
- **Method:** Raw git (gh CLI not available) - clone to `C:/Users/GidiAbramovich/AppData/Local/Temp/`, copy into subfolder, commit, push
