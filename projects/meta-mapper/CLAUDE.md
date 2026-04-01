# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Implementation Gate (Non-Negotiable)

**Do not write, generate, or modify any code or metadata files until the user explicitly says to proceed.**

This applies to every phase and every artifact - Apex classes, LWC components, object metadata, static resources, test classes, config files, and any other deployable file. Design discussions, plan updates, and CLAUDE.md edits are permitted. Code is not.

---

## Project Overview

MetaMapper is an open-source, 100% native Salesforce application that visualizes deep metadata dependencies using the Tooling API. It targets enterprise/LDV orgs where synchronous Governor Limits are a hard constraint. All runtime data stays within the Salesforce trust boundary - no external APIs, no CDN calls.

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

1. User submits a search via the LWC - an `@AuraEnabled` controller creates a `Dependency_Job__c` record and inserts the root `Dependency_Node__c`, then enqueues `DependencyQueueable`.
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
`SELECT Metadata_ID__c FROM Dependency_Node__c WHERE Dependency_Job__c = :jobId AND Metadata_ID__c IN :currentResultIds`
Rows returned = number of already-inserted matches within `currentResultIds` (bounded by the result set size, not by the IN list size). This avoids the full-table scan that would occur when querying all previously inserted nodes. If a result is already in this set, **skip insertion entirely** (deduplication). Do NOT mark as circular.

> **Why not query all nodes upfront?** At 10k-20k nodes a full-scan query consumes a large portion of the 6MB async heap before any Tooling API work begins. Scoping to `currentResultIds` limits the dedup query to matches within the current callout's result set only.

**Tier 2 - True ancestry cycle detection (`Path__c`):**
Each `Dependency_Node__c` stores a pipe-delimited `Path__c` field: the chain of ancestor `Metadata_ID__c` values from root to this node.

- **Root node:** `Path__c = ''` (empty string, not null). This ensures the first child path is built as `'' + '|' + rootId = '|rootId'`, which is handled by trimming the leading pipe, OR by initializing root as `Path__c = rootId` and children as `parentPath + '|' + parentId`.
- **Correct path-building:** `child.Path__c = (String.isBlank(parent.Path__c) ? '' : parent.Path__c + '|') + parent.Metadata_ID__c`. This avoids a leading delimiter on first-level children.
- **Cycle check:** if `parent.Path__c` contains the new node's `Metadata_ID__c`, it is a true ancestry cycle (A→B→A pattern).
- **Circular node path:** Keep the **full `Path__c`** on circular nodes - do NOT set to null. The path is most valuable precisely when a cycle is found (debugging, export). Mark `Is_Circular__c = true`, `Is_Processed__c = true`. Append the cycle-closing segment to `Context_Data__c` as `{"cycleClosesAt": "<parentMetadataId>"}` for UI visualization.
- **CPU consideration:** `String.contains()` on a long Path__c string inside an inner loop is CPU-intensive for deep trees. Check `Limits.getCpuTime()` against the guardrail threshold **inside the node-processing loop**, not only at the batch boundary.

> **Path__c capacity:** At 18 chars/ID + 1 delimiter, a depth-1,500 path would be ~28,500 chars - within the Long Text 32768 limit. Deeper trees are unrealistic in practice.

### Cancellation

`DependencyQueueable` checks `Status__c` as the first operation in `execute()`. If `Status__c = 'Cancelled'`, it exits immediately without enqueuing a successor. The `cancelJob(String jobId)` `@AuraEnabled` method in `DependencyJobController` sets `Status__c = 'Cancelled'` (WITH USER_MODE). The LWC Cancel button calls this method. Queueables that are already enqueued will check on entry and terminate cooperatively - there is no force-kill mechanism in Salesforce.

### Async Context Guard

`createJob()` in `DependencyJobController` must only be invoked from a synchronous Lightning context (LWC `@AuraEnabled` call). If called from an already-async context (e.g., a Copilot Action, a Batch finish handler), `System.enqueueJob()` inside a Queueable that is itself inside a Queueable will exceed Salesforce's nested async restrictions in certain governor contexts.

Guard: `DependencyJobController.createJob()` should validate `!System.isQueueable() && !System.isBatch() && !System.isFuture()` and throw a descriptive exception if called from an unsupported async context. Document this constraint in `setup/SETUP.md`.

### Live Progress (Platform Events)

`DependencyQueueable` publishes **exactly one** `Dependency_Status__e` event per Queueable execution - after the final DML commit of that execution, not after each inner batch loop iteration. The `metaMapperProgress` LWC subscribes via `lightning/empApi` on mount and unsubscribes on destroy - no polling. Do not publish events inside a try-catch that swallows the exception.

> **Why one event per execution?** Salesforce enforces a daily org-wide Platform Event delivery limit (50,000 for Standard Volume). At 50 nodes per Queueable execution, a 10,000-node job generates ~200 executions = ~200 events - well within limits. Publishing per inner batch loop (e.g., once per IN-chunk callout) would multiply this by 5-10x and could exhaust the org's daily allocation during concurrent admin scans.

### Graph Visualization

`metaMapperGraph` loads Apache ECharts from the `ECharts` Static Resource (no CDN). It receives a flat `Dependency_Node__c` list and builds the ECharts `graph` series client-side, using `Parent_Node__c` to derive edge links. Node color is keyed to `Metadata_Type__c`.

> **Static Resource build**: use `echarts/dist/echarts.min.js` (core minified build, ~1.0-1.2MB) sourced from the npm package. Do **not** use the full bundle - it includes maps and 3D features and risks exceeding Salesforce's 5MB static resource hard limit.

### Security Model

- OWD: `Dependency_Job__c` = Private (users see only their own jobs)
- All Apex DML/SOQL uses `WITH USER_MODE` or `AccessLevel.USER_MODE` - FLS and CRUD enforced at runtime
- Permission Set `MetaMapper_Admin` grants CRUD on both custom objects, Named Credential principal access, and LWC/controller access

### Data Lifecycle

`DependencyCleanupBatch` runs nightly at 02:00 via `DependencyCleanupScheduler`. It hard-deletes closed jobs older than `MetaMapper_Settings__mdt.Retention_Hours__c`.

**Lifecycle rule (critical):**
- Only delete jobs where `Status__c IN ('Completed', 'Failed', 'Cancelled')` AND `Closed_At__c < :DateTime.now().addHours(-retentionHours)`. Never delete `Initializing` or `Processing` jobs - a long-running in-progress scan must not be destroyed by the cleanup window.
- `Closed_At__c` (DateTime field on `Dependency_Job__c`) is stamped by the Queueable engine the moment a job transitions to Completed, Failed, or Cancelled. Using `CreatedDate` would incorrectly target long-running jobs still in progress.

**Cascade delete DML trap (critical):**
Master-Detail cascade deletion counts child record deletes against the 10,000 DML row limit of the batch `execute()` transaction. A job with 15,000 nodes would cause `System.LimitException: Too many DML rows` on the first delete call.

Fix: `DependencyCleanupBatch` must explicitly delete child `Dependency_Node__c` records in chunks **before** deleting the parent `Dependency_Job__c`. The batch scope is per Job record; for each Job in scope, query and delete its nodes in chunks of 9,000 rows (safe headroom below 10,001), then delete the parent.

```
// In execute(Database.BatchableContext ctx, List<Dependency_Job__c> scope):
for (Dependency_Job__c job : scope) {
    List<Dependency_Node__c> nodes = [
        SELECT Id FROM Dependency_Node__c
        WHERE Dependency_Job__c = :job.Id
        LIMIT 9000
    ];
    while (!nodes.isEmpty()) {
        delete nodes;
        nodes = [SELECT Id FROM Dependency_Node__c WHERE Dependency_Job__c = :job.Id LIMIT 9000];
    }
    delete job;
}
```

> Batch size for `DependencyCleanupBatch` should be set to 1 (one Job per execute() call) to guarantee that the full node-deletion loop completes within one transaction's DML budget.

---

## Data Model

### Dependency_Job__c
| Field | Type | Notes |
|---|---|---|
| `Target_Metadata_Type__c` | Picklist | CustomField, ValidationRule, Flow, ApexClass, ApexTrigger, WorkflowRule, etc. |
| `Target_API_Name__c` | Text 255 | Developer Name of the target metadata |
| `Target_Object__c` | Text 255 | Optional - populated by typeahead for field-scoped searches |
| `Active_Flows_Only__c` | Checkbox | Default true - drops inactive Flow versions |
| `Status__c` | Picklist | Initializing, Processing, Completed, Failed, **Cancelled** |
| `Error_Message__c` | Long Text 32768 | Full exception on failure |
| `Nodes_Processed__c` | Number | Running counter for progress bar |
| `Summary_JSON__c` | Long Text 32768 | JSON map of `{MetadataType: count}` - populated on Completed |
| `Closed_At__c` | DateTime | Stamped when Status transitions to Completed, Failed, or Cancelled. Cleanup batch uses this field - never CreatedDate - to avoid deleting in-progress jobs. |
| `Rechain_Count__c` | Number | Incremented each time the Queueable self-chains. If this value increases by N (configurable in CMDT) without a corresponding increase in `Nodes_Processed__c`, the engine is hot-looping on a pathological node and pauses with a user-facing warning. |

> **Visited_IDs__c removed.** A Long Text 131072 field caps at ~5,957 IDs (22 chars/ID with JSON formatting). Enterprise orgs can easily exceed this, causing `StringException` and crashing the Queueable chain. Cycle detection is instead performed via two-tier logic (see Cycle Detection below).

### Dependency_Node__c
| Field | Type | Notes |
|---|---|---|
| `Dependency_Job__c` | Master-Detail | Cascade delete |
| `Parent_Node__c` | Lookup (self) | Builds hierarchical tree |
| `Metadata_ID__c` | Text 18 | Exact 18-char Tooling API ID |
| `Metadata_Type__c` | Text 50 | e.g. ApexClass, CustomField, Flow |
| `Metadata_Name__c` | Text 255 | Human-readable API name |
| `Level__c` | Number | Depth from root (0 = root target) |
| `Is_Processed__c` | Checkbox | Engine flag: false = pending child traversal |
| `Is_Circular__c` | Checkbox | True only when this node's `Metadata_ID__c` appears in its own `Path__c` (true ancestry cycle) |
| `Is_Dynamic_Reference__c` | Checkbox | True if reference cannot be statically analyzed (e.g. dynamic Apex string) - flagged in UI |
| `Context_Data__c` | Long Text 32768 | JSON "pills" - contextual metadata per type (see below) |
| `Source__c` | Picklist | `ToolingAPI` or `Supplemental` - tracks how the node was discovered |
| `Path__c` | Long Text 32768 | Pipe-delimited ancestor `Metadata_ID__c` chain from root to this node - used for true cycle detection |
| `Supplemental_Confidence__c` | Number (3,0) | 0-100 confidence score for supplemental nodes only. Regex/XML matches are inherently fuzzy; score reflects match certainty. Nodes below 70 display a warning badge in the UI. Null for ToolingAPI nodes. |
| `Node_Unique_Key__c` | Text 40 (External ID, Unique) | Composite key: `JobId + ':' + Metadata_ID__c`. Used for upsert to prevent duplicate nodes from race conditions in concurrent Queueable chains. |
| `Ancestors_Hash__c` | Text 255 | Concatenated 6-char base64url hashes of ancestor `Metadata_ID__c` values. Used as a bloom-filter shortcut for cycle detection before invoking `String.contains()` on the full `Path__c`. Reduces CPU on deep trees. If hash check finds a suspected cycle, validate conclusively against `Path__c`. |

### Context_Data__c (Pills) by Metadata Type
| Type | JSON shape |
|---|---|
| ApexClass / ApexTrigger | `{"isWrite": true}` - whether the class writes to the target field/object |
| Flow | `{"activeVersions": 3, "isActive": true}` |
| WorkflowRule | `{"isActive": true, "triggerType": "onInsertOrUpdate"}` |
| CustomField | `{"parentObject": "Account", "parentType": "CustomObject"}` |
| Report | `{"filterUsage": ["filter", "grouping", "column"]}` |

---

## Key Apex Classes

**Interfaces (Dependency Injection / testability):**

| Interface | Contract |
|---|---|
| `IDependencyService` | `fetchDependencies(List<String> ids, DependencyOptions opts)`, `buildContextData(Dependency_Node__c node)`, `computeScore(String handlerType, String matchBasis)` |
| `IDependencyTypeHandler` | `List<Dependency_Node__c> findSupplemental(Id jobId, List<Dependency_Node__c> nodes)` |
| `INotificationService` | `publishProgress(String jobId, String status, Integer count, String msg)`, `sendCompletion(String jobId, String userId)` |
| `ISettingsProvider` | `MetaMapper_Settings__mdt getSettings()` - read once per execution, cached per-transaction |

**Selectors (all SOQL centralized here):**

| Selector | Key Methods |
|---|---|
| `DependencyJobSelector` | `getByIdForEngine(String jobId)` - minimal fields for engine; `getClosedJobsBefore(DateTime threshold)` - for cleanup |
| `DependencyNodeSelector` | `nextUnprocessed(String jobId, Integer lim)` - ordered fetch; `dedupForResults(String jobId, Set<String> ids)` - scoped dedup query; `listByJob(String jobId)` - for export |

**Classes:**

| Class | Role |
|---|---|
| `DependencyJobController` | `@AuraEnabled` (USER_MODE): `createJob()` with async guard + preflight check, `getObjectList()`, `getJobStatus()`, `getNodeHierarchy()`, `cancelJob()`. Delegates to services - no SOQL/DML directly. |
| `DependencyService` (implements `IDependencyService`) | Tooling API SOQL formatting, character-budget chunking, QueryMore, Active Flows filter, `buildContextData()`, `computeScore()` |
| `DependencyTypeHandlerFactory` | `IDependencyTypeHandler getHandler(String metadataType)` - returns correct handler or no-op default |
| `CustomFieldHandler` | Supplemental: WorkflowFieldUpdate (95), ValidationRule regex (65), FlexiPage XML (60), CMT lookups (85), Lookup relationships (95) |
| `ApexClassHandler` | Supplemental: CMT references (85); flags `Is_Dynamic_Reference__c` |
| `FlowHandler` | Supplemental: QuickActionDefinition, subflows, WebLink URLs |
| `DependencyQueueable` | Async engine. Constructor: `DependencyQueueable(String jobId, Boolean activeFlowsOnly)`. Savepoint/catch; cancel check; CMDT read via `ISettingsProvider`; hot-loop detection; pre-batch + mid-loop seven-limit guardrail; scoped dedup + upsert by `Node_Unique_Key__c`; two-tier cycle detection; callouts; handlers; one PE event per execution (suppressed if `Disable_PE__c`); self-chain. |
| `DependencyNotificationService` (implements `INotificationService`) | `publishProgress()` - one event per execution; `sendCompletionNotification()` |
| `DependencyCleanupBatch` | Scope = 1. Explicit node chunk-delete before parent. Filter: `Closed_At__c` + closed statuses. |
| `DependencyCleanupScheduler` | Schedules cleanup at 02:00 |
| `NamedCredentialHealthCheck` | Setup-only Apex class: verifies Tooling API reachability via Named Credential. Called by pre-flight LWC check on page load. |

### Type Handler Pattern
Every `IDependencyTypeHandler` implementation follows the same contract:
- Receives the current batch of `Dependency_Node__c` records of its type
- Executes supplemental queries (Tooling API, SOQL, Metadata API) to find dependencies **not** returned by `MetadataComponentDependency`
- Returns additional `Dependency_Node__c` records to be inserted with `Source__c = 'Supplemental'`
- Sets `Is_Dynamic_Reference__c = true` on nodes that cannot be statically resolved

---

## Hot-Loop Backoff Detection

If `DependencyQueueable` self-chains repeatedly without processing any new nodes (e.g. a single pathological node saturates every guardrail before children can be inserted), the engine must detect and break the loop.

**Detection logic:**
- On each self-chain, increment `Rechain_Count__c` on the Job and compare `Nodes_Processed__c` to the previous value stored in a transient variable.
- If `Rechain_Count__c` increases by `Hotloop_Threshold__c` (default 5) without any change in `Nodes_Processed__c`, transition Job to `Status__c = 'Paused'` (new status value), set `Error_Message__c` with diagnostic context, and publish a `Dependency_Status__e` warning event.
- The LWC surfaces this as a user-visible warning: "The scan paused because it encountered a highly complex component. Review the error details and retry with a smaller batch size."

> `Status__c` gains a `Paused` value. `DependencyJobController` exposes a `resumeJob(String jobId)` method that re-enqueues with `Rechain_Count__c` reset, after admin lowers `Batch_Size__c` in CMDT.

---

## Key LWC Components

| Component | Role |
|---|---|
| `metaMapperApp` | Root shell; owns `jobId` state; switches between input, progress, and results views. Runs pre-flight Named Credential health check on mount; shows setup error state if check fails. |
| `metaMapperInput` | Metadata type picklist, API name text input, typeahead object lookup (debounced 300ms, queries `EntityDefinition`), "Active Flows Only" checkbox with tooltip explanation. Shows estimated node complexity preview when available. Validates required fields before enabling submit. |
| `metaMapperProgress` | `lightning-progress-bar` + human-readable status label ("Analyzing metadata...", "Paused - limit reached", "Cancelling..."). Subscribes to `Dependency_Status__e` via `lightning/empApi`; falls back to `getJobStatus()` polling if `Disable_PE__c = true`. Displays elapsed time. Cancel button transitions to disabled "Cancelling..." spinner on click; shows confirmation modal before cancelling. |
| `metaMapperResults` | Tab container: "Tree View" and "Graph View" sharing filter state. Stats tile (type counts from `Summary_JSON__c`). Hosts export controls with primary (CSV/JSON) and advanced (package.xml) tiers. |
| `metaMapperTree` | Virtual-rendered SLDS tree with search, type filter, level filter, and confidence filter. Supports collapse/expand per branch. Keyboard navigable. |
| `metaMapperGraph` | ECharts force-directed graph. Node click: opens component in Salesforce Setup. Right-click: "Copy API Name". Hover: tooltip with `Context_Data__c` pills in plain English. "Expand All" guard: shows modal warning if node count > 1,000. Persistent sidebar legend (always visible). "Focus path to root" breadcrumb. Type filter + level slider. |
| `metaMapperExport` | Primary export: CSV and JSON (analysis outputs). Advanced export (collapsible): package.xml (developer artifact). No server round-trip. |

---

## UX Design Specification

### Pre-Flight Check
On `metaMapperApp` mount, call `NamedCredentialHealthCheck.verify()` via `@AuraEnabled`. If the Named Credential is not authenticated or unreachable:
- Block the input form entirely
- Show a friendly empty state: "MetaMapper needs one-time setup. Follow the setup guide to authorize the Tooling API connection." with a direct link to `setup/SETUP.md`
- Do not allow job submission until the check passes

### Input Screen (`metaMapperInput`)

| Element | Behavior |
|---|---|
| Metadata Type picklist | Required; shows supported types only |
| API Name input | Required; inline validation on blur |
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
| Paused | "Analysis paused - encountered a complex component. Adjust batch size and retry." |
| Cancelled | "Analysis cancelled. Partial results are available below." |
| Completed | "Analysis complete. [N] components found." |
| Failed | "Analysis failed. [error summary]. See details for diagnostics." |

**Cancel interaction:**
1. User clicks "Cancel" - show confirmation modal: "Stop the analysis? The job will stop at the next checkpoint. Partial results already found will remain available."
2. On confirm: button transitions to disabled "Cancelling..." with spinner; calls `cancelJob()`
3. LWC waits for `Dependency_Status__e` with `Status__c = 'Cancelled'` before re-enabling UI

### Graph View (`metaMapperGraph`)

**Node visual language (SLDS-compliant, not color-only):**

| Node type | Color | Icon | Shape indicator |
|---|---|---|---|
| Is_Circular__c | Type color | `utility:rotate` | Dashed border |
| Is_Dynamic_Reference__c | Type color | `utility:warning` | Solid border (no tilde prefix) |
| Source__c = Supplemental | Type color | `utility:info` | [S] badge |
| Supplemental_Confidence__c < 70 | Type color | `utility:error` | Red badge; click opens popover |
| Normal node | Type color | Type-specific icon | Solid border |

**Interactions:**
- **Click:** opens component in Salesforce Setup in new tab
- **Right-click:** context menu with "Copy API Name", "Focus path to root", "Collapse subtree"
- **Hover:** SLDS tooltip showing `Metadata_Type__c`, `Metadata_Name__c`, `Context_Data__c` pills in plain English, confidence score (if supplemental)
- **"Expand All" guard:** if `Nodes_Processed__c > 1,000`, clicking "Expand All" shows modal: "This graph contains [N] nodes. Expanding all levels may slow or freeze your browser. Consider using the Level Filter or exporting to CSV instead."
- **"Focus path to root":** highlights the direct ancestor chain from selected node to root; dims all other nodes
- **Persistent legend:** always-visible sidebar listing all node types with color swatch + icon + label

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

### Accessibility

- All color distinctions reinforced by SLDS icon + shape (not color alone)
- Contrast ratios: all palette colors verified WCAG AA against white and Salesforce dark backgrounds before implementation
- ARIA labels on all interactive graph elements; `role="tree"` on tree view
- Keyboard navigation: Tab to focus graph container; arrow keys to traverse nodes; Enter to open in Setup
- Screen reader: every node badge includes `aria-label` in plain English (e.g. "Warning: low confidence supplemental match")
- Color-blind safe: icon + border shape carry meaning independent of hue

### Export Hierarchy

**Primary exports (prominent placement):**
- CSV - "Download as Spreadsheet" - for analysis in Excel / Sheets
- JSON - "Download as JSON" - for programmatic processing

**Advanced exports (collapsible "Advanced" section):**
- package.xml - "Download Deployment Manifest" - developer artifact for deployment pipelines; tooltip explains what it is and when to use it

### Settings UI (CMDT labels)

When surfacing `MetaMapper_Settings__mdt` fields in any admin UI, use human-readable labels:

| Field API name | UI label | Help text |
|---|---|---|
| `Retention_Hours__c` | "Keep completed jobs for" | "Jobs older than this are automatically deleted. Minimum 1 hour. Recommended: 72+ hours for diagnostic use." |
| `Batch_Size__c` | "Analysis speed (standard)" | "How many metadata components to analyze per processing step. Lower this if you see timeout errors." |
| `Flow_Batch_Size__c` | "Analysis speed (Flow jobs)" | "Lower batch size used when 'Active Flows Only' is enabled, because each Flow requires an extra check." |
| `Dml_Reserve_Rows__c` | "Safety margin (DML rows)" | "Advanced: number of database rows to reserve as a safety buffer. Increase for orgs with very connected metadata." |
| `Disable_PE__c` | "Disable live progress updates" | "Turn on if your org is hitting real-time event limits. Progress will refresh every few seconds instead." |
| `Hotloop_Threshold__c` | "Pause after N stuck retries" | "If the analysis retries this many times without finding new components, it pauses and alerts you." |

---

## Query Strategy

### IN Clause Chunking
Start with batches of **100 IDs** as a safe default, but split is driven by **estimated query character length**, not a fixed count. The Tooling API REST endpoint embeds SOQL in the URL - URI length depends on the IDs themselves, encoding, and the surrounding SOQL string. If estimated URL length exceeds 8KB, halve the batch before sending. 100 IDs is the starting estimate; the dynamic check is authoritative.

### QueryMore
Tooling API results exceeding 2,000 rows return a `nextRecordsUrl`. `DependencyService` must follow `nextRecordsUrl` iteratively until `done = true` before returning results to the Queueable. Each follow-up counts against the callout budget.

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
// Also check mid-loop: String.contains() on long Path__c strings inside the
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
    || heapPct >= 0.80
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
| JSON | Nested tree mirroring `Dependency_Node__c` hierarchy with `Context_Data__c` pills included |
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
| `Batch_Size__c` | Number | 50 | Unprocessed nodes queried per Queueable execution (non-Flow jobs). Tune down for high-DML orgs. |
| `Flow_Batch_Size__c` | Number | 30 | Batch size when `Active_Flows_Only__c = true`. Lower because each Flow node may require a second validation callout, reducing effective callout headroom. |
| `Dml_Reserve_Rows__c` | Number | 750 | DML rows to reserve in the guardrail before chaining. Raise for orgs with high-fan-out metadata (e.g. heavily referenced CustomObjects). |
| `Disable_PE__c` | Checkbox | false | When true, suppresses `Dependency_Status__e` publish and falls back to polling via `getJobStatus()`. Use when org is approaching the daily Platform Event delivery limit. |
| `Hotloop_Threshold__c` | Number | 5 | Number of consecutive re-chains with zero `Nodes_Processed__c` progress before the engine pauses the job and surfaces a warning to the UI. |

> Hard-coding batch size and DML reserve is inappropriate for an enterprise tool. A highly-connected org may need `Flow_Batch_Size__c = 15` and `Dml_Reserve_Rows__c = 1500`. Admins tune without a code deploy.

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
1. Updates `Dependency_Job__c.Status__c = 'Failed'`, sets `Error_Message__c` and `Closed_At__c`.
2. Publishes a `Dependency_Status__e` failure event.
3. Does NOT re-throw the exception (allows the catch block's DML to commit).

> **Why savepoint?** Without `Database.rollback(sp)`, partial engine work (e.g., some nodes inserted, some not) remains in the database in a corrupt intermediate state. The rollback cleans this up; the subsequent status update DML commits cleanly in the same transaction as a separate operation after the rollback point.

---

## Known Limitations

- `MetadataComponentDependency` does not capture all dependency types. Supplemental handlers fill 5 known static gaps. **Dynamic Apex string references are a permanent blind spot** - they cannot be resolved by any supplemental query and are flagged with `Is_Dynamic_Reference__c = true` in the UI. This is not a gap to be closed; it is an inherent Salesforce platform limitation.
- Supplemental handler matches (ValidationRule regex, FlexiPage XML parsing) are best-effort. Results may include false positives. Confidence scoring is deterministic per handler: WorkflowFieldUpdate exact match = 95, ValidationRule regex = 65, FlexiPage XML parse = 60, CMT field lookup = 85, Lookup relationship = 95. Nodes with `Supplemental_Confidence__c < 70` display a warning badge - treat as leads, not confirmed dependencies.
- `DependencyCleanupBatch` must delete child `Dependency_Node__c` records in chunks before deleting parent jobs. Implicit Master-Detail cascade counts against the 10,000 DML row limit; a job with 15,000 nodes would exceed it on a single parent delete.
- Named Credential requires one-time admin authorization post-install and cannot be scripted or source-tracked.
- `Active Flows Only` mode excludes inactive Flow versions by design to preserve heap and reduce DML.
- package.xml export excludes managed package components (namespace-prefixed) by default.
- Cancellation is cooperative. A Queueable already in the flex queue will check `Status__c` on entry and exit cleanly - it cannot be force-killed immediately.
- `createJob()` must be called from a synchronous Lightning context only. Invocation from Batch, Future, or Queueable contexts is blocked by an async-context guard. See `setup/SETUP.md` for integration constraints.

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
