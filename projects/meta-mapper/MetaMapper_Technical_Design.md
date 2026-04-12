# MetaMapper - Technical Design

**Version:** 13.0  
**Date:** 2026-04-12  
**Status:** Phase 3 implementation in progress

---

## Overview

MetaMapper is an open-source, 100% native Salesforce application that maps reachable metadata dependencies using the Tooling API. For each component it discovers, it stores one representative path (the first path found during traversal - spanning tree model). It targets enterprise/LDV orgs where synchronous Governor Limits are a hard constraint. All runtime data stays within the Salesforce trust boundary - no external APIs, no CDN calls.

---

## Architecture

### Processing Model

The core challenge: enterprise org metadata trees are too large for synchronous Apex (10s CPU, 6MB synchronous heap). Async Queueable context provides 12MB heap and no CPU hard timeout - but governor limits still apply per execution. The solution is a Queueable chain + Custom Object state machine:

1. User submits a search via LWC. An `@AuraEnabled` controller creates a `Metadata_Scan_Job__c` record, inserts the root `Metadata_Dependency__c`, and enqueues `DependencyQueueable`.
2. Each `DependencyQueueable` execution queries a batch of unprocessed nodes (`Dependencies_Fetched__c = false`), calls the Tooling API via Named Credential, inserts new child nodes, marks current nodes processed, and checks limit proximity.
3. When the remaining callout budget drops below a safe threshold, it self-enqueues a fresh instance and exits. The guardrail uses a remaining-callout budget model (not percentage alone): reserve explicit headroom for QueryMore follow-ups, Flow status validation, and retry splits. Chain when `remaining < headroom`.
4. When no unprocessed nodes remain, `DependencyQueueable` enqueues `ResultSerializerQueueable` and exits. The serializer serializes all node records to a Salesforce File, deletes the node records to free Data Storage, enforces the ring buffer, transitions the job to `Completed`, and fires notifications.

### Tooling API Callout (Loopback Auth)

Direct Tooling API calls from within async Apex require a Named Credential loopback:
- Connected App + Auth Provider configured in the org
- Named Credential `MetaMapper_Tooling_API` authorized once by admin post-install
- Callout target: `callout:MetaMapper_Tooling_API/services/data/v66.0/tooling/query/?q=...`
- These three config items cannot be source-tracked; setup instructions live in `setup/SETUP.md`

### Cycle Detection (Two-Tier)

A single global visited set incorrectly flags shared/diamond dependencies as circular. Two separate concerns are handled independently:

**Tier 1 - Global deduplication (`processedIds`):**  
After the Tooling API returns results for the current batch, query the DB scoped to only those returned IDs:
```
SELECT Metadata_Id__c FROM Metadata_Dependency__c
WHERE Metadata_Scan_Job__c = :jobId AND Metadata_Id__c IN :currentResultIds
```
If a result ID is already in this set, skip insertion (deduplication). Do NOT mark as circular.

**Tier 2 - True ancestry cycle detection (`Ancestor_Path__c`):**  
Each `Metadata_Dependency__c` stores a pipe-delimited `Ancestor_Path__c` chain. Cycle check uses delimiter-safe containment: `('|' + parent.Ancestor_Path__c + '|').contains('|' + newNodeId + '|')`. A raw `String.contains(id)` is vulnerable to false positives where one 18-char ID is a substring of another.

- **Root node:** `Ancestor_Path__c = ''` (empty string).
- **Path building:** `child.Ancestor_Path__c = (String.isBlank(parent.Ancestor_Path__c) ? '' : parent.Ancestor_Path__c + '|') + parent.Metadata_Id__c`
- **Circular node:** keep full `Ancestor_Path__c`, set `Is_Circular__c = true`, `Dependencies_Fetched__c = true`. Append `{"cycleClosesAt": "<parentMetadataId>"}` to `Component_Attributes__c`.
- **Depth guard:** before building path for any child, check if `(parent.Ancestor_Path__c?.length() ?? 0) + 20 > 32000`. If true, mark child as circular and log to `Error_Status_Message__c`.

### Cancellation

`DependencyQueueable` checks `Status__c` as the first operation in `execute()`. If `Status__c = 'Cancelled'`, it exits immediately without enqueuing a successor. Cancellation is cooperative - queued Queueables check on entry and terminate; there is no force-kill mechanism in Salesforce.

### Async Context Guard

`createJob()` validates `!System.isQueueable() && !System.isBatch() && !System.isFuture()` and throws a descriptive exception if called from an unsupported async context.

### Concurrency Guard

`createJob()` checks active Queueable count before accepting a new job:
```java
Integer activeQueueables = [
    SELECT COUNT() FROM AsyncApexJob
    WHERE JobType = 'Queueable'
    AND ApexClass.Name = 'DependencyQueueable'
    AND Status IN ('Processing', 'Preparing')
];
```
Rejects with user-facing message if count >= `Max_Concurrent_Jobs__c` (default 2).

### Live Progress (Platform Events)

`DependencyQueueable` publishes exactly one `Dependency_Scan_Status__e` event per execution - after the final DML commit, not after each inner loop iteration. The `metaMapperProgress` LWC subscribes via `lightning/empApi` on mount and unsubscribes on destroy.

**Dynamic Platform Event degradation:**  
`DependencyNotificationService.publishProgress()` checks `OrgLimits.getMap().get('DailyStandardVolumePlatformEvents')` before each publish. If >80% consumed, suppresses the event and flips `Disable_Platform_Events__c = true` on the CMDT Default record via `Metadata.Operations.enqueueDeployment()`.

### Graph Visualization

`metaMapperGraph` loads Apache ECharts from the `ECharts` Static Resource (no CDN). Receives a flat node list and builds the ECharts `graph` series client-side using `Parent_Dependency__c` to derive edge links. Node color keyed to `Metadata_Type__c`.

**Static Resource build:** use `echarts/dist/echarts.min.js` (core minified build, ~1.0-1.2MB). Do not use the full bundle - it includes maps and 3D features and risks exceeding Salesforce's 5MB static resource limit.

### Security Model

- OWD: `Metadata_Scan_Job__c` = Private
- `@AuraEnabled` controller methods use `WITH USER_MODE` / `AccessLevel.USER_MODE`
- Async engine classes (`DependencyQueueable`, `ResultSerializerQueueable`, `DependencyCleanupBatch`, `DependencyNodeCleanupBatch`) operate in SYSTEM_MODE for reliable internal orchestration
- `ContentVersion.FirstPublishLocationId = jobId`. After auto-creation of `ContentDocumentLink`, `ResultSerializerQueueable` queries it and sets `ShareType = 'V'`, `Visibility = 'InternalUsers'`
- Permission Set `MetaMapper_Admin` grants CRUD on both custom objects, Named Credential principal access, and LWC/controller access

### Data Lifecycle

MetaMapper uses a hybrid ContentVersion model. Node records exist only during the active scan.

**On-Completed Serialization:**  
When no unprocessed nodes remain, `DependencyQueueable` enqueues `ResultSerializerQueueable`. The serializer:
1. Queries all `Metadata_Dependency__c` records for the job
2. Serializes to JSON
3. Creates `ContentVersion` with `FirstPublishLocationId = jobId`
4. Requeries `ContentDocumentId` from the inserted `ContentVersion` (not available directly on the record)
5. Updates `Result_File_Id__c`
6. Computes `Result_Summary__c`
7. Bulk-deletes all node records via `DependencyNodeCleanupBatch(jobId, NODES_ONLY)`
8. Transitions job to Completed
9. Enforces ring buffer
10. Enqueues `ScanSummaryQueueable`

**Ring Buffer:**  
`Max_Stored_Jobs__c` (default 5) limits completed jobs retained org-wide. Deletion query uses `FOR UPDATE` to serialize concurrent completions: `[SELECT Id FROM Metadata_Scan_Job__c WHERE Status__c = 'Completed' ORDER BY Status_Closed_At__c ASC, Id ASC LIMIT 1 FOR UPDATE]`.

**Nightly Cleanup:**  
`DependencyCleanupBatch` targets only Failed and Cancelled jobs older than `Retention_Hours__c`. Never deletes Completed (ring buffer), Initializing, Processing, or Paused jobs.

---

## Data Model

### Metadata_Scan_Job__c

| Field | Type | Notes |
|---|---|---|
| `Target_Metadata_Type__c` | Picklist | CustomField, ValidationRule, Flow, ApexClass, ApexTrigger, WorkflowRule, etc. |
| `Target_API_Name__c` | Text 255 | Developer Name of the target metadata |
| `Target_Object__c` | Text 255 | Optional - required when type = CustomField |
| `Active_Flows_Only__c` | Checkbox | Default true - drops inactive Flow versions |
| `Status__c` | Picklist | Initializing, Processing, Completed, Failed, Cancelled, Paused |
| `Error_Status_Message__c` | Long Text 32768 | Full exception on failure + diagnostic notices |
| `Components_Analyzed__c` | Number | Running counter for progress bar |
| `Result_Summary__c` | Long Text 32768 | JSON map `{MetadataType: count}` - populated on Completed |
| `Status_Closed_At__c` | DateTime | Set when Status = Completed, Failed, or Cancelled. Not set on Paused. Used by cleanup batch. |
| `Total_Processing_Cycles__c` | Number | Incremented on every Queueable execution |
| `Last_Successful_Cycle__c` | Number | Value of `Total_Processing_Cycles__c` at last execution where `Components_Analyzed__c` increased. Persisted (survives Queueable self-chain boundaries). Stall condition: `Total - Last >= Stall_Detection_Threshold__c`. |
| `Scan_Summary_Text__c` | Long Text 32768 | Plain-English summary populated by `ScanSummaryQueueable` after Completed. Null until populated. |
| `Result_File_Id__c` | Text 18 | ContentDocumentId of completed scan result JSON. Null during active scans. |
| `Batch_Size_Override__c` | Number | Job-specific batch size override set by `resumeJob()`. Not reset after use. |
| `Last_Result_Count__c` | Number | Rows returned by most recent Tooling API callout. Used to determine `queryMorePossible` (>= 1,900). |

> `Visited_IDs__c` removed. 131,072-char Long Text caps at ~5,957 IDs. Cycle detection uses two-tier logic instead.

### Metadata_Dependency__c

> Records exist only during active scans. On Completed, serialized to `ContentVersion` JSON and deleted. File Storage impact: ~1-3MB per job. Data Storage impact for completed jobs: ~5KB (job record only).

| Field | Type | Notes |
|---|---|---|
| `Metadata_Scan_Job__c` | Master-Detail | Cascade delete |
| `Parent_Dependency__c` | Lookup (self) | Root node has null. Self-referential bulk DML: insert root first, commit, then bulk-upsert children. |
| `Metadata_Id__c` | Text 18 | Exact 18-char Tooling API ID |
| `Metadata_Type__c` | Text 50 | e.g. ApexClass, CustomField, Flow |
| `Metadata_Name__c` | Text 255 | Human-readable API name |
| `Dependency_Depth__c` | Number | Depth from root (0 = root target) |
| `Dependencies_Fetched__c` | Checkbox | false = pending traversal; true = fetched or intentionally skipped |
| `Is_Circular__c` | Checkbox | True only when node's `Metadata_Id__c` appears in its own `Ancestor_Path__c` |
| `Is_Dynamic_Reference__c` | Checkbox | True if reference cannot be statically analyzed |
| `Component_Attributes__c` | Long Text 32768 | JSON pills - type-specific context (see below). Root key `"v": 1` for versioning. |
| `Discovery_Source__c` | Picklist | `ToolingAPI` or `Supplemental` |
| `Ancestor_Path__c` | Long Text 32768 | Pipe-delimited ancestor `Metadata_Id__c` chain. Excludes self. Used for true cycle detection. |
| `Supplemental_Confidence__c` | Number (3,0) | 0-100 confidence score. Null for ToolingAPI nodes. Nodes < 70 show warning badge. |
| `Component_Uniqueness_Key__c` | Text 80 (External ID, Unique) | Composite key: `JobId + ':' + Metadata_Id__c`. Used for upsert dedup. |
| `Cycle_Detection_Index__c` | Long Text 32768 | Pipe-delimited 6-char prefixes of ancestor IDs. Bloom-filter pre-screen; `Ancestor_Path__c` confirms positives. |

### Component_Attributes__c Payloads by Type

| Type | JSON shape |
|---|---|
| ApexClass / ApexTrigger | `{"v": 1, "isWrite": true}` |
| Flow | `{"v": 1, "activeVersions": 3, "isActive": true}` |
| WorkflowRule | `{"v": 1, "isActive": true, "triggerType": "onInsertOrUpdate"}` |
| CustomField | `{"v": 1, "parentObject": "Account", "parentType": "CustomObject"}` |
| Report | `{"v": 1, "filterUsage": ["filter", "grouping", "column"]}` |

### Dependency_Scan_Status__e (Platform Event)

| Field | Type | Notes |
|---|---|---|
| `Scan_Job_Id__c` | Text 18 | Links event to Job record |
| `Status__c` | Text 50 | Mirrors job Status__c |
| `Components_Analyzed__c` | Number | Progress counter |
| `Status_Message__c` | Text 255 | Human-readable status message |

---

## Key Apex Classes

### Interfaces

| Interface | Contract |
|---|---|
| `IMetadataDependencyService` | `fetchDependencies()`, `buildContextData()`, `computeScore()` |
| `IDependencyTypeHandler` | `SupplementalResult findSupplemental(Id jobId, List<Metadata_Dependency__c> nodes)` |
| `INotificationService` | `publishProgress()`, `sendCompletion()` |
| `IMetaMapperSettingsProvider` | `MetaMapper_Settings__mdt getSettings()` - static cache; one SOQL per transaction |

### Selectors

| Selector | Key Methods |
|---|---|
| `DependencyJobSelector` | `getByIdForEngine()`, `getClosedJobsBefore()`, `countActiveQueueables()` |
| `DependencyNodeSelector` | `nextUnprocessed()`, `dedupForResults()`, `listByJob()`, `getResultFile()` |

### Classes

| Class | Role |
|---|---|
| `DependencyJobController` | `@AuraEnabled` (USER_MODE): `createJob()` with async + concurrency + storage + node cap + preflight, `getObjectList()`, `getJobStatus()`, `getNodeHierarchy()`, `cancelJob()`, `resumeJob()` |
| `MetadataDependencyService` | Tooling API SOQL formatting, chunking, QueryMore, Active Flows filter, `buildContextData()`, `computeScore()`. Heap guard: check raw HTTP response string length > 500,000 chars BEFORE `JSON.deserializeUntyped()` |
| `DependencyTypeHandlerFactory` | Returns correct `IDependencyTypeHandler` or no-op default |
| `CustomFieldHandler` | WorkflowFieldUpdate (95), ValidationRule tokenized (65), CMT field value (75). FlexiPage + Lookup deferred. |
| `ApexClassHandler` | CMT class-reference fields (85); all matches flagged `Is_Dynamic_Reference__c = true` |
| `FlowHandler` | Gap notice for SubFlow XML parsing (deferred). No SOQL queries. |
| `MetaMapperDescribeCache` | Transaction-level static cache for CMT `describeSObjects()` data. Shared by all handlers. |
| `MetaMapperSettingsProvider` | Reads and caches `MetaMapper_Settings__mdt` Default record via `getInstance()` |
| `SupplementalResult` | Return type for `IDependencyTypeHandler.findSupplemental()`. Guards `Error_Status_Message__c` overflow via `appendErrorsSafe()`. |
| `DependencyQueueable` | Async engine. Savepoint/catch; cancel check; CMDT read; hot-loop detection; seven-limit guardrail; scoped dedup; two-tier cycle detection; callouts; HTTP 414/431 reactive split (max depth 5); handlers; one PE per execution; self-chain. On completion: enqueues `ResultSerializerQueueable`. |
| `DependencyNotificationService` | `publishProgress()` with OrgLimits PE check + auto-suppress; `sendCompletionNotification()` |
| `ScanSummaryQueueable` | One-shot: reads `Result_Summary__c`, writes `Scan_Summary_Text__c` |
| `ResultSerializerQueueable` | Savepoint/rollback; heap pre-check before `JSON.serialize()`; creates `ContentVersion`; requeries `ContentDocumentId`; computes `Result_Summary__c`; bulk-deletes nodes via `DependencyNodeCleanupBatch(NODES_ONLY)`; ring buffer; enqueues `ScanSummaryQueueable` |
| `DependencyCleanupBatch` | `Database.Stateful`. Discovers Failed/Cancelled jobs past `Retention_Hours__c`. Batch size 10. Max 4 child batch submissions per `finish()`. |
| `DependencyNodeCleanupBatch` | Node deletion. Constructor: `(String jobId, CleanupMode mode)`. `CleanupMode` enum: `NODES_ONLY` / `NODES_AND_JOB`. Batch size = `Cleanup_Chunk_Size__c` (default 2,000). |
| `DependencyCleanupScheduler` | Schedules cleanup at 02:00 |
| `ToolingApiHealthCheck` | Pre-flight callout: verifies Tooling API reachability via Named Credential |

---

## Hot-Loop Backoff Detection

| Field | Purpose |
|---|---|
| `Total_Processing_Cycles__c` | Incremented on every execution |
| `Last_Successful_Cycle__c` | Reset to `Total` whenever `Components_Analyzed__c` increases |

If `Total - Last >= Stall_Detection_Threshold__c` (default 5), transition to `Status__c = 'Paused'`. LWC surfaces: "MetaMapper paused because it encountered a component with extremely deep or wide dependencies."

`resumeJob(String jobId, Integer overrideBatchSize)`: sets `Status__c = 'Processing'`, writes override to `Batch_Size_Override__c`. The Queueable reads this at startup. Does NOT write back to CMDT (job-specific state).

---

## Key LWC Components

| Component | Role |
|---|---|
| `metaMapperApp` | Root shell; owns `jobId` state; switches between input, progress, results views. Pre-flight health check on mount. Deep-link routing via `@wire(CurrentPageReference)`. |
| `metaMapperInput` | Metadata type picklist, API name input, typeahead object lookup (debounced 300ms), Active Flows Only checkbox. Submit button `is-loading` state on click. |
| `metaMapperProgress` | `lightning-progress-bar`. Subscribes to `Dependency_Scan_Status__e`. Falls back to `getJobStatus()` polling if PEs disabled. Cancel button with confirmation modal. |
| `metaMapperResults` | Tab container (Tree View / Graph View). AI Summary card (when Completed). Stats tile. Export controls. |
| `metaMapperTree` | Virtual-rendered SLDS tree. Full-text search, type/level/confidence filters, collapse/expand. Keyboard navigable. |
| `metaMapperGraph` | ECharts force-directed graph. Node click = populates Node Details Panel. Right-click context menu. Hover tooltip (plain English, no raw JSON). Expand All guard (> 1,000 nodes). Focus path to root. Graph toolbar search (Ctrl+K). Spanning tree notice badge. |
| `metaMapperNodeDetailsPanel` | Sidebar. Full node data including `Ancestor_Path__c` as named breadcrumb chain (ID-to-name via in-memory map). "Open in Setup" primary action. "Copy Link" deep-link generator. |
| `metaMapperExport` | CSV, JSON, package.xml exports. All client-side. No server round-trip. Default filename: `MetaMapper_[Target_API_Name]_[YYYYMMDD]_[HHmm]`. |

---

## Query Strategy

### IN Clause Chunking

Start at 100 IDs. Dynamic check: `if (80 + (batchIds.size() * 19) > 8000) { halve batch; }`. Maximum safe batch at this formula: 418 IDs. 100 provides comfortable headroom.

### QueryMore

Follow `nextRecordsUrl` iteratively until `done = true`. Wrap each `nextRecordsUrl` callout in try/catch for `INVALID_QUERY_LOCATOR` (cursor expiry). On catch: restart query from scratch with same ID batch. Log restart to `Error_Status_Message__c`.

### Reactive HTTP 414 Handling

Split batch in half, retry both halves. Track `splitDepth` through retries. Maximum depth: 5 levels. At depth 5, if still 414: mark affected nodes `Dependencies_Fetched__c = true`, log, continue. Do not fail the job.

### Limit Guardrails (Remaining-Budget Model)

Run in two places:
1. **Pre-batch check** - before starting the Tooling API callout
2. **Mid-loop check** - inside the result-processing loop, before adding children to insert list

```java
Integer calloutsRemaining = Limits.getLimitCallouts() - Limits.getCallouts();
Integer headroom = 1 + (queryMorePossible ? 1 : 0) + flowNodeCount + 4;

if (calloutsRemaining < headroom
    || dmlRemaining < dmlReserve          // from MetaMapper_Settings__mdt, default 750
    || heapPct >= 0.70                    // 0.70 - async heap lag; 0.80 insufficient margin
    || cpuPct >= 0.75
    || queryRowsRemaining < 1000
    || queriesRemaining < 10
    || dmlStmtsRemaining < 40) {          // 40 - supplemental handlers consume 8+ DML stmts each
    System.enqueueJob(new DependencyQueueable(jobId, activeFlowsOnly, null));
    return;
}
```

`queryMorePossible = (job.Last_Result_Count__c != null && job.Last_Result_Count__c >= 1900)`

### USER_MODE Scope

Apply `WITH USER_MODE` / `AccessLevel.USER_MODE` only at the `@AuraEnabled` controller boundary. Engine internals operate in SYSTEM_MODE for reliable orchestration.

### Supplemental Query Gaps

| Gap | Handler | Strategy |
|---|---|---|
| Workflow Field Updates -> Custom Field | `CustomFieldHandler` | Query `WorkflowFieldUpdate` WHERE `Field IN :fieldApiNames` |
| Validation Rule formulas | `CustomFieldHandler` | Tokenized match + namespace-aware regex fallback |
| CMT record field lookups (field refs) | `CustomFieldHandler` | SOQL on CMT records, fields with field__c/lookup__c/field_api_name__c/field_name__c suffixes |
| CMT record field lookups (class refs) | `ApexClassHandler` | SOQL on CMT records, fields with class__c/handler__c/type__c/instance__c suffixes |
| Dynamic Apex string references | `ApexClassHandler` | Flagged `Is_Dynamic_Reference__c = true`; cannot be statically resolved |
| SubFlow parent detection | `FlowHandler` | Deferred - requires Tooling API XML parsing |
| FlexiPage visibility rules | `CustomFieldHandler` | Deferred - requires Metadata API XML parsing |
| Lookup field relationships | `CustomFieldHandler` | Deferred - requires `CustomField.ReferenceTo` Tooling API traversal |

---

## Export Formats

| Format | Structure |
|---|---|
| CSV | Flat: `Level, Metadata_Type, Metadata_Name, Metadata_ID, Parent_Name, Is_Circular, Is_Dynamic` |
| JSON | Nested tree mirroring hierarchy with `Component_Attributes__c` pills |
| package.xml | Valid Salesforce deployment manifest. Excludes managed packages (namespace-prefixed components). |

**Namespace detection rule:** exclude if `Metadata_Name__c` matches `^[A-Za-z]\w+__\w`. For CustomField (`Object.Field`), apply check to the segment after the last dot.

---

## Runtime Configuration (MetaMapper_Settings__mdt)

| Field | Default | Notes |
|---|---|---|
| `Scan_Batch_Size__c` | 50 | Unprocessed nodes per Queueable execution (non-Flow) |
| `Flow_Scan_Batch_Size__c` | 15 | Flow batch size. Each Flow node = 1 extra validation callout. |
| `Retention_Hours__c` | 72 | Hours before Failed/Cancelled job hard-delete. Min 1. |
| `Dml_Reserve_Rows__c` | 750 | DML rows to reserve in guardrail before self-chain |
| `Disable_Platform_Events__c` | false | Suppresses PE publish; LWC falls back to polling |
| `Stall_Detection_Threshold__c` | 5 | Consecutive zero-progress cycles before auto-pause |
| `Max_Concurrent_Jobs__c` | 2 | Max active MetaMapper Queueables. Rejects above threshold. |
| `Cleanup_Chunk_Size__c` | 2000 | DML chunk size for node deletion batch |
| `Max_Components__c` | 5000 | Node cap per job. Engine pauses at limit. 0 = disable (not recommended). |
| `Storage_Reserve_MB__c` | 50 | Min free data storage (MB) required before accepting new job |
| `Max_Stored_Jobs__c` | 5 | Ring buffer size for completed scan results |

### Sandbox vs. Production Defaults

| Setting | Dev Sandbox | Production |
|---|---|---|
| `Retention_Hours__c` | 1 | 72 |
| `Max_Concurrent_Jobs__c` | 1 | 2 |
| `Max_Components__c` | 5,000 | 5,000 |
| `Storage_Reserve_MB__c` | 50 | 200 |
| `Max_Stored_Jobs__c` | 5 | 10 |

Applied only on first install (when CMDT record has never been saved with explicit values).

---

## Failure Handling Pattern (DependencyQueueable)

```java
public void execute(QueueableContext ctx) {
    Savepoint sp = Database.setSavepoint();
    try {
        // ... all engine work ...
    } catch (Exception e) {
        Database.rollback(sp);
        updateJobFailed(jobId, e.getMessage());
    }
}
```

`updateJobFailed()`:
1. Checks `Status__c = 'Processing'` before updating (prevents overwriting a Completed status from a concurrent instance)
2. Sets `Status__c = 'Failed'`, `Error_Status_Message__c = e.getMessage() + '\n' + e.getStackTraceString()`, `Status_Closed_At__c`
3. Publishes a failure `Dependency_Scan_Status__e`
4. Does NOT re-throw

---

## Source API Version

`66.0` (configured in `sfdx-project.json`). Minimum supported: v49.0 (when `MetadataComponentDependency` became reliable).

---

## UX Design Specification

### Health Check + First-Time Onboarding

On `metaMapperApp` mount, call `ToolingApiHealthCheck.verify()` via `@AuraEnabled`. Block input form until check resolves. Show `lightning-spinner` during check.

Three distinct failure states:

| Failure | Detected by | UI message | Action |
|---|---|---|---|
| Named Credential not authorized | HTTP 401 | "MetaMapper needs one-time setup. An admin must authorize the Tooling API connection." | Link to SETUP.md |
| User lacks permission | HTTP 403 or FIELD_CUSTOM_VALIDATION_EXCEPTION | "You don't have access to MetaMapper. Ask your admin to assign you the MetaMapper Admin permission set." | Text only |
| Tooling API temporarily unreachable | HTTP 5xx or callout timeout | "MetaMapper cannot reach the Tooling API right now. This may be a temporary org issue." | "Retry" button |

**First-time guided tour:** One-time `lightning-modal` after successful health check. Detected via `localStorage` flag `metaMapper_tourSeen_v1`. Three slides: (1) Reading the graph, (2) Warning badges, (3) Supplemental results. Dismiss via "X" or "Don't show again" checkbox + "Got it".

### Input Screen

| Element | Behavior |
|---|---|
| Metadata Type picklist | Required; supported types only |
| API Name input | Required; placeholder: "e.g. Account.My_Field__c"; inline validation on blur |
| Target Object typeahead | Required for CustomField only; debounced 300ms |
| Active Flows Only checkbox | Default checked; tooltip explaining inclusion of inactive versions if unchecked |
| Submit button | Disabled until required fields valid; `is-loading` state on click; re-enables on error |

### Progress Screen

**Status labels:**

| Status__c | UI label |
|---|---|
| Initializing | "Setting up your analysis..." |
| Processing | "Analyzing metadata... [N] components found so far" |
| Paused | "Analysis paused - encountered a complex component. You can resume at a slower speed or with current settings." |
| Cancelled | "Analysis cancelled. Partial results are available below." |
| Completed | "Analysis complete. [N] components found." |
| Failed | "Analysis failed. [first 200 chars of Error_Status_Message__c]. See details for diagnostics." |

Cancel: confirmation modal ("Keep Running" vs "Stop Analysis") before `cancelJob()`. Falls back to polling if PEs disabled. Cancel button state machine: 5 distinct states defined.

### Graph View

Node visual language:

| Node type | Icon | Shape |
|---|---|---|
| Is_Circular__c | `utility:rotate` | Dashed border |
| Is_Dynamic_Reference__c | `utility:warning` | Solid border |
| Discovery_Source__c = Supplemental | `utility:info` | [S] badge |
| Supplemental_Confidence__c < 70 | `utility:error` | Red badge |

Node click = populates Node Details Panel (sidebar). "Open in Setup" is in the panel, not triggered by click. Spanning tree notice badge in persistent legend (`localStorage` key `metaMapper_spanningTreeNotice_v1`).

### Tree/Graph Synchronization

- Type/level filters: shared state owned by `metaMapperResults`
- Search: Tree-local only (does not affect Graph)
- Selection: node click in one view highlights corresponding node in other view
- Tab switch: selection and focus clear; filter state preserved
- No undefined state: parent owns all shared state; child components fire events only

### Empty and Error States

| Scenario | UI |
|---|---|
| Zero results | Empty state + "No dependencies found for [API name]." |
| Job failed | Error banner with first 200 chars of `Error_Status_Message__c`. "View full error" expander. "Start a new scan" button. |
| Serializer failed (completed traversal but no file) | Detected by: `Status__c = 'Failed'` AND `Components_Analyzed__c > 0` AND `Result_File_Id__c` is null. Message: "Scan analysis is complete but results could not be saved." + "Download Partial Results" button. |
| Loading | Skeleton shimmer (3 rows) in both tabs while `getNodeHierarchy()` resolves. |
| Paused | Warning banner. "Resume at a slower speed" + "Resume with current settings" buttons. Both buttons disable on click with inline spinner. |
| Concurrency rejection | Toast: "A scan is already in progress." |

### AI Summary Card (Completed jobs)

- Displays `Scan_Summary_Text__c` verbatim
- "Copy" button: inline label changes to "Copied!" + `utility:check` for 2 seconds, then reverts
- "Ask Copilot" button: conditionally rendered based on Copilot availability
- Collapsed by default (first 2 sentences + "Show more" toggle)
- Null state: skeleton shimmer while `ScanSummaryQueueable` runs

### Responsive Behavior

- >= 1280px: full layout
- 1024px - 1279px: sidebar collapses to toggle; filter panel to drawer
- < 1024px: Tree View is default landing; Graph degrades to pan-only; Node Details Panel becomes full-screen modal

MetaMapper is a **desktop-first application**. Mobile/tablet is graceful degradation, not full feature parity.

### Accessibility

- All color distinctions reinforced by icon + shape
- WCAG AA contrast ratios on all palette colors
- `role="tree"` on tree view; ARIA labels on all interactive graph elements
- Keyboard: Tab = focus graph; arrow keys = traverse nodes; Enter = select node
- `aria-live="polite"` on progress counter, status label, graph interaction results

---

## Known Limitations

- **Spanning tree model (by design):** Each node stores one parent (first-discovered path). Diamond dependencies (A->C and B->C) produce one `Metadata_Dependency__c` with one parent. Full DAG representation deferred.
- `MetadataComponentDependency` does not capture all dependency types. Supplemental handlers fill 5 known static gaps. Dynamic Apex string references are a permanent blind spot.
- Supplemental matches may include false positives. Confidence scoring is deterministic: WorkflowFieldUpdate = 95, ValidationRule regex = 65, FlexiPage XML = 60, CMT lookup = 85, Lookup relationship = 95.
- `DependencyCleanupBatch` uses a two-class chained pattern (`DependencyNodeCleanupBatch`) to avoid the 10,000 DML row limit on cascade deletes. Max 4 batch submissions per `finish()` call.
- Named Credential requires one-time admin authorization post-install.
- `Active Flows Only` excludes inactive Flow versions by design.
- package.xml export excludes managed package components.
- Cancellation is cooperative. Force-kill not available.
- `createJob()` must be called from synchronous Lightning context only.
- **Serializer ceiling:** `ResultSerializerQueueable` serializes all nodes in one heap-bound JSON operation. Safe ceiling ~2,000-3,000 nodes for deep trees. Default `Max_Components__c = 5,000` works for most dev sandbox metadata. Raising above 5,000 without a chunked serializer will hit the heap failure path.
- `Scan_Summary_Text__c` populated only on Completed. Agentforce Actions should check `Status__c = 'Completed'` before reading.
- **Storage model during active scans:** nodes temporarily occupy Data Storage (~5KB/node). A 5,000-node scan peaks at ~25MB. `Storage_Reserve_MB__c = 50` ensures headroom.
- `Cycle_Detection_Index__c` 6-char prefix has negligible false-positive probability. `Ancestor_Path__c` always used to confirm.

---

## Architecture Decisions

| Decision | Choice | Reason |
|---|---|---|
| Deployment | Unlocked Package + SFDX project on GitHub | Open source, version-controlled |
| Graph visualization | Apache ECharts bundled as Static Resource | No CDN at runtime; MIT licensed; built-in force-directed graph |
| Live progress | Platform Events + `lightning/empApi` | Native push; no polling; no Governor pressure |
| Cycle detection | Two-tier: `processedIds` dedup + `Ancestor_Path__c` ancestry | Separates dedup from true cycle detection correctly |
| Auth | OAuth 2.0 loopback via Connected App + Named Credential | Internal Tooling API only; admin-authorized once post-install |
| Security | USER_MODE on `@AuraEnabled`; Private OWD; Permission Set | Enterprise InfoSec compliant |
| DLM | Ring buffer (5 completed) + Nightly Batch for Failed/Cancelled | Bounds storage without time-expiring completed results |
| IN clause chunk size | Dynamic: `80 + (size * 19) < 8000` | URL-length driven, not fixed count |
| Supplemental queries | Type-specific handler classes implementing `IDependencyTypeHandler` | MetadataComponentDependency misses 5+ dependency categories |
| QueryMore | Iterative `nextRecordsUrl` follow | Tooling API caps at 2,000 rows |
| Data lifecycle | Hybrid ContentVersion model | Node records deleted on Completed; ~5KB/job data storage for completed |
