# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Output Rules
- After applying fixes (code review rounds, bug fixes, any edits): do not explain what was changed. Make the edits and stop. The user can read the diff.

---

## Code Review and Deployment Protocol (Non-Negotiable)

When writing Apex classes, LWC components, or any other code artifact:

1. **Write** all code for the current artifact group (e.g. all Phase 3 classes).
2. **Update the Markdown review document** (`MetaMapper_Code_Review_vN.md`) with purpose statements and full code for all changed classes.
3. **Wait** for the user to upload the file to external AI review tools and provide findings.
4. **Apply fixes** based on findings.
5. **Repeat** steps 2-4 until the user explicitly says the code is approved.
6. **Only then**: deploy to the Salesforce org and push to GitHub.

Never deploy code before the user explicitly approves it. "Proceed" or "do it" means write the code - not deploy it.

---

## Document Management (Two Documents, Two Triggers)

### MetaMapper_Technical_Design.md
Updated **only when the design changes** (CLAUDE.md, architecture, data model, UX spec, key decisions).
- File: `MetaMapper_Technical_Design.md` in the project root
- Update method: Edit tool with targeted diffs only - never rewrite from scratch

### MetaMapper_Code_Review_vN.md
Updated **whenever code changes** (Apex classes, LWC, metadata). Version number `N` increments with each new code review or fix round.
- File: `MetaMapper_Code_Review_vN.md` in the project root (version suffix in filename)
- Contains: project background + for each class a 1-2 sentence purpose statement + full code

### Markdown Update Method (Token-Efficient)

For either document:
1. Use the **Edit tool with targeted diffs** - only the changed sections.
2. For a new code review version, use the **Write tool** to create the new versioned file.
3. Never rewrite the full document from scratch unless creating a new version.

---

## External Review Round Workflow

When the user pastes architecture or UX reviews from external sources:

1. **Parse all reviews first.** Read every review before producing any output.
2. **Present an assessment table** - one row per actionable item. Columns: `#`, `Source`, `Issue`, `Action`, `Impact`. Mark items to skip with reason.
3. **Wait for explicit approval** before applying anything.
4. **On approval: apply ALL CLAUDE.md edits first**, then update the Markdown review file.
5. **Never name AI tools in technical design documents.** Strip all reviewer names, tool names, and score references - no engineering value.
6. **Deploy immediately after updates** - push CLAUDE.md + Markdown files to GitHub in one commit.

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

The core challenge: enterprise org metadata trees are too large for synchronous Apex (10s CPU, 6MB synchronous heap). Async Queueable context provides 12MB heap and no CPU hard timeout - but governor limits still apply per execution. The solution is a **Queueable chain + Custom Object state machine**:

1. User submits a search via the LWC - an `@AuraEnabled` controller creates a `Metadata_Scan_Job__c` record and inserts the root `Metadata_Dependency__c`, then enqueues `DependencyQueueable`.
2. Each `DependencyQueueable` execution queries a batch of unprocessed nodes (`Dependencies_Fetched__c = false`), calls the Tooling API via Named Credential, inserts new child nodes, marks current nodes processed, and checks limit proximity.
3. When the remaining callout budget drops below a safe threshold, it self-enqueues a fresh instance and exits. The guardrail uses a **remaining-callout budget** model (not percentage alone): reserve explicit headroom for QueryMore follow-ups, Flow status validation, and retry splits. Chain when `remaining < headroom`; see Limit Guardrails section below.
4. When no unprocessed nodes remain, `DependencyQueueable` enqueues `ResultSerializerQueueable` and exits. The serializer serializes all node records to a Salesforce File, deletes the node records to free Data Storage, enforces the ring buffer, transitions the job to `Completed`, and fires notifications. This two-step handoff keeps the engine's governor budget separate from the serialization work.

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

> **Why not query all nodes upfront?** At 10k-20k nodes a full-scan query consumes a large portion of the 12MB async heap before any Tooling API work begins. Scoping to `currentResultIds` limits the dedup query to matches within the current callout's result set only.

**Tier 2 - True ancestry cycle detection (`Ancestor_Path__c`):**
Each `Metadata_Dependency__c` stores a pipe-delimited `Ancestor_Path__c` field: the chain of ancestor `Metadata_Id__c` values from root to this node.

- **Root node:** `Ancestor_Path__c = ''` (empty string, not null). This ensures the first child path is built as `'' + '|' + rootId = '|rootId'`, which is handled by trimming the leading pipe, OR by initializing root as `Ancestor_Path__c = rootId` and children as `parentPath + '|' + parentId`.
- **Correct path-building:** `child.Ancestor_Path__c = (String.isBlank(parent.Ancestor_Path__c) ? '' : parent.Ancestor_Path__c + '|') + parent.Metadata_Id__c`. This avoids a leading delimiter on first-level children.
- **Cycle check:** use delimiter-safe containment: `('|' + parent.Ancestor_Path__c + '|').contains('|' + newNodeId + '|')`. A raw `String.contains(id)` is vulnerable to false positives where one 18-char ID is a substring of another. The delimiter-wrapped form is the authoritative check.
- **Circular node path:** Keep the **full `Ancestor_Path__c`** on circular nodes - do NOT set to null. The path is most valuable precisely when a cycle is found (debugging, export). Mark `Is_Circular__c = true`, `Dependencies_Fetched__c = true`. Append the cycle-closing segment to `Component_Attributes__c` as `{"cycleClosesAt": "<parentMetadataId>"}` for UI visualization.
- **CPU consideration:** `String.contains()` on a long Ancestor_Path__c string inside an inner loop is CPU-intensive for deep trees. Check `Limits.getCpuTime()` against the guardrail threshold **inside the node-processing loop**, not only at the batch boundary.

> **Ancestor_Path__c capacity and guard:** At 18 chars/ID + 1 delimiter, a depth-1,500 path would be ~28,500 chars - within the Long Text 32768 limit. However, appending beyond 32,000 chars causes a silent truncation or `StringException`. **Before building the path for any child node**, check: `if ((parent.Ancestor_Path__c?.length() ?? 0) + 20 > 32000)` - if true, mark the child as `Is_Circular__c = true`, `Dependencies_Fetched__c = true`, log to `Error_Status_Message__c` ("Max ancestor depth exceeded at [nodeId]; traversal stopped at this node"), and skip insertion. Do NOT fail the job.

### Cancellation

`DependencyQueueable` checks `Status__c` as the first operation in `execute()`. If `Status__c = 'Cancelled'`, it exits immediately without enqueuing a successor. The `cancelJob(String jobId)` `@AuraEnabled` method in `DependencyJobController` sets `Status__c = 'Cancelled'` (WITH USER_MODE). The LWC Cancel button calls this method. Queueables that are already enqueued will check on entry and terminate cooperatively - there is no force-kill mechanism in Salesforce.

**cancelJob() failure handling:** Wrap the USER_MODE DML in a try/catch. If the update fails (e.g. user lacks CRUD/FLS on `Status__c`), throw `DependencyJobException('Unable to cancel: insufficient permissions to update job status. Contact your admin.')`. The LWC must catch this exception and render it as a toast error - never leave the Cancel button in a permanent "Cancelling..." spinner when the server-side call failed.

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
OrgLimit peLimit = OrgLimits.getMap().get('DailyStandardVolumePlatformEvents');
// If (peLimit.getValue() / peLimit.getLimit()) >= 0.80: skip publish, log to Error_Status_Message__c
```

This is additive to `Disable_Platform_Events__c` - the CMDT switch remains for proactive admin control, while the runtime check provides automatic degradation. When auto-degraded, set `Disable_Platform_Events__c = true` on the CMDT Default record so all subsequent executions in the same day also skip publishing without re-checking limits on every call. **Append to `Error_Status_Message__c`** when auto-suppress fires: `"[timestamp] Platform Events suppressed - org daily delivery limit >80% consumed. Progress updates switched to polling."` so admins have visibility without needing debug logs.

**CMDT mutation path:** `DependencyNotificationService` writes the flag via `Metadata.Operations.enqueueDeployment()` (async, does not consume a DML statement). If the deployment call itself fails (e.g. insufficient metadata deployment permissions), the suppression flag is NOT persisted - but the event is still skipped for the current execution. On the next execution, the OrgLimits check will run again and attempt the write again. The suppression notice is appended to `Error_Status_Message__c` regardless of whether the CMDT write succeeds, ensuring admin visibility is never gated on metadata deployment access.

### Graph Visualization

`metaMapperGraph` loads Apache ECharts from the `ECharts` Static Resource (no CDN). It receives a flat node list (deserialized from the `ContentVersion` result file for completed jobs, or from live `Metadata_Dependency__c` records for active jobs - the shape is identical in both cases) and builds the ECharts `graph` series client-side, using `Parent_Dependency__c` to derive edge links. Node color is keyed to `Metadata_Type__c`.

> **Static Resource build**: use `echarts/dist/echarts.min.js` (core minified build, ~1.0-1.2MB) sourced from the npm package. Do **not** use the full bundle - it includes maps and 3D features and risks exceeding Salesforce's 5MB static resource hard limit.

> **Dark mode**: register a Salesforce-compatible dark theme via `echarts.registerTheme('sfDark', { backgroundColor: '#1B1B1B', textStyle: { color: '#FFFFFF' }, ... })`. Apply when `document.body.classList.contains('slds-theme_inverse')`. Use `slds-theme_inverse` detection, not a manual preference flag.

### Security Model

- OWD: `Metadata_Scan_Job__c` = Private (users see only their own jobs)
- `@AuraEnabled` controller methods (`DependencyJobController`) use `WITH USER_MODE` or `AccessLevel.USER_MODE` - FLS and CRUD enforced at the controller boundary. Async engine classes (`DependencyQueueable`, `ResultSerializerQueueable`, `DependencyCleanupBatch`, `DependencyNodeCleanupBatch`) operate in SYSTEM_MODE for reliable internal orchestration.
- `ContentVersion` / `ContentDocumentLink` records are created in SYSTEM_MODE by `ResultSerializerQueueable`. `ContentVersion.FirstPublishLocationId` is set to the job record ID (not a Chatter library) so Salesforce automatically creates the only `ContentDocumentLink` - tied to the job. No additional links to files libraries or other records are created. After the auto-created `ContentDocumentLink` is created, `ResultSerializerQueueable` must query it and explicitly set `ShareType = 'V'` (viewer) and `Visibility = 'InternalUsers'`. Using `'InternalUsers'` ensures the file is never visible to community or guest users even if a community portal is granted access to the job record. Do NOT use `'AllUsers'` - that value includes portal/community users with access to the parent record.
- Permission Set `MetaMapper_Admin` grants CRUD on both custom objects, Named Credential principal access, and LWC/controller access

### Data Lifecycle

MetaMapper uses a **hybrid ContentVersion model** to minimize data storage impact. Node records are temporary engine state; completed results live in Salesforce File Storage.

#### On-Completed Serialization (inline, final Queueable execution)

When `DependencyQueueable` determines no unprocessed nodes remain, it executes the following sequence atomically before transitioning the job to Completed:

1. Query all `Metadata_Dependency__c` records for the job (`DependencyNodeSelector.listByJob(jobId)`).
2. Serialize the flat list to JSON.
3. Create a `ContentVersion` record with `PathOnClient = 'MetaMapper_[jobId].json'`, `VersionData = Blob.valueOf(json)`, and `FirstPublishLocationId = jobId`. Setting `FirstPublishLocationId` causes Salesforce to automatically create the `ContentDocumentLink` tied to the job - do NOT create the link manually. A manual insert would create a duplicate link and fail with a constraint violation.
4. Requery `ContentDocumentId`: `[SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId`. The `ContentDocumentId` is NOT available on the inserted `ContentVersion` record directly - it is populated by Salesforce after insert and must be retrieved via a fresh SOQL query before it can be stored.
5. Update `Metadata_Scan_Job__c.Result_File_Id__c = contentDocumentId`.
6. Bulk-delete all `Metadata_Dependency__c` records for the job using `DependencyNodeCleanupBatch` chained from `finish()`. The job record stays; all node records are removed.
7. **Ring buffer enforcement**: AFTER transitioning the job to Completed (step included in `ResultSerializerQueueable`), count all Completed jobs for the org (inclusive of the job just transitioned). If count > `Max_Stored_Jobs__c`, delete the oldest Completed job (including its `ContentVersion` via `ContentDocument` delete). **Count must happen after the Completed transition** - counting before gives one fewer than the true total, causing a systematic off-by-one that gradually over-retains one extra job.

If the serialization or ContentVersion creation fails (e.g., heap or callout limit), the engine transitions the job to `Failed` via the standard `updateJobFailed()` path. Node records remain and are cleaned up by the nightly batch.

> **File Storage note:** `ContentVersion` uses File Storage, not Data Storage. Developer Sandbox has 200MB of each. In practice, file storage is far less utilized than data storage in most sandboxes. A completed job consumes ~1-3MB file storage vs ~60-120MB data storage with the old model.

#### Ring Buffer (Completed Jobs)

`Max_Stored_Jobs__c` (default 5) limits the number of completed scan jobs retained org-wide. When the 6th job completes, the oldest completed job is deleted (job record + ContentVersion). This keeps file storage bounded at ~5-15MB for completed jobs regardless of how many scans are run.

**Ring buffer deletion must be deterministic and safe under concurrent completions:** The deletion query must use `FOR UPDATE` to serialize concurrent `ResultSerializerQueueable` executions: `[SELECT Id FROM Metadata_Scan_Job__c WHERE Status__c = 'Completed' ORDER BY Status_Closed_At__c ASC, Id ASC LIMIT 1 FOR UPDATE]`. Sort by `Status_Closed_At__c ASC, Id ASC` for determinism when two jobs have identical timestamps. Wrap deletion in a try/catch - a failed ring buffer delete (e.g. record already deleted by a concurrent instance) must NOT fail the job. Log the error to `Error_Status_Message__c` and continue.

`Retention_Hours__c` applies **only to Failed and Cancelled jobs** - it no longer governs completed jobs, which are managed by the ring buffer instead.

#### Nightly Cleanup (Failed and Cancelled Jobs)

`DependencyCleanupBatch` runs nightly at 02:00 via `DependencyCleanupScheduler`. It targets **only** Failed and Cancelled jobs older than `Retention_Hours__c`.

**Lifecycle rule (critical):**
- Only delete jobs where `Status__c IN ('Failed', 'Cancelled')` AND `Status_Closed_At__c < :DateTime.now().addHours(-retentionHours)`. Never delete `Initializing`, `Processing`, `Paused`, or `Completed` jobs - Completed jobs are managed by the ring buffer; in-progress jobs must not be destroyed.
- `Status_Closed_At__c` is stamped the moment Status transitions to Completed, Failed, or Cancelled. It is **not** stamped on a Paused transition - Paused is a resumable checkpoint, not a terminal state, and stamping it would give a misleading "closed" timestamp to a job that will continue. The cleanup batch uses this field, not `CreatedDate`, to avoid targeting long-running in-progress jobs.

**Cascade delete DML trap (critical):**
Master-Detail cascade deletion counts child record deletes against the 10,000 DML row limit of the batch `execute()` transaction. A job with 15,000 nodes would cause `System.LimitException: Too many DML rows` on the first delete call. An inner `while (!nodes.isEmpty())` loop inside `execute()` compounds this risk in LDV orgs - 80k+ node jobs can exceed CPU or trigger "Too many DML statements" from customer triggers firing on every 2,000-node delete within the same transaction.

**Fix: two-class chained cleanup pattern.**

`DependencyCleanupBatch` discovers expired jobs; `DependencyNodeCleanupBatch` handles the actual deletion.

**`DependencyCleanupBatch`** (job discovery):
- `start()`: returns QueryLocator for Failed/Cancelled jobs where `Status_Closed_At__c < threshold`
- `execute(scope)`: no DML - accumulates job IDs
- `finish()`: fires one `DependencyNodeCleanupBatch(jobId, CleanupMode.NODES_AND_JOB)` per accumulated job ID. **Maximum 4 submissions per `finish()` call** - Salesforce limits `Database.executeBatch()` calls per transaction. If more than 4 expired jobs accumulate, submit the first 4 and leave the remainder for the next nightly run. Document: "Cleanup backlog from >4 expired jobs clears over multiple nightly runs."
- Batch size: 10 (multiple jobs per discovery pass is safe since execute() does no DML)

**`DependencyNodeCleanupBatch`** (node + job deletion):
- Constructor: `DependencyNodeCleanupBatch(String jobId, CleanupMode mode)` where `CleanupMode` is an inner enum: `public enum CleanupMode { NODES_ONLY, NODES_AND_JOB }`. The enum replaces the previous `Boolean deleteJob` parameter to prevent accidental argument swaps (a boolean `true`/`false` swap is silent; an enum mismatch is a compile error). Two distinct calling paths:
  - **Nightly cleanup path** (`DependencyCleanupBatch.finish()`): `CleanupMode.NODES_AND_JOB` - nodes deleted, then job record deleted.
  - **Serializer path** (`ResultSerializerQueueable`): `CleanupMode.NODES_ONLY` - nodes deleted only; the job record is retained (it holds the result file pointer and will be managed by the ring buffer).
- `start()`: `SELECT Id FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :jobId`
- `execute(scope)`: `delete scope;` - scope is already `<= Cleanup_Chunk_Size__c`
- `finish()`: if `deleteJob` is true: `delete [SELECT Id FROM Metadata_Scan_Job__c WHERE Id = :jobId];` - otherwise: no-op.
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
| `Status_Closed_At__c` | DateTime | Stamped when Status transitions to Completed, Failed, or Cancelled. Not set on Paused - Paused is a resumable checkpoint, not a terminal state. Cleanup batch uses this field - never CreatedDate - to avoid deleting in-progress jobs. |
| `Total_Processing_Cycles__c` | Number | Number of times the async engine has processed a batch for this scan. Incremented on every Queueable execution. Used together with `Last_Successful_Cycle__c` for stall detection. |
| `Last_Successful_Cycle__c` | Number | The value of `Total_Processing_Cycles__c` at the last execution that made measurable progress (i.e., `Components_Analyzed__c` increased). Persisted on the job record so it survives across Queueable self-chain boundaries (transient variables are reset on each new Queueable instance). Stall condition: `Total_Processing_Cycles__c - Last_Successful_Cycle__c >= Stall_Detection_Threshold__c`. Reset to `Total_Processing_Cycles__c` whenever `Components_Analyzed__c` increases. |
| `Scan_Summary_Text__c` | Long Text 32768 | Plain-English summary populated after job Completed by `ScanSummaryQueueable`. Derived from `Result_Summary__c`. Example: "This scan found 42 dependencies, including 3 active Flows and 5 Apex classes." Enables Agentforce Actions to consume job results without parsing JSON. Null until Completed. Populated asynchronously - LWC should poll `getJobStatus()` until this field is non-null before rendering the Summary Card. |
| `Result_File_Id__c` | Text 18 | ContentDocumentId of the Salesforce File containing the complete scan result JSON. Populated when Status transitions to Completed, after all `Metadata_Dependency__c` records have been serialized to the file and deleted. Null during active scans and for Failed/Cancelled jobs. Used by `getNodeHierarchy()` to serve results for completed jobs without querying the (already-deleted) node records. |
| `Batch_Size_Override__c` | Number | Transient-safe batch size override set by `resumeJob()` when the user chooses "Resume at a slower speed". `DependencyQueueable.execute()` reads this field at startup and uses it instead of `Scan_Batch_Size__c` if non-null. The field is NOT reset after use - it persists for the job lifetime, keeping the slower speed in effect for subsequent self-chains until the admin resets it to null. Does NOT write back to CMDT (CMDT is org-wide; this is job-specific state). |
| `Last_Result_Count__c` | Number | The number of rows returned by the most recent Tooling API callout. Updated after each callout: `job.Last_Result_Count__c = results.size()`. Used by the guardrail to determine `queryMorePossible`: `queryMorePossible = (job.Last_Result_Count__c != null && job.Last_Result_Count__c >= 1900)`. If the previous callout returned >= 1,900 rows, QueryMore is likely for the next batch. Initialized to 0 on job creation. |

> **Visited_IDs__c removed.** A Long Text 131072 field caps at ~5,957 IDs (22 chars/ID with JSON formatting). Enterprise orgs can easily exceed this, causing `StringException` and crashing the Queueable chain. Cycle detection is instead performed via two-tier logic (see Cycle Detection below).

### Metadata_Dependency__c

> **Storage model:** `Metadata_Dependency__c` records exist **only during the active scan**. When a job transitions to Completed, the engine serializes the entire node tree to a JSON Salesforce File (`ContentVersion`), bulk-deletes all `Metadata_Dependency__c` records for the job, and stores the `ContentDocumentId` in `Result_File_Id__c` on the job. Data Storage impact for completed jobs is therefore near-zero (~5KB for the job record alone). File Storage (also 200MB in Developer Sandbox) holds the serialized result JSON (~1-3MB per job). Failed and Cancelled jobs may retain partial node records until the nightly cleanup batch removes them.

| Field | Type | Notes |
|---|---|---|
| `Metadata_Scan_Job__c` | Master-Detail | Cascade delete |
| `Parent_Dependency__c` | Lookup (self) | Builds hierarchical tree. **Self-referential bulk DML constraint:** Salesforce does not resolve self-referential lookups within a single bulk DML operation. The root node must be committed in a separate DML call before any child nodes can reference it by ID. Insert root first, commit, then bulk-upsert children. |
| `Metadata_Id__c` | Text 18 | Exact 18-char Tooling API ID |
| `Metadata_Type__c` | Text 50 | e.g. ApexClass, CustomField, Flow |
| `Metadata_Name__c` | Text 255 | Human-readable API name |
| `Dependency_Depth__c` | Number | Depth from root (0 = root target) |
| `Dependencies_Fetched__c` | Checkbox | Engine flag: false = this node's child dependencies have not yet been fetched from the Tooling API |
| `Is_Circular__c` | Checkbox | True only when this node's `Metadata_Id__c` appears in its own `Ancestor_Path__c` (true ancestry cycle) |
| `Is_Dynamic_Reference__c` | Checkbox | True if reference cannot be statically analyzed (e.g. dynamic Apex string) - flagged in UI |
| `Component_Attributes__c` | Long Text 32768 | JSON "pills" - contextual metadata per type (see below) |
| `Discovery_Source__c` | Picklist | `ToolingAPI` or `Supplemental` - tracks how the node was discovered |
| `Ancestor_Path__c` | Long Text 32768 | Pipe-delimited ancestor `Metadata_Id__c` chain from root to this node's **parent** (excludes self). The path-building formula appends `parent.Metadata_Id__c` to the child's path, so a child's `Ancestor_Path__c` contains all ancestors above it but not its own ID. Used for true cycle detection. |
| `Supplemental_Confidence__c` | Number (3,0) | 0-100 confidence score for supplemental nodes only. Regex/XML matches are inherently fuzzy; score reflects match certainty. Nodes below 70 display a warning badge in the UI. Null for ToolingAPI nodes. |
| `Component_Uniqueness_Key__c` | Text 80 (External ID, Unique) | Composite key: `JobId + ':' + Metadata_Id__c`. Used for upsert to prevent duplicate nodes from race conditions in concurrent Queueable chains. Text 80 provides headroom for future scoping additions beyond the current 37-char minimum. |
| `Cycle_Detection_Index__c` | Long Text 32768 | Stores a pipe-delimited set of 6-character prefixes of each ancestor `Metadata_Id__c` (e.g. `"abc123|def456|..."`). Used as a fast bloom-filter-style pre-screen: before performing the full delimiter-safe `Ancestor_Path__c` containment check, the engine checks whether the new node's 6-char prefix appears in this index. If no match, skip the expensive full-string check. If a match is found, confirm conclusively against `Ancestor_Path__c` before marking the node circular. **Long Text 32768 is required** - at 7 chars per prefix entry (6 + delimiter), a 1,500-depth tree yields ~10,500 chars. Text 255 overflows at depth >36. The 6-char prefix has a negligible false-positive probability; the `Ancestor_Path__c` confirmation step resolves all false positives. |

### Component_Attributes__c (Pills) by Metadata Type

All `Component_Attributes__c` payloads include a root `"v": 1` version key. The LWC renders unknown keys as plain text with a fallback label rather than failing. Handlers must increment `"v"` when the payload schema changes - the LWC version check gate is the only compatibility contract.

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
| `IMetaMapperSettingsProvider` | `MetaMapper_Settings__mdt getSettings()` - read once per transaction, cached in a `static` variable. The cache must be `static` (not instance-level) so that supplemental handlers calling `getSettings()` independently within the same Apex transaction reuse the same record and do not each burn a SOQL query. |

**Selectors (all SOQL centralized here):**

| Selector | Key Methods |
|---|---|
| `DependencyJobSelector` | `getByIdForEngine(String jobId)` - minimal fields for engine; `getClosedJobsBefore(DateTime threshold)` - for cleanup; `countActiveQueueables()` - scoped `AsyncApexJob` count for concurrency guard (includes `ApexClass.Name = 'DependencyQueueable'` filter) |
| `DependencyNodeSelector` | `nextUnprocessed(String jobId, Integer lim)` - ordered fetch; `dedupForResults(String jobId, Set<String> ids)` - scoped dedup query; `listByJob(String jobId)` - full node list for on-Completed serialization; `getResultFile(String contentDocumentId)` - queries `ContentVersion` WHERE `ContentDocumentId = :id` and returns the `VersionData` blob for completed job results |

**Classes:**

| Class | Role |
|---|---|
| `DependencyJobController` | `@AuraEnabled` (USER_MODE): `createJob()` with async guard + concurrency guard + storage check + node cap enforcement + preflight check, `getObjectList()`, `getJobStatus()`, `getNodeHierarchy()`, `cancelJob()`, `resumeJob(String jobId, Integer overrideBatchSize)` - passes transient batch override to Queueable (does not write CMDT). Delegates to services - no SOQL/DML directly. **Storage check:** before accepting a new job, reads `OrgLimits.getMap().get('DataStorageMB')` and computes free storage as `orgLimit.getLimit() - orgLimit.getValue()`. Rejects with a user-facing message if free storage < `Storage_Reserve_MB__c`. User message: "Not enough data storage to start a scan. Free up storage or reduce the retention window in MetaMapper Settings." **`getNodeHierarchy()` routing:** if `Metadata_Scan_Job__c.Status__c = 'Completed'`, reads the result JSON from `ContentVersion` via `DependencyNodeSelector.getResultFile(job.Result_File_Id__c)` and deserializes it - `Metadata_Dependency__c` records no longer exist for completed jobs. For all other statuses (Initializing, Processing, Paused, Cancelled, **Failed**), queries `Metadata_Dependency__c` records directly - partial nodes from a Failed job are valid for export. This routing is transparent to the LWC - both paths return the same flat node list shape. |
| `MetadataDependencyService` (implements `IMetadataDependencyService`) | Tooling API SOQL formatting, character-budget chunking, QueryMore, Active Flows filter, `buildContextData()`, `computeScore()`. **Heap pre-check rule (critical):** do NOT use `Limits.getHeapSize()` to predict deserialization cost - it is delayed and does not reflect the memory cost of the pending deserialization. Instead, check the **raw HTTP response body string length** BEFORE calling `JSON.deserializeUntyped()`. If the string length exceeds 500,000 characters (~500KB), split the batch in half and re-query rather than deserializing the full payload. This is the only reliable pre-deserialization heap guard available in Apex. |
| `DependencyTypeHandlerFactory` | `IDependencyTypeHandler getHandler(String metadataType)` - returns correct handler or no-op default |
| `CustomFieldHandler` | Supplemental: WorkflowFieldUpdate (95), ValidationRule regex (65), FlexiPage XML (60), CMT lookups (85), Lookup relationships (95). **Regex safety rule:** all regex patterns must be non-backtracking (no nested quantifiers). Before each regex call, check `Limits.getCpuTime() / Limits.getLimitCpuTime() >= 0.60` - if true, skip the field, log a diagnostic notice to `Error_Status_Message__c`, and continue. ValidationRule formula fields in complex orgs can be 10,000+ characters; unbounded backtracking patterns will hit the CPU limit and fail the Queueable. |
| `ApexClassHandler` | Supplemental: CMT references (85); flags `Is_Dynamic_Reference__c` |
| `FlowHandler` | Supplemental: QuickActionDefinition, subflows, WebLink URLs |
| `DependencyQueueable` | Async engine. Constructor: `DependencyQueueable(String jobId, Boolean activeFlowsOnly, Integer overrideBatchSize)`. **Node cap check:** at the start of each execution, if `Components_Analyzed__c >= Max_Components__c` (and `Max_Components__c > 0`), transition job to `Status__c = 'Paused'`, set `Error_Status_Message__c` with: "Scan paused: node limit of [N] reached. This protects your org's data storage. Raise Max_Components__c in MetaMapper Settings to continue." Do not self-chain. The LWC pause banner surfaces the resume option. Note: the cap is a soft ceiling - the final batch before the limit is reached may push `Components_Analyzed__c` up to `Max_Components__c + Scan_Batch_Size__c - 1`; the check fires at the start of the next execution. - `overrideBatchSize` is null for normal execution; set to half of `Scan_Batch_Size__c` when `resumeJob()` triggers after a hot-loop pause. Savepoint/catch; cancel check; CMDT read via `IMetaMapperSettingsProvider`; hot-loop detection; pre-batch + mid-loop seven-limit guardrail; scoped dedup + upsert by `Component_Uniqueness_Key__c`; two-tier cycle detection; callouts; HTTP 414/431 reactive split-and-retry (halves batch, retries both halves as separate callouts, does not fail job - logs restart to `Error_Status_Message__c`); handlers; one PE event per execution (suppressed if `Disable_Platform_Events__c`); self-chain. **On completion:** when no unprocessed nodes remain, instead of directly transitioning to Completed, enqueues `ResultSerializerQueueable` - this separates the concern of engine traversal (this class) from result persistence (serializer). The engine does not transition Status itself; `ResultSerializerQueueable` owns the Completed transition. **DML bulkification rule (critical):** child nodes discovered during the result-processing loop are accumulated in a `List<Metadata_Dependency__c>` and upserted in a single bulk statement after the loop completes (or before a mid-loop self-chain fires). Never upsert per-node inside the loop. |
| `DependencyNotificationService` (implements `INotificationService`) | `publishProgress()` - one event per execution; checks org daily PE allocation via `OrgLimits` before publishing (auto-suppresses and flips `Disable_Platform_Events__c` if >80% consumed - appends suppression notice to `Error_Status_Message__c` for admin visibility); `sendCompletionNotification()`. Does NOT enqueue `ScanSummaryQueueable` - that is the responsibility of `ResultSerializerQueueable` after the Completed transition. |
| `ScanSummaryQueueable` | Lightweight one-shot Queueable enqueued by `ResultSerializerQueueable` after the Completed transition. Reads `Result_Summary__c`, builds the plain-English `Scan_Summary_Text__c` string, and updates the Job record. Offloaded because string templating on a large `Result_Summary__c` JSON payload competes with the serializer's own CPU/heap budget, and chaining keeps each unit of work within a predictable governor envelope. |
| `ResultSerializerQueueable` | One-shot Queueable enqueued by the final `DependencyQueueable` execution when no unprocessed nodes remain. **Must use the Savepoint/rollback pattern** (same as `DependencyQueueable`): `Database.setSavepoint()` before all work; on any exception `Database.rollback(sp)` then `updateJobFailed()` in a fresh DML scope - without this, an uncaught exception rolls back the ContentVersion creation AND the job update, leaving the job stuck in `Processing` permanently with no recovery path. **Heap guard (critical):** before calling `JSON.serialize()` on the full node list, estimate the payload: if `Components_Analyzed__c * avgBytesPerNode > heapThreshold`, fail the job immediately via `updateJobFailed()` with message: "Scan completed but results could not be saved - result set too large for available heap. Reduce Max_Components__c and run again." Default safety assumption: ~4-6KB per node for deep trees (Ancestor_Path__c and Component_Attributes__c add significant size beyond the base record); at 5,000 nodes that is ~20-30MB against a 12MB async heap limit. This means the practical safe ceiling is ~2,000-3,000 nodes for enterprise orgs with deeply nested metadata. Admins raising `Max_Components__c` above 3,000 should be aware the serializer will likely hit the heap failure path. **Terminal on failure:** `Failed` jobs from this class are not retryable - the admin must start a new scan. Steps: heap-check before serializing; serialize all `Metadata_Dependency__c` to JSON; create `ContentVersion` with `FirstPublishLocationId = jobId` (no library link); requery `ContentDocumentId` from the inserted `ContentVersion`; update `Result_File_Id__c`; **compute and update `Result_Summary__c`** (JSON map of `{MetadataType: count}` derived from the serialized nodes - must be populated before transitioning to Completed so `ScanSummaryQueueable` has data to work with); bulk-delete all node records via `DependencyNodeCleanupBatch(jobId, false)` (nodes only - keep job); transition to Completed; enforce ring buffer; enqueue `ScanSummaryQueueable`. Offloaded from the engine Queueable because serializing thousands of node records consumes significant heap and CPU that would compete with the final batch of Tooling API work. |
| `DependencyCleanupBatch` | Job discovery batch. **Must implement `Database.Stateful`** - the class accumulates job IDs across multiple `execute()` chunks and passes them to `finish()`. Without `Database.Stateful`, Apex discards all instance state between chunk invocations and `finish()` receives an empty list, firing zero child batches. `start()` = Failed/Cancelled jobs past `Retention_Hours__c` threshold (Completed jobs are managed by the ring buffer, not time-based deletion). `execute()` = no DML - accumulates job IDs into a `List<Id>` instance variable. `finish()` = fires one `DependencyNodeCleanupBatch` per accumulated job ID. Batch size 10. |
| `DependencyNodeCleanupBatch` | Node deletion batch with optional job deletion. Constructor: `DependencyNodeCleanupBatch(String jobId, CleanupMode mode)` where `CleanupMode` enum values are `NODES_ONLY` (serializer path - retain job) and `NODES_AND_JOB` (nightly cleanup path - delete job after nodes). Using an enum prevents the silent argument-swap bug that a boolean `deleteJob` parameter would allow. `start()` = QueryLocator for child nodes. `execute()` = `delete scope`. `finish()` = deletes parent job record only when `mode = NODES_AND_JOB`; no-op when `mode = NODES_ONLY`. Batch size = `Cleanup_Chunk_Size__c` (default 2,000). No inner loops - each transaction is one chunk only. |
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
- On each execution, increment `Total_Processing_Cycles__c` on the Job.
- If `Components_Analyzed__c` increased since the last execution, reset `Last_Successful_Cycle__c = Total_Processing_Cycles__c`.
- If `Total_Processing_Cycles__c - Last_Successful_Cycle__c >= Stall_Detection_Threshold__c` (default 5), transition Job to `Status__c = 'Paused'`, set `Error_Status_Message__c` with diagnostic context, and publish a `Dependency_Scan_Status__e` warning event.
- **Why persisted field, not transient variable:** each Queueable self-chain creates a new instance - transient variables are discarded. `Last_Successful_Cycle__c` on the job record is the only state that survives across Queueable chain boundaries.
- The LWC surfaces this as a user-visible warning: "MetaMapper paused because it encountered a component with extremely deep or wide dependencies. You can resume at a slower speed or with current settings."

> `Status__c` gains a `Paused` value. `DependencyJobController` exposes a `resumeJob(String jobId, Integer overrideBatchSize)` method. When the LWC calls `resumeJob`, it passes a suggested batch size (half of the current `Scan_Batch_Size__c` CMDT value). `resumeJob()` sets `Status__c = 'Processing'` and writes the override to `Batch_Size_Override__c` on the job record (persisted, not transient - each new Queueable instance would lose a transient variable). `DependencyQueueable.execute()` reads `Batch_Size_Override__c` at startup and uses it instead of CMDT if non-null. This does NOT write back to CMDT. The LWC pause banner displays: "Scan paused. [Resume at a slower speed] or [Resume with current settings]."

---

## Key LWC Components

| Component | Role |
|---|---|
| `metaMapperApp` | Root shell; owns `jobId` state; switches between input, progress, and results views. Runs pre-flight Named Credential health check on mount; shows setup error state if check fails. **Deep-link routing:** on mount, reads URL params via `@wire(CurrentPageReference)`. If `jobId` param is present, skips the input screen and loads the results view for that job directly (calls `getJobStatus()` to verify the job exists). If `nodeId` param is also present, after results load, selects that node and opens the Node Details Panel. If the job no longer exists (expired by ring buffer): renders a dedicated error state - "This scan result is no longer available. It may have been automatically deleted." + "Start a new scan" button. If the job exists but the node is not found in the result set: loads results normally and shows a toast - "The linked component could not be found in this scan result." |
| `metaMapperInput` | Metadata type picklist, API name text input, typeahead object lookup (debounced 300ms, queries `EntityDefinition`), "Active Flows Only" checkbox with tooltip explanation. Shows estimated node complexity preview when available. Validates required fields before enabling submit. |
| `metaMapperProgress` | `lightning-progress-bar` + human-readable status label ("Analyzing metadata...", "Paused - limit reached", "Cancelling..."). Subscribes to `Dependency_Scan_Status__e` via `lightning/empApi`; falls back to `getJobStatus()` polling if `Disable_Platform_Events__c = true`. When polling fallback is active, shows persistent info label: "Live updates paused - refreshing every few seconds." Displays elapsed time. Cancel button transitions to disabled "Cancelling..." spinner on click; shows confirmation modal before cancelling. |
| `metaMapperResults` | Tab container: "Tree View" and "Graph View" sharing filter state. **AI Summary card** at top (visible when `Status__c = Completed`): displays `Scan_Summary_Text__c` with "Copy" button and "Ask Copilot" quick action. Stats tile (type counts from `Result_Summary__c`). Hosts export controls. |
| `metaMapperTree` | Virtual-rendered SLDS tree with search, type filter, level filter, and confidence filter. Supports collapse/expand per branch. Keyboard navigable. |
| `metaMapperGraph` | ECharts force-directed graph. Node click: selects node and populates the **Node Details Panel** (sidebar) - does NOT open Setup directly. Right-click: "Copy API Name". Hover: tooltip with `Component_Attributes__c` pills in plain English. "Expand All" guard: shows modal warning if node count > 1,000. Persistent sidebar legend. "Focus path to root". Graph toolbar search (quick-find: highlights matching nodes without affecting Tree). "?" keyboard shortcut legend. Type filter + level slider. ECharts theme registered for Salesforce dark mode (`slds-theme_inverse`). |
| `metaMapperNodeDetailsPanel` | Sidebar panel (right side of results screen). Renders full node data when a node is selected in either Tree or Graph: `Metadata_Name__c`, `Metadata_Type__c`, `Dependency_Depth__c`, `Discovery_Source__c`, `Supplemental_Confidence__c`, all `Component_Attributes__c` pills in plain English, `Ancestor_Path__c` rendered as a named breadcrumb chain, `Is_Circular__c` / `Is_Dynamic_Reference__c` flags with explanations. **Breadcrumb ID-to-Name resolution:** `Ancestor_Path__c` contains pipe-delimited `Metadata_Id__c` values. The component builds a `Map<String, String>` (id → name) from the flat node list already loaded in `metaMapperResults` (passed as a prop). Each ID in the breadcrumb is looked up in this map to display `Metadata_Name__c`. Fallback: if an ID is not found in the map (should not occur under normal operation), display the raw ID. No extra SOQL query required. "Open in Setup" button (primary action). "Copy Link" button generates a deep-link URL (`[current URL]?jobId=[jobId]&nodeId=[Metadata_Id__c]`) and copies to clipboard. Closes when selection is cleared. |
| `metaMapperExport` | Primary export: CSV ("Download as CSV") and JSON ("Download Complete Hierarchy (for developers)"). Default filename: `MetaMapper_[Target_API_Name]_[YYYYMMDD]_[HHmm]`. Advanced export (collapsible): package.xml ("Download Deployment Manifest"). No server round-trip. |

---

## UX Design Specification

### What MetaMapper Helps You Do

MetaMapper answers a single question that Salesforce Setup cannot: **"If I change or delete this component, what else will break?"** It traces every dependency of a metadata component - Apex classes, Flows, Validation Rules, Field Updates, page layouts, and more - and maps the full chain to any depth. Instead of manually cross-referencing Setup pages, running change sets blind, or discovering broken automation after deployment, you start a scan, wait a few minutes, and get a complete, explorable dependency map. The results are yours to filter, export, and share. Everything runs inside your org; nothing leaves the Salesforce trust boundary.

### Pre-Flight Check + First-Time Onboarding
On `metaMapperApp` mount, call `ToolingApiHealthCheck.verify()` via `@AuraEnabled`. Block the input form entirely until the check resolves. **Health check in-progress visual treatment:** while the callout is in flight, render a `lightning-spinner` variant="brand" size="medium" centered above the blocked input form. The form fields are rendered but disabled (not hidden). The spinner is removed and the form is enabled (or replaced by an error state) when the check resolves. Three distinct failure states (not a single generic error):

| Failure type | Detected by | UI message | Action link |
|---|---|---|---|
| Named Credential not authorized | HTTP 401 from health check callout | "MetaMapper needs one-time setup. An admin must authorize the Tooling API connection." | Link to `setup/SETUP.md` |
| Current user lacks permission | HTTP 403 or FIELD_CUSTOM_VALIDATION_EXCEPTION on Job insert | "You don't have access to MetaMapper. Ask your admin to assign you the MetaMapper Admin permission set." | No link; text only |
| Tooling API temporarily unreachable | HTTP 5xx or callout timeout | "MetaMapper cannot reach the Tooling API right now. This may be a temporary org issue." | "Retry" button that re-runs the health check |

Do not collapse all three into a single "setup required" message - each requires a different user action and a different responsible party (admin vs user vs wait).

**First-time guided tour:** After the Named Credential health check passes for the first time (detected via a `localStorage` flag `metaMapper_tourSeen_v1`), show a one-time `lightning-modal` walkthrough with three slides:
1. **"Reading the graph"** - Body: "Nodes are color-coded by metadata type. Solid borders show standard dependencies. Dashed borders indicate circular dependencies - these components depend on each other in a loop. Hover over any node to see details."
2. **"Warning badges"** - Body: "Orange warning badge = dynamic reference (an Apex string we can't fully resolve - verify manually). Red error badge = low confidence match (below 70% - verify before making changes). Dashed border = circular dependency."
3. **"Supplemental results"** - Body: "Some dependencies are found through secondary analysis, not the standard Salesforce metadata API. These may include false positives. Nodes with a confidence score below 70% should be verified before making any changes."

User can dismiss at any time. "Don't show again" checkbox label: **"Don't show again. I understand MetaMapper basics."** Checking this and clicking "Got it" on the final slide, or clicking "X" on any slide, sets `localStorage` flag `metaMapper_tourSeen_v1 = true`. Tour will not reappear on the same browser after dismissal. Bump the version suffix (e.g. `_v2`) on major UX changes to force the tour to re-display for all existing users.

### Input Screen (`metaMapperInput`)

| Element | Behavior |
|---|---|
| Metadata Type picklist | Required; shows supported types only |
| API Name input | Required; placeholder: "e.g. Account.My_Field__c"; inline validation on blur |
| Target Object typeahead | Required only when type is `CustomField`; shows validation message if omitted; placeholder: "e.g. Account" |
| "Only analyze active Flow versions" checkbox | Label: "Only analyze active Flow versions". Default checked; tooltip: "When checked, inactive and deprecated Flow versions are excluded from results. This reduces scan scope and processing time. Uncheck to include all Flow versions, including inactive ones." |
| Complexity preview | After API Name is entered, show: "Estimated scan scope: [Small / Medium / Large / Very Large] based on historical averages for this metadata type." (non-blocking, best-effort) |
| Submit button | Disabled until required fields valid; label "Analyze Dependencies". **Post-click loading state:** on click, immediately disable all form inputs and set the button to `is-loading` with label "Starting analysis...". If `createJob()` returns an error, re-enable all inputs and restore the button label. On success, parent component transitions to the progress view. |

### Progress Screen (`metaMapperProgress`)

**Status labels (human-readable, not Status__c API values):**

| Status__c value | UI label |
|---|---|
| Initializing | "Setting up your analysis..." |
| Processing | "Analyzing metadata... [N] components found so far" |
| Paused | "Analysis paused - encountered a complex component. You can resume at a slower speed or with current settings." |
| Cancelled | "Analysis cancelled. Partial results are available below." |
| Completed | "Analysis complete. [N] components found." |
| Failed | "Analysis failed. [first 200 chars of Error_Status_Message__c, or 'An unexpected error stopped the analysis.' if blank]. See details for diagnostics." |

**Cancel interaction:**
1. User clicks "Cancel" - show confirmation modal. **Modal title:** "Stop this analysis?" **Body:** "The job will stop at the next checkpoint. Partial results already found will remain available." **Buttons:** "Keep Running" (left, neutral style, default focus) and "Stop Analysis" (right, destructive style).
2. On confirm ("Stop Analysis"): button transitions to disabled "Cancelling..." with spinner; calls `cancelJob()`
3. LWC waits for `Dependency_Scan_Status__e` with `Status__c = 'Cancelled'` before re-enabling UI. **PE-disabled fallback:** if `Disable_Platform_Events__c = true` or PE has been auto-suppressed, the event will never arrive. In this case the LWC must fall back to polling `getJobStatus()` (same polling loop used for progress updates) until `Status__c = 'Cancelled'` is returned, then re-enable the UI. The cancel flow must not rely on PE as the sole completion signal.

**Cancel visual state machine (all intermediate states defined):**

| Phase | Cancel button state | Status label |
|---|---|---|
| Before confirmation modal | Enabled, label "Cancel" | Current status label |
| Confirmation modal open | Modal open; Cancel button unchanged | Current status label |
| Modal dismissed (user chose "Keep running") | Enabled, label "Cancel" | Current status label |
| Modal confirmed; `cancelJob()` in flight | Disabled, label "Cancelling..." with spinner | "Stopping analysis..." |
| `cancelJob()` call returned error | Re-enabled, label "Cancel"; toast error shown | Restored to previous label |
| `Status__c = 'Cancelled'` received (PE or poll) | Button hidden; "Start new scan" shown | "Analysis cancelled. Partial results are available below." |

**Long-running scan notice:** If the scan has been in `Processing` status for more than 15 minutes (tracked client-side from the first `Processing` status received), display a persistent dismissible info banner above the progress bar: "This scan is taking longer than usual. [View partial results so far] - this will not cancel the scan." The "View partial results so far" link calls `getNodeHierarchy()` and opens the results view without changing the job status. The banner is dismissed with a close icon. It reappears if the user navigates away and returns while the scan is still running.

### Graph View (`metaMapperGraph`)

**Node visual language (SLDS-compliant, not color-only):**

| Node type | Color | Icon | Shape indicator |
|---|---|---|---|
| Is_Circular__c | Type color | `utility:rotate` | Dashed border |
| Is_Dynamic_Reference__c | Type color | `utility:warning` | Solid border |
| Discovery_Source__c = Supplemental | Type color | `utility:info` | [S] badge |
| Supplemental_Confidence__c < 70 | Type color | `utility:error` | Red badge; click opens popover |
| Normal node | Type color | Type-specific icon | Solid border |

**Interactions:**
- **Click:** selects node and populates the Node Details Panel sidebar. Does NOT open Setup directly - "Open in Setup" is a button in the panel. This separates selection (inspect) from navigation (open Setup).
- **Right-click:** context menu with "Copy API Name", "Focus path to root", "Collapse subtree"
- **Hover:** SLDS tooltip with this exact template: `[Metadata_Name__c] ([Metadata_Type__c]) | [plain-English pill rendering] | [Confidence: N% - verify manually]` where pill rendering maps `Component_Attributes__c` keys to human sentences (e.g. `isWrite: true` -> "Writes to this field"; `activeVersions: 3` -> "3 active versions"; `cycleClosesAt: X` -> "Cycle closes at X"). Never render raw JSON in the tooltip.
- **"Expand All" guard:** if `Components_Analyzed__c > 1,000`, clicking "Expand All" shows modal: title "Large Graph", body "This graph contains [N] nodes. Expanding all levels may slow or freeze your browser. Consider using the Level Filter or exporting to CSV instead." Buttons: "Expand Anyway" (destructive-style, right) and "Keep Collapsed" (left, default focus).
- **"Focus path to root":** highlights the direct ancestor chain from selected node to root; dims all other nodes. A **"Clear Focus"** button appears in the graph toolbar while focus is active - do not rely on "click anywhere" alone as the only dismissal affordance.
- **Persistent legend:** always-visible sidebar listing all node types with color swatch + icon + label
- **Graph toolbar search:** lightweight search box on the graph toolbar (Ctrl+K shortcut). Placeholder text: "Search nodes in this graph..." Inline note below the input: "(Search applies to Graph view only)". Highlights matching nodes in the graph canvas without filtering them out. Does not affect Tree View (Tree-local search remains separate). Clears with Esc.
- **"?" keyboard shortcut legend:** small "?" icon button in graph toolbar. Opens a popover listing: `Ctrl+K` = Search graph, `Shift+?` = Open keyboard legend (global), `Esc` = Clear focus / search, arrow keys = traverse nodes, `Enter` = Select node (open Node Details Panel), right-click = Context menu. `Shift+?` works even when focus is inside the graph canvas. Rendered as an SLDS popover, not a modal.
- **Node Details Panel:** selecting a node (single click) populates the `metaMapperNodeDetailsPanel` sidebar panel with full node data. "Open in Setup" is the primary action button in the panel, not triggered by the click itself. This separates selection (inspect) from navigation (open Setup).
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
| Node action | Click selects node and populates Node Details Panel. "Open in Setup" is a button in the panel. |
| Right-click | Context menu with two options: "Copy API Name" (copies `Metadata_Name__c` to clipboard) and "Collapse branch" (collapses this node's subtree). "Focus path to root" is omitted from the Tree context menu - use Graph view for path visualization. |

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

**Simultaneous state update rules:**
- Filter changes are last-write-wins. If the user changes a filter while a tab switch is in progress, the filter change takes effect after the tab transition completes.
- Selection events (node clicks) are dropped during a tab transition. If a node click and a tab switch occur simultaneously, the selection is ignored - the user must re-select after the tab renders.
- No undefined state is possible: the parent component (`metaMapperResults`) owns all shared state and processes events in sequence. Child components fire events; they do not mutate shared state directly.

### Empty and Error States

| Scenario | UI |
|---|---|
| Job completed with zero results | Empty state illustration + "No dependencies found for [API name]. This metadata type may not have trackable dependencies, or the component may not exist." |
| Job failed mid-way | Error banner with collapsed detail. **Error summary text:** the first 200 characters of `Error_Status_Message__c`, truncated at the nearest word boundary with "..." appended. If `Error_Status_Message__c` is null or blank, use static fallback: "An unexpected error stopped the analysis." Full detail available via "View full error" expander showing the complete `Error_Status_Message__c`. "Start a new scan" button. |
| Job failed during result serialization | Distinct from "failed mid-way": `ResultSerializerQueueable` failed after all traversal completed - the job is `Failed` but all `Metadata_Dependency__c` records still exist and have value. Detected by: `Status__c = 'Failed'` AND `Components_Analyzed__c > 0` AND `Result_File_Id__c` is null. Error banner message must explicitly say: "Scan analysis is complete but results could not be saved. Your data is available for export for [Retention_Hours__c] hours before it is automatically deleted." Show a conditional "Download Partial Results" button (CSV and JSON) visible only in this specific state. |
| `getNodeHierarchy()` loading | Skeleton loader (3 rows of shimmer) in both Tree and Graph tabs while results load. Do not show empty state during loading. |
| Job status = Paused | Warning banner (not error): "Scan paused - encountered a complex component." + "[Resume at a slower speed]" button (calls `resumeJob()` with half batch size) + "[Resume with current settings]" button (calls `resumeJob()` with current batch size). **Resume button loading state:** on click of either button, immediately disable both buttons and show a `lightning-spinner` size="small" inline next to the clicked button. On `resumeJob()` success, the banner is replaced by the progress view. On error, re-enable both buttons and render a toast error. |
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
- Keyboard navigation: Tab to focus graph container; arrow keys to traverse nodes; Enter to select node (populates Node Details Panel)
- Screen reader: every node badge includes `aria-label` in plain English (e.g. "Warning: low confidence supplemental match")
- Color-blind safe: icon + border shape carry meaning independent of hue
- Dynamic content updates (progress counter, status label) use `aria-live="polite"` so screen readers announce changes without interrupting user input
- Graph interaction results (node highlight, focus path activation) announced via a dedicated `aria-live="polite"` region in the graph toolbar - e.g. "Focus path activated: 4 nodes highlighted" and "3 nodes match your search"

### Results Screen - AI Summary Card

When `Status__c = Completed`, display a prominent card at the top of the Results screen (above both tabs):

| Element | Detail |
|---|---|
| Card title | "Scan Summary" |
| Body | `Scan_Summary_Text__c` text verbatim (e.g. "This scan found 42 dependencies: 3 active Flows, 5 Apex classes...") |
| "Copy" button | Copies `Scan_Summary_Text__c` to clipboard. On click: (1) copy text to clipboard, (2) button label changes to "Copied!" with `utility:check` icon, (3) after 2 seconds reverts to "Copy". No toast notification needed - the inline label change is the confirmation signal. |
| "Ask Copilot" button | Opens Einstein Copilot with `Scan_Summary_Text__c` pre-populated. Conditionally rendered: shown only if Copilot is enabled in the org. If Copilot is unavailable, show helper text "Einstein Copilot not available in this org." in place of the button (do not hide silently). Note: the exact LWC API for programmatically opening Einstein Copilot with pre-populated text is platform-dependent and subject to Salesforce Copilot API availability - implementation details TBD. |
| Card height | Compact by default - collapsed height shows the first two sentences of `Scan_Summary_Text__c` followed by an ellipsis. Full text revealed by a "Show more" inline toggle. Prevents the card from pushing Tree/Graph tabs below the fold on smaller laptops. |

The card is not shown for Failed, Cancelled, or Paused jobs. For Paused jobs, a warning banner replaces it.

**Responsive behavior at < 1024px:** the card renders below the stats tile and above the tabs, with no "Show more / collapse" toggle - the first sentence of `Scan_Summary_Text__c` is shown in full (one paragraph, no truncation). The "Ask Copilot" button is hidden on viewports < 1024px (rendered only at >= 1024px).

**Null state (loading):** `Status__c` transitions to `Completed` before `ScanSummaryQueueable` has run. The card must handle a null `Scan_Summary_Text__c`: show a skeleton shimmer in place of the body text while polling `getJobStatus()` until the field is non-null. Do not render an empty card or suppress the card entirely - the shimmer communicates "generating summary" without confusing the user. Polling stops and the shimmer is replaced with the text once the field is populated.

### Export Hierarchy

**Primary exports (prominent placement):**
- "Download as CSV" - flat row-per-node, for analysis in Excel / Sheets. Default filename: `MetaMapper_[Target_API_Name]_[YYYYMMDD]_[HHmm].csv`
- "Download Complete Hierarchy (for developers)" - nested tree with all `Component_Attributes__c` pills. Tooltip: "Contains all dependency data including context fields. Useful for scripting, auditing, or custom tooling." Default filename: `MetaMapper_[Target_API_Name]_[YYYYMMDD]_[HHmm].json`

**Advanced exports (collapsible "Advanced" section):**
- "Download Deployment Manifest" - package.xml, developer artifact; tooltip: "Use this to deploy or retrieve the components found in this scan using Salesforce CLI or VS Code. Includes only components from this scan (managed packages excluded)."

### Settings UI (CMDT labels)

When surfacing `MetaMapper_Settings__mdt` fields in any admin UI, use human-readable labels:

| Field API name | UI label | Help text |
|---|---|---|
| `Retention_Hours__c` | "Keep failed/cancelled jobs for" | "Failed and cancelled scan records older than this are automatically deleted. Does not affect completed scans - those are managed by the 'Keep last N completed scans' setting. Minimum 1 hour. Recommended: 72+ hours for diagnostic use." |
| `Scan_Batch_Size__c` | "Analysis speed (standard)" | "How many metadata components to analyze per processing step. Lower this if you see timeout errors." |
| `Flow_Scan_Batch_Size__c` | "Analysis speed (Flow jobs)" | "Batch size when 'Only analyze active Flow versions' is enabled. Each Flow node requires one extra validation callout - 15 Flow nodes = 15 extra callouts. Lower this if you see 'Too many callouts' errors on Flow-heavy orgs. Default: 15." |
| `Dml_Reserve_Rows__c` | "Safety margin (DML rows)" | "Advanced: number of database rows to reserve as a safety buffer. Increase for orgs with very connected metadata." |
| `Disable_Platform_Events__c` | "Disable live progress updates" | "Turn on if your org is hitting real-time event limits. Progress will refresh every few seconds instead." |
| `Stall_Detection_Threshold__c` | "Pause after N empty processing cycles" | "If the analysis runs this many cycles without finding new components, it pauses and alerts you." |
| `Max_Concurrent_Jobs__c` | "Max concurrent scans" | "How many MetaMapper scans can run at the same time. Default 2. Raise only for orgs with large async capacity." |
| `Cleanup_Chunk_Size__c` | "Cleanup chunk size (Advanced)" | "Records deleted per database transaction during cleanup. Default 2,000. Lower this value if you see 'Too many DML statements' errors from other automation during cleanup." |
| `Max_Stored_Jobs__c` | "Keep last N completed scans" | "How many completed scan results to keep as files in your org. When the limit is reached, the oldest result is deleted automatically. Completed scans use File Storage (not Data Storage). Default 5." |
| `Max_Components__c` | "Maximum components per scan" | "The scan pauses automatically when this many components are found. Default 5,000. Do not raise above 5,000 without testing - the result serializer may hit memory limits on large scans with deeply nested metadata. Set to 0 to disable (not recommended)." |
| `Storage_Reserve_MB__c` | "Minimum free storage required (MB)" | "MetaMapper checks that your org has at least this much free data storage before starting a new scan. Increase this value if you see storage-related errors during active scans. Default 50MB." |

**Admin-only controls (Settings UI):**
- "Reset First-Time Tour" button: clears the `metaMapper_tourSeen_v1` localStorage flag for the current browser session. Useful for admins demoing the tour to new team members. Implemented as a client-side JS action - no Apex required.

---

## Query Strategy

### IN Clause Chunking
Start with batches of **100 IDs** as a safe default, but split is driven by **estimated query character length**, not a fixed count. The Tooling API REST endpoint embeds SOQL in the URL - URI length depends on the IDs themselves, encoding, and the surrounding SOQL string. If estimated URL length exceeds 8KB, halve the batch before sending. 100 IDs is the starting estimate; the dynamic check is authoritative.

**Exact formula:** `estimatedLength = 80 + (batchIds.size() * 19)` where 80 = base SOQL + callout endpoint overhead, 19 = 18-char ID + comma delimiter. Check: `if (80 + (batchIds.size() * 19) > 8000) { halve batch; }`. At this formula, maximum safe batch size is `(8000 - 80) / 19 = 418 IDs`. Starting at 100 provides comfortable headroom.

### QueryMore
Tooling API results exceeding 2,000 rows return a `nextRecordsUrl`. `MetadataDependencyService` must follow `nextRecordsUrl` iteratively until `done = true` before returning results to the Queueable. Each follow-up counts against the callout budget.

**Cursor expiration risk:** Tooling API query cursors typically expire after ~15 minutes. If a complex node causes the Queueable to self-chain and the chained job waits in the Salesforce Flex Queue during high org utilization, the cursor may expire before the next execution resumes QueryMore. `MetadataDependencyService` must wrap each `nextRecordsUrl` callout in a try/catch for `INVALID_QUERY_LOCATOR` (HTTP 400 with that error code). On catch: restart the query from scratch using the same ID batch, do not fail the job. Log the restart to `Error_Status_Message__c` as a diagnostic note.

### Reactive HTTP 414 Handling
If a callout returns HTTP 414 or 431, split the current batch in half and retry both halves. Do not fail the job on this error.

**Depth limit (critical):** The split-and-retry must track recursion depth. Use `Integer splitDepth` passed as a parameter through each retry. Maximum depth: **5 levels** (1 → 2 → 4 → 8 → 16 → 32 batches). At depth 5, if the batch still returns 414: log to `Error_Status_Message__c` ("Component [IDs] returned HTTP 414 after 5 split attempts; skipping this batch. Possible cause: metadata IDs contain non-standard characters."), mark affected nodes as `Dependencies_Fetched__c = true`, and continue. Do NOT fail the job. Without this depth limit, a "poison" component with extremely large IN-clause encoding will recursively consume all callout budget in a single execution.

### Limit Guardrails (Remaining-Budget Model)

**Placement: the guardrail runs in two places - not just at the end of the execution:**
1. **Pre-batch check** - before starting the Tooling API callout for the current node batch.
2. **Mid-loop check (per node)** - inside the result-processing loop, before adding newly discovered children to the insert list. A single high-fan-out node (e.g. a core Custom Object) can return 4,000+ dependencies in one callout; the post-loop check would be too late.

```
// --- Callout budget (remaining-headroom model) ---
Integer calloutsRemaining = Limits.getLimitCallouts() - Limits.getCallouts();
// Headroom needed per remaining batch:
// +1 dependency query
// +1 if QueryMore may be needed (determined by Last_Result_Count__c from prior execution: true if >= 1,900)
// +1 per Flow node in current batch if Active_Flows_Only__c = true (1 validation callout per Flow node)
// +4 buffer for reactive 414/431 retry splits (up to 2 levels: 1 + 2 + 4 = 7; +4 covers most cases)
// queryMorePossible = (job.Last_Result_Count__c != null && job.Last_Result_Count__c >= 1900)
// needsFlowValidation = Active_Flows_Only__c AND current batch contains Flow nodes (count, not boolean - 1 callout per node)
Integer headroom = 1 + (queryMorePossible ? 1 : 0) + flowNodeCount + 4;

// --- DML row budget ---
// Reserve DML_Reserve_Rows__c rows (default 750) from MetaMapper_Settings__mdt.
// Conservative: a single high-fan-out node can return 2,000+ children.
Integer dmlReserve = (Integer) settings.Dml_Reserve_Rows__c; // read from CMDT, default 750
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

// --- DML statement count budget (150 limit; reserve 40 for handler SOQL + upsert + status update) ---
// 40 = worst-case 5 supplemental handlers × ~8 statements each. Reserve of 10 is insufficient.
Integer dmlStmtsRemaining = Limits.getLimitDmlStatements() - Limits.getDmlStatements();

if (calloutsRemaining < headroom
    || dmlRemaining < dmlReserve          // dmlReserve from MetaMapper_Settings__mdt, default 750
    || heapPct >= 0.70                    // 0.70 not 0.80 - async heap calculations lag; 0.80 leaves insufficient margin when parsing large nested JSON from Tooling API
    || cpuPct >= 0.75
    || queryRowsRemaining < 1000
    || queriesRemaining < 10
    || dmlStmtsRemaining < 40) {          // 40 not 10 - supplemental handlers can consume 8+ DML statements each
    System.enqueueJob(new DependencyQueueable(jobId, activeFlowsOnly, null)); // null = no batch size override; normal continuation
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
| JSON | Nested tree mirroring `Metadata_Dependency__c` hierarchy with `Component_Attributes__c` pills included |
| package.xml | Valid Salesforce deployment manifest grouped by `<types>`. Excludes managed package components. **Namespace detection rule:** a component is excluded if its `Metadata_Name__c` matches the pattern `^[A-Za-z]\w+__\w` (one or more word characters, then a double underscore, then at least one more character). For `CustomField` (API name format `Object.Field` or `Object__c.Field__c`), apply the check to the field portion only - the segment after the last dot. This rule is consistent with Salesforce CLI and sfdc-soup behavior. |

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
| `Flow_Scan_Batch_Size__c` | Number | 15 | Batch size when `Active_Flows_Only__c = true`. **Flow validation is 1 callout per Flow node** (not 1 per batch) - each Flow node requires a separate Tooling API callout to validate its version status. A batch of 15 Flow nodes consumes 15 validation callouts. The headroom formula accounts for `flowNodeCount` (the number of Flow nodes in the current batch result), not a single boolean flag. Default lowered from 30 to 15 to stay within callout budget for orgs with dense Flow dependencies. |
| `Dml_Reserve_Rows__c` | Number | 750 | DML rows to reserve in the guardrail before chaining. Raise for orgs with high-fan-out metadata (e.g. heavily referenced CustomObjects). |
| `Disable_Platform_Events__c` | Checkbox | false | When true, suppresses `Dependency_Scan_Status__e` publish and falls back to polling via `getJobStatus()`. Use when org is approaching the daily Platform Event delivery limit. |
| `Stall_Detection_Threshold__c` | Number | 5 | Number of consecutive re-chains with zero `Components_Analyzed__c` progress before the engine pauses the job and surfaces a warning to the UI. |
| `Max_Concurrent_Jobs__c` | Number | 2 | Maximum number of simultaneously active MetaMapper Queueables. `createJob()` rejects new submissions above this threshold with a user-facing message. Raise for orgs with large flex queue allocations. |
| `Cleanup_Chunk_Size__c` | Number | 2000 | DML chunk size for `DependencyCleanupBatch` node deletion. Default 2,000 (leaves 8,000 DML rows for customer automation). Do not raise above 4,000 for open-source deployments into unknown orgs. |
| `Max_Components__c` | Number | 5000 | Hard cap on `Components_Analyzed__c` per job. When reached, the engine pauses the job and surfaces a warning. Default 5,000 (safe for Developer Sandbox data storage during active scan). **Serializer ceiling:** `ResultSerializerQueueable` serializes all nodes in a single heap-bound JSON operation. At ~2KB per node, the 12MB async heap supports approximately 5,000-6,000 nodes. Raising `Max_Components__c` beyond this ceiling without redesigning the serializer for chunked streaming will cause the "results too large" failure path. Set to 0 to disable the cap (not recommended without a chunked serializer). |
| `Storage_Reserve_MB__c` | Number | 50 | Minimum free data storage in MB required before `createJob()` accepts a new scan. Checked via `OrgLimits` on submission. Applies to the transient peak - during an active scan nodes live in Data Storage before serialization to File Storage on Completed. Default 50MB ensures sufficient headroom during the scan peak. |
| `Max_Stored_Jobs__c` | Number | 5 | Maximum number of completed scan results retained org-wide as Salesforce Files. When a new job completes and this limit is reached, the oldest completed job (and its result file) is deleted automatically. This bounds File Storage consumption regardless of how many scans are run. Default 5 (keeps ~5-15MB of file storage). Raise to 10-20 for production orgs or teams needing longer result history. |

> Hard-coding batch size and DML reserve is inappropriate for an enterprise tool. A highly-connected org may need `Flow_Scan_Batch_Size__c = 15` and `Dml_Reserve_Rows__c = 1500`. Admins tune without a code deploy.

### Sandbox vs. Production Defaults

MetaMapper is designed to run in both Developer Sandboxes and production orgs. Developer Sandboxes have a hard 200MB data storage limit - a single large uncapped scan can exhaust the entire allocation. `createJob()` detects the org type via `[SELECT IsSandbox FROM Organization]` and applies a conservative profile automatically if no admin has customized the settings:

| Setting | Developer Sandbox default | Production default | Reason |
|---|---|---|---|
| `Retention_Hours__c` | 1 | 72 | Failed/Cancelled jobs with partial nodes still consume Data Storage; shorter retention limits the window of exposure. |
| `Max_Concurrent_Jobs__c` | 1 | 2 | Concurrent active scans can simultaneously peak Data Storage; serializing one at a time keeps peak bounded. |
| `Max_Components__c` | 5,000 | 5,000 | Bounded by `ResultSerializerQueueable` heap capacity. Practical safe ceiling is ~2,000-3,000 nodes for deep/complex metadata trees. Do not raise above 5,000 without testing serializer heap consumption - the serializer will hit the heap failure path at high node counts with deep Ancestor_Path__c values. A chunked serializer is required before this ceiling can be safely raised. |
| `Storage_Reserve_MB__c` | 50 | 200 | Ensures sufficient free Data Storage for the scan peak before committing to a new job. |
| `Max_Stored_Jobs__c` | 5 | 10 | Bounds File Storage consumption. Both sandbox and production have 200MB file storage; sandboxes typically have less available headroom. |

These are applied only when the CMDT record has never been saved with explicit values (i.e. first-install defaults). Once an admin saves the CMDT record, their explicit values take precedence.

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
1. **Checks `Status__c = 'Processing'` before updating** - if the job is already Completed or Cancelled (e.g. set by a concurrent Queueable instance), skip the Failed update entirely. This prevents a losing race from overwriting a Completed status with Failed.
2. Updates `Metadata_Scan_Job__c.Status__c = 'Failed'`, sets `Error_Status_Message__c` to `e.getMessage() + '\n' + e.getStackTraceString()`, and sets `Status_Closed_At__c`.
3. Publishes a `Dependency_Scan_Status__e` failure event.
4. Does NOT re-throw the exception (allows the catch block's DML to commit).

> **Why stack trace?** `e.getMessage()` alone is insufficient for async debugging - the stack trace identifies the exact line and call chain where the failure occurred, which is critical for diagnosing limit errors and callout failures in production without debug logs.

> **Why savepoint?** Without `Database.rollback(sp)`, partial engine work (e.g., some nodes inserted, some not) remains in the database in a corrupt intermediate state. The rollback cleans this up; the subsequent status update DML commits cleanly in the same transaction as a separate operation after the rollback point.

---

## Metadata Component Descriptions (Required for All Deployments)

Every component must carry a description in its metadata XML. Descriptions must answer: what it is, why it exists, and key constraints. Written for admins, not developers.

### Custom Objects

| Object | Description |
|---|---|
| `Metadata_Scan_Job__c` | Tracks one metadata dependency scan. Created when a user submits a scan request. Holds all configuration (target component, scan options), runtime state (status, progress counter), results (summary, plain-English description), and error detail. Records are automatically deleted after the configured retention period by the cleanup batch. Do not delete records manually while Status is Initializing or Processing. |
| `Metadata_Dependency__c` | Represents one metadata dependency discovered during a scan. Records exist only while the scan is active - they are the engine's working state that tracks which components have been found and which still need processing. When the scan completes, all records for that job are serialized to a Salesforce File and deleted, freeing Data Storage. Records for Failed or Cancelled scans remain until the nightly cleanup batch removes them. Do not create or edit records manually. |

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
| `Status_Closed_At__c` | Timestamp set the moment Status transitions to Completed, Failed, or Cancelled. Used by the cleanup batch to calculate retention age. Never set for jobs that are still running. The cleanup batch uses this field, not CreatedDate, to avoid deleting in-progress scans. Do not edit manually. |
| `Total_Processing_Cycles__c` | Number of times the async engine has processed a batch for this scan. Incremented on every execution. Compared against Last_Successful_Cycle__c to detect stall loops. Do not edit manually. |
| `Last_Successful_Cycle__c` | The value of Total_Processing_Cycles__c at the last execution that made progress (Components_Analyzed__c increased). Reset when new components are found. If the gap between Total_Processing_Cycles__c and this field reaches the Stall Detection Threshold, the scan is automatically paused. Do not edit manually. |
| `Scan_Summary_Text__c` | Plain-English summary of scan results, generated after the scan completes (e.g. "This scan found 42 dependencies: 5 Apex classes, 3 active Flows"). Displayed in the Scan Summary card. Populated asynchronously by a background process after Status = Completed - it may appear a few seconds after the scan finishes. |
| `Result_File_Id__c` | The ID of the Salesforce File (ContentDocument) that stores the complete scan result as JSON. This field is populated after the scan completes and all dependency records have been serialized and deleted. It is the pointer the app uses to load results for completed jobs - instead of querying thousands of individual records, it reads a single file. Null for active, failed, or cancelled scans. Do not edit manually. |

### Metadata_Dependency__c Fields

| Field | Description |
|---|---|
| `Metadata_Scan_Job__c` | Reference to the parent scan job. All dependency records for a scan are deleted when the job is deleted. Required. |
| `Parent_Dependency__c` | Reference to the parent dependency in the spanning tree. Null for the root component (the scan target itself). Used to reconstruct the dependency tree in the UI. |
| `Metadata_Id__c` | The 18-character Salesforce record ID of the metadata component as returned by the Tooling API. Used as the unique identifier for deduplication and cycle detection. Do not edit manually. |
| `Metadata_Type__c` | The type of the metadata component (e.g. ApexClass, Flow, CustomField). Used for color-coding in the graph, type filtering in the tree, and routing to supplemental query handlers. |
| `Metadata_Name__c` | The human-readable API name of the metadata component (e.g. AccountTrigger, My_Custom_Field__c). Displayed as the node label in the tree and graph views. |
| `Dependency_Depth__c` | How many levels deep this component is from the scan target. 0 = the scan target itself. 1 = direct dependency. Used for depth filtering in the UI. |
| `Dependencies_Fetched__c` | Internal engine flag. False = this component's dependencies have not yet been fetched from the Tooling API. True = fetching complete, or intentionally skipped because the node is circular or a dynamic reference that cannot be resolved. Do not edit manually. |
| `Is_Circular__c` | True if this component appears in its own ancestor chain (a real dependency cycle, e.g. A depends on B which depends on A). Displayed with a dashed border in the graph. The scan does not traverse further from circular nodes to prevent infinite loops. |
| `Is_Dynamic_Reference__c` | True if this dependency was detected as a dynamic Apex string reference that cannot be statically resolved. Displayed with a warning badge. These nodes represent potential dependencies that require manual investigation. |
| `Component_Attributes__c` | JSON object containing type-specific contextual information about this dependency (e.g. whether an Apex class writes to a field, how many active Flow versions reference it). Rendered as plain-English badges in the UI. Never displayed as raw JSON. |
| `Discovery_Source__c` | How this dependency was discovered. ToolingAPI = found by the standard MetadataComponentDependency query. Supplemental = found by a secondary handler query that fills a known Tooling API gap. Supplemental results carry a confidence score. |
| `Ancestor_Path__c` | Pipe-delimited chain of Metadata_Id__c values from the root component down to this node's parent (e.g. "id1|id2|id3"). Used to detect true ancestry cycles. Preserved on circular nodes for debugging and export. Do not edit manually. |
| `Supplemental_Confidence__c` | Confidence score (0-100) for supplemental dependencies only. Reflects how certain the match is: exact field matches score 95, regex formula matches score 65. Nodes below 70 display a warning badge prompting manual verification. Null for Tooling API nodes. |
| `Component_Uniqueness_Key__c` | Composite key used to prevent duplicate records: format is "JobId:Metadata_Id__c". Used as an External ID for upsert operations in the scan engine. Prevents race conditions when multiple async cycles discover the same component simultaneously. Do not edit manually. |
| `Cycle_Detection_Index__c` | Internal engine field. Stores pipe-delimited 6-character prefixes of each ancestor ID as a fast pre-screen index. The engine checks this index before running the expensive full Ancestor_Path__c string search. A match here triggers the conclusive full-string confirmation; no match skips it entirely. Only consulted by the cycle detection engine. Do not edit manually. |

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
| `Max_Components__c` | Maximum number of dependency records this scan is allowed to create. When reached, the scan pauses automatically and prompts the user to raise the limit or accept partial results. Default: 5,000. Set to 0 to disable the cap (not recommended - the serializer will fail at high node counts). Do not raise above 5,000 without validating serializer heap capacity for your org's typical metadata depth. |
| `Storage_Reserve_MB__c` | Minimum free data storage in megabytes required before a new scan is accepted. Checked at scan submission using org storage limits. If free storage is below this value, the scan is rejected with a clear message. Default: 50MB. Lower this value only if you are certain the org has sufficient storage headroom. |
| `Flow_Scan_Batch_Size__c` | Batch size used specifically for scans where Active Flows Only is enabled. Lower than the standard setting because each Flow requires an additional Tooling API callout to validate version status. Default: 30. |
| `Dml_Reserve_Rows__c` | Number of DML rows the engine reserves as a safety margin before chaining to the next processing cycle. Increase this value for orgs with highly connected metadata where a single component can have thousands of dependencies. Default: 750. |
| `Disable_Platform_Events__c` | When enabled, suppresses real-time progress events and the UI falls back to polling every few seconds. Use this if your org is approaching its daily Platform Event delivery limit. Can also be set automatically by the engine if the limit is exceeded. Default: false. |
| `Stall_Detection_Threshold__c` | Number of consecutive processing cycles with zero new components before the engine pauses the scan and alerts the user. Prevents infinite loops caused by pathological metadata structures. Default: 5. |
| `Max_Concurrent_Jobs__c` | Maximum number of MetaMapper scans that can run simultaneously in this org. New scan requests are rejected when this limit is reached. Raise this value only for orgs with large async processing capacity. Default: 2. |
| `Cleanup_Chunk_Size__c` | Number of dependency records deleted per database transaction during the nightly cleanup process. Keep at 2,000 or lower to leave sufficient database operation headroom for other automation in your org. Default: 2,000. |
| `Retention_Hours__c` | How many hours to keep Failed and Cancelled scan records (and any partial node records they contain) before automatic deletion. Completed scan results are retained by the ring buffer (Max_Stored_Jobs__c) and are not subject to this time limit. Default: 72. |
| `Max_Stored_Jobs__c` | Maximum number of completed scan results retained as Salesforce Files. When a scan completes and this limit is exceeded, the oldest completed job and its result file are deleted automatically. Completed results use File Storage, not Data Storage. Default: 5 (sandbox), 10 (production). |

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
- `Cycle_Detection_Index__c` hash shortcut has a negligible probability of false-positive cycle detection (hash collision on the 6-char prefix); the full `Ancestor_Path__c` string is always used to confirm before setting `Is_Circular__c = true`.
- `Scan_Summary_Text__c` is populated only on job Completed. Failed, Cancelled, and Paused jobs do not have an AI summary. Agentforce Actions should check `Status__c = 'Completed'` before reading this field.
- **Storage model and sandbox safety:** MetaMapper uses a hybrid model - `Metadata_Dependency__c` records exist only during the active scan (engine state), then are serialized to a Salesforce File (`ContentVersion`) and deleted when the job completes. Data Storage impact for a completed job is ~5KB (job record only). File Storage impact is ~1-3MB per completed job. A ring buffer of `Max_Stored_Jobs__c` completed results bounds total file storage consumption to ~5-15MB. **During an active scan, nodes do temporarily occupy Data Storage** - a 5,000-node scan (the sandbox default cap) consumes ~25MB of Data Storage at peak. Developer Sandbox has 200MB of both Data Storage and File Storage. Conservative sandbox defaults (`Max_Components__c = 5,000`, `Storage_Reserve_MB__c = 50`) ensure the transient peak stays within safe limits even when the sandbox is already partially used. Failed and Cancelled jobs may retain partial node records until the nightly cleanup batch removes them; `Retention_Hours__c = 1` in sandboxes limits this window.
- **Result serialization is terminal on failure:** if `ResultSerializerQueueable` fails (e.g. heap limit during serialization), the job transitions to `Failed` and cannot be resumed. The admin must start a new scan. Node records **may** remain in the org and are available for export until the nightly cleanup batch removes them (`Retention_Hours__c`) - but only if the failure occurred before the bulk-delete step (step 5). If failure occurs during or after node deletion, records are partially or fully gone. The UI surfaces the export option in this state; the LWC detects it via `Status__c = 'Failed'` AND `Components_Analyzed__c > 0` AND `Result_File_Id__c` is null.
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
