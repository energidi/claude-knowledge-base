# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Output Rules
- After applying fixes (code review rounds, bug fixes, any edits): do not explain what was changed. Make the edits and stop. The user can read the diff.

---

## sf-review Session Protocol (Non-Negotiable)

When the user asks to run a code review (with or without specifying skills):

1. **Run all four skills in parallel**: `sf-review-architecture`, `sf-review-ux`, `sf-review-naming`, `sf-review-design`. Never fewer. Never sequentially when parallel is possible.
2. **Apply all approved fixes** across Apex, XML, and LWC files.
3. **Grep verify**: after applying fixes, run a grep scan confirming zero stale references in `force-app/`.
4. **Update `MetaMapper_Technical_Design.md`** with any renamed fields, classes, or architectural changes.
5. **Add a new round entry to `MetaMapper_Code_Review.md`** summarizing what changed.
6. **Confirm all five steps above are done** before writing TASK COMPLETE.

TASK COMPLETE is blocked until all six steps are verified. A grep scan that finds stale references is not a passing verification.

---

## Code Review and Deployment Protocol (Non-Negotiable)

When writing Apex classes, LWC components, or any other code artifact:

1. **Write** all code for the current artifact group (e.g. all Phase 3 classes).
2. **Apply fixes** based on review findings.
3. **Repeat** until the user explicitly says the code is approved.
4. **Only then**: deploy to the Salesforce org and push to GitHub.

Never deploy code before the user explicitly approves it. "Proceed" or "do it" means write the code - not deploy it.

---

## Document Management

### MetaMapper_Technical_Design.md
Updated **only when the design changes** (CLAUDE.md, architecture, data model, UX spec, key decisions).
- File: `MetaMapper_Technical_Design.md` in the project root
- Update method: Edit tool with targeted diffs only - never rewrite from scratch

### MetaMapper_Code_Review.md
Updated **only when the change log needs a new entry**. Contains: project background + for each class a 1-2 sentence purpose statement + change log. No code blocks.
- File: `MetaMapper_Code_Review.md` in the project root
- Update method: Edit tool with targeted diffs only - never rewrite from scratch

### Markdown Update Method (Token-Efficient)

For either document:
1. Use the **Edit tool with targeted diffs** - only the changed sections.
2. Never rewrite the full document from scratch.

---

## External Review Round Workflow

When the user pastes architecture or UX reviews from external sources:

1. **Parse all reviews first.** Read every review before producing any output.
2. **Present an assessment table** - one row per actionable item. Columns: `#`, `Source`, `Issue`, `Action`, `Impact`. Mark items to skip with reason.
3. **Wait for explicit approval** before applying anything.
4. **On approval: apply ALL CLAUDE.md edits first.**
5. **Never name AI tools in technical design documents.** Strip all reviewer names, tool names, and score references - no engineering value.
6. **Never deploy immediately after updates** - only push CLAUDE.md + Markdown files to GitHub after explicit user approval.

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
4. When no unprocessed nodes remain, `DependencyQueueable` enqueues `ScanResultFileQueueable` and exits. The serializer serializes all node records to a Salesforce File, deletes the node records to free Data Storage, enforces the ring buffer, transitions the job to `Completed`, and fires notifications. This two-step handoff keeps the engine's governor budget separate from the serialization work.

### Tooling API Callout (Loopback Auth)

Direct Tooling API calls from within async Apex require a **Named Credential loopback**:
- Connected App + Auth Provider configured in the org
- Named Credential `MetaMapper_Tooling_API` authorized once by admin post-install. **Description for admin visibility:** Loopback Named Credential enabling MetaMapper to call the Salesforce Tooling API from async Apex. Requires one-time admin authorization after install. Do not delete or deauthorize while scans are running - any active scan will fail on its next callout.
- Callout target: `callout:MetaMapper_Tooling_API/services/data/v66.0/tooling/query/?q=...`
- These three config items cannot be source-tracked; setup instructions live in `setup/SETUP.md`

### Cycle Detection (Two-Tier)

A single global visited set incorrectly flags shared/diamond dependencies (node B reachable via Aâ†’B and Câ†’B) as circular. These are valid repeated references, not cycles. Two separate concerns must be separated:

**Tier 1 - Global deduplication (`processedIds`):**
After the Tooling API returns dependency results for the current batch, query the DB scoped to only those returned IDs:
`SELECT Metadata_Id__c FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :jobId AND Metadata_Id__c IN :currentResultIds`
Rows returned = number of already-inserted matches within `currentResultIds` (bounded by the result set size, not by the IN list size). This avoids the full-table scan that would occur when querying all previously inserted nodes. If a result is already in this set, **skip insertion entirely** (deduplication). Do NOT mark as circular.

> **Why not query all nodes upfront?** At 10k-20k nodes a full-scan query consumes a large portion of the 12MB async heap before any Tooling API work begins. Scoping to `currentResultIds` limits the dedup query to matches within the current callout's result set only.

**Tier 2 - True ancestry cycle detection (`Ancestor_Path__c`):**
Each `Metadata_Dependency__c` stores a pipe-delimited `Ancestor_Path__c` field: the chain of ancestor `Metadata_Id__c` values from root to this node.

- **Root node:** `Ancestor_Path__c = ''` (empty string, not null). The first child path is built by the ternary formula: `(String.isBlank('') ? '' : '' + '|') + rootId = rootId` - no leading pipe, no trimming needed.
- **Correct path-building:** `child.Ancestor_Path__c = (String.isBlank(parent.Ancestor_Path__c) ? '' : parent.Ancestor_Path__c + '|') + parent.Metadata_Id__c`. This avoids a leading delimiter on first-level children.
- **Cycle check:** after building `child.Ancestor_Path__c` (which already includes `parent.Metadata_Id__c` as its last segment), check: `('|' + child.Ancestor_Path__c + '|').contains('|' + childId + '|')`. This catches all cases including 1-hop self-referential cycles and 2-hop A→B→A cycles. Checking `parent.Ancestor_Path__c` alone (without the parent's own ID) would miss the 2-hop case where the child IS the parent. A raw `String.contains(id)` is vulnerable to false positives where one 18-char ID is a substring of another - the delimiter-wrapped form is the authoritative check.
- **Circular node path:** Keep the **full `Ancestor_Path__c`** on circular nodes - do NOT set to null. The path is most valuable precisely when a cycle is found (debugging, export). Mark `Is_Circular__c = true`, `Dependencies_Fetched__c = true`. Append the cycle-closing segment to `Dependency_Context__c` as `{"cycleClosesAt": "<parentMetadataId>"}` for UI visualization.
- **CPU consideration:** `String.contains()` on a long Ancestor_Path__c string inside an inner loop is CPU-intensive for deep trees. Check `Limits.getCpuTime()` against the guardrail threshold **inside the node-processing loop**, not only at the batch boundary.

> **Ancestor_Path__c capacity and guard:** At 18 chars/ID + 1 delimiter, a depth-1,500 path would be ~28,500 chars - within the Long Text 32768 field limit. However, appending beyond ~32,000 chars risks a `StringException`. **Before building the path for any child node**, check: `if ((parent.Ancestor_Path__c?.length() ?? 0) + 20 > 32000)` - if true, set `Dependencies_Fetched__c = true` and `Dependency_Context__c = '{"v":1,"maxDepthExceeded":true}'`, log to `Scan_Diagnostic_Log__c` ("Max ancestor depth exceeded at [nodeId]; traversal stopped at this node"), and insert the child (do not skip - it still needs a record). Do NOT set `Is_Circular__c = true`: depth overflow is a traversal ceiling, not an ancestry cycle. Setting `Is_Circular__c` would cause the UI to render these nodes with dashed "circular dependency" styling, which is incorrect. `Dependencies_Fetched__c = true` is the correct mechanism to stop further traversal. Do NOT fail the job. The actual field limit is 32,768 chars; the 32,000 threshold provides 768 chars of conservative headroom against any concurrent path-append race. The authoritative check is `(parent.Ancestor_Path__c?.length() ?? 0) + 20 > 32000`, providing 768 chars of headroom against the 32,768 field limit.

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
// Secondary soft lock: count job records in Initializing or Processing state
// This partially covers the TOCTOU race window in the AsyncApexJob count above.
Integer activeJobRecords = [
    SELECT COUNT() FROM Metadata_Scan_Job__c
    WHERE Status__c IN ('Initializing', 'Processing')
];
if (activeJobRecords >= maxConcurrent) {
    throw new DependencyJobException(
        'Another MetaMapper scan is already running. Wait for it to complete before starting a new one.'
    );
}
```

`Max_Concurrent_Jobs__c` is a new `MetaMapper_Settings__mdt` field (Number, default 2). The LWC surfaces the rejection as a user-friendly banner: "A scan is already in progress. MetaMapper runs one scan at a time to avoid impacting org performance."

> **Why 2?** One active + one in-flight is the pragmatic limit for orgs under normal load. Admins can raise to 3-5 for orgs with a large flex queue allocation and fast metadata trees.

> **Advisory note:** The count check is not an atomic lock - two simultaneous `createJob()` calls could both pass the threshold before either Queueable is enqueued. For an admin tool this race window is near-zero in practice, but the design acknowledges it. `ApexClass.Name = 'DependencyQueueable'` is required for query selectivity on LDV orgs where `AsyncApexJob` can hold millions of rows. Route this query through `DependencyJobSelector.countActiveQueueables()` to keep SOQL centralized. **Performance note:** add `LIMIT :maxConcurrentPlusOne` (where `maxConcurrentPlusOne = maxConcurrent + 1`) to this count query - do NOT hard-code `LIMIT 3`. This bounds query cost on a large `AsyncApexJob` table regardless of org history, and correctly scales when admins raise `Max_Concurrent_Jobs__c` above 2. Pass `maxConcurrent` as a parameter to `DependencyJobSelector.countActiveQueueables(Integer maxConcurrent)` and build the LIMIT dynamically. A hard-coded `LIMIT 3` would silently allow 4 or 5 active Queueables when `Max_Concurrent_Jobs__c` is raised to 4 or 5.

> **Two-check concurrency gate:** The `AsyncApexJob` count and the active job record count are checked in sequence. Neither is an atomic lock, but together they narrow the TOCTOU race window to near-zero for an admin tool. The job record inserted by `createJob()` at the start of execution serves as the authoritative state after both checks pass.

### Live Progress (Platform Events)

`DependencyQueueable` publishes **exactly one** `Dependency_Scan_Status__e` event per Queueable execution - after the final DML commit of that execution, not after each inner batch loop iteration. `metaMapperApp` owns the `empApi` subscription and distributes payloads to `metaMapperProgress` via `scanstatuschange` custom events - `metaMapperProgress` does NOT subscribe to `empApi` directly. Do not publish events inside a try-catch that swallows the exception.

> **Why one event per execution?** Salesforce enforces a daily org-wide Platform Event delivery limit (50,000 for Standard Volume). At 50 nodes per Queueable execution, a 10,000-node job generates ~200 executions = ~200 events - well within limits. Publishing per inner batch loop (e.g., once per IN-chunk callout) would multiply this by 5-10x and could exhaust the org's daily allocation during concurrent admin scans.

**Dynamic Platform Event degradation (auto-protect against limit exhaustion):**
`DependencyNotificationService.publishProgress()` must check the org's remaining daily PE allocation before each publish. If the org has consumed >80% of its daily limit, suppress the event automatically and fall back to polling - without requiring admin intervention:

```
// In DependencyNotificationService.publishProgress():
OrgLimit peLimit = OrgLimits.getMap().get('DailyStandardVolumePlatformEvents');
// If (peLimit.getValue() / peLimit.getLimit()) >= 0.80: skip publish, log to Scan_Diagnostic_Log__c
```

This is additive to `Disable_Platform_Events__c` - the CMDT switch remains for proactive admin control, while the runtime check provides automatic degradation. When auto-degraded, set `Disable_Platform_Events__c = true` on the CMDT Default record so all subsequent executions in the same day also skip publishing without re-checking limits on every call. **Append to `Scan_Diagnostic_Log__c`** when auto-suppress fires: `"[timestamp] Platform Events suppressed - org daily delivery limit >80% consumed. Progress updates switched to polling."` so admins have visibility without needing debug logs.

**CMDT mutation path:** `DependencyNotificationService` writes the flag via `Metadata.Operations.enqueueDeployment()` (async, does not consume a DML statement). Wrap ONLY the `enqueueDeployment()` call in a narrow try/catch - on failure, log to `Scan_Diagnostic_Log__c` and continue. The Platform Event publish itself must remain outside any swallowing catch (per the rule above). If the deployment call fails, the suppression flag is NOT persisted - but the event is still skipped for the current execution. On the next execution, the OrgLimits check will run again and attempt the write again. The suppression notice is appended to `Scan_Diagnostic_Log__c` regardless of whether the CMDT write succeeds, ensuring admin visibility is never gated on metadata deployment access. **Rate-limit guard:** `Metadata.Operations.enqueueDeployment()` counts against the org's daily Metadata API deployment limit. Before calling it, check whether the suppression flag has already been set on the CMDT record in this transaction (cache the CMDT read in the `static` `IMetaMapperSettingsProvider` cache). If `Disable_Platform_Events__c` is already `true` on the cached record, skip the `enqueueDeployment()` call - no redundant deployment is needed. This avoids one unnecessary Metadata API deployment per Queueable execution after the first auto-suppress fires.

### Graph Visualization

`metaMapperGraph` loads Apache ECharts from the `ECharts` Static Resource (no CDN). It receives a flat node list (deserialized from the `ContentVersion` result file for completed jobs, or from live `Metadata_Dependency__c` records for active jobs - the shape is identical in both cases) and builds the ECharts `graph` series client-side, using `Parent_Dependency__c` to derive edge links. Node color is keyed to `Metadata_Type__c`.

> **Static Resource build**: use `echarts/dist/echarts.min.js` (core minified build, ~1.0-1.2MB) sourced from the npm package. Do **not** use the full bundle - it includes maps and 3D features and risks exceeding Salesforce's 5MB static resource hard limit.

> **Dark mode**: register a Salesforce-compatible dark theme via `echarts.registerTheme('sfDark', { backgroundColor: '#1B1B1B', textStyle: { color: '#FFFFFF' }, ... })`. Apply when `document.body.classList.contains('slds-theme_inverse')`. Use `slds-theme_inverse` detection, not a manual preference flag.

### Security Model

- OWD: `Metadata_Scan_Job__c` = Private (users see only their own jobs)
- OWD: `Metadata_Dependency__c` = Controlled by Parent (access governed by the parent job's OWD and sharing rules; no independent OWD configuration is required for Master-Detail children)
- `@AuraEnabled` controller methods (`DependencyJobController`) use `WITH USER_MODE` or `AccessLevel.USER_MODE` - FLS and CRUD enforced at the controller boundary. Async engine classes (`DependencyQueueable`, `ScanResultFileQueueable`, `DependencyCleanupBatch`, `MetadataDependencyDeletionBatch`) operate in SYSTEM_MODE for reliable internal orchestration.
- `ContentVersion` / `ContentDocumentLink` records are created in SYSTEM_MODE by `ScanResultFileQueueable`. `ContentVersion.FirstPublishLocationId` is set to the job record ID (not a Chatter library) so Salesforce automatically creates the only `ContentDocumentLink` - tied to the job. No additional links to files libraries or other records are created. After the auto-created `ContentDocumentLink` is created, `ScanResultFileQueueable` must query it and explicitly set `ShareType = 'V'` (viewer) and `Visibility = 'InternalUsers'`. Using `'InternalUsers'` ensures the file is never visible to community or guest users even if a community portal is granted access to the job record. Do NOT use `'AllUsers'` - that value includes portal/community users with access to the parent record. **Same-transaction visibility note:** the auto-created `ContentDocumentLink` is written by a Salesforce internal trigger on `ContentVersion` insert. Query it in the same transaction via `[SELECT Id FROM ContentDocumentLink WHERE ContentDocumentId = :cdId]` immediately after the `ContentVersion` insert - Salesforce guarantees same-transaction visibility. Set `ShareType = 'V'` and `Visibility = 'InternalUsers'` via a subsequent DML update on the queried link record.
- Permission Set `MetaMapper_Admin` grants CRUD on both custom objects, Named Credential principal access, and LWC/controller access. **FLS requirement:** the permission set must explicitly grant Field-Level Security READ access to all `Metadata_Dependency__c` fields returned by `getNodeHierarchy()`. Engine-internal-only fields (`Ancestor_Id_Shortkeys__c`, `Unique_Component_Key__c`) must be excluded from the `getNodeHierarchy()` SOQL field list - these fields are not consumed by the LWC, and omitting them from the projection avoids `WITH USER_MODE` failures for non-sysadmin users who lack FLS on those fields.

### Data Lifecycle

MetaMapper uses a **hybrid ContentVersion model** to minimize data storage impact. Node records are temporary engine state; completed results live in Salesforce File Storage.

#### On-Completed Serialization (inline, final Queueable execution)

When `DependencyQueueable` determines no unprocessed nodes remain, it executes the following sequence atomically before transitioning the job to Completed:

1. Query all `Metadata_Dependency__c` records for the job (`MetadataDependencySelector.listByJob(jobId, maxComponents)`).
2. Serialize the flat list to JSON.
3. Create a `ContentVersion` record with `PathOnClient = 'MetaMapper_[jobId].json'`, `VersionData = Blob.valueOf(json)`, and `FirstPublishLocationId = jobId`. Setting `FirstPublishLocationId` causes Salesforce to automatically create the `ContentDocumentLink` tied to the job - do NOT create the link manually. A manual insert would create a duplicate link and fail with a constraint violation.
4. Requery `ContentDocumentId`: `[SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId`. The `ContentDocumentId` is NOT available on the inserted `ContentVersion` record directly - it is populated by Salesforce after insert and must be retrieved via a fresh SOQL query before it can be stored.
5. Update `Metadata_Scan_Job__c.Result_File_Id__c = contentDocumentId`.
6. Bulk-delete all `Metadata_Dependency__c` records for the job using `MetadataDependencyDeletionBatch` chained from `finish()`. The job record stays; all node records are removed. **Critical ordering constraint:** `MetadataDependencyDeletionBatch` must only be enqueued after all prior steps (1-5) have committed successfully. The Savepoint/rollback pattern ensures that on any exception, the rollback fires before `MetadataDependencyDeletionBatch` is ever called. Never move node deletion before `Result_File_Id__c` is updated.
7. **Ring buffer enforcement**: AFTER transitioning the job to Completed (step included in `ScanResultFileQueueable`), count all Completed jobs for the org (inclusive of the job just transitioned). If count > `Max_Stored_Jobs__c`, delete the oldest Completed job (including its `ContentVersion` via `ContentDocument` delete). **Count must happen after the Completed transition** - counting before gives one fewer than the true total, causing a systematic off-by-one that gradually over-retains one extra job.

If the serialization or ContentVersion creation fails (e.g., heap or callout limit), the engine transitions the job to `Failed` via the standard `updateJobFailed()` path. Node records remain and are cleaned up by the nightly batch.

> **File Storage note:** `ContentVersion` uses File Storage, not Data Storage. Developer Sandbox has 200MB of each. In practice, file storage is far less utilized than data storage in most sandboxes. A completed job consumes ~1-3MB file storage vs ~60-120MB data storage with the old model.

#### Ring Buffer (Completed Jobs)

`Max_Stored_Jobs__c` (default 5) limits the number of completed scan jobs retained org-wide. When the 6th job completes, the oldest completed job is deleted (job record + ContentVersion). This keeps file storage bounded at ~5-15MB for completed jobs regardless of how many scans are run.

**Ring buffer deletion must be deterministic and safe under concurrent completions:** The deletion query must use `FOR UPDATE` to serialize concurrent `ScanResultFileQueueable` executions: `[SELECT Id FROM Metadata_Scan_Job__c WHERE Status__c = 'Completed' ORDER BY Status_Closed_At__c ASC, Id ASC LIMIT 1 FOR UPDATE]`. Sort by `Status_Closed_At__c ASC, Id ASC` for determinism when two jobs have identical timestamps. Wrap the ENTIRE ring buffer block - including the `SELECT ... FOR UPDATE` statement - in a single try/catch for both `System.QueryException` and `System.DmlException`. A Salesforce row lock timeout fires on the SELECT (not the DELETE), so catching only around the DELETE is insufficient. On any exception: log to `Scan_Diagnostic_Log__c` and continue. A failed ring buffer delete must NOT fail the job.

`Retention_Hours__c` applies **only to Failed and Cancelled jobs** - it no longer governs completed jobs, which are managed by the ring buffer instead.

#### Nightly Cleanup (Failed and Cancelled Jobs)

`DependencyCleanupBatch` runs nightly at 02:00 via `DependencyCleanupScheduler`. It targets **only** Failed and Cancelled jobs older than `Retention_Hours__c`.

**Lifecycle rule (critical):**
- Only delete jobs where `Status__c IN ('Failed', 'Cancelled')` AND `Status_Closed_At__c < :DateTime.now().addHours(-retentionHours)`. Never delete `Initializing`, `Processing`, `Paused`, or `Completed` jobs - Completed jobs are managed by the ring buffer; in-progress jobs must not be destroyed.
- `Status_Closed_At__c` is stamped the moment Status transitions to Completed, Failed, or Cancelled. It is **not** stamped on a Paused transition - Paused is a resumable checkpoint, not a terminal state, and stamping it would give a misleading "closed" timestamp to a job that will continue. The cleanup batch uses this field, not `CreatedDate`, to avoid targeting long-running in-progress jobs.

**Cascade delete DML trap (critical):**
Master-Detail cascade deletion counts child record deletes against the 10,000 DML row limit of the batch `execute()` transaction. A job with 15,000 nodes would cause `System.LimitException: Too many DML rows` on the first delete call. An inner `while (!nodes.isEmpty())` loop inside `execute()` compounds this risk in LDV orgs - 80k+ node jobs can exceed CPU or trigger "Too many DML statements" from customer triggers firing on every 2,000-node delete within the same transaction.

**Fix: two-class chained cleanup pattern.**

`DependencyCleanupBatch` discovers expired jobs; `MetadataDependencyDeletionBatch` handles the actual deletion.

**`DependencyCleanupBatch`** (job discovery):
- `start()`: returns QueryLocator for Failed/Cancelled jobs where `Status_Closed_At__c < threshold`
- `execute(scope)`: no DML - accumulates job IDs
- `finish()`: fires one `MetadataDependencyDeletionBatch(jobId, CleanupMode.NODES_AND_JOB)` per accumulated job ID. **Maximum 5 submissions per `finish()` call** - Salesforce allows up to 5 `Database.executeBatch()` calls per transaction. If more than 5 expired jobs accumulate, submit the first 5. If remaining job IDs exist after the first 5 submissions, log the overflow count to `Scan_Diagnostic_Log__c` on the oldest remaining expired job: "Cleanup backlog: [N] additional expired jobs will be processed in subsequent nightly runs." This is safe as long as `Retention_Hours__c >= 24`; shorter retention windows may cause backlog accumulation if more than 5 jobs expire each night consistently.
- Batch size: 10 (multiple jobs per discovery pass is safe since execute() does no DML)

**`MetadataDependencyDeletionBatch`** (node + job deletion):
- Constructor: `MetadataDependencyDeletionBatch(String jobId, CleanupMode mode)` where `CleanupMode` is an inner enum: `public enum CleanupMode { NODES_ONLY, NODES_AND_JOB }`. The enum replaces the previous `Boolean deleteJob` parameter to prevent accidental argument swaps (a boolean `true`/`false` swap is silent; an enum mismatch is a compile error). Two distinct calling paths:
  - **Nightly cleanup path** (`DependencyCleanupBatch.finish()`): `CleanupMode.NODES_AND_JOB` - nodes deleted, then job record deleted.
  - **Serializer path** (`ScanResultFileQueueable`): `CleanupMode.NODES_ONLY` - nodes deleted only; the job record is retained (it holds the result file pointer and will be managed by the ring buffer).
- `start()`: `SELECT Id FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :jobId`
- `execute(scope)`: `delete scope;` - scope is already `<= Cleanup_Chunk_Size__c`
- `finish()`: if `mode = NODES_AND_JOB`: `delete [SELECT Id FROM Metadata_Scan_Job__c WHERE Id = :jobId];` - if `mode = NODES_ONLY`: no-op.
- Batch size: `Cleanup_Chunk_Size__c` (default 2,000)

**Chunk size: `Cleanup_Chunk_Size__c` in `MetaMapper_Settings__mdt` (default 2,000).** Do NOT use 9,000. MetaMapper is deployed into customer orgs where managed packages, record-triggered Flows, or Apex Triggers may fire on delete events for any Custom Object. A chunk of 9,000 leaves only 1,000 DML rows for customer automation - insufficient for orgs with non-trivial delete handlers. 2,000 provides 8,000 rows of headroom for customer triggers while keeping each transaction practical.

> Each `MetadataDependencyDeletionBatch` `execute()` call deletes exactly one chunk of 2,000 nodes in its own transaction - no inner loops, no compounding DML risk regardless of total node count.

---

## Data Model

### Metadata_Scan_Job__c
| Field | Type | Notes |
|---|---|---|
| `Target_Metadata_Type__c` | Picklist | CustomField, ValidationRule, Flow, ApexClass, ApexTrigger, WorkflowRule, etc. |
| `Target_API_Name__c` | Text 255 | Developer Name of the target metadata |
| `Target_Parent_Object__c` | Text 255 | Optional - populated by typeahead for field-scoped searches |
| `Active_Flows_Only__c` | Checkbox | Default true - drops inactive Flow versions |
| `Status__c` | Picklist | Initializing, Processing, Completed, Failed, **Cancelled**, **Paused** |
| `Scan_Diagnostic_Log__c` | Long Text 32768 | Full exception on failure |
| `Components_Analyzed__c` | Number | Running counter for progress bar |
| `Component_Type_Counts__c` | Long Text 32768 | JSON map of `{MetadataType: count}` - populated on Completed |
| `Status_Closed_At__c` | DateTime | Stamped when Status transitions to Completed, Failed, or Cancelled. Not set on Paused - Paused is a resumable checkpoint, not a terminal state. Cleanup batch uses this field - never CreatedDate - to avoid deleting in-progress jobs. |
| `Processing_Cycle_Count__c` | Number | Number of times the async engine has processed a batch for this scan. Incremented on every Queueable execution. Used together with `Last_Progress_Cycle__c` for stall detection. |
| `Last_Progress_Cycle__c` | Number | The value of `Processing_Cycle_Count__c` at the last execution that made measurable progress (i.e., `Components_Analyzed__c` increased). Persisted on the job record so it survives across Queueable self-chain boundaries. Stall condition: `Processing_Cycle_Count__c - Last_Progress_Cycle__c >= Stall_Pause_Threshold__c`. Reset to `Processing_Cycle_Count__c` whenever `Components_Analyzed__c` increases. |
| `Scan_Summary_Text__c` | Long Text 32768 | Plain-English summary populated after job Completed by `ScanSummaryQueueable`. Derived from `Component_Type_Counts__c`. Example: "This scan found 42 dependencies, including 3 active Flows and 5 Apex classes." Enables Agentforce Actions to consume job results without parsing JSON. Null until Completed. Populated asynchronously - LWC should poll `getJobStatus()` until this field is non-null before rendering the Summary Card. |
| `Result_File_Id__c` | Text 18 | ContentDocumentId of the Salesforce File containing the complete scan result JSON. Stores the 18-character ContentDocument ID. Salesforce does not support Lookup relationships to ContentDocument on custom objects; referential integrity is maintained by the ring buffer (deletes ContentDocument when the job is deleted). Populated via Apex requery path only. Populated when Status transitions to Completed, after all `Metadata_Dependency__c` records have been serialized to the file and deleted. Null during active scans and for Failed/Cancelled jobs. Used by `getNodeHierarchy()` to serve results for completed jobs without querying the (already-deleted) node records. Must always be populated via the Apex requery path (`[SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id]`) - never populated from user input. |
| `Batch_Size_Override__c` | Number | Transient-safe batch size override set by `resumeJob()` when the user chooses "Resume at a slower speed". `DependencyQueueable.execute()` reads this field at startup and uses it instead of `Scan_Batch_Size__c` if non-null. The field is NOT reset after use - it persists for the job lifetime, keeping the slower speed in effect for subsequent self-chains until the admin resets it to null. Does NOT write back to CMDT (CMDT is org-wide; this is job-specific state). |
| `Last_Query_Row_Count__c` | Number | The number of rows returned by the most recent Tooling API callout. Updated after each callout: `job.Last_Query_Row_Count__c = results.size()`. Used by the guardrail to determine `queryMorePossible`: `queryMorePossible = (job.Last_Query_Row_Count__c != null && job.Last_Query_Row_Count__c >= 1900)`. If the previous callout returned >= 1,900 rows, QueryMore is likely for the next batch. Initialized to 0 on job creation. |
| `Result_Save_Attempted__c` | Checkbox | Set to `true` at the start of `ScanResultFileQueueable.execute()`, committed in a separate DML call **before** `Database.setSavepoint()` so a rollback cannot revert this flag. Used by the LWC to distinguish "serializer failed after traversal completed" (this = true, Result_File_Id__c = null, Status = Failed) from "engine failed mid-traversal" (this = false). Without this flag these two states share identical detection conditions, causing the "Download Partial Results" button to appear on mid-traversal failures where node data may be incomplete. Default false. Do not edit manually. |
| `Job_Type__c` | Picklist | Job type for future extensibility. Values: `Dependency_Map` (default - Tooling API-based dependency scan), `Text_Search` (reserved and inactive - do not use). The engine sets this to `Dependency_Map` on every `createJob()` call. Do not create jobs with `Job_Type__c = 'Text_Search'` - this value is reserved and the UI does not support it. |
| `Pause_Reason__c` | Picklist | Machine-readable reason for the most recent pause. Values: `NodeCapReached` (scan paused because `Components_Analyzed__c >= Max_Components__c`), `StallDetected` (scan paused because `Processing_Cycle_Count__c - Last_Progress_Cycle__c >= Stall_Pause_Threshold__c`). Null when `Status__c` is not `Paused`. The LWC reads this field to render the correct pause banner copy and resume options without parsing `Scan_Diagnostic_Log__c` strings. Set by the engine only; do not edit manually. |

> **Visited_IDs__c removed.** A Long Text 131072 field caps at ~5,957 IDs (22 chars/ID with JSON formatting). Enterprise orgs can easily exceed this, causing `StringException` and crashing the Queueable chain. Cycle detection is instead performed via two-tier logic (see Cycle Detection below).

### Metadata_Dependency__c

> **Storage model:** `Metadata_Dependency__c` records exist **only during the active scan**. When a job transitions to Completed, the engine serializes the entire node tree to a JSON Salesforce File (`ContentVersion`), bulk-deletes all `Metadata_Dependency__c` records for the job, and stores the `ContentDocumentId` in `Result_File_Id__c` on the job. Data Storage impact for completed jobs is therefore near-zero (~5KB for the job record alone). File Storage (also 200MB in Developer Sandbox) holds the serialized result JSON (~1-3MB per job). Failed and Cancelled jobs may retain partial node records until the nightly cleanup batch removes them.

| Field | Type | Notes |
|---|---|---|
| `Metadata_Scan_Job__c` | Master-Detail | Cascade delete |
| `Parent_Dependency__c` | Lookup (self) | Builds hierarchical tree. **Self-referential bulk DML constraint:** Salesforce does not resolve self-referential lookups within a single bulk DML operation. The root node must be committed in a separate DML call before any child nodes can reference it by ID. Insert root first, commit, then bulk-upsert children. |
| `Metadata_Id__c` | Text 18 | Exact 18-char Tooling API ID. **Required validation rule** (API name `Metadata_Id_Must_Be_18_Characters`): formula `IF(NOT(ISBLANK(Metadata_Id__c)), LEN(Metadata_Id__c) <> 18, FALSE)`, error message "Metadata ID must be exactly 18 characters." The cycle detection delimiter safety (`'|' + id + '|'` containment checks) depends on this invariant. |
| `Metadata_Type__c` | Text 50 | e.g. ApexClass, CustomField, Flow |
| `Metadata_Name__c` | Text 255 | Human-readable API name |
| `Dependency_Depth__c` | Number | Depth from root (0 = root target) |
| `Dependencies_Fetched__c` | Checkbox | Engine flag: false = this node's child dependencies have not yet been fetched from the Tooling API. **Query selectivity note:** `MetadataDependencySelector.nextUnprocessed()` queries `WHERE Metadata_Scan_Job__c = :jobId AND Dependencies_Fetched__c = false`. Selectivity relies on the Master-Detail relationship index on `Metadata_Scan_Job__c` (indexed by default). The compound filter `Metadata_Scan_Job__c = :jobId` must appear first in the WHERE clause and is sufficient for selectivity on this object at the expected data volumes. If query performance degrades in LDV orgs with many concurrent active scans, add a custom index on `Dependencies_Fetched__c`. |
| `Is_Circular__c` | Checkbox | True only when this node's `Metadata_Id__c` appears in its own `Ancestor_Path__c` (true ancestry cycle) |
| `Is_Dynamic_Reference__c` | Checkbox | True if reference cannot be statically analyzed (e.g. dynamic Apex string) - flagged in UI |
| `Dependency_Context__c` | Long Text 32768 | JSON "pills" - contextual metadata per type (see below) |
| `Discovery_Source__c` | Picklist | `ToolingAPI` or `Supplemental` - tracks how the node was discovered |
| `Ancestor_Path__c` | Long Text 32768 | Pipe-delimited ancestor `Metadata_Id__c` chain from root to this node's **parent** (excludes self). The path-building formula appends `parent.Metadata_Id__c` to the child's path, so a child's `Ancestor_Path__c` contains all ancestors above it but not its own ID. Used for true cycle detection. |
| `Supplemental_Confidence__c` | Number (3,0) | 0-100 confidence score for supplemental nodes only. Regex/XML matches are inherently fuzzy; score reflects match certainty. Nodes below 70 display a warning badge in the UI. Null for ToolingAPI nodes. |
| `Unique_Component_Key__c` | Text 80 (External ID, Unique) | Composite deduplication key in format `JobId + ':' + Metadata_Id__c`. Used as an External ID for upsert operations to prevent duplicate nodes from race conditions in concurrent Queueable chains. Text 80 provides headroom for future scoping additions beyond the current 37-char minimum. Generated by the engine only - do not edit manually. |
| `Ancestor_Id_Shortkeys__c` | Long Text 32768 | Stores a pipe-delimited set of 6-character tails (last 6 characters via `.right(6)`) of each ancestor `Metadata_Id__c` (e.g. `"abc123|def456|..."`). Uses the auto-number suffix portion of the 18-char ID, which is unique per component - unlike the entity key prefix (left 6 chars) which is identical for all components of the same type. Used as a fast bloom-filter-style pre-screen: before performing the full delimiter-safe `Ancestor_Path__c` containment check, the engine checks whether the new node's 6-char tail appears in this index. If no match, skip the expensive full-string check. If a match is found, confirm conclusively against `Ancestor_Path__c` before marking the node circular. **Long Text 32768 is required** - at 7 chars per tail entry (6 + delimiter), a 1,500-depth tree yields ~10,500 chars. Text 255 overflows at depth >36. The 6-char tail has a negligible false-positive probability; the `Ancestor_Path__c` confirmation step resolves all false positives. **Multi-generation propagation rule:** after bulk-upserting a generation of child nodes, if those nodes will themselves become parents in the same Queueable execution (i.e., the engine continues within the same execution due to remaining callout budget), their `Ancestor_Id_Shortkeys__c` values must be held in a local `Map<Id, String>` (keyed by node Id) before building grandchild records. Do not re-query; pass the in-memory map forward to avoid an additional SOQL query and to ensure the correct tail index is used for each node in the next generation. |

### Dependency_Context__c (Pills) by Metadata Type

All `Dependency_Context__c` payloads include a root `"v": 1` version key. The LWC renders unknown keys as plain text with a fallback label rather than failing. Handlers must increment `"v"` when the payload schema changes - the LWC version check gate is the only compatibility contract.

| Type | JSON shape |
|---|---|
| ApexClass / ApexTrigger | `{"v": 1, "isWrite": true}` - whether the class writes to the target field/object |
| Flow | `{"v": 1, "activeVersions": 3, "isActive": true}` |
| WorkflowRule | `{"v": 1, "isActive": true, "triggerType": "onInsertOrUpdate"}` |
| CustomField | `{"v": 1, "parentObject": "Account", "parentType": "CustomObject"}` |
| Report | `{"v": 1, "filterUsage": ["filter", "grouping", "column"]}` |

`Component_Type_Counts__c` also carries a version key at root: `{"v": 1, "ApexClass": 5, "Flow": 3}`. LWC stat tile ignores unknown keys rather than failing.

---

## Key Apex Classes

**Interfaces (Dependency Injection / testability):**

| Interface | Contract |
|---|---|
| `IMetadataDependencyService` | `fetchDependencies(List<String> ids, DependencyOptions opts)`, `buildContextData(Metadata_Dependency__c node)`, `computeScore(String handlerType, String matchBasis)` |
| `IDependencyTypeHandler` | `SupplementalResult findSupplemental(Id jobId, List<Metadata_Dependency__c> nodes)` |
| `IScanNotificationService` | `publishProgress(String jobId, String status, Integer count, String msg)`, `sendCompletion(String jobId, String userId)` |
| `IMetaMapperSettingsProvider` | `MetaMapper_Settings__mdt getSettings()` - read once per transaction, cached in a `static` variable. The cache must be `static` (not instance-level) so that supplemental handlers calling `getSettings()` independently within the same Apex transaction reuse the same record and do not each burn a SOQL query. |

**Selectors (all SOQL centralized here):**

| Selector | Key Methods |
|---|---|
| `DependencyJobSelector` | `getByIdForEngine(String jobId)` - minimal fields for engine; `getClosedJobsBefore(DateTime threshold)` - for cleanup; `countActiveQueueables()` - scoped `AsyncApexJob` count for concurrency guard; `getByIdForStatusView(String jobId)` - full UI fields WITH USER_MODE; `getByIdForResume(String jobId)` - status + flow fields WITH USER_MODE; `getByIdForSummary(String jobId)` - for ScanSummaryQueueable; `countActiveJobRecords()` - secondary soft lock for concurrency gate |
| `MetadataDependencySelector` | `nextUnprocessed(String jobId, Integer lim)` - ordered fetch; `dedupForResults(String jobId, Set<String> ids)` - scoped dedup query; `listByJob(String jobId, Integer limitRows)` - full node list for on-Completed serialization; `getResultFile(String jobId, String contentDocumentId)` - ownership-verified ContentVersion fetch; `getNodeHierarchyForJob(String jobId)` - flat list WITH USER_MODE for controller; `getVersionContentDocumentId(Id cvId)` - post-insert ContentDocumentId requery; `getContentDocumentsByIds(Set<String> fileIds)` - bulk ring-buffer file delete; `getNodeExistenceByJobs(Set<Id> jobIds)` - ring-buffer guard |

**Classes:**

| Class | Role |
|---|---|
| `MetaMapperSettingsProvider` (implements `IMetaMapperSettingsProvider`) | Returns the single `MetaMapper_Settings__mdt Default` record. Uses a `static` cache so all callers within the same Apex transaction share one SOQL query. Read by `DependencyQueueable`, `DependencyJobController`, `DependencyNotificationService`, and supplemental handlers. |
| `DependencyJobException` | Custom checked exception thrown by controller and engine methods. Extends `Exception`. Used instead of a generic `Exception` so callers can distinguish MetaMapper-specific errors from platform errors. Caught at `@AuraEnabled` boundaries and surfaced to the LWC as user-facing messages. |
| `DependencyJobController` | `@AuraEnabled` (USER_MODE): `createJob()` with async guard + concurrency guard + storage check + node cap enforcement + preflight check, `getObjectList()`, `getJobStatus()`, `getNodeHierarchy()`, `cancelJob()`, `resumeJob(String jobId, Integer overrideBatchSize)` - passes transient batch override to Queueable (does not write CMDT), `getComponentCount(String apiName)` (cacheable=true - queries `MetadataComponentDependency` count for an API name via standard SOQL using a bind variable (`:apiName`) - never string concatenation - and maps to Small/Medium/Large/Very Large complexity bucket; on any exception returns null and the LWC suppresses the preview; the `cacheable=true` exception-swallowing for permission-denial on the Tooling API object is intentional for this best-effort preview feature), `isCopilotEnabled()` (cacheable=true - returns `FeatureManagement.checkPermission('Einstein_Copilot')`; result cached for component lifetime). Delegates to services - no SOQL/DML directly. **Storage check:** before accepting a new job, reads `OrgLimits.getMap().get('DataStorageMB')` and computes free storage as `orgLimit.getLimit() - orgLimit.getValue()`. Rejects with a user-facing message if free storage < `Min_Free_Storage_MB__c`. User message: "Not enough data storage to start a scan. Free up storage or reduce the retention window in MetaMapper Settings." **`getNodeHierarchy()` routing:** if `Metadata_Scan_Job__c.Status__c = 'Completed'`, reads the result JSON from `ContentVersion` via `MetadataDependencySelector.getResultFile(jobId, job.Result_File_Id__c)` and deserializes it - `Metadata_Dependency__c` records no longer exist for completed jobs. For all other statuses (Initializing, Processing, Paused, Cancelled, **Failed**), queries `Metadata_Dependency__c` records directly - partial nodes from a Failed job are valid for export. This routing is transparent to the LWC - both paths return the same flat node list shape. Job record access is validated via `WITH USER_MODE` before reading `Result_File_Id__c` - the Private OWD on `Metadata_Scan_Job__c` ensures users can only access their own jobs' result files. `Result_File_Id__c` is populated by the engine only; never used as a user-supplied ContentDocument ID. **`getResultFile()` null guard:** `MetadataDependencySelector.getResultFile()` must handle a ContentVersion query returning zero rows (file deleted externally). When zero rows are returned, `getNodeHierarchy()` must throw `DependencyJobException('The result file for this scan could not be found. It may have been deleted. Start a new scan.')` - do not throw an unhandled platform exception. The controller exception message must propagate through the `@AuraEnabled` error response so the LWC can render it as the primary error body - not as secondary help text. The LWC `getNodeHierarchy()` failure state renders the server exception message directly as the error banner body copy. |
| `MetadataDependencyService` (implements `IMetadataDependencyService`) | Tooling API SOQL formatting, character-budget chunking, QueryMore, Active Flows filter, `buildContextData()`, `computeScore()`. **HTTP 5xx single retry:** On receiving an HTTP 5xx response from any Tooling API callout, if `Limits.getLimitCallouts() - Limits.getCallouts() > 1`, retry the callout once before throwing. On a second consecutive 5xx, throw the exception and allow the Savepoint/rollback path to set the job to Failed. Log the retry attempt to `Scan_Diagnostic_Log__c`: `'[timestamp] Tooling API 5xx on [endpoint] - retrying once.'` **Heap pre-check rule (critical):** do NOT use `Limits.getHeapSize()` to predict deserialization cost - it is delayed and does not reflect the memory cost of the pending deserialization. Instead, check the **raw HTTP response body string length** BEFORE calling `JSON.deserializeUntyped()`. If the string length exceeds 500,000 characters (~500KB), split the batch in half and re-query rather than deserializing the full payload. This is the only reliable pre-deserialization heap guard available in Apex. |
| `DependencyFetchContext` | Mutable context object passed to `IMetadataDependencyService.fetchDependencies()`. Holds `jobId`, `activeFlowsOnly`, `lastResultCount` (max rows seen across chunks - drives `queryMorePossible` in the guardrail), accumulated `errors` (diagnostic strings written to `Scan_Diagnostic_Log__c` by the caller after all handlers complete), `queryMoreFailed` (set by the service when a QueryMore cursor expires, prevents premature `Dependencies_Fetched__c = true`), and `failedParentMetaIds` (parent IDs whose Tooling API fetch failed - excluded from the fully-processed set so they are re-queried on the next Queueable execution). Errors are accumulated rather than thrown so a single-batch failure does not abort the whole execution. |
| `SupplementalScanResult` | Return type for `IDependencyTypeHandler.findSupplemental()`. Encapsulates the list of discovered supplemental `Metadata_Dependency__c` nodes (ready for upsert by the caller) and diagnostic error strings (appended to `Scan_Diagnostic_Log__c` by `DependencyQueueable` after all handlers complete, via `appendErrorsSafe()` which enforces the 32,768-char log field limit). Errors are accumulated in-memory rather than persisted inside handlers, removing unbulkified DML from handler catch blocks and ensuring errors survive Queueable rollbacks. **`appendErrorsSafe()` is the ONLY permitted write path to `Scan_Diagnostic_Log__c`.** Direct string concatenation to the log field is forbidden across ALL classes (DependencyQueueable, DependencyNotificationService, ScanResultFileQueueable, DependencyCleanupBatch, and all handler classes). This is a hard cross-cutting rule: every log write must call `appendErrorsSafe(existingLog, newText)` which enforces the 32,768-char ceiling by truncating `newText` so that `existingLog + newText <= 32768`. If a class does not currently call `appendErrorsSafe()`, update it to do so before shipping. |
| `DependencyTypeHandlerFactory` | `IDependencyTypeHandler getHandler(String metadataType)` - returns correct handler or no-op default |
| `CustomFieldDependencyHandler` | Supplemental: WorkflowFieldUpdate (95), ValidationRule regex (65), FlexiPage XML (60), CMT lookups (85), Lookup relationships (95). **Regex safety rule:** all regex patterns must be non-backtracking (no nested quantifiers). Before each regex call, check `Limits.getCpuTime() / Limits.getLimitCpuTime() >= 0.60` - if true, skip the field, log a diagnostic notice to `Scan_Diagnostic_Log__c`, and continue. ValidationRule formula fields in complex orgs can be 10,000+ characters; unbounded backtracking patterns will hit the CPU limit and fail the Queueable. |
| `ApexClassDependencyHandler` | Supplemental: CMT references (85); flags `Is_Dynamic_Reference__c` |
| `FlowDependencyHandler` | Supplemental: QuickActionDefinition, subflows, WebLink URLs |
| `DependencyQueueable` | Async engine. Constructor: `DependencyQueueable(String jobId, Boolean activeFlowsOnly, Integer overrideBatchSize)`. **Node cap check:** at the start of each execution, if `Components_Analyzed__c >= Max_Components__c` (and `Max_Components__c > 0`), transition job to `Status__c = 'Paused'`, set `Scan_Diagnostic_Log__c` with: "Scan paused: node limit of [N] reached. This protects your org's data storage. Raise Max_Components__c in MetaMapper Settings to continue." Do not self-chain. The LWC pause banner surfaces the resume option. Note: the cap is a soft ceiling - the final batch before the limit is reached may push `Components_Analyzed__c` up to `Max_Components__c + Scan_Batch_Size__c - 1`; the check fires at the start of the next execution. - `overrideBatchSize` is null for normal execution; set to half of `Scan_Batch_Size__c` when `resumeJob()` triggers after a hot-loop pause. Savepoint/catch; cancel check; CMDT read via `IMetaMapperSettingsProvider`; hot-loop detection; pre-batch + mid-loop seven-limit guardrail; scoped dedup + upsert by `Unique_Component_Key__c`; two-tier cycle detection; callouts; HTTP 414/431 reactive split-and-retry (halves batch, retries both halves as separate callouts, does not fail job - logs restart to `Scan_Diagnostic_Log__c`); handlers; one PE event per execution (suppressed if `Disable_Platform_Events__c`); self-chain. **On completion:** when no unprocessed nodes remain, instead of directly transitioning to Completed, enqueues `ScanResultFileQueueable` - this separates the concern of engine traversal (this class) from result persistence (serializer). The engine does not transition Status itself; `ScanResultFileQueueable` owns the Completed transition. **DML bulkification rule (critical):** child nodes discovered during the result-processing loop are accumulated in a `List<Metadata_Dependency__c>` and upserted in a single bulk statement after the loop completes (or before a mid-loop self-chain fires). Never upsert per-node inside the loop. |
| `DependencyNotificationService` (implements `IScanNotificationService`) | `publishProgress()` - one event per execution; checks org daily PE allocation via `OrgLimits` before publishing (auto-suppresses and flips `Disable_Platform_Events__c` if >80% consumed - appends suppression notice to `Scan_Diagnostic_Log__c` for admin visibility); `sendCompletionNotification()`. Does NOT enqueue `ScanSummaryQueueable` - that is the responsibility of `ScanResultFileQueueable` after the Completed transition. |
| `ScanSummaryQueueable` | Lightweight one-shot Queueable enqueued by `ScanResultFileQueueable` after the Completed transition. Reads `Component_Type_Counts__c`, builds the plain-English `Scan_Summary_Text__c` string, and updates the Job record. Offloaded because string templating on a large `Component_Type_Counts__c` JSON payload competes with the serializer's own CPU/heap budget, and chaining keeps each unit of work within a predictable governor envelope. **Status guard (critical):** the first operation in `execute()` must be `if (job.Status__c != 'Completed') return;` - if `ScanResultFileQueueable` rolled back after this Queueable was enqueued, the job will be in `Failed` state; running on a Failed job would write a nonsensical summary. **Enqueue timing (critical):** `System.enqueueJob(new ScanSummaryQueueable(...))` in `ScanResultFileQueueable` must be the **last statement inside the try block**, after all DML has been issued. It executes in the same transaction; Salesforce stages the enqueue and fires the child Queueable only after the parent transaction commits cleanly. Do NOT place it after the catch block or after a `return` statement - the phrase "after all DML has committed" in older versions of this spec was misleading; the call is always in-transaction. |
| `ScanResultFileQueueable` | One-shot Queueable enqueued by the final `DependencyQueueable` execution when no unprocessed nodes remain. **Must use the Savepoint/rollback pattern** (same as `DependencyQueueable`): `Database.setSavepoint()` before all work; on any exception `Database.rollback(sp)` then `updateJobFailed()` in a fresh DML scope - without this, an uncaught exception rolls back the ContentVersion creation AND the job update, leaving the job stuck in `Processing` permanently with no recovery path. **Heap guard (critical):** call `MetadataDependencySelector.listByJob(jobId, maxComponents)` exactly once and reuse the result for both the heap check and serialization. Use `nodes.size()` (the actual loaded count) - do NOT use `Components_Analyzed__c` from the job record. `Components_Analyzed__c` is an engine counter that may slightly exceed the true row count due to dedup rejections on External ID upsert. Do NOT call `listByJob()` a second time for the count - that wastes heap and SOQL budget. If `actualNodeCount * avgBytesPerNode > heapThreshold`, fail the job immediately via `updateJobFailed()` with message: "Scan completed but results could not be saved - result set too large for available heap. Reduce Max_Components__c and run again." Default safety assumption: ~4-6KB per node for deep trees (Ancestor_Path__c and Dependency_Context__c add significant size beyond the base record); at 5,000 nodes that is ~20-30MB against a 12MB async heap limit. This means the practical safe ceiling is ~2,000-3,000 nodes for enterprise orgs with deeply nested metadata. Admins raising `Max_Components__c` above 3,000 should be aware the serializer will likely hit the heap failure path. **Terminal on failure:** `Failed` jobs from this class are not retryable - the admin must start a new scan. Steps: heap-check before serializing; serialize all `Metadata_Dependency__c` to JSON; create `ContentVersion` with `FirstPublishLocationId = jobId` (no library link); requery `ContentDocumentId` from the inserted `ContentVersion`; update `Result_File_Id__c`; **compute and update `Component_Type_Counts__c`** (JSON map of `{MetadataType: count}` derived from the serialized nodes - must be populated before transitioning to Completed so `ScanSummaryQueueable` has data to work with); bulk-delete all node records via `MetadataDependencyDeletionBatch(jobId, CleanupMode.NODES_ONLY)` (nodes only - keep job); transition to Completed; enforce ring buffer; enqueue `ScanSummaryQueueable`. Offloaded from the engine Queueable because serializing thousands of node records consumes significant heap and CPU that would compete with the final batch of Tooling API work. |
| `DependencyCleanupBatch` | Job discovery batch. **Must implement `Database.Stateful`** - the class accumulates job IDs across multiple `execute()` chunks and passes them to `finish()`. Without `Database.Stateful`, Apex discards all instance state between chunk invocations and `finish()` receives an empty list, firing zero child batches. `start()` = Failed/Cancelled jobs past `Retention_Hours__c` threshold (Completed jobs are managed by the ring buffer, not time-based deletion). `execute()` = no DML - accumulates job IDs into a `List<Id>` instance variable. `finish()` = fires one `MetadataDependencyDeletionBatch` per accumulated job ID. Maximum 5 `MetadataDependencyDeletionBatch` submissions per `finish()` call. Batch size 10. |
| `MetadataDependencyDeletionBatch` | Node deletion batch with optional job deletion. Constructor: `MetadataDependencyDeletionBatch(String jobId, CleanupMode mode)` where `CleanupMode` enum values are `NODES_ONLY` (serializer path - retain job) and `NODES_AND_JOB` (nightly cleanup path - delete job after nodes). Using an enum prevents the silent argument-swap bug that a boolean `deleteJob` parameter would allow. `start()` = QueryLocator for child nodes. `execute()` = `delete scope`. `finish()` = deletes parent job record only when `mode = NODES_AND_JOB`; no-op when `mode = NODES_ONLY`. Batch size = `Cleanup_Chunk_Size__c` (default 2,000). No inner loops - each transaction is one chunk only. |
| `DependencyCleanupScheduler` | Implements `Schedulable`. Schedules `DependencyCleanupBatch` to run nightly at 02:00 via the Salesforce scheduler. If the scheduled job is lost (sandbox refresh, manual deletion), re-schedule via anonymous Apex: `System.schedule('MetaMapper Nightly Cleanup', '0 0 2 * * ?', new DependencyCleanupScheduler());` |
| `ToolingApiHealthCheck` | Setup-only Apex class: verifies Tooling API reachability via Named Credential. Called by pre-flight LWC check on page load. **Permission guard (critical):** the first operation in `verify()` must check that the calling user has been assigned the `MetaMapper_Admin` permission set (via `FeatureManagement.checkPermission('MetaMapper_Application_Access')` or a custom permission). (Custom Permission `MetaMapper_Application_Access` must be defined as a metadata component and included in the `MetaMapper_Admin` permission set - see `setup/SETUP.md`) If not assigned, return the "insufficient permissions" error code without making any callout - unauthorized users must not trigger Named Credential network calls. |

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
- On each execution, increment `Processing_Cycle_Count__c` on the Job.
- If `Components_Analyzed__c` increased since the last execution, reset `Last_Progress_Cycle__c = Processing_Cycle_Count__c`.
- If `Processing_Cycle_Count__c - Last_Progress_Cycle__c >= Stall_Pause_Threshold__c` (default 5), transition Job to `Status__c = 'Paused'`, set `Scan_Diagnostic_Log__c` with diagnostic context, and publish a `Dependency_Scan_Status__e` warning event.
- **Why persisted field, not transient variable:** each Queueable self-chain creates a new instance - transient variables are discarded. `Last_Progress_Cycle__c` on the job record is the only state that survives across Queueable chain boundaries.
- The LWC surfaces this as a user-visible warning: "MetaMapper paused because it encountered a component with extremely deep or wide dependencies. You can resume at a slower speed or with current settings."

> `Status__c` gains a `Paused` value. `DependencyJobController` exposes a `resumeJob(String jobId, Integer overrideBatchSize)` method. When the LWC calls `resumeJob`, it passes a suggested batch size (half of the current `Scan_Batch_Size__c` CMDT value). `resumeJob()` sets `Status__c = 'Processing'` and writes the override to `Batch_Size_Override__c` on the job record (persisted, not transient - each new Queueable instance would lose a transient variable). `DependencyQueueable.execute()` reads `Batch_Size_Override__c` at startup and uses it instead of CMDT if non-null. This does NOT write back to CMDT. The LWC pause banner displays: "Scan paused. [Resume at a slower speed] or [Resume with current settings]."

---

## Key LWC Components

| Component | Role |
|---|---|
| `metaMapperApp` | Root shell; owns `jobId` state; switches between input, progress, and results views. Runs pre-flight Named Credential health check on mount; shows setup error state if check fails. **Deep-link routing:** on mount, reads URL params via `@wire(CurrentPageReference)`. If `jobId` param is present, skips the input screen and loads the results view for that job directly (calls `getJobStatus()` to verify the job exists). If `nodeId` param is also present, after results load, selects that node and opens the Node Details Panel. If the job no longer exists (expired by ring buffer): renders a dedicated error state - "This scan result is no longer available. It may have been automatically deleted." + "Start a new scan" button. If the job exists but the node is not found in the result set: loads results normally and shows a toast - "The linked component could not be found in this scan result." |
| `metaMapperSearch` | Metadata type picklist, API name text input, typeahead object lookup (debounced 300ms, queries `EntityDefinition`), "Active Flows Only" checkbox with tooltip explanation. Shows estimated node complexity preview when available. Validates required fields before enabling submit. |
| `metaMapperProgress` | Progress bar + human-readable status label. Receives PE payloads via `scanstatuschange` events from `metaMapperApp` (does not subscribe to `empApi` directly). **Progress bar calculation:** when `Max_Components__c > 0`, use `value = Math.min((Components_Analyzed__c / Max_Components__c) * 100, 95)` capped at 95% until `Status__c = 'Completed'` (jumps to 100%). When `Max_Components__c = 0` (cap disabled), replace the bar with a `lightning-spinner` variant="brand" size="small" inline next to the status label. **Elapsed time:** rendered immediately below the status label, right-aligned. Format: `MM:SS` for scans under 1 hour, `H:MM:SS` for scans >= 1 hour. Label: "Elapsed: [time]". Timer freezes when `Status__c = 'Paused'`; resumes from the paused value on resume. **Elapsed time derivation:** Elapsed time is always computed client-side from server-provided `CreatedDate`: `Math.floor((Date.now() - new Date(job.CreatedDate).getTime()) / 1000)`. This ensures elapsed time is accurate after navigation, page reload, and deep-link entry - not dependent on component state persistence. `getByIdForStatusView()` must include `CreatedDate` in the queried fields. **Mobile layout (< 768px):** stack status label (row 1) and elapsed time (row 2, right-aligned) vertically inside a flex container. Use `flex-direction: column; align-items: stretch`. Status label: row 1, full width, `white-space: normal` (wraps if long). Elapsed time: row 2, `align-self: flex-end; white-space: nowrap` - never wraps regardless of status label length. At >= 768px, render both on one row with status on left, elapsed on right. **Status label API name truncation:** if `Target_API_Name__c` exceeds 50 characters, truncate at 47 characters with "..." appended. Show full name in a tooltip on hover. **Polling:** when polling fallback is active (PE disabled or auto-suppressed), poll every 5 seconds during `Processing`, every 10 seconds during `Paused`. Show persistent info label immediately when the first poll result returns `Disable_Platform_Events__c = true`: "Live updates paused - refreshing every 5 seconds." **PE suppression detection:** The `getJobStatus()` response includes a `peSuppressionActive: Boolean` field (true when `Disable_Platform_Events__c = true` OR the engine has auto-suppressed PE for this execution). The LWC switches to polling mode immediately on receiving `peSuppressionActive: true` - without waiting for the async CMDT write to complete. `DependencyJobController.getJobStatus()` must derive this field from `job.Disable_Platform_Events__c` (read from settings) OR from a job-level `Platform_Events_Auto_Suppressed__c` flag if added to the job object. When `Status__c = 'Paused'` and polling is active, change this label to: "Live updates paused - refreshing every 10 seconds." Remove this label when `Status__c` reaches any terminal state (Completed, Failed, Cancelled). The label must not persist on a completed scan. Clear interval in `disconnectedCallback`. **Polling error recovery:** each `getJobStatus()` call in the polling loop is wrapped in try/catch. On failure, increment a `_pollFailCount` counter. If `_pollFailCount >= 3` and `< 5`, show a persistent dismissible warning banner below the progress bar: "Progress updates are having trouble reaching the server. The scan is still running - retrying..." (do not stop polling). If `_pollFailCount >= 5`, stop polling entirely and show a persistent non-dismissible error banner: "Progress updates have stopped. Check your network connection. [Retry polling]" - where "Retry polling" resets `_pollFailCount` to 0 and restarts the polling loop. A successful poll response resets `_pollFailCount` to 0 and removes any error banner. **Poll termination:** if `Status__c` has not reached a terminal state (Completed, Failed, Cancelled) after 60 minutes of polling, stop polling and show a persistent banner: "This scan has been running for over an hour. It may be stuck. [View partial results] or [Start a new scan]." **Paused visual state machine:** when `Status__c` transitions to `Paused`: the status label `<div>` is hidden (`display: none`). A warning banner element renders in its place: "Analysis paused - encountered a complex component. You can resume at a slower speed or with current settings." Resume buttons appear below the banner. The Cancel button is hidden. The progress bar freezes at its current value (not 100%). **Spinner-vs-paused:** when `Max_Components__c = 0` (cap disabled), the progress bar is replaced by a `lightning-spinner` during `Processing`. When `Status__c` transitions to `Paused`, this spinner must also be hidden - do not leave the spinner running while the paused warning banner is shown. The paused banner is the sole visual indicator of engine state during `Paused`; a simultaneous spinner contradicts it. Hide the spinner by conditioning its render on `Status__c === 'Processing'` (not just `Max_Components__c === 0`). Subscribes to `Dependency_Scan_Status__e` via `lightning/empApi` on mount; unsubscribes on destroy. **empApi subscription failure recovery:** wrap `empApi.subscribe()` in a try/catch in `connectedCallback`. On failure (e.g. `empApi` not available, org PE disabled at the platform level, or streaming API quota exceeded), log the error to the browser console and immediately start the polling fallback - do not surface the `empApi` error to the user directly. Show the "Live updates paused - refreshing every 5 seconds." info label as if `peSuppressionActive` were `true`. If the error reason is available and indicates a hard platform limit (e.g. `"Streaming API concurrent clients limit exceeded"`), also show a dismissible admin info banner above the progress bar: "Live updates unavailable - your org has reached the Streaming API client limit. Progress will refresh every 5 seconds." This banner is only shown if the error string contains a recognizable quota-limit message; generic errors fall back to the silent polling-only path. **Mounted guard (required):** add `this._isMounted = true` in `connectedCallback` and `this._isMounted = false` in `disconnectedCallback`. Wrap every PE event handler body with `if (!this._isMounted) return;` to prevent state updates on unmounted components when a PE delivery arrives after the component has been removed from the DOM. Cancel button shows confirmation modal before calling `cancelJob()`. |
| `metaMapperResults` | Tab container: "Tree View" and "Graph View" sharing filter state. **AI Summary card** at top (visible when `Status__c = Completed`): displays `Scan_Summary_Text__c` with "Copy" button and "Ask Copilot" quick action. Stats tile (type counts from `Component_Type_Counts__c`). Hosts export controls. |
| `metaMapperTree` | Virtual-rendered SLDS tree with search, type filter, level filter, and confidence filter. Supports collapse/expand per branch. Keyboard navigable. |
| `metaMapperGraph` | ECharts force-directed graph. Node click: selects node and populates the **Node Details Panel** (sidebar) - does NOT open Setup directly. Right-click: "Copy API Name". Hover: tooltip with `Dependency_Context__c` pills in plain English. "Expand All" guard: shows modal warning if node count > 1,000. Persistent sidebar legend. "Focus path to root". Graph toolbar search (quick-find: highlights matching nodes without affecting Tree). "?" keyboard shortcut legend. Type filter + level slider. ECharts theme registered for Salesforce dark mode (`slds-theme_inverse`). |
| `metaMapperComponentDetailsPanel` | Sidebar panel (right side of results screen). Renders full node data when a node is selected in either Tree or Graph: `Metadata_Name__c`, `Metadata_Type__c`, `Dependency_Depth__c`, `Discovery_Source__c`, `Supplemental_Confidence__c`, all `Dependency_Context__c` pills in plain English, `Ancestor_Path__c` rendered as a named breadcrumb chain, `Is_Circular__c` / `Is_Dynamic_Reference__c` flags with explanations. **Breadcrumb ID-to-Name resolution:** `Ancestor_Path__c` contains pipe-delimited `Metadata_Id__c` values. The component builds a `Map<String, String>` (id â†’ name) from the flat node list already loaded in `metaMapperResults` (passed as a prop). Each ID in the breadcrumb is looked up in this map to display `Metadata_Name__c`. Fallback: if an ID is not found in the map (should not occur under normal operation), display the raw ID. No extra SOQL query required. "Open in Setup" button (primary action) - behavior varies by type: ApexClass/ApexTrigger opens `/[orgId]/lightning/setup/ApexClasses/home`; Flow opens `/[orgId]/builder_platform_interaction/flowBuilder.app?flowId=[Metadata_Id__c]`; CustomField opens `/[orgId]/lightning/setup/ObjectManager/[ParentObject]/FieldsAndRelationships/view` (parent object extracted from `Dependency_Context__c.parentObject` or by splitting `Metadata_Name__c` on "." and using segment 0); ValidationRule opens `/[orgId]/lightning/setup/ObjectManager/[ParentObject]/ValidationRules/view`; WorkflowRule opens `/[orgId]/lightning/setup/WorkflowRules/home`; Report opens `/[orgId]/lightning/r/Report/[Metadata_Id__c]/view`. For types with no direct Setup URL (e.g. supplemental-only nodes, unknown types), the button is disabled and shows tooltip: "Setup link not available for this component type. You can search for it manually in Salesforce Setup." Do not hide the button - a disabled button communicates the feature exists but is unavailable. "Copy Link" button generates a deep-link URL (`[current URL]?jobId=[jobId]&nodeId=[Metadata_Id__c]`) and copies to clipboard. On success: label changes to "Link copied!" with `utility:check` icon, reverts after 2 seconds. The label change must be announced to screen readers via a visually-hidden `<span aria-live="polite" class="slds-assistive-text">` sibling element adjacent to the Copy Link button. On success, set its text content to "Link copied to clipboard." and clear after 2 seconds. Do NOT update the button's `aria-label` attribute - this causes focus re-announcement in some screen readers (NVDA, JAWS) when the button retains focus. On clipboard failure: toast "Could not copy to clipboard. Select and copy the URL manually instead." **Auto-close:** when `selectedNodeId` becomes null (user clicks blank canvas space, programmatic deselection, or filter hides the selected node), the panel closes immediately. When a filter hides the currently-selected node, selection clears (`selectedNodeId = null`), which closes the panel. A filtered-out node must never remain selected in state. Closes when selection is cleared. |
| `metaMapperExport` | Primary export: CSV ("Download as CSV") and JSON ("Download Complete Hierarchy (for developers)"). Default filename: `MetaMapper_[Target_API_Name]_[YYYYMMDD]_[HHmm]`. Advanced export (collapsible): package.xml ("Download Deployment Manifest"). No server round-trip. |

---

## UX Design Specification

### What MetaMapper Helps You Do

MetaMapper answers a single question that Salesforce Setup cannot: **"If I change or delete this component, what else will break?"** It traces every dependency of a metadata component - Apex classes, Flows, Validation Rules, Field Updates, page layouts, and more - and maps the full chain to any depth. Instead of manually cross-referencing Setup pages, running change sets blind, or discovering broken automation after deployment, you start a scan, wait a few minutes, and get a complete, explorable dependency map. The results are yours to filter, export, and share. Everything runs inside your org; nothing leaves the Salesforce trust boundary.

### Pre-Flight Check + First-Time Onboarding
On `metaMapperApp` mount, call `ToolingApiHealthCheck.verify()` via `@AuraEnabled`. Block the input form entirely until the check resolves. **Health check in-progress visual treatment:** while the callout is in flight, render a `lightning-spinner` variant="brand" size="medium" centered above the blocked input form. The form fields are rendered but disabled (not hidden). The spinner is removed and the form is enabled (or replaced by an error state) when the check resolves. **Deep-link mount loading state:** when `metaMapperApp` mounts with a `?jobId=` URL param, `getJobStatus()` is called to verify the job exists before deciding which view to render. During that call, render a full-page `lightning-spinner` variant="brand" centered on a blank shell. Do not render the form, progress view, or results view until `getJobStatus()` resolves. On resolution: if the job exists, route based on `Status__c`: `Initializing`, `Processing`, or `Paused` → render the progress view (subscribes to Platform Events and polling as normal, including the 15-minute long-running banner if applicable); `Completed`, `Failed`, or `Cancelled` → render the results view (calls `getNodeHierarchy()`). If not found, show the "scan result no longer available" error state. Five distinct pre-flight failure states (not a single generic error):

| Failure type | Detected by | UI message | Action link |
|---|---|---|---|
| Named Credential not authorized | HTTP 401 from health check callout | "MetaMapper needs one-time setup. An admin must authorize the Tooling API connection." | "Learn more" link opens an SLDS modal rendering the Named Credential setup steps from `setup/SETUP.md` with an explicit "Close" button. Modal `aria-label="MetaMapper setup instructions"`. |
| Current user lacks MetaMapper permission set | `PERMISSION_SET_MISSING` (custom permission check, fires before callout) | "You don't have access to MetaMapper. Ask your admin to assign you the MetaMapper Admin permission set. If you were recently assigned, try refreshing your browser - Salesforce caches permission checks for a few minutes." | No link; text only |
| Connected App OAuth scope misconfigured | `CALLOUT_FORBIDDEN` (HTTP 403 from Tooling API) | "MetaMapper connected but was denied by the Tooling API. Ask your admin to verify the Connected App has the required OAuth scopes." | No link; text only |
| Tooling API temporarily unreachable | HTTP 5xx | "MetaMapper cannot reach the Tooling API right now. This may be a temporary org issue." | "Retry" button that re-runs the health check |
| Callout timeout | `System.CalloutException` with "Read timed out" | "MetaMapper's connection check timed out. This is usually a temporary org issue - try again in a moment." | "Retry" button that re-runs the health check |

Do not collapse all five into a single "setup required" message - each requires a different user action and a different responsible party (admin vs user vs wait).

> **`ToolingApiHealthCheck` return code restriction:** `verify()` must return ONLY `PERMISSION_SET_MISSING` to users who fail the permission check. It must NOT return `UNAUTHORIZED`, `CALLOUT_FORBIDDEN`, `UNREACHABLE`, or `TIMEOUT` to unauthorized users - those codes reveal Named Credential and Connected App configuration state to users who should not see it.

**"Learn more" modal content:** the Named Credential setup steps shown in the modal are hardcoded as static HTML in the LWC component - they are NOT read from `setup/SETUP.md` at runtime (Markdown source files are not accessible in a deployed Salesforce org). The LWC contains the setup instructions as a static template. When `setup/SETUP.md` is updated, the LWC modal content must be updated manually to stay in sync.

**First-time guided tour:** After the Named Credential health check passes for the first time (detected via a `localStorage` flag `metaMapper_tourSeen_v1`), show a one-time `lightning-modal` walkthrough with three slides:
1. **"Reading the graph"** - Body: "Nodes are color-coded by metadata type. Solid borders show standard dependencies. Dashed borders indicate circular dependencies - these components depend on each other in a loop. Hover over any node to see details."
2. **"Warning badges"** - Body: "Orange warning badge = dynamic reference (an Apex string we can't fully resolve - verify manually). Red error badge = low confidence match (below 70% - verify before making changes). Dashed border = circular dependency."
3. **"Supplemental results"** - Body: "Some dependencies are found through secondary analysis, not the standard Salesforce metadata API. These may include false positives. Nodes with a confidence score below 70% should be verified before making any changes."

User can dismiss at any time. "Don't show again" checkbox label: **"Don't show again. I understand MetaMapper basics."** Clicking "X" on any slide always closes the modal and sets `localStorage` flag `metaMapper_tourSeen_v1 = true`, regardless of checkbox state. The checkbox is informational only - the flag is set on any dismissal path (X button or "Got it" on slide 3). Dismissal on any slide is final - no minimum content gate, no "are you sure?" confirmation. Bump the version suffix (e.g. `_v2`) on major UX changes to force the tour to re-display for all existing users.

**Focus management:** On close (any method - X button, "Got it", or Esc), return focus to the element that had focus immediately before the tour opened. If auto-triggered on first login (no triggering element), return focus to the first focusable element in `metaMapperSearch`. Track the triggering element via `this._tourTriggerElement = document.activeElement` immediately before opening the tour.

**Mobile behavior (< 1024px):** The tour renders as a full-screen fixed-position modal (`position: fixed; inset: 0; z-index: 2000`). The container has `role="dialog"` `aria-modal="true"` `aria-label="MetaMapper first-time tour"` `tabindex="-1"`. The Close button is fixed in the header with minimum 44px touch target. Slide content and navigation buttons scroll within the modal. Slide transitions: same 300ms fade as desktop. **Mobile focus management:** on mobile (< 1024px), `document.activeElement` is typically `document.body` (no keyboard focus in a touch session). On tour open, move programmatic focus to the modal container (`tabindex="-1"` element) so screen readers announce the dialog. On tour close, do NOT attempt to restore focus to the pre-open element - restoring focus to `document.body` on a touch device provides no UX value and may cause unexpected scroll jumps. Instead, set focus to the first focusable element in `metaMapperSearch` (same fallback as the auto-triggered desktop path).

**localStorage vs sessionStorage:** Use `localStorage` (persistent per browser, survives tab close and browser restart). The "Reset First-Time Tour" admin button clears the `localStorage` key for the current browser, not just the current session. Update button tooltip: "Resets the tour for this browser. The tour will appear again on the next page load."

**Slide transitions:** 300ms fade-out of the current slide + 300ms fade-in of the new slide (`transition: opacity 300ms ease-in-out`). No slide, bounce, or other motion. **Slide navigation buttons:** Slide 1: "Next" only (no Previous). Slides 2-3: both "Previous" and "Next". Slide 3: "Previous" and "Got it" (no Next). **Progress indicator:** visible text "Slide [N] of 3" rendered below the slide body, updated on each advance. **Tour modal ARIA:** modal container `aria-label="MetaMapper first-time tour"`. Navigation buttons: `aria-label="Next (slide [current+1] of 3)"` and `aria-label="Previous (slide [current-1] of 3)"` where the number references the target slide. Close button: `aria-label="Close tour"`. On each slide advance, focus moves programmatically to the slide body container (a `<div tabindex='-1'>` wrapping the body text) so screen readers re-announce the new content. An `aria-live='polite'` region on the slide body is an acceptable alternative. Do NOT leave the new slide content in a stable DOM container without either focus movement or a live region - screen readers will not re-announce unchanged containers.

### Input Screen (`metaMapperSearch`)

| Element | Behavior |
|---|---|
| Metadata Type picklist | Required; shows supported types only |
| API Name input | Required; placeholder is type-responsive (computed getter): CustomField = "e.g. Account.My_Field__c"; ApexClass = "e.g. AccountTriggerHandler"; Flow = "e.g. Account_Before_Save"; ValidationRule = "e.g. Validate_Phone (developer name only, no object prefix)"; default (no type selected) = "e.g. Account.My_Field__c". Inline validation on blur. Blank after blur: 'Enter the API name of the component you want to scan.' Invalid format: 'Use the exact API name as it appears in Salesforce Setup (e.g. Account.My_Field__c).' **ValidationRule input note:** When `Target_Metadata_Type__c = ValidationRule`, show inline help text below the API Name field: "Validation Rule API names do not include the parent object. Enter just the developer name as shown in Setup (e.g. Validate_Phone)." |
| Target Object typeahead | Required only when type is `CustomField`; shows validation message if omitted: "Enter the API name of the parent object (e.g. Account)."; placeholder: "e.g. Account". **Loading state:** while the `EntityDefinition` query is in flight (debounce 300ms + callout), show a `lightning-spinner` size="x-small" inside the input field's right slot. **Empty state:** if the query returns zero results, show dropdown item "(No matching objects found)" - disabled, not selectable. **Error state:** if the callout throws, show inline validation message below the field: "Could not load object list. Type the object API name manually." - do not block the form. The field remains freeform-text-editable in all states so the user can type the API name without relying on the typeahead. |
| "Only analyze active Flow versions" checkbox | Label: "Only analyze active Flow versions". Default checked; tooltip: "When checked, inactive and deprecated Flow versions are excluded from results. This reduces scan scope and processing time. Uncheck to include all Flow versions, including inactive ones." |
| Complexity preview | After API Name is entered, show: "Estimated scan scope: [Small / Medium / Large / Very Large] based on historical averages for this metadata type." (non-blocking, best-effort). **Loading state:** while `getComponentCount()` is in flight (after the 300ms debounce), render the text "Estimating scope..." in the preview slot with a `lightning-spinner` size="x-small" inline to the left of the text. Replace with the bucket label on success. Hide the slot entirely on any exception. The loading state must appear immediately after the debounce fires so the user knows the system is working. **Implementation:** call a new `@AuraEnabled(cacheable=true)` method `DependencyJobController.getComponentCount(String apiName)` that executes: `SELECT COUNT() FROM MetadataComponentDependency WHERE RefMetadataComponentId IN (SELECT Id FROM MetadataComponentDependency WHERE MetadataComponentId.Name = :apiName)`. Map the count to buckets: 0-100 = Small, 101-500 = Medium, 501-2000 = Large, >2000 = Very Large. On any exception (type not in Tooling API, callout fails, permission error), suppress the slot entirely - do not render an error message in the preview area. |
| Submit button | Disabled until required fields valid; label "Analyze Dependencies". **Post-click loading state:** on click, immediately disable **only the Submit button** (set to `is-loading`, label "Starting analysis..."). Form inputs remain enabled so the user can correct values if the server returns a validation error. If `createJob()` returns an error, re-enable the Submit button and restore the label. On success, parent component transitions to the progress view. |

### Progress Screen (`metaMapperProgress`)

**Status labels (human-readable, not Status__c API values):**

| Status__c value | UI label |
|---|---|
| Initializing | "Setting up your analysis..." |
| Processing | "Analyzing [Target_API_Name__c]... [N] components found so far" |
| Paused | "Analysis of [Target_API_Name__c] paused - encountered a complex component." + "[Resume at slower speed (reduces batch size by 50%)]" button + "[Resume with current settings (batch size: [current_value])]" button (`[current_value]` is populated from `batchSizeInUse` in the `getJobStatus()` response - equal to `Batch_Size_Override__c` if non-null, else the CMDT `Scan_Batch_Size__c` value. `getJobStatus()` must include `batchSizeInUse: Integer` in its response wrapper.) |
| Cancelled | "Analysis of [Target_API_Name__c] cancelled. Partial results are available." + "[View partial results]" link button that calls `getNodeHierarchy()` and navigates to the results view |
| Completed | "Analysis of [Target_API_Name__c] complete. [N] components found." |
| Failed | "Analysis of [Target_API_Name__c] failed. [first 200 chars of Scan_Diagnostic_Log__c, or 'An unexpected error stopped the analysis.' if blank]. See details for diagnostics." |

> **Status label truncation scope:** the 50-character truncation rule (see `metaMapperProgress` description above) applies only to the static display of `Target_API_Name__c` in the progress bar area. Status labels in this table render the **full** `Target_API_Name__c` without truncation, even if the name is long. Never truncate the name inside a sentence - a truncated name mid-label (e.g., "Analyzing Account.Phone__... 42 components found") is confusing and provides no value over the full name.

**Cancel interaction:**
1. User clicks "Cancel" - NO state change yet; show confirmation modal immediately. **Modal title:** "Stop this analysis?" **Body:** "The job will stop at the next checkpoint. Partial results already found will remain available." **Buttons:** "Keep Running" (left, neutral style, `aria-label="Keep the scan running - do not cancel"`) and "Stop Analysis" (right, destructive style, `aria-label="Confirm. Stop the analysis now."`). **Focus management:** on modal open, focus moves programmatically to the "Keep Running" button. On "Keep Running" (modal close), focus returns to the Cancel button. On "Stop Analysis", focus stays on the button as it transitions to "Cancelling..." state.
2. On confirm ("Stop Analysis"): THEN button transitions to disabled "Cancelling..." with spinner; calls `cancelJob()`
3. LWC waits for `Dependency_Scan_Status__e` with `Status__c = 'Cancelled'` before re-enabling UI. **PE-disabled fallback:** if `Disable_Platform_Events__c = true` or PE has been auto-suppressed, the event will never arrive. In this case the LWC must fall back to polling `getJobStatus()` (same polling loop used for progress updates) until `Status__c = 'Cancelled'` is returned, then re-enable the UI. The cancel flow must not rely on PE as the sole completion signal.

The Cancel button is visible and enabled from the moment `Status__c = 'Initializing'` - the job record exists and can be cancelled before any processing begins.

**Cancel visual state machine (all intermediate states defined):**

| Phase | Cancel button state | Status label |
|---|---|---|
| Before confirmation modal | Enabled, label "Cancel" | Current status label |
| Confirmation modal open | Modal open; Cancel button unchanged | Current status label |
| Modal dismissed (user chose "Keep running") | Enabled, label "Cancel" | Current status label |
| Modal confirmed; `cancelJob()` in flight | Disabled, label "Cancelling..." with spinner | "Stopping analysis..." Below the Cancel button (outside it), add a non-button secondary label: "Stopping at next checkpoint..." - appears immediately on `cancelJob()` RPC initiation (before it resolves). Removed when `Status__c = 'Cancelled'` is received or timeout fires. |
| `cancelJob()` call returned error | Re-enabled, label "Cancel"; toast error shown | Restored to previous label |
| `Status__c = 'Cancelled'` received (PE or poll) | Button hidden; "Start new scan" shown | "Analysis cancelled. Partial results are available." + "[View partial results]" link button that calls `getNodeHierarchy()` and navigates to the results view |
| 60-min poll termination fires while cancel in progress | Cancel timer stopped; Cancel button disabled permanently (no PE mechanism to detect Cancelled); 60-min banner shown only | "This scan has been running for over an hour. It may be stuck. [View partial results] or [Start a new scan]." |

**Cancel timeout:** if `Status__c = 'Cancelled'` is not received within 30 seconds of `cancelJob()` returning success (via either PE or polling), the LWC re-enables the Cancel button and shows a persistent info banner: "Cancellation is taking longer than expected. The scan will stop when the current step finishes. You can try cancelling again if this persists." **Timer start point:** the 30-second timer starts the moment `cancelJob()` RPC resolves successfully - not when the user clicks the Cancel button, and not when the user confirms in the modal. The full cancel timeline: (1) user clicks Cancel â†’ modal opens, no timer; (2) user clicks "Stop Analysis" â†’ `cancelJob()` RPC fires, no timer; (3) `cancelJob()` returns success â†’ **30-second timer starts now**; (4) LWC polls or waits for PE until `Status__c = 'Cancelled'`; (5) on timeout, re-enable the button and show info banner.

**Long-running scan notice:** If the scan has been in `Processing` status for more than 15 minutes (calculated from `CreatedDate` server-side on every page load: `elapsedSeconds = Math.floor((Date.now() - new Date(job.CreatedDate).getTime()) / 1000)`; if `elapsedSeconds > 900` AND `Status__c = 'Processing'`, show the banner immediately regardless of whether this session started the scan - survives page reloads and deep-links), display a persistent dismissible info banner above the progress bar: "This scan is taking longer than usual. [View partial results so far] - this will not cancel the scan." The "View partial results so far" link calls `getNodeHierarchy()` and opens the results view without changing the job status. When the user is viewing partial results and the scan completes (PE event `Status__c = 'Completed'` received), show a persistent banner at the top of the results view: "Scan complete! [Reload results] to see the final dependency map." If the "Reload results" call fails, replace the banner with the `getNodeHierarchy()` error state: title "Results unavailable", body "The final results could not be loaded. [Retry]". When the user is viewing partial results and the scan transitions to `Failed` or `Cancelled`, show a persistent banner: "This scan has stopped. These results are partial. [Download partial results] or [Start a new scan]." **Back-navigation:** if the user navigates back to the progress view from partial results while the scan is still `Processing`, re-render the progress view with the long-running scan banner already showing (elapsed time > 15 min). Do not reset the elapsed timer. This prevents the user from acting on stale partial data without context. The 15-minute banner is dismissed with a close icon. Dismiss is per page load only (not stored in localStorage). The banner reappears on every new page load when the scan is still in `Processing` status and elapsed time exceeds 15 minutes.

**Banner precedence:** When both the 15-minute and 60-minute conditions are met simultaneously (elapsed >= 60 min AND `Status__c = Processing`), render only the 60-minute banner. The 60-minute banner supersedes the 15-minute banner - suppress the 15-minute banner entirely.

### Graph View (`metaMapperGraph`)

**Node visual language (SLDS-compliant, not color-only):**

**Node type colors (SLDS tokens - required inputs for `setup/CONTRAST_MATRIX.md`):**

| Metadata_Type__c | SLDS token | Hex | Icon |
|---|---|---|---|
| ApexClass | `--lwc-colorTextActionLabelActive` (`#0176d3`) | `#0176d3` | `utility:apex` |
| ApexTrigger | `--lwc-colorTextActionLabelActive` (`#0176d3`) | `#0176d3` | `utility:apex` |
| Flow | `--lwc-brandAccessibilityColor` (`#1b5297`) | `#1b5297` | `utility:flow` |
| CustomField | `--lwc-colorTextSuccess` (`#2e844a`) | `#2e844a` | `utility:custom_apps` |
| ValidationRule | `--lwc-colorTextError` (`#ba0517`) | `#ba0517` | `utility:rules` |
| WorkflowRule | `--lwc-colorTextWarning` (`#dd7a01`) | `#dd7a01` | `utility:process` |
| Report | `--lwc-colorTextInverse` (`#444`) | `#444444` | `utility:report` |
| (default/other) | `--lwc-colorTextDefault` (`#3e3e3c`) | `#3e3e3c` | `utility:connected_apps` |

> These tokens must be verified against WCAG AA (4.5:1 normal text, 3:1 large text/UI) on both `#FFFFFF` and `#1B1B1B` backgrounds and recorded in `setup/CONTRAST_MATRIX.md` before any LWC implementation begins.

| Node type | Color | Icon | Shape indicator |
|---|---|---|---|
| Is_Circular__c | Type color | `utility:rotate` | Dashed border |
| Is_Dynamic_Reference__c | Type color | `utility:warning` | Solid border |
| Discovery_Source__c = Supplemental | Type color | `utility:info` | [S] badge |
| Supplemental_Confidence__c < 70 | Type color | `utility:error` | Red badge; click opens popover |
| Normal node | Type color | Type-specific icon | Solid border |

**Interactions:**
- **Click:** selects node and populates the Node Details Panel sidebar. Does NOT open Setup directly - "Open in Setup" is a button in the panel. This separates selection (inspect) from navigation (open Setup).
- **Right-click:** context menu with "Copy API Name", "Focus path to root", "Collapse subtree". **"Focus path to root" in the right-click menu operates on the right-clicked node, NOT the left-click selected node** - right-click does not change selection. The Node Details Panel is NOT updated by right-click. When right-clicking while focus mode is active, the current focus path clears **synchronously before the menu renders** (canvas undims before menu appears). If the right-clicked node is dimmed (non-focused), focus clears before the context menu appears. **Context menu dismiss:** `role="menu"` on the context menu container. `role="menuitem"` on each item. When the context menu opens via any method (mouse right-click or keyboard), focus moves programmatically to the first menu item. (a) Esc closes the menu and returns focus to the element that had focus immediately before the context menu opened - tracked via `this._lastFocusBeforeMenu = document.activeElement` captured on the `contextmenu` event. If that element is no longer in the DOM, fall back to `this.template.querySelector('.graph-canvas-wrapper')` which has `tabindex="0"`. (b) click anywhere outside the menu closes it; (c) selecting a menu item executes the action and closes the menu. **Right-click does NOT change the selected node or the Node Details Panel** - the context menu operates independently of selection. To select a node and open the panel, use left-click. **"Copy API Name" confirmation:** on clipboard success, show a transient toast "Copied API Name: [value]" (auto-dismisses after 3 seconds). On clipboard failure, show error toast: "Could not copy to clipboard. Select and copy the name manually instead." **Esc while menu open:** closes the menu only - does not affect any active focus mode. To clear focus, use the explicit "Clear Focus" button in the toolbar.
- **Hover:** SLDS tooltip with this exact template: `[Metadata_Name__c] ([Metadata_Type__c]) | [plain-English pill rendering] | [Confidence: N% - verify manually]` where pill rendering maps `Dependency_Context__c` keys to human sentences (e.g. `isWrite: true` -> "Writes to this field"; `activeVersions: 3` -> "3 active versions"; `cycleClosesAt: X` -> "Cycle closes at X"; `filterUsage: ["filter", "grouping", "column"]` -> "Used as: [comma-joined list of values]" (e.g. "Used as: filter, grouping, column"; single-item: "Used as: filter")). Never render raw JSON in the tooltip.
- **"Expand All" guard:** if `Components_Analyzed__c > 1,000`, clicking "Expand All" shows modal: title "Large Graph Warning", body "This graph contains [N] nodes. Expanding all levels may slow or freeze your browser. Consider using the Level Filter or exporting to CSV instead." Buttons: "Keep Collapsed" (left, neutral style, `aria-label="Cancel. Do not expand all nodes - return to filtered view."`, **receives focus when modal opens per WCAG 2.4.3** - the non-destructive option must always be the default focus target) and "Expand All ([N] nodes)" (right, destructive style, `aria-label="Confirm. Expand all [N] nodes now. This may slow your browser."`).
- **"Collapse All" button:** Add a "Collapse All" button to the graph toolbar alongside (or near) the Expand All control. No size guard required - collapsing is always safe at any node count. Label: "Collapse All". `aria-label="Collapse all branches"`. Collapses all expanded branches to show only depth-0 (root) nodes - not viewport-relative. "Collapse subtree" in the right-click context menu collapses only the right-clicked node's children and grandchildren, leaving sibling branches unaffected. If the right-clicked node is the root node (depth 0), "Collapse subtree" is equivalent to "Collapse All" - all non-root nodes are hidden. The root node itself is never hidden. In this case the menu item label changes to "Collapse all children" to avoid confusion. Symmetric counterpart to the Expand All guard.
- **"Focus path to root":** highlights the direct ancestor chain from selected node to root; dims all other nodes. A **"Clear Focus"** button appears in the graph toolbar while focus is active. When focus path is activated, keyboard focus moves to the "Clear Focus" button in the toolbar, making the mode immediately dismissible by keyboard without additional Tab presses. Pressing `Esc` while focus mode is active also clears the focus path. Do not rely on "click anywhere" alone as the only dismissal affordance.
- **Persistent legend:** always-visible sidebar listing all node types with color swatch + icon + label
- **Graph toolbar search:** lightweight search box on the graph toolbar (Ctrl+K shortcut - scoped to the graph canvas container only; the event listener must NOT intercept Ctrl+K globally so as not to override browser address bar behavior when focus is outside the canvas). **Exact scoping:** The Ctrl+K event listener is attached to the graph canvas wrapper element via `addEventListener` in `connectedCallback` and removed in `disconnectedCallback`. It fires only when `event.target` is a descendant of (or equal to) the canvas wrapper. Do NOT attach to `document` or `window`. When fired, moves focus to the graph toolbar search input and selects any existing text. If the search input already has focus, Ctrl+K is a no-op. Placeholder text: "Search nodes in this graph..." Inline note below the input: "(Search applies to Graph view only - highlights nodes without hiding non-matches)". Highlights matching nodes in the graph canvas without filtering them out. Does not affect Tree View (Tree-local search remains separate and filters/hides non-matching rows - this asymmetry is intentional). Clears with Esc.
- **"?" keyboard shortcut legend:** small "?" icon button in graph toolbar with visible text label "?" on desktop. Button has `aria-label="Show keyboard shortcuts (Shift+?)"` and a persistent hover tooltip: "Keyboard shortcuts (Shift+?)". On mobile (< 1024px), the button is hidden (keyboard shortcuts are not relevant on touch devices). Opens a dialog listing: `Ctrl+K` = Search graph (canvas focus only), `Shift+?` = Open keyboard legend (canvas focus only), `Esc` = Clear focus / search, arrow keys = traverse nodes, `Enter` = Select node (open Node Details Panel), right-click = Context menu. Rendered as an SLDS dialog (`role="dialog"`, `aria-label="Keyboard shortcuts"`, `aria-modal="true"`) with an explicit "Close" button inside. Esc closes the dialog and returns focus to the "?" button. Do NOT use `role="region"` - a region landmark requires a visible heading, and a popover without one is invalid ARIA.
- **Node Details Panel:** selecting a node (single click) populates the `metaMapperComponentDetailsPanel` sidebar panel with full node data. "Open in Setup" is the primary action button in the panel, not triggered by the click itself. This separates selection (inspect) from navigation (open Setup).
- **Spanning tree notice:** a dismissible info badge is shown in the persistent graph legend: "Showing the first-discovered path to each component. A node reachable via multiple paths appears once." Dismissed via a close icon (`<button aria-label="Dismiss spanning tree notice">`); state persisted in `localStorage` key `metaMapper_spanningTreeNotice_v1`. Does not reappear after dismissal on the same browser. The badge container is `<div role="status">` so screen readers announce it on initial render without interrupting interaction. (`role="status"` implies `aria-live="polite"` natively - do NOT add a redundant explicit `aria-live="polite"` attribute, as this causes double-announcement in some screen readers.) On dismiss, focus moves to the graph canvas container.
- **Large graph performance warning:** when `Components_Analyzed__c > 8,000`, show a persistent banner above the graph canvas: "Large graph detected ([N] components). For best performance, use Tree View or apply filters to reduce scope." Banner includes a "Switch to Tree View" button that activates the Tree tab directly. Banner is dismissible. Does not affect Tree View. On mobile (< 1024px), the large graph performance warning is suppressed - the mobile "For best results, use a desktop browser" banner already communicates degraded experience. The two banners never stack.
- **ECharts dark mode:** register a Salesforce-compatible dark theme using `echarts.registerTheme('sfDark', {...})` with SLDS dark background token (`#1B1B1B`) and text token (`#FFFFFF`). Apply theme when `document.body.classList.contains('slds-theme_inverse')`.

**Confidence badge popover (Supplemental nodes with score < 70):**
Plain-English explanation by handler (show popover for ALL Supplemental nodes with `Supplemental_Confidence__c < 70`):
- ValidationRule regex (65%): "This dependency was found by scanning Validation Rule formulas for field names. The match may be from comments or cross-object references. Verify manually before making changes."
- FlexiPage XML (60%): "This dependency was found by parsing Lightning page XML. Version-sensitive: if the page was saved in a different API version, this reference may no longer exist. Verify in Lightning App Builder."
- CustomFieldDependencyHandler CMT lookups (85% - no popover, above threshold): not shown.
- Lookup relationships (95% - no popover, above threshold): not shown.
- ApexClassDependencyHandler CMT references (85% - no popover, above threshold): not shown.
- If `Supplemental_Confidence__c` is between 60-69 and the handler type is not listed above: "This dependency was found through supplemental analysis. The match confidence is below 70%. Verify manually before making changes."
- **`Is_Dynamic_Reference__c = true` nodes:** show a popover on the `utility:warning` badge for ALL nodes with `Is_Dynamic_Reference__c = true`, regardless of `Supplemental_Confidence__c` value or `Discovery_Source__c`: "This dependency was detected as a dynamic Apex string reference. The actual dependency target is determined at runtime and cannot be statically resolved. Verify manually before making changes to referenced types." This popover is separate from the confidence-score popover - a node can have both flags set simultaneously, in which case both popovers are shown (confidence popover on the red badge, dynamic reference popover on the orange warning badge).

### Tree View (`metaMapperTree`)

| Feature | Behavior |
|---|---|
| Rendering | Virtual (only visible rows rendered); handles 10,000+ nodes without freeze |
| Search | Full-text search on `Metadata_Name__c`; highlights matches; clears with X |
| Filters | Type multi-select, Level range slider, Confidence threshold, Is_Circular, Is_Dynamic, Source |
| Collapse/Expand | Per branch; keyboard navigable (arrow keys, Enter, Space) |
| Node action | Click selects node and populates Node Details Panel. "Open in Setup" is a button in the panel. |
| Right-click | Context menu with two options: "Copy API Name" (copies `Metadata_Name__c` to clipboard - this is the developer API name, not the display label; on success show toast "Copied API Name: [value]" so the user knows what was copied; on failure show error toast) and "Collapse subtree" (collapses this node's subtree - same label as Graph View for consistency; if the right-clicked node is the root node (`Dependency_Depth__c = 0`), the label changes to "Collapse all children" - consistent with Graph View behavior for root nodes). "Focus path to root" is omitted from the Tree context menu - use Graph view for path visualization. **"View path in Graph":** A third right-click option on every tree node. On selection: (1) store this node's `Metadata_Id__c` in `pendingFocusNodeId` on `metaMapperResults`, (2) switch the active tab to Graph. Do NOT activate Focus Path immediately - the graph may not have rendered yet. On receipt of the `tabready` event from `metaMapperGraph`, check if `pendingFocusNodeId` is set; if so, activate Focus Path to Root for that node and clear `pendingFocusNodeId`. While `isTransitioning === true`, do not apply focus - wait for the transition to complete. The option is always shown (not conditional on graph rendering state). **Keyboard dismissal:** Esc closes the menu and returns focus to the tree container element, consistent with Graph View behavior. |

### Tree/Graph Synchronization Rules

The Tree View and Graph View share the same underlying data set. These rules govern their coordination:

| Interaction | Tree View | Graph View |
|---|---|---|
| Type filter changed | Hides/shows rows of that type | Hides/shows nodes of that type |
| Level filter changed | Collapses/shows depth | Dims/hides nodes beyond level |
| Node selected (click) in Tree | Node highlighted in tree | Corresponding node highlighted in graph (same `Metadata_Id__c`). If the graph tab has not been rendered in this session, defer graph rendering until the user switches to the Graph tab - do NOT pre-render in background. On tab switch, highlight the last-selected node (if still selected). If the node is filtered out by a graph-only filter, it remains selected in the panel but is not visually highlighted until the filter is cleared. Node selection highlights use a 300ms glow via ECharts `emphasis.itemStyle`. |
| Node selected (click) in Graph | Corresponding row scrolled into view and highlighted in tree. If the target row is inside a collapsed branch, expand all ancestor branches from root to parent first, then scroll the now-visible row into view. Show "Locating node..." inline indicator next to the Tree search box if ancestor expansion takes > 200ms. | Node highlighted |
| "Focus path to root" triggered in Graph | Tree scrolls to root; ancestor chain nodes highlighted | Ancestor chain highlighted; others dimmed |
| Tab switched (Tree -> Graph) | Focus state in Tree clears | Graph renders with same filter state as Tree |
| Tab switched (Graph -> Tree) | Tree renders with same filter state as Graph | Focus state in Graph clears |
| Search applied in Tree | Tree filters rows (hides non-matching nodes) | Graph is NOT affected (search is Tree-only; Graph search highlights without hiding) |

> Filters (type, level) are shared state owned by `metaMapperResults` and persist across tab switches and page navigation within the session (stored in `sessionStorage` key `metaMapper_filters_v1`). On loading filter state from sessionStorage, validate each stored filter value against the current result set - discard any stored filter values whose metadata types are not present in the current scan. If all stored filters are invalid (every stored type absent from the new scan), render the default filter state (no type filters active, full level range, no confidence threshold). **Empty types array is always valid:** An empty `types: []` array means "show all types" and requires no type validation - it is always treated as valid regardless of the new scan's metadata types. Type validation applies only to non-empty `types` arrays. Discarding individual invalid entries that results in an empty array is treated silently (no toast) - the user effectively sees all nodes, which is the desired behavior. If any filters are discarded (partial or complete), show a dismissible info toast: "Some filters from your previous session were reset because this scan has different metadata types." Tree search term is Tree-local state but persists across tab switches within the session (stored in `sessionStorage` key `metaMapper_treeSearch_v1`); it is not shared with Graph. Selection and focus are transient and clear on tab switch. **sessionStorage scope:** sessionStorage is tab-scoped by the browser - filter and search state persist for the lifetime of the browser tab but clear when the tab is closed or the user opens MetaMapper in a new tab. No cross-tab or cross-session persistence. On a new tab or after tab close-and-reopen, filters start fresh.

**sessionStorage filter schema (`metaMapper_filters_v1`):** JSON object with this exact shape:
```json
{
  "types": ["ApexClass", "Flow"],
  "minLevel": 0,
  "maxLevel": 10,
  "confidenceThreshold": 0,
  "showCircular": true,
  "showDynamic": true,
  "showSupplemental": true
}
```
`types`: array of `Metadata_Type__c` string values to SHOW (empty array = show all types). `minLevel`/`maxLevel`: inclusive depth range. `confidenceThreshold`: hide nodes where `Supplemental_Confidence__c < threshold` (0 = no threshold). Boolean flags: when `false`, hide those node categories. Deserialize with `try/catch` and fall back to default state on any parse error or schema mismatch (unknown key, wrong type). Default state: `types: [], minLevel: 0, maxLevel: 9999, confidenceThreshold: 0, showCircular: true, showDynamic: true, showSupplemental: true`.

**Simultaneous state update rules:**
- Filter changes are last-write-wins. If the user changes a filter while a tab switch is in progress, the filter change takes effect after the tab transition completes.
- Selection events (node clicks) are dropped during a tab transition. If a node click and a tab switch occur simultaneously, the selection is ignored - the user must re-select after the tab renders.
- No undefined state is possible: the parent component (`metaMapperResults`) owns all shared state and processes events in sequence. Child components fire events; they do not mutate shared state directly.
- **`isTransitioning` flag:** implemented as a boolean property on `metaMapperResults`. Set to `true` when a tab switch begins; cleared only after the newly active child tab has finished rendering its data (not just when the DOM mounts). **`tabready` event timing (critical):** both child tab components must fire `tabready` only after data is actually rendered - `renderedCallback` fires after DOM mount but before async data loading or ECharts canvas rendering. For `metaMapperTree`: fire `tabready` in `renderedCallback` after the virtual list is populated with data (guard with `_hasRendered` boolean). For `metaMapperGraph`: fire `tabready` inside the ECharts `'finished'` event callback (after `.setOption()` completes), not in `renderedCallback`. As a safe fallback, parent holds `isTransitioning = true` for a minimum 300ms after `tabready` fires (matching the CSS animation duration) before clearing - this guarantees the animation completes regardless of when the event fires. Do NOT clear in `connectedCallback`. **Hard timeout:** if `tabready` is not received within 3 seconds of tab switch initiation, force `isTransitioning = false` and render the tab's error state: "Graph could not be loaded. [Retry]" (re-calls `.setOption()`) or "Tree could not be loaded. [Retry]". This prevents permanent interaction block if tab rendering fails silently. While `isTransitioning === true`, node-click events received from child components are silently dropped. **Platform Event handling during transition:** Platform Events received while `isTransitioning === true` are **discarded** (not queued). The 5-second polling fallback will capture any missed status change on the next poll cycle. This avoids the data-consistency risk of replaying stale PE payloads after the tab renders with potentially newer data. Do NOT queue PEs during transition.

**Tab transition reconciliation (critical):** After `isTransitioning` clears (either via the `tabready` event or the 3-second hard timeout), `metaMapperResults` must issue a single `getJobStatus()` reconciliation call to catch any `Dependency_Scan_Status__e` Platform Events that were discarded during the transition. This is a one-time poll - not the start of the polling loop. Apply the reconciled status to the progress bar and status label. This only applies when PE is active (not suppressed); when polling is already running, the next scheduled poll cycle covers this automatically.

**PE subscription ownership:** PE routing is centralized in `metaMapperApp`. `metaMapperApp` owns the `empApi` subscription for `Dependency_Scan_Status__e` and distributes events to children via `scanstatuschange` custom event properties. `metaMapperResults` does NOT subscribe to `empApi` directly - it receives PE payloads from `metaMapperApp` via this event. This ensures `isTransitioning` in `metaMapperResults` can gate PE delivery before passing the payload to its children.

### Empty and Error States

| Scenario | UI |
|---|---|
| Job completed with zero results | Empty state illustration + "No dependencies found for [API name]. This metadata type may not have trackable dependencies, or the component may not exist." |
| Job failed mid-way | Error banner with collapsed detail. **Error summary text:** the first 200 characters of `Scan_Diagnostic_Log__c`, truncated at the nearest word boundary with "..." appended. If `Scan_Diagnostic_Log__c` is null or blank, use static fallback: "An unexpected error stopped the analysis." Full detail available via "View full error" expander showing the complete `Scan_Diagnostic_Log__c`. "Start a new scan" button. |
| Job failed during result serialization | Distinct from "failed mid-way": `ScanResultFileQueueable` failed after all traversal completed. Detected by: `Status__c = 'Failed'` AND `Components_Analyzed__c > 0` AND `Result_File_Id__c` is null AND `Result_Save_Attempted__c = true`. (`Result_Save_Attempted__c` is set to `true` as the first operation in `ScanResultFileQueueable.execute()`, before any DML - this is the distinguishing signal. Without it, mid-traversal failures share the same detection condition and would incorrectly show the "Download Partial Results" button for incomplete data.) Error banner: "Scan analysis is complete but results could not be saved. Your data is available for export for [Retention_Hours__c] hours before it is automatically deleted." Show a conditional "Download Partial Results" button (CSV and JSON) visible only in this specific state. Partial exports use filename: `MetaMapper_[Target_API_Name]_PARTIAL_[YYYYMMDD]_[HHmm].csv` and `.json`. **Zero-node partial download:** If `getNodeHierarchy()` for a `Status__c = Failed` job with `Result_Save_Attempted__c = true` returns an empty node list, do NOT render the "Download Partial Results" button. Instead render: "Scan analysis completed but the results could not be recovered. The dependency data has been deleted. Start a new scan." The download button is only shown when at least one node is available. |
| `getNodeHierarchy()` loading | Skeleton loader (3 rows of shimmer) in the Tree tab while results load. In the Graph tab, render a `lightning-spinner` variant="brand" size="large" centered on the graph canvas area (not shimmer rows - a row-shimmer is semantically incorrect for a canvas). Do not show empty state during loading in either tab. |
| Job status = Paused | Warning banner (not error): "Scan paused - encountered a complex component." + "[Resume at a slower speed]" button (calls `resumeJob()` with half batch size) + "[Resume with current settings]" button (calls `resumeJob()` with current batch size). **Resume button loading state:** on click of either button, immediately disable both buttons and show a `lightning-spinner` size="small" inline next to the clicked button. Button label remains unchanged during loading - only the spinner appears. No label change. On `resumeJob()` success, the banner is replaced by the progress view and focus moves to the progress bar. On `resumeJob()` exception: (1) remove the spinner, (2) re-enable both buttons, (3) status label reverts to "Analysis paused - encountered a complex component.", (4) show toast: "Could not resume the scan. [error detail]". |
| Concurrency rejection | Persistent inline error banner below the submit button (not a toast - a transient toast auto-dismisses before the user can act): "A scan is already running in this org. [View the running scan]." `[View the running scan]` calls `getJobStatus()` on the first job with `Status__c IN ('Initializing', 'Processing')` returned by the server (the same query used by `DependencyJobController.countActiveJobRecords()`, or a dedicated lightweight selector method) and navigates to the progress view for that job. If no active job is found (race condition - it completed between button click and navigation), dismiss the banner and re-enable the Submit button. **Link loading state:** The "View the running scan" link transitions to disabled with an inline `lightning-spinner` size="x-small" on click. If `getJobStatus()` throws while loading, re-enable the link and show an inline error: "Could not load the running scan. Try again." If the call returns success with no active job, show toast: "The scan finished while this message was showing. You can start a new scan now." Banner dismisses only when the user clicks dismiss or navigates away. Re-enables the form so the user can try again once the running scan completes. |
| Storage rejection | Persistent inline error banner below the submit button: "Not enough data storage to start a new scan. Free up storage or go to MetaMapper Settings to shorten the retention window." Re-enables the form so the user can try again after taking action. |
| `getNodeHierarchy()` call failed | Full-page error state (replaces both Tree and Graph tabs): error banner with title "Results unavailable" and body "The dependency data could not be loaded. This may be a temporary issue." + "Retry" button that re-calls `getNodeHierarchy()`. If the job is Completed and `Result_File_Id__c` is set, also show "The result file may have been deleted" as secondary help text. Do not show an empty tree or blank graph - an empty view is indistinguishable from a zero-result scan. |

**Resume visual state machine (all intermediate states defined):**

| Phase | Button state | Status label |
|---|---|---|
| Paused, awaiting user action | Both buttons enabled | "Analysis paused - encountered a complex component." |
| Either resume button clicked; `resumeJob()` in flight | Both buttons disabled; clicked button shows `lightning-spinner` size="small" inline | "Resuming analysis..." |
| `resumeJob()` returned exception | Both buttons re-enabled immediately; toast error shown | "Analysis paused - encountered a complex component." |
| `resumeJob()` succeeded | Banner replaced by progress view; focus moves to progress bar | Progress status label |
| `resumeJob()` succeeded but `Status__c` does not leave `Paused` within 30 seconds | Both buttons re-enabled; persistent info banner: "Resume is taking longer than expected. The scan will continue when the current step finishes. Try resuming again if this persists." | "Analysis paused - encountered a complex component." |

After `resumeJob()` returns success, polling resumes at 5-second intervals (not 10 seconds) to catch the `Status__c = Processing` transition quickly. The 30-second timeout is reset on each poll that returns `Status__c = Paused` - confirming the job is still paused but the resume is in progress.

### Responsive Behavior

**Breakpoint definitions (inclusive boundaries):** `>= 1280px` = desktop full layout. `1024px - 1279px` = tablet landscape (inclusive on both ends). `< 1024px` = strictly less than 1024px (tablet portrait / mobile). `< 768px` = mobile-only layout for `metaMapperProgress` status label stacking. The 768px tier applies only to the progress bar component; all other components use the 1024px breakpoint as their mobile threshold. Use Salesforce responsive design tokens for all breakpoints - no hardcoded pixel widths.

**`metaMapperSearch` responsive:** at `< 768px`, stack all form fields vertically. The typeahead dropdown must be constrained to viewport width. Submit button is full width.

| Viewport | Behavior |
|---|---|
| >= 1280px (desktop) | Full layout: sidebar legend + graph canvas + filter panel all visible |
| 1024px - 1279px (tablet landscape) | **Sidebar legend:** collapses into a toggle button at the top-right of the graph toolbar (`lightning-button-icon icon-name="utility:rows" size="small" aria-label="Toggle legend"`). When toggled open, the legend slides out from the right edge as an overlay drawer (200px wide, semi-transparent backdrop rgba(0,0,0,0.3), z-index 1000) with a "Close" button in the header. Auto-closes on tab switch. **Filter panel:** moves to a collapsible drawer. **Node Details Panel:** remains as a right sidebar at 280px fixed width. **Panel/drawer precedence:** selecting a node ALWAYS opens the Node Details Panel and closes any open filter drawer (selection takes priority). Opening the filter drawer closes any open Node Details Panel; selection state is preserved but the panel does not re-open - the user must re-select the node to re-open it. Panel/drawer transitions use 150ms fade-out + 150ms fade-in. **Simultaneous-open handling:** all panel/drawer state changes are queued sequentially - if a node-click fires while a drawer close animation is in progress, the close animation completes first (300ms total), then the panel open begins. No concurrent animations. When the filter drawer is force-closed because a node is selected, focus moves to the Node Details Panel header. When the panel is closed, the filter drawer does not auto-reopen. **Animation queue cap:** The animation queue is capped at 1 pending operation (latest wins). If a second node-click arrives while a queued animation is pending, the first queued operation is discarded and replaced with the latest. This bounds maximum wait to 600ms regardless of click frequency. **Opacity continuity:** when an incoming animation begins before a prior animation has completed, start the new animation from the element's current computed opacity rather than resetting to 0. This prevents a visible flash when rapid clicks queue and discard animations. Read `getComputedStyle(el).opacity` at the moment the new animation starts and use that value as the CSS animation start point via a CSS custom property (`--anim-start-opacity`). While `isTransitioning === true`, the filter panel container shows `opacity: 0.5` and `pointer-events: none` via a CSS class `is-transitioning`. The `inert` attribute is set on the filter panel container during this window (removes the element and all its descendants from the accessibility tree and blocks keyboard interaction). Additionally set `aria-disabled="true"` on the container for browsers that do not yet support `inert`. Do NOT use `aria-busy="true"` - `aria-busy` signals content is updating in-place, not that interaction is blocked; it does not prevent screen readers from announcing or users from activating controls, which are both required here. |
| < 1024px (tablet portrait / mobile) | **Default landing view is Tree View.** Graph tab is present but shows "For best results, use a desktop browser" banner when selected. Graph is pan-only; node labels are truncated to 20 characters with "..." appended, and only the depth-0 (root) node and the currently selected node show a label. Node Details Panel becomes a full-screen modal with an explicit "Close" button in the header. **Mobile node selection:** On mobile Graph view (< 1024px), double-tap selects a node and opens the full-screen details modal. Single tap = pan/zoom only. This disambiguates selection from pan gestures. **Required CSS:** set `touch-action: manipulation` on the graph canvas wrapper element. Without this, the browser imposes a 300ms tap-delay before firing the `click` event (to distinguish single-tap from double-tap natively), which causes a noticeable lag on single-tap panning. `touch-action: manipulation` disables double-tap-to-zoom while preserving panning - the component then manages double-tap detection in JS via a timestamp delta (two taps within 300ms on the same node = double-tap select). On first mobile Graph render, show a one-time dismissible tooltip anchored to the center of the canvas: "Double-tap a node to view its details." Dismissed on first tap anywhere. State stored in `sessionStorage` key `metaMapper_mobileGraphTip_v1`. The panel's `isOpen` state is a computed property: `get isOpen() { return this.selectedNodeId !== null; }` - node selection in either Tree or Graph opens the full-screen modal panel on mobile. Switching to Tree View does NOT automatically close the panel (the `activeTab === 'graph'` gate is removed; the user must tap "Close"). Breadcrumb chains deeper than 10 levels stack vertically; levels beyond 10 are collapsed behind a "Show all [N] ancestors" expander. |

MetaMapper is a **desktop-first application**. The responsive behaviour on tablet and mobile is graceful degradation, not full feature parity. Do not invest implementation effort in making the graph fully interactive on mobile - Tree View is the intentional primary interface on small viewports. On viewports < 1024px, render the Tree View tab as the active default; the Graph tab remains accessible but is a secondary choice.

Use Salesforce responsive design tokens and the SLDS grid system. Do not hard-code pixel widths.

### Accessibility

- All color distinctions reinforced by SLDS icon + shape (not color alone)
- **Contrast Ratio Compliance Matrix (mandatory pre-implementation gate):** before any LWC implementation, populate a test matrix for every node type color using the tokens defined in the Node visual language table above. For each type: document the SLDS token name, hex value, contrast ratio on `#FFFFFF`, contrast ratio on `#1B1B1B`, and WCAG AA pass/fail at 4.5:1 (normal text) / 3:1 (large text and UI components). Required minimums: node label text on white `#FFFFFF` >= 4.5:1; node label text on SLDS dark `#1B1B1B` >= 4.5:1; confidence badge text on badge background >= 4.5:1; progress bar fill on track background >= 3:1; graph search highlight (`#FFB81C` border) on all node base colors >= 3:1. Store the completed matrix in `setup/CONTRAST_MATRIX.md`. Do not begin LWC implementation without a completed matrix. The node color tokens are defined in the Graph View section above - use those hex values as the input to the matrix.
- **Graph search highlight color:** matching nodes are highlighted via ECharts `emphasis.itemStyle.borderColor = '#FFB81C'` (SLDS warning yellow) with `borderWidth: 3`. Non-matching nodes remain at normal opacity. On mobile, `borderWidth: 2`.
- ARIA labels on all interactive graph elements; `role="tree"` on tree view; `role="treeitem"` on every rendered row; each row carries `aria-expanded` (true/false/undefined for leaf nodes) and `aria-level="[depth + 1]"` (ARIA `aria-level` is 1-indexed: root node = `aria-level="1"`, direct children = `aria-level="2"`, etc. `Dependency_Depth__c` is 0-indexed so the formula is `aria-level = Dependency_Depth__c + 1`)
- **Keyboard navigation (committed approach - virtual focus index):** Tab to focus graph container; arrow keys traverse nodes via a tracked `activeNodeIndex` JS property; the canvas renders a visible focus ring overlay on the active node; Enter selects the active node (opens Node Details Panel). This is the required approach for WCAG 2.1 SC 2.1.1 since ECharts renders to `<canvas>` with no native per-node DOM focus targets. Virtual focus index is the required implementation path. If, after documented technical investigation, the virtual focus index cannot be implemented due to ECharts API constraints, raise it as a blocking issue before shipping - do not ship without either virtual focus or explicit product sign-off documenting the accessibility trade-off. The banner fallback is not a shipping-acceptable substitute; it is an emergency disclosure only.
- Screen reader: every node badge includes `aria-label` in plain English that includes the confidence score where applicable (e.g. "Warning: low confidence supplemental match, 65% confidence")
- Color-blind safe: icon + border shape carry meaning independent of hue
- Dynamic content updates (progress counter, status label) use `aria-live="polite"` so screen readers announce changes without interrupting user input
- Graph interaction results (node highlight, focus path activation) announced via a dedicated `aria-live="polite"` region in the graph toolbar - e.g. "Focus path activated: 4 nodes highlighted" and "3 nodes match your search"
- Persistent banners (the long-running scan notice, the large graph performance warning) use `aria-live="assertive"` - these interrupt the screen reader because they signal a potential problem or require action. Modal dialogs (the "Expand All" large-graph guard, the Cancel confirmation) rely on focus management for screen reader announcement - do NOT add `aria-live="assertive"` to modal trigger elements, as focus movement into the modal already announces the dialog to the screen reader, causing a double-announcement.
- **ECharts Canvas accessibility:** ECharts renders to a Canvas element, which is invisible to assistive technology. Implement an off-screen ARIA summary table (visually hidden via `slds-assistive-text` class, `aria-hidden="false"`) that lists all nodes with their name, type, and flags (circular/dynamic/supplemental/low-confidence). Update this table whenever graph data changes, including when filters change. **Debounce ARIA table rebuilds by 400ms after any filter change** - use a single `setTimeout` that cancels and restarts on each input event. Set `aria-busy="true"` on the ARIA table container during the debounce window; set `aria-busy="false"` when the rebuild completes. Do not rebuild on every keystroke. The ARIA table must reflect only currently visible (non-filtered-out) nodes so screen readers and the visual graph stay in sync. The graph canvas wrapper `<div>` (the container element wrapping the `<canvas>`) must have `tabindex="0"` as a mandatory attribute - this makes it a valid programmatic focus target for spanning tree notice dismiss and other focus-return operations. Add `role="img"` and `aria-label="Dependency graph for [Target_API_Name__c]. Use Tree View tab for full keyboard access and screen reader support."` to the Canvas container element.
- **"Locating node..." ARIA:** the inline indicator shown when cross-view node selection triggers ancestor branch expansion (>200ms) must be wrapped in an element with `aria-live="polite"` so screen readers announce the expansion in progress. Clear the live region text once expansion completes.
- **Health check spinner:** add `aria-label="Checking MetaMapper connection..."` to the pre-flight `lightning-spinner`. An unlabeled spinner is invisible to screen readers.

### Results Screen - AI Summary Card

When `Status__c = Completed`, display a prominent card at the top of the Results screen (above both tabs):

| Element | Detail |
|---|---|
| Card title | "Scan Summary" |
| Body | `Scan_Summary_Text__c` rendered as plain text - no markdown processing. Line breaks preserved as `<br>`. Text is user-selectable. Framework auto-escapes HTML characters (`<`, `>`, `&`, quotes) - no manual escaping required. |
| "Copy" button | Copies `Scan_Summary_Text__c` to clipboard. On click success: (1) copy text to clipboard, (2) button label changes to "Copied!" with `utility:check` icon, (3) after 2 seconds reverts to "Copy". No toast notification needed on success - the inline label change is the confirmation signal. On clipboard write failure (e.g. browser permission denied): button label reverts to "Copy" immediately and a toast error is shown: "Could not copy to clipboard. Your browser may require clipboard permission. Select the text manually instead." **Unified copy-success pattern:** All copy operations (AI Summary "Copy" button AND Node Details Panel "Copy Link" button) use the same pattern: (1) inline label change to "Copied!" with `utility:check` icon, (2) visually-hidden `<span aria-live="polite" class="slds-assistive-text">` sibling receives the text "Copied to clipboard." and is cleared after 2 seconds, (3) label reverts after 2 seconds. Do NOT update the button's `aria-label` attribute on success - this causes double-announcement in NVDA/JAWS. |
| "Ask Copilot" button | Opens Einstein Copilot with `Scan_Summary_Text__c` pre-populated. Conditionally rendered: shown only if Copilot is enabled in the org. **Detection:** call `DependencyJobController.isCopilotEnabled()` (new `@AuraEnabled(cacheable=true)` method, implementation: `return FeatureManagement.checkPermission('Einstein_Copilot');`) on component mount; cache the result for the component lifetime so it is fetched once. If false, render helper text: "Einstein Copilot not available in this org." in place of the button (do not hide silently). **On exception from `isCopilotEnabled()`:** suppress the button silently - do not render the helper text, do not surface the error to the user. Log to browser console only. |
| Card height | Compact by default - collapsed height shows the first 300 characters of `Scan_Summary_Text__c`, truncated at the nearest word boundary, followed by an ellipsis. If the full text is 300 characters or fewer, show it in full with no ellipsis or toggle. Full text revealed by a "Show more" inline toggle. Prevents the card from pushing Tree/Graph tabs below the fold on smaller laptops. |

The card is not shown for Failed, Cancelled, or Paused jobs. For Paused jobs, a warning banner replaces it.

**Stats tile:** Rendered above the Tree/Graph tab container, below the AI Summary Card, inside a single SLDS card. Displays type counts from `Component_Type_Counts__c`. Layout: 2-column grid on desktop (>= 1024px), 1-column on tablet/mobile (< 1024px). Each metadata type is one cell: icon + type name + count. Sorted by count descending. Types with a count of zero are omitted. Unknown types (not in the graph legend) are omitted silently. If `Status__c = Completed` AND `Component_Type_Counts__c` is null (race condition - job just transitioned to Completed but `ScanResultFileQueueable` hasn't populated the field yet), render the stats tile as a shimmer skeleton matching the 2-column grid dimensions. The shimmer clears on the same polling cycle that populates `Scan_Summary_Text__c`. "No type counts available." is shown only when `Status__c` is NOT `Completed` (e.g. Failed, Cancelled). If all types have zero count (a completed scan with literally no dependencies found), omit the stats tile entirely and render the zero-result empty state: "No dependencies found. This metadata type may not have trackable dependencies." Example cell: `[utility:flow] Flows (3)`. **Confidence threshold filter:** applies to both Tree View and Graph View (shared state). Filter rule: if `Supplemental_Confidence__c != null` AND `Supplemental_Confidence__c < threshold`, hide the node in both views. Stats tile counts update **synchronously** on every filter change - no debounce, no re-query. Counts are derived from the same filtered node array used to drive the tree and graph. If a type is entirely filtered out, its cell is omitted from the tile.

**Responsive behavior at < 1024px:** the card renders below the stats tile and above the tabs, with no "Show more / collapse" toggle - show the first 200 characters of `Scan_Summary_Text__c` truncated at the nearest word boundary, followed by a "Show more" tap target (minimum 44px touch target height). On expand: full text revealed. On collapse: return to 200-char view. The "Ask Copilot" button is hidden on viewports < 1024px (rendered only at >= 1024px).

**Null state (loading):** `Status__c` transitions to `Completed` before `ScanSummaryQueueable` has run. The card must handle a null `Scan_Summary_Text__c`: show a skeleton shimmer in place of the body text. Poll `getJobStatus()` every 5 seconds while `Scan_Summary_Text__c` is null. Do not render an empty card or suppress the card entirely - the shimmer communicates "generating summary" without confusing the user. Polling stops and the shimmer is replaced with the text once the field is populated. **Shimmer timeout:** if `Scan_Summary_Text__c` is still null after 6 consecutive polls (30 seconds at 5-second intervals), stop polling and replace the shimmer with: "Summary could not be generated. [Dismiss]" Do not re-show the shimmer after dismiss. After the user dismisses the "Summary could not be generated" message, collapse the AI Summary card container entirely (`display: none` or remove from DOM). The stats tile moves up to fill the vacated space. Do not leave a visible empty card shell.

### Export Hierarchy

**Primary exports (prominent placement):**
- "Download as CSV" - flat row-per-node, for analysis in Excel / Sheets. Default filename: `MetaMapper_[Target_API_Name]_[YYYYMMDD]_[HHmm].csv`. **Filename sanitization:** replace all `.`, `/`, and `\` in `Target_API_Name__c` with `_` before building the filename (e.g. `Account.Phone__c` â†’ `MetaMapper_Account_Phone__c_20260602_1430.csv`).
- "Download Complete Hierarchy (for developers)" - nested tree with all `Dependency_Context__c` pills. Tooltip: "Contains all dependency data including context fields. Useful for scripting, auditing, or custom tooling." Default filename: `MetaMapper_[Target_API_Name]_[YYYYMMDD]_[HHmm].json`

**Advanced exports (collapsible "Advanced" section):**
- "Download Deployment Manifest" - package.xml, developer artifact; tooltip: "Use this to deploy or retrieve the components found in this scan using Salesforce CLI or VS Code. Includes only components from this scan. Namespace-prefixed components (managed package members) are excluded automatically."

**Export button states:** All export buttons are disabled while `getNodeHierarchy()` is loading (nodes prop is null or empty). Buttons re-enable as soon as the node list is available - do NOT wait for the graph or tree to finish rendering. If a client-side export fails at runtime (e.g. `Blob` creation throws on an unusually large result set), show a toast: "Export failed. Try filtering to fewer nodes first, or use JSON instead of CSV for large result sets." Do NOT disable all export buttons after a single-format failure - if CSV fails, JSON or package.xml may still succeed.

### Settings UI (CMDT labels)

When surfacing `MetaMapper_Settings__mdt` fields in any admin UI, use human-readable labels:

| Field API name | UI label | Help text |
|---|---|---|
| `Retention_Hours__c` | "Keep failed/cancelled jobs for (hours)" | "Failed and cancelled scan records older than this are automatically deleted. Does not affect completed scans - those are managed by the 'Keep last N completed scans' setting. Minimum 1 hour. Recommended: 72+ hours for diagnostic use." |
| `Scan_Batch_Size__c` | "Analysis speed (Standard)" | "How many metadata components to analyze per processing step. Lower this if you see timeout errors." |
| `Flow_Scan_Batch_Size__c` | "Analysis speed (Flow jobs)" | "Batch size when 'Only analyze active Flow versions' is enabled. Each Flow node requires one extra validation callout - 15 Flow nodes = 15 extra callouts. Lower this if you see 'Too many callouts' errors on Flow-heavy orgs. Default: 15." |
| `Dml_Safety_Margin_Rows__c` | "Safety margin (DML rows)" | "Advanced: number of database rows to reserve as a safety buffer. Increase for orgs with very connected metadata." |
| `Disable_Platform_Events__c` | "Disable live progress updates" | "Turn on if your org is hitting real-time event limits. Progress will refresh every few seconds instead." |
| `Stall_Pause_Threshold__c` | "Pause after N empty processing cycles" | "If the analysis runs this many cycles without finding new components, it pauses and alerts you." |
| `Max_Concurrent_Jobs__c` | "Max concurrent scans" | "How many MetaMapper scans can run at the same time. Default 2. Raise only for orgs with large async capacity." |
| `Cleanup_Chunk_Size__c` | "Deletion batch size (Advanced)" | "Records deleted per database transaction during cleanup. Default 2,000. Lower this value if you see 'Too many DML statements' errors from other automation during cleanup." |
| `Max_Stored_Jobs__c` | "Keep last N completed scans" | "How many completed scan results to keep as files in your org. When the limit is reached, the oldest result is deleted automatically. Completed scans use File Storage (not Data Storage). Default 5." |
| `Max_Components__c` | "Maximum components per scan" | "The scan pauses automatically when this many components are found. Default 5,000. Do not raise above 5,000 without testing - the result serializer may hit memory limits on large scans with deeply nested metadata. Set to 0 to disable (not recommended)." |
| `Min_Free_Storage_MB__c` | "Minimum free storage required (MB)" | "MetaMapper checks that your org has at least this much free data storage before starting a new scan. Increase this value if you see storage-related errors during active scans. Default 50MB." |
| `Custom_Settings_Saved__c` | "Custom Settings Saved" | Not surfaced in Settings UI - set automatically by the save action. |

**Admin-only controls (Settings UI):**
- "Reset First-Time Tour" button: clears the `metaMapper_tourSeen_v1` localStorage flag for the current browser session. Useful for admins demoing the tour to new team members. Implemented as a client-side JS action - no Apex required.

---

## Query Strategy

### IN Clause Chunking
Start with batches of **100 IDs** as a safe default, but split is driven by **estimated query character length**, not a fixed count. The Tooling API REST endpoint embeds SOQL in the URL - URI length depends on the IDs themselves, encoding, and the surrounding SOQL string. If estimated URL length exceeds 8KB, halve the batch before sending. 100 IDs is the starting estimate; the dynamic check is authoritative.

**Actual implementation constants:** `URL_OVERHEAD = 350` (covers ~220 chars static SOQL text + ~80 chars Named Credential path + URL encoding inflation), `ID_CHAR_COST = 21` (1 open-quote + 18-char ID + 1 close-quote + 1 comma), `URL_BUDGET = 8000`. Check: `if (URL_OVERHEAD + (ids.size() * ID_CHAR_COST) > URL_BUDGET) { halve batch recursively; }`. At these constants, maximum safe batch size is `(8000 - 350) / 21 = 364 IDs`. These constants are more conservative than the minimum-formula estimates to avoid relying on reactive 414 retries under normal conditions.

### QueryMore
Tooling API results exceeding 2,000 rows return a `nextRecordsUrl`. `MetadataDependencyService` must follow `nextRecordsUrl` iteratively until `done = true` before returning results to the Queueable. Each follow-up counts against the callout budget.

**Cursor expiration risk:** Tooling API query cursors typically expire after ~15 minutes. If a complex node causes the Queueable to self-chain and the chained job waits in the Salesforce Flex Queue during high org utilization, the cursor may expire before the next execution resumes QueryMore. `MetadataDependencyService` handles `INVALID_QUERY_LOCATOR` (HTTP 400 with that error code) in `followQueryMore()` by setting `opts.queryMoreFailed = true` and logging a diagnostic notice to `Scan_Diagnostic_Log__c`: "QueryMore cursor expired. Batch will be re-queried on next execution." Setting `queryMoreFailed = true` prevents `DependencyQueueable` Step 15 from marking the parent as fully fetched, so the parent stays with `Dependencies_Fetched__c = false` and is re-queried from scratch on the next Queueable execution. This is functionally equivalent to a restart: the parent re-enters the unprocessed queue and a fresh Tooling API query is issued. The upsert on `Unique_Component_Key__c` deduplicates any nodes that were partially inserted before the cursor expired.

**QueryMore callout budget guard:** Before each `nextRecordsUrl` callout inside the QueryMore loop, check remaining callout headroom: `if (Limits.getLimitCallouts() - Limits.getCallouts() < headroom)`. If insufficient: commit partial results gathered so far (mark processed nodes with `Dependencies_Fetched__c = true`), leave remaining node IDs from the current batch with `Dependencies_Fetched__c = false` so the next execution re-queries them, and break out of the QueryMore loop to trigger self-chain. The cursor restart (INVALID_QUERY_LOCATOR recovery) handles the re-query cleanly on the next execution without losing data.

### Reactive HTTP 414 Handling
If a callout returns HTTP 414 or 431, split the current batch in half and retry both halves. Do not fail the job on this error.

**Depth limit (critical):** The split-and-retry must track recursion depth. Use `Integer splitDepth` passed as a parameter through each retry. Maximum depth: **5 levels** (1 â†’ 2 â†’ 4 â†’ 8 â†’ 16 â†’ 32 batches). At depth 5, if the batch still returns 414: log to `Scan_Diagnostic_Log__c` ("Component [IDs] returned HTTP 414 after 5 split attempts; skipping this batch. Possible cause: metadata IDs contain non-standard characters."), mark affected nodes as `Dependencies_Fetched__c = true`, and continue. Do NOT fail the job. Without this depth limit, a "poison" component with extremely large IN-clause encoding will recursively consume all callout budget in a single execution.

### Limit Guardrails (Remaining-Budget Model)

**Placement: the guardrail runs in two places - not just at the end of the execution:**
1. **Pre-batch check** - before starting the Tooling API callout for the current node batch.
2. **Mid-loop check (per node)** - inside the result-processing loop, before adding newly discovered children to the insert list. A single high-fan-out node (e.g. a core Custom Object) can return 4,000+ dependencies in one callout; the post-loop check would be too late.

```
// --- Callout budget (remaining-headroom model) ---
Integer calloutsRemaining = Limits.getLimitCallouts() - Limits.getCallouts();
// Headroom needed per remaining batch:
// +1 dependency query
// +1 if QueryMore may be needed (determined by Last_Query_Row_Count__c from prior execution: true if >= 1,900)
// +1 per Flow node in current batch if Active_Flows_Only__c = true (1 validation callout per Flow node)
// +7 buffer for reactive 414/431 retry splits (covers 2 full split levels: 1+2+4=7 callouts).
// Note: depth-5 splits are theoretically possible (up to 63 callouts) but require a "poison" component
// with extremely large IN-clause encoding on every retry. The +7 headroom covers common cases.
// For pathological components, the depth-5 guard in the 414 handler (mark nodes Dependencies_Fetched__c = true
// and continue) is the safety net when callout budget is exhausted before depth 5.
// queryMorePossible = (job.Last_Query_Row_Count__c != null && job.Last_Query_Row_Count__c >= 1900)
// needsFlowValidation = Active_Flows_Only__c AND current batch contains Flow nodes (count, not boolean - 1 callout per node)
Integer headroom = 1 + (queryMorePossible ? 1 : 0) + flowNodeCount + 7 + 1; // +1 for potential 5xx single retry in MetadataDependencyService

// --- DML row budget ---
// Reserve Dml_Safety_Margin_Rows__c rows (default 750) from MetaMapper_Settings__mdt.
// Conservative: a single high-fan-out node can return 2,000+ children.
Integer dmlReserve = (Integer) settings.Dml_Safety_Margin_Rows__c; // read from CMDT, default 750
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
// 40 = worst-case 5 supplemental handlers Ã— ~8 statements each. Reserve of 10 is insufficient.
Integer dmlStmtsRemaining = Limits.getLimitDmlStatements() - Limits.getDmlStatements();

if (calloutsRemaining < headroom
    || dmlRemaining < dmlReserve          // dmlReserve from MetaMapper_Settings__mdt, default 750
    || heapPct >= 0.70                    // 0.70 not 0.80 - async heap calculations lag; 0.80 leaves insufficient margin when parsing large nested JSON from Tooling API
    || cpuPct >= 0.75
    || queryRowsRemaining < 1000
    || queriesRemaining < 10
    || dmlStmtsRemaining < 40) {          // 40 not 10 - supplemental handlers can consume 8+ DML statements each
    System.enqueueJob(new DependencyQueueable(jobId, activeFlowsOnly, overrideBatchSize)); // preserve active batch size override across guardrail chains
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
| Workflow Field Updates â†’ Custom Field | `CustomFieldDependencyHandler` | Query `WorkflowFieldUpdate` WHERE `Field = :apiName` |
| Validation Rule formulas | `CustomFieldDependencyHandler` | Query `ValidationRule` bodies, regex match field API name |
| FlexiPage visibility rules | `CustomFieldDependencyHandler` | Query `FlexiPage` metadata, parse XML for field references |
| Custom Metadata Type record lookups | `CustomFieldDependencyHandler` / `ApexClassDependencyHandler` | SOQL on CMT records, filter fields named `class`, `handler`, `type` |
| Lookup field relationships | `CustomFieldDependencyHandler` | Query `CustomField` WHERE `ReferenceTo = :objectName` |
| Dynamic Apex string references | `ApexClassDependencyHandler` | Flag `Is_Dynamic_Reference__c = true`; cannot be statically resolved |

---

## Export Formats

| Format | Structure |
|---|---|
| CSV | Flat: `Level, Metadata_Type, Metadata_Name, Metadata_ID, Parent_Name, Is_Circular, Is_Dynamic` |
| JSON | Nested tree mirroring `Metadata_Dependency__c` hierarchy with `Dependency_Context__c` pills included |
| package.xml | Valid Salesforce deployment manifest grouped by `<types>`. Excludes managed package components. **Namespace detection rule:** a component is excluded if its `Metadata_Name__c` matches the pattern `^[A-Za-z][A-Za-z0-9]+__` - i.e., a namespace prefix (letters and digits only, no underscores) followed by a double underscore. For `CustomField` (API name format `Object.Field` or `Object__c.Field__c`), apply the check to the field portion only - the segment after the last dot. Components with a namespace prefix (e.g. `myns__MyClass`, `myns__My_Field__c`) are excluded; customer custom components (e.g. `My_Custom_Field__c`, `MyClass`) are included. The previous pattern `^[A-Za-z]\w+__\w` was incorrect - `\w+` allows underscores in the "namespace" segment, causing all custom components (which contain `__c` or `__mdt`) to be flagged as managed and excluded from the manifest. **Test cases for namespace detection (include in export unit tests):** `myns__MyClass` â†’ excluded (namespace `myns`); `My_Custom_Field__c` â†’ included (no namespace, `__c` is Salesforce convention not a namespace separator); `My__Test__c` â†’ included (inner double-underscore without a leading namespace prefix); `_myns__Test` â†’ included (leading underscore is not a valid namespace character); `a__MyClass` â†’ excluded (single-character namespace `a` is valid per Salesforce rules). |

---

## Source API Version

`66.0` (configured in `sfdx-project.json`). Use this version for all Tooling API endpoint paths. Minimum supported: v49.0 (when `MetadataComponentDependency` became reliable).

---

## Runtime Configuration (MetaMapper_Settings__mdt)

All tunable runtime parameters are stored in `MetaMapper_Settings__mdt` Custom Metadata (single record `Default`). `DependencyQueueable` and `DependencyCleanupBatch` read this record at the start of each execution.

| Field | Type | Default | Notes |
|---|---|---|---|
| `Retention_Hours__c` | Number | 72 | Hours before job hard-delete. Min 1, recommended â‰¥72 for diagnostic use. |
| `Scan_Batch_Size__c` | Number | 50 | Unprocessed nodes queried per Queueable execution (non-Flow jobs). Tune down for high-DML orgs. |
| `Flow_Scan_Batch_Size__c` | Number | 15 | Batch size when `Active_Flows_Only__c = true`. **Flow validation is 1 callout per Flow node** (not 1 per batch) - each Flow node requires a separate Tooling API callout to validate its version status. A batch of 15 Flow nodes consumes 15 validation callouts. The headroom formula accounts for `flowNodeCount` (the number of Flow nodes in the current batch result), not a single boolean flag. Default lowered from 30 to 15 to stay within callout budget for orgs with dense Flow dependencies. |
| `Dml_Safety_Margin_Rows__c` | Number | 750 | DML rows to reserve in the guardrail before chaining. Raise for orgs with high-fan-out metadata (e.g. heavily referenced CustomObjects). |
| `Disable_Platform_Events__c` | Checkbox | false | When true, suppresses `Dependency_Scan_Status__e` publish and falls back to polling via `getJobStatus()`. Use when org is approaching the daily Platform Event delivery limit. |
| `Stall_Pause_Threshold__c` | Number | 5 | Number of consecutive re-chains with zero `Components_Analyzed__c` progress before the engine pauses the job and surfaces a warning to the UI. |
| `Max_Concurrent_Jobs__c` | Number | 2 | Maximum number of simultaneously active MetaMapper Queueables. `createJob()` rejects new submissions above this threshold with a user-facing message. Raise for orgs with large flex queue allocations. |
| `Cleanup_Chunk_Size__c` | Number | 2000 | DML chunk size for `DependencyCleanupBatch` node deletion. Default 2,000 (leaves 8,000 DML rows for customer automation). Do not raise above 4,000 for open-source deployments into unknown orgs. |
| `Max_Components__c` | Number | 5000 | Hard cap on `Components_Analyzed__c` per job. When reached, the engine pauses the job and surfaces a warning. Default 5,000 (safe for Developer Sandbox data storage during active scan). **Serializer ceiling:** `ScanResultFileQueueable` serializes all nodes in a single heap-bound JSON operation. At ~2KB per node, the 12MB async heap supports approximately 5,000-6,000 nodes. Raising `Max_Components__c` beyond this ceiling without redesigning the serializer for chunked streaming will cause the "results too large" failure path. Set to 0 to disable the cap (not recommended without a chunked serializer). |
| `Min_Free_Storage_MB__c` | Number | 50 | Minimum free data storage in MB required before `createJob()` accepts a new scan. Checked via `OrgLimits` on submission. Applies to the transient peak - during an active scan nodes live in Data Storage before serialization to File Storage on Completed. Default 50MB ensures sufficient headroom during the scan peak. |
| `Max_Stored_Jobs__c` | Number | 5 | Maximum number of completed scan results retained org-wide as Salesforce Files. When a new job completes and this limit is reached, the oldest completed job (and its result file) is deleted automatically. This bounds File Storage consumption regardless of how many scans are run. Default 5 (keeps ~5-15MB of file storage). Raise to 10-20 for production orgs or teams needing longer result history. |
| `Custom_Settings_Saved__c` | Checkbox | false | Set to true when an admin explicitly saves the Settings UI. Used by `createJob()` to decide whether to apply sandbox/production default profiles. When false (first-install state), profile overrides apply at runtime without mutating the CMDT record. |

> Hard-coding batch size and DML reserve is inappropriate for an enterprise tool. A highly-connected org may need `Flow_Scan_Batch_Size__c = 15` and `Dml_Safety_Margin_Rows__c = 1500`. Admins tune without a code deploy.

### Sandbox vs. Production Defaults

MetaMapper is designed to run in both Developer Sandboxes and production orgs. Developer Sandboxes have a hard 200MB data storage limit - a single large uncapped scan can exhaust the entire allocation. `createJob()` detects the org type via `[SELECT IsSandbox FROM Organization]` and applies a conservative profile automatically if no admin has customized the settings:

| Setting | Developer Sandbox default | Production default | Reason |
|---|---|---|---|
| `Retention_Hours__c` | 1 | 72 | Failed/Cancelled jobs with partial nodes still consume Data Storage; shorter retention limits the window of exposure. |
| `Max_Concurrent_Jobs__c` | 1 | 2 | Concurrent active scans can simultaneously peak Data Storage; serializing one at a time keeps peak bounded. |
| `Max_Components__c` | 5,000 | 5,000 | Bounded by `ScanResultFileQueueable` heap capacity. Practical safe ceiling is ~2,000-3,000 nodes for deep/complex metadata trees. Do not raise above 5,000 without testing serializer heap consumption - the serializer will hit the heap failure path at high node counts with deep Ancestor_Path__c values. A chunked serializer is required before this ceiling can be safely raised. |
| `Min_Free_Storage_MB__c` | 50 | 200 | Ensures sufficient free Data Storage for the scan peak before committing to a new job. |
| `Max_Stored_Jobs__c` | 5 | 10 | Bounds File Storage consumption. Both sandbox and production have 200MB file storage; sandboxes typically have less available headroom. |

These are applied only when the CMDT record has never been saved with explicit values (i.e. first-install defaults). Once an admin saves the CMDT record, their explicit values take precedence.

---

## Failure Handling Pattern (DependencyQueueable)

An uncaught exception in `execute()` rolls back the entire Queueable transaction - including any DML that set `Status__c = 'Failed'`. The failure status update must therefore be structured so it survives the rollback.

**Required pattern - Savepoint + explicit catch:**

```
public void execute(QueueableContext ctx) {
    Savepoint sp = null;
    // Capture callout count BEFORE the savepoint. checkAndSuppressIfNeeded() and the
    // Initializing→Processing DML run before the savepoint so they are never rolled back.
    // The delta check (Limits.getCallouts() == calloutsAtSavepoint) is the authoritative
    // rollback guard: Limits.getCallouts() == 0 is incorrect because pre-savepoint
    // callouts from checkAndSuppressIfNeeded() leave the counter non-zero even when no
    // engine callout has fired.
    Integer calloutsAtSavepoint = 0;
    try {
        // Pre-savepoint work: PE limit check + Initializing→Processing transition
        calloutsAtSavepoint = Limits.getCallouts();
        sp = Database.setSavepoint();
        // ... all engine work ...
    } catch (Exception e) {
        // Only roll back if no callout fired after the savepoint.
        if (sp != null && Limits.getCallouts() == calloutsAtSavepoint) {
            Database.rollback(sp);
        }
        // Status update is now a fresh DML outside the failed transaction scope
        updateJobFailed(jobId, e.getMessage() + '\n' + e.getStackTraceString());
    }
}
```

`updateJobFailed()` must be a private method that:
1. **Checks `Status__c NOT IN ('Completed', 'Cancelled', 'Failed')` before updating** - `Paused` is intentionally NOT in this list: a Paused job that throws during a resume attempt must transition to Failed with full error detail, not remain stuck in Paused permanently. This prevents a losing race from overwriting a Completed or Cancelled status with Failed.
   3a. Uses `FOR UPDATE` when querying the job record to prevent concurrent failure handler races - via `DependencyJobSelector.getForFailedUpdateLocked()`.
2. Updates `Metadata_Scan_Job__c.Status__c = 'Failed'`, sets `Scan_Diagnostic_Log__c` to `e.getMessage() + '\n' + e.getStackTraceString()`, and sets `Status_Closed_At__c`.
3. Publishes a `Dependency_Scan_Status__e` failure event. **The `EventBus.publish()` call inside `updateJobFailed()` must be wrapped in its own narrow try-catch that swallows EventBus-specific exceptions:** `try { EventBus.publish(...); } catch (Exception peEx) { /* PE publish failed; job status DML already committed - do not rethrow */ }`. If the PE publish itself throws and is not caught here, the exception propagates out of the outer catch block with no further handler, rolling back the `updateJobFailed()` DML and leaving the job stuck in Processing permanently.
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
| `Target_Parent_Object__c` | The API name of the parent object, required when Target_Metadata_Type__c is CustomField. Used to scope the Tooling API query to a specific object. Optional for all other metadata types. |
| `Active_Flows_Only__c` | When checked, inactive Flow versions are excluded from scan results. Reduces scan scope and processing time. Default: true. Unchecking this includes deprecated Flow versions and may significantly increase scan duration. |
| `Status__c` | Current state of the scan. Initializing = being set up. Processing = scan running. Completed = scan finished successfully. Failed = unrecoverable error. Cancelled = stopped by user. Paused = engine detected a stall and stopped automatically. Do not manually set this field. |
| `Scan_Diagnostic_Log__c` | Multi-purpose engine log: full exception stack trace on failure, plus diagnostic notices (e.g. Platform Event suppression warnings, cursor restart notices, 5xx retry attempts). Visible to admins via the scan results screen error detail expander. Populated by the scan engine only. |
| `Components_Analyzed__c` | Running count of metadata components discovered so far. Updated after each processing cycle. Used to drive the progress bar in the UI. Do not edit manually. |
| `Component_Type_Counts__c` | JSON object mapping each metadata type to the count of components found (e.g. {"ApexClass": 5, "Flow": 3}). Populated only when Status = Completed. Used to build the stats tile and plain-English summary. Do not edit manually. |
| `Status_Closed_At__c` | Timestamp set the moment Status transitions to Completed, Failed, or Cancelled. Used by the cleanup batch to calculate retention age. Never set for jobs that are still running. The cleanup batch uses this field, not CreatedDate, to avoid deleting in-progress scans. Do not edit manually. |
| `Processing_Cycle_Count__c` | Number of times the async engine has processed a batch for this scan. Incremented on every execution. Compared against `Last_Progress_Cycle__c` to detect stall loops. Do not edit manually. |
| `Last_Progress_Cycle__c` | The value of `Processing_Cycle_Count__c` at the last execution that made progress (`Components_Analyzed__c` increased). Reset when new components are found. If the gap between `Processing_Cycle_Count__c` and this field reaches `Stall_Pause_Threshold__c`, the scan is automatically paused. Do not edit manually. |
| `Scan_Summary_Text__c` | Plain-English summary of scan results, generated after the scan completes (e.g. "This scan found 42 dependencies: 5 Apex classes, 3 active Flows"). Displayed in the Scan Summary card. Populated asynchronously by a background process after Status = Completed - it may appear a few seconds after the scan finishes. |
| `Result_File_Id__c` | Lookup to the ContentDocument (Salesforce File) that stores the complete scan result as JSON. Populated after the scan completes and all dependency records have been serialized and deleted. The app reads this file to display results for completed jobs instead of querying individual dependency records. Null for active, failed, or cancelled scans. Populated via the Apex requery path only (`[SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id]`). Do not edit manually. |
| `Batch_Size_Override__c` | Batch size override. Set by `resumeJob()` when the user resumes at a slower speed. The engine reads this at startup and uses it instead of CMDT batch size if non-null. Persists for the job lifetime; does not write back to CMDT (CMDT is org-wide, this is job-specific). Set to null to return to standard batch size. Do not edit manually during an active scan. |
| `Last_Query_Row_Count__c` | Number of rows returned by the most recent Tooling API callout. Updated after each callout. Used by the guardrail to determine whether QueryMore is likely on the next batch (threshold: >= 1,900 rows). Initialized to 0 on job creation. Do not edit manually. |
| `Result_Save_Attempted__c` | Set to true at the start of `ScanResultFileQueueable.execute()`, committed before `Database.setSavepoint()` so a rollback cannot revert this flag. Allows the app to distinguish a serializer failure (traversal completed but saving failed) from a mid-traversal engine failure. When true and Result_File_Id__c is null and Status is Failed, the app surfaces a "Download Partial Results" option. Do not edit manually. |

### Metadata_Dependency__c Fields

| Field | Description |
|---|---|
| `Metadata_Scan_Job__c` | Reference to the parent scan job. All dependency records for a scan are deleted when the job is deleted. Required. |
| `Parent_Dependency__c` | Reference to the parent dependency in the spanning tree. Null for the root component (the scan target itself). Used to reconstruct the dependency tree in the UI. |
| `Metadata_Id__c` | The 18-character Salesforce record ID of the metadata component as returned by the Tooling API. Used as the unique identifier for deduplication and cycle detection. Do not edit manually. |
| `Metadata_Type__c` | The type of the metadata component (e.g. ApexClass, Flow, CustomField). Used for color-coding in the graph, type filtering in the tree, and routing to supplemental query handlers. |
| `Metadata_Name__c` | The human-readable API name of the metadata component (e.g. AccountTrigger, My_Custom_Field__c). Displayed as the node label in the tree and graph views. |
| `Dependency_Depth__c` | How many levels deep this component is from the scan target. 0 = the scan target itself. 1 = direct dependency. Used for depth filtering in the UI. |
| `Dependencies_Fetched__c` | Internal engine flag. False = this component's child dependencies have not yet been fetched from the Tooling API. True = fetching complete, or intentionally skipped (circular, dynamic reference, or max ancestor depth exceeded). The engine's `nextUnprocessed()` query filters on this field to find pending work. Do not edit manually. |
| `Is_Circular__c` | True if this component appears in its own ancestor chain (a real dependency cycle, e.g. A depends on B which depends on A). Displayed with a dashed border in the graph. The scan does not traverse further from circular nodes to prevent infinite loops. |
| `Is_Dynamic_Reference__c` | True if this dependency was detected as a dynamic Apex string reference that cannot be statically resolved. Displayed with a warning badge. These nodes represent potential dependencies that require manual investigation. |
| `Dependency_Context__c` | Type-specific contextual JSON: key-value pairs describing the dependency's role (e.g. `isWrite`, `activeVersions`, `cycleClosesAt`). Rendered as plain-English badges in the UI. Never displayed as raw JSON. Schema versioned via root `'v'` key. |
| `Discovery_Source__c` | How this dependency was discovered. ToolingAPI = found by the standard MetadataComponentDependency query. Supplemental = found by a secondary handler query that fills a known Tooling API gap. Supplemental results carry a confidence score. |
| `Ancestor_Path__c` | Pipe-delimited chain of Metadata_Id__c values from the root component down to this node's parent (e.g. "id1|id2|id3"). Used to detect true ancestry cycles. Preserved on circular nodes for debugging and export. Do not edit manually. |
| `Supplemental_Confidence__c` | Confidence score (0-100) for supplemental dependencies only. Reflects how certain the match is: exact field matches score 95, regex formula matches score 65. Nodes below 70 display a warning badge prompting manual verification. Null for Tooling API nodes. |
| `Unique_Component_Key__c` | Composite deduplication key in the format "JobId:Metadata_Id__c". Used as an External ID for upsert operations to prevent duplicate nodes when multiple async cycles discover the same component simultaneously. The value is generated by the engine from the job ID and metadata component ID. Do not edit manually. |
| `Ancestor_Id_Shortkeys__c` | Internal engine field storing a pipe-delimited set of 6-character tails (last 6 chars via `.right(6)`) of each ancestor `Metadata_Id__c` value. Uses the auto-number suffix portion of the 18-char ID, which is unique per component. Used as a fast pre-screen index: before performing the full delimiter-safe `Ancestor_Path__c` containment check, the engine checks whether the new node's 6-char tail appears in this index. If no match, skip the expensive full-string check. If a match is found, confirm conclusively against `Ancestor_Path__c`. Long Text 32768 required (7 chars per entry; 1,500-depth tree = ~10,500 chars). Do NOT re-query for multi-generation propagation - pass the in-memory map forward. Do not edit manually. |

### Apex Classes

| Class | Description |
|---|---|
| `DependencyJobController` | `@AuraEnabled` controller for all LWC interactions with scan jobs. Invoked by `metaMapperApp`, `metaMapperSearch`, and `metaMapperProgress`. Enforces FLS and CRUD via USER_MODE. Delegates all business logic to services - no SOQL or DML directly. Must NOT be called from async contexts (Batch, Future, Queueable). Exposes: `createJob()`, `getJobStatus()` (response wrapper includes `batchSizeInUse: Integer` - equal to `Batch_Size_Override__c` if non-null, else the CMDT `Scan_Batch_Size__c` value - and `peSuppressionActive: Boolean`), `getNodeHierarchy()`, `cancelJob()`, `resumeJob()`, `getObjectList()`, `getComponentCount()`, `isCopilotEnabled()`. |
| `MetadataDependencyService` | Executes Tooling API callouts to fetch `MetadataComponentDependency` records. Invoked by `DependencyQueueable` on each execution. Handles IN-clause chunking, QueryMore pagination, Active Flows version filtering, cursor expiry restart, and HTTP 414/431 reactive splits. Must NOT make callouts outside of async context. Heap pre-check rule: check raw HTTP response body length before `JSON.deserializeUntyped()`. |
| `DependencyQueueable` | Async scan engine. Self-chains to traverse the metadata dependency graph. Enqueued by `DependencyJobController.createJob()` initially; self-enqueues via `System.enqueueJob()` for continuation. Must NOT transition Status to Completed (that belongs to `ScanResultFileQueueable`). Must NOT upsert nodes per-record inside the result-processing loop (bulkify to a List). Checks Status on entry for cancellation; uses Savepoint/rollback pattern for failure isolation. |
| `ScanResultFileQueueable` | One-shot Queueable that serializes completed scan results to a Salesforce File and transitions the job to Completed. Enqueued only by the final `DependencyQueueable` execution. Uses Savepoint/rollback pattern - failure transitions job to Failed (terminal, not retryable). Must NOT be enqueued more than once per job. Performs heap-check before serialization; enforces ring buffer; enqueues `ScanSummaryQueueable` as the final step after all DML commits. **Single-enqueue constraint (non-negotiable):** `execute()` must contain exactly one `System.enqueueJob()` call (ScanSummaryQueueable) and exactly one `Database.executeBatch()` call (MetadataDependencyDeletionBatch). Adding any further async calls will exceed the Queueable child limit and throw `System.LimitException`. |
| `DependencyNotificationService` | Publishes `Dependency_Scan_Status__e` Platform Events and sends completion notifications. Invoked by `DependencyQueueable` once per execution. Must NOT publish inside a try-catch that swallows exceptions. Must NOT enqueue `ScanSummaryQueueable` (that is `ScanResultFileQueueable`'s responsibility). Auto-suppresses PE publish when org daily limit >80% consumed and flips the CMDT flag via `Metadata.Operations.enqueueDeployment()`. |
| `ScanSummaryQueueable` | Lightweight one-shot Queueable that generates the plain-English `Scan_Summary_Text__c` from `Component_Type_Counts__c`. Enqueued only by `ScanResultFileQueueable` after the Completed transition. Must check `Status__c = 'Completed'` as its first operation and exit immediately if not - protects against running on a job whose serializer rolled back. No callouts; one DML statement (job update). |
| `DependencyCleanupBatch` | Nightly cleanup batch that discovers expired Failed and Cancelled jobs and fires `MetadataDependencyDeletionBatch` to remove them. Scheduled at 02:00 by `DependencyCleanupScheduler`. Must implement `Database.Stateful` to accumulate job IDs across execute() chunks. Must NOT delete Completed, Processing, Initializing, or Paused jobs. Must NOT perform DML in execute() - accumulate IDs only. Maximum 5 `MetadataDependencyDeletionBatch` submissions per finish() call (Salesforce platform limit is 5 `Database.executeBatch()` calls per transaction). |
| `MetadataDependencyDeletionBatch` | Deletes `Metadata_Dependency__c` records in safe chunks (default 2,000) and optionally deletes the parent job. Invoked by `DependencyCleanupBatch` (NODES_AND_JOB mode) and `ScanResultFileQueueable` (NODES_ONLY mode). Must NOT use inner loops within execute() - one chunk per transaction only. Constructor accepts `CleanupMode` enum (NODES_ONLY or NODES_AND_JOB) to prevent boolean argument-swap bugs. |
| `DependencyCleanupScheduler` | Schedules `DependencyCleanupBatch` to run at 02:00 daily via the Salesforce scheduler. Implements `Schedulable`. Called once during post-install setup. If the scheduled job is lost (e.g. after a sandbox refresh), re-schedule via anonymous Apex: `System.schedule('MetaMapper Nightly Cleanup', '0 0 2 * * ?', new DependencyCleanupScheduler());` |
| `ToolingApiHealthCheck` | Setup-only class that verifies Tooling API reachability via Named Credential. Called by `metaMapperApp` on mount via `@AuraEnabled`. Must check the calling user's MetaMapper permission before making any callout (unauthorized users must not trigger Named Credential network calls). Returns one of five codes: `AUTHORIZED`, `UNAUTHORIZED` (HTTP 401 - Named Credential not set up), `PERMISSION_SET_MISSING` (custom permission `MetaMapper_Application_Access` not assigned to calling user - check fires before any callout), `CALLOUT_FORBIDDEN` (HTTP 403 from Tooling API - Connected App OAuth scopes misconfigured), `UNREACHABLE` (HTTP 5xx), `TIMEOUT` (`CalloutException` with read timeout). Must NOT be called by the scan engine. |

### LWC Components

| Component | Description |
|---|---|
| `metaMapperApp` | Root shell component. Owns `jobId` state and switches between input, progress, and results views. Calls `ToolingApiHealthCheck.verify()` and `getJobStatus()`. Owns the `empApi` subscription for `Dependency_Scan_Status__e` and distributes events to children via `scanstatuschange` custom events. Handles deep-link routing via `@wire(CurrentPageReference)`. |
| `metaMapperSearch` | Input form for starting a new scan. Calls `DependencyJobController.createJob()` and `getObjectList()`. No event subscriptions. Fires `jobcreated` event to `metaMapperApp` on successful job creation. |
| `metaMapperProgress` | Progress screen. Calls `DependencyJobController.getJobStatus()` (polling fallback) and `cancelJob()` and `resumeJob()`. Receives `Dependency_Scan_Status__e` payloads via `scanstatuschange` custom events from `metaMapperApp` (does not subscribe to `empApi` directly). Fires `jobcomplete`, `jobcancelled`, and `jobpaused` events to `metaMapperApp`. |
| `metaMapperResults` | Tab container and shared state owner for Tree and Graph views. Calls `DependencyJobController.getNodeHierarchy()`. Owns filter state (shared with child tabs), selection state (transient), and `isTransitioning` flag. Hosts `metaMapperComponentDetailsPanel`, `metaMapperExport`, and the AI Summary card. After `isTransitioning` clears (either via `tabready` event or the 3-second hard timeout), issue a single `getJobStatus()` reconciliation call to catch any `Dependency_Scan_Status__e` Platform Events that were discarded during the transition. This is a one-time reconciliation, not a polling loop. Only applies when PE is active (not suppressed). |
| `metaMapperTree` | Virtual-rendered SLDS tree for browsing dependencies. Receives node list as a prop from `metaMapperResults`. No direct Apex calls. Fires `nodeselected` and `tabready` events. **ARIA requirements:** `role='tree'` on the container; `role='treeitem'` on every rendered row; each row must carry `aria-expanded` (true/false/undefined for leaf nodes) and `aria-level='[depth]'`. |
| `metaMapperGraph` | ECharts force-directed graph. Receives node list as a prop. No direct Apex calls. Fires `nodeselected` and `tabready` events. Loads ECharts from the `ECharts` Static Resource (no CDN). |
| `metaMapperComponentDetailsPanel` | Sidebar/modal panel showing full details of the selected node. Receives selected node data and the full node map (for breadcrumb ID-to-name resolution) as props. No direct Apex calls. Fires `panelclosed` event. |
| `metaMapperExport` | Export controls for CSV, JSON, and package.xml. Receives node list and job metadata as props. No direct Apex calls; all export logic runs client-side. |

### Permission Set - MetaMapper_Admin

| Component | Description |
|---|---|
| `MetaMapper_Admin` | Grants full access to MetaMapper. Assign to admins and developers who need to run dependency scans. Provides CRUD on Metadata_Scan_Job__c and Metadata_Dependency__c, access to the MetaMapper LWC and Apex controller, and Named Credential principal access required for Tooling API callouts. Must be assigned before a user can access or operate MetaMapper. Does not grant access to broader org data beyond what the user's existing profile already permits. Also grants the Custom Permission `MetaMapper_Application_Access` which is checked by `ToolingApiHealthCheck` before any callout. This Custom Permission must be explicitly listed in the permission set metadata XML. |

### Platform Event - Dependency_Scan_Status__e

> **Description:** Published once per async engine execution to report scan progress to subscribed LWC components. Carries current scan status, component count, and a progress label. Subscribe only from MetaMapper LWC components. Do not delete - active scans depend on this event for real-time progress updates. When suppressed due to org PE limits, the engine automatically falls back to polling.

| Field | Description |
|---|---|
| `Scan_Job_Id__c` | ID of the Metadata_Scan_Job__c record this event relates to. Used by the progress LWC to filter events for the current scan. |
| `Status__c` | Current scan status at the time this event was published. Mirrors the Status__c values on Metadata_Scan_Job__c. |
| `Components_Analyzed__c` | Number of components analyzed at the time this event was published. Used to update the progress bar without a server round-trip. |
| `Progress_Message__c` | Human-readable description of what the scan engine was doing when this event was published (e.g. "Analyzing Flow dependencies..."). Displayed below the progress bar. |

### MetaMapper_Settings__mdt Fields

> **Object description:** Stores all tunable runtime parameters for MetaMapper. The engine reads the single record named `Default` at the start of every scan submission and every async processing cycle. Modify this record to tune analysis speed, storage limits, cleanup behavior, and concurrency without a code deploy. Do not delete the `Default` record.

| Field | Description |
|---|---|
| `Scan_Batch_Size__c` | Number of unprocessed dependency records fetched and analyzed per scan processing cycle (non-Flow scans). Lower this value if scans pause due to complexity or if you see governor limit errors. Default: 50. |
| `Max_Components__c` | Maximum number of dependency records this scan is allowed to create. When reached, the scan pauses automatically and prompts the user to raise the limit or accept partial results. Default: 5,000. Set to 0 to disable the cap (not recommended - the serializer will fail at high node counts). Do not raise above 5,000 without validating serializer heap capacity for your org's typical metadata depth. |
| `Min_Free_Storage_MB__c` | Minimum free data storage in megabytes required before a new scan is accepted. Checked at scan submission using org storage limits. If free storage is below this value, the scan is rejected with a clear message. Default: 50MB. Lower this value only if you are certain the org has sufficient storage headroom. |
| `Flow_Scan_Batch_Size__c` | Batch size used specifically for scans where Active Flows Only is enabled. Lower than the standard setting because each Flow requires an additional Tooling API callout to validate version status. Default: 15. |
| `Dml_Safety_Margin_Rows__c` | Number of DML rows the engine reserves as a safety margin before chaining to the next processing cycle. Increase this value for orgs with highly connected metadata where a single component can have thousands of dependencies. Default: 750. |
| `Disable_Platform_Events__c` | When enabled, suppresses real-time progress events and the UI falls back to polling every few seconds. Use this if your org is approaching its daily Platform Event delivery limit. Can also be set automatically by the engine if the limit is exceeded. Default: false. |
| `Stall_Pause_Threshold__c` | Number of consecutive processing cycles with zero new components before the engine pauses the scan and alerts the user. Prevents infinite loops caused by pathological metadata structures. Default: 5. |
| `Max_Concurrent_Jobs__c` | Maximum number of MetaMapper scans that can run simultaneously in this org. New scan requests are rejected when this limit is reached. Raise this value only for orgs with large async processing capacity. Default: 2. |
| `Cleanup_Chunk_Size__c` | Number of dependency records deleted per database transaction during the nightly cleanup process. Keep at 2,000 or lower to leave sufficient database operation headroom for other automation in your org. Default: 2,000. |
| `Retention_Hours__c` | How many hours to keep Failed and Cancelled scan records (and any partial node records they contain) before automatic deletion. Completed scan results are retained by the ring buffer (Max_Stored_Jobs__c) and are not subject to this time limit. Default: 72. |
| `Max_Stored_Jobs__c` | Maximum number of completed scan results retained as Salesforce Files. When a scan completes and this limit is exceeded, the oldest completed job and its result file are deleted automatically. Completed results use File Storage, not Data Storage. Default: 5 (sandbox), 10 (production). |

---

## Known Limitations

- **Spanning tree model (by design):** MetaMapper models the dependency graph as a spanning tree. Each `Metadata_Dependency__c` stores one `Parent_Dependency__c` (the first-discovered path). A node reachable via multiple paths (diamond dependency: Aâ†’C and Bâ†’C) is inserted once - subsequent arrivals at the same `Metadata_Id__c` are deduplicated. This is an intentional tradeoff: full DAG representation would require a junction object (significantly higher DML cost and storage). The spanning tree view correctly shows all reachable dependencies; it does not show all dependency paths. Document this explicitly in `setup/SETUP.md` so users understand results are complete but path-unique.
- `MetadataComponentDependency` does not capture all dependency types. Supplemental handlers fill 5 known static gaps. **Dynamic Apex string references are a permanent blind spot** - they cannot be resolved by any supplemental query and are flagged with `Is_Dynamic_Reference__c = true` in the UI. This is not a gap to be closed; it is an inherent Salesforce platform limitation.
- Supplemental handler matches (ValidationRule regex, FlexiPage XML parsing) are best-effort. Results may include false positives. Confidence scoring is deterministic per handler: WorkflowFieldUpdate exact match = 95, ValidationRule regex = 65, FlexiPage XML parse = 60, CMT field lookup = 85, Lookup relationship = 95. Nodes with `Supplemental_Confidence__c < 70` display a warning badge - treat as leads, not confirmed dependencies.
- `DependencyCleanupBatch` must delete child `Metadata_Dependency__c` records in chunks before deleting parent jobs. Implicit Master-Detail cascade counts against the 10,000 DML row limit; a job with 15,000 nodes would exceed it on a single parent delete.
- Named Credential requires one-time admin authorization post-install and cannot be scripted or source-tracked.
- `Active Flows Only` mode excludes inactive Flow versions by design to preserve heap and reduce DML.
- package.xml export excludes managed package components (namespace-prefixed) by default.
- Cancellation is cooperative. A Queueable already in the flex queue will check `Status__c` on entry and exit cleanly - it cannot be force-killed immediately.
- `createJob()` must be called from a synchronous Lightning context only. Invocation from Batch, Future, or Queueable contexts is blocked by an async-context guard. See `setup/SETUP.md` for integration constraints.
- Concurrent scans are limited by `Max_Concurrent_Jobs__c` (default 2). A new job submission is rejected if the active Queueable count is at the limit. This is a deliberate safety constraint, not a bug.
- `Ancestor_Id_Shortkeys__c` tail shortcut has a negligible probability of false-positive cycle detection (6-char tail collision); the full `Ancestor_Path__c` delimiter-safe containment check is always used to confirm before setting `Is_Circular__c = true`.
- `Scan_Summary_Text__c` is populated only on job Completed. Failed, Cancelled, and Paused jobs do not have an AI summary. Agentforce Actions should check `Status__c = 'Completed'` before reading this field.
- **Storage model and sandbox safety:** MetaMapper uses a hybrid model - `Metadata_Dependency__c` records exist only during the active scan (engine state), then are serialized to a Salesforce File (`ContentVersion`) and deleted when the job completes. Data Storage impact for a completed job is ~5KB (job record only). File Storage impact is ~1-3MB per completed job. A ring buffer of `Max_Stored_Jobs__c` completed results bounds total file storage consumption to ~5-15MB. **During an active scan, nodes do temporarily occupy Data Storage** - a 5,000-node scan (the sandbox default cap) consumes ~25MB of Data Storage at peak. Developer Sandbox has 200MB of both Data Storage and File Storage. Conservative sandbox defaults (`Max_Components__c = 5,000`, `Min_Free_Storage_MB__c = 50`) ensure the transient peak stays within safe limits even when the sandbox is already partially used. Failed and Cancelled jobs may retain partial node records until the nightly cleanup batch removes them; `Retention_Hours__c = 1` in sandboxes limits this window.
- **Result serialization is terminal on failure:** if `ScanResultFileQueueable` fails (e.g. heap limit during serialization), the job transitions to `Failed` and cannot be resumed. The admin must start a new scan. Node records **may** remain in the org and are available for export until the nightly cleanup batch removes them (`Retention_Hours__c`) - but only if the failure occurred before the bulk-delete step (step 5). If failure occurs during or after node deletion, records are partially or fully gone. The UI surfaces the export option in this state; the LWC detects it via `Status__c = 'Failed'` AND `Components_Analyzed__c > 0` AND `Result_File_Id__c` is null AND `Result_Save_Attempted__c = true`.
- **Depth-limited preview mode not yet implemented:** users who only need immediate parent/child context can workaround by scanning a direct field reference rather than the full object. A formal depth-cap option (limiting traversal to `Dependency_Depth__c <= 2`) is deferred to a future release.
- **`DependencyCleanupBatch` backlog notice is best-effort:** when more than 5 expired jobs accumulate in a single nightly run, `DependencyCleanupBatch.finish()` submits the first 5 `MetadataDependencyDeletionBatch` instances and logs an overflow notice to `Scan_Diagnostic_Log__c` on the oldest remaining expired job. The notice text "Cleanup backlog: [N] additional expired jobs will be processed in subsequent nightly runs." is written via a best-effort DML update inside `finish()`. If that update fails (e.g. the job record was concurrently deleted), the notice is silently lost - the backlog itself is harmless (subsequent nightly runs clear it), but admins lose the diagnostic signal. This is an accepted trade-off for the rare-case overflow path.
- **`Processing_Cycle_Count__c` counter is not atomic:** the read-then-increment pattern means two Queueable instances running simultaneously for the same job (theoretically possible during a resume after a flex queue delay) could both read the same counter value and write `N+1` instead of `N+1` and `N+2`. Stall detection may be delayed by at most one cycle per race event. This is acceptable for an admin tool - the detection will trigger on the next execution if the stall persists. Node deduplication via `Unique_Component_Key__c` External ID upsert prevents duplicate data from concurrent execution.

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
