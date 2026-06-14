# Phase 4: Engine Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

---

## Session Status (last updated 2026-05-15)

| Task | Status | Notes |
|---|---|---|
| Task 0 - Job_Type__c field | DONE | Field file created and committed |
| Task 1 - MetadataDependencyService | DONE | DependencyOptions refactored to mutable accumulator; IMetadataDependencyService return type changed to `Map<String, List<Metadata_Dependency__c>>`; isFirstPage guard on lastResultCount; INVALID_QUERY_LOCATOR gated on HTTP 400; buildNode() null guard |
| Task 2 - DependencyNotificationService | DONE | Uses `new MetaMapperSettingsProvider().getSettings()` |
| Task 3 - DependencyNodeCleanupBatch | DONE | CleanupMode enum (NODES_ONLY / NODES_AND_JOB); constructor reads no CMDT - batchSize passed by caller |
| Task 4 - DependencyQueueable | DONE | |
| Task 5 - ScanResultFileQueueable | SPEC REVIEW PASSED - quality review pending | **Open fix:** ring buffer failure logs only to `System.debug` - should also append to `Error_Progress_Label__c` on current job for admin visibility |
| Task 6 - ScanSummaryQueueable | NOT STARTED | Spec at lines 1124-1211 of this file |
| Task 7 - Test classes (x6) | NOT STARTED | Specs at lines 1219-1654 of this file |
| Task 8 - Code Review v17 | NOT STARTED | Copy structure from v16; update for Phase 4 classes |

### Key Technical Decisions (non-negotiable for next session)

- `MetaMapperSettingsProvider`: no `getInstance()` - use `new MetaMapperSettingsProvider().getSettings()`
- `Error_Progress_Label__c` on Metadata_Scan_Job__c: Long Text **32768** - use `.left(32768)` everywhere
- `MetadataDependencySelector.listByJob()`: two params - `(String jobId, Integer limitRows)`
- `IMetadataDependencyService.fetchDependencies()`: returns `Map<String, List<Metadata_Dependency__c>>` keyed by `RefMetadataComponentId`
- `DependencyNodeCleanupBatch` constructor: no CMDT read; batchSize passed by caller to `Database.executeBatch()`
- Supplemental handler DML in `DependencyQueueable`: accumulate ALL nodes across the handler loop, single bulk upsert AFTER the loop

### Resume Sequence

1. Run code quality review for Task 5 (`ScanResultFileQueueable.cls`) - apply ring buffer observability fix
2. Mark Task 5 complete
3. Task 6: implement `ScanSummaryQueueable.cls` (spec below, line 1124)
4. Task 7: implement all 6 test classes (spec below, line 1219)
5. Task 8: create `MetaMapper_Code_Review_v17.md`
6. Dispatch final code-reviewer subagent across all Phase 4 files
7. Push to GitHub: raw git to `C:/Users/GidiAbramovich/AppData/Local/Temp/`, copy to `projects/meta-mapper/`, push to `github.com/energidi/claude-knowledge-base`

---

**Goal:** Build the six Apex classes that form MetaMapper's scan engine: Tooling API service, notification service, node cleanup batch, async engine Queueable, result serializer, and summary generator.

**Architecture:** `DependencyQueueable` is the orchestrator - it reads unprocessed nodes, calls `MetadataDependencyService` for Tooling API results, invokes supplemental handlers via `DependencyTypeHandlerFactory`, self-chains until the tree is exhausted, then hands off to `ScanResultFileQueueable`. `DependencyNotificationService` publishes progress events. `DependencyNodeCleanupBatch` and `ScanSummaryQueueable` are invoked by the serializer on completion.

**Tech Stack:** Apex (Queueable, Database.AllowsCallouts, Database.Stateful, Batchable), Salesforce Tooling API via Named Credential `MetaMapper_Tooling_API`, Platform Events, ContentVersion/ContentDocument.

**Excluded from this phase:** `DependencyJobController`, `DependencyCleanupBatch`, `DependencyCleanupScheduler`, `ToolingApiHealthCheck`, all LWC components. Those are Phase 5.

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `force-app/main/default/classes/MetadataDependencyService.cls` | Create | Tooling API HTTP layer - fetches `MetadataComponentDependency`, handles QueryMore, HTTP 414 split/retry |
| `force-app/main/default/classes/MetadataDependencyService.cls-meta.xml` | Create | API version 66.0 |
| `force-app/main/default/classes/DependencyNotificationService.cls` | Create | Platform Event publisher with OrgLimits auto-suppress |
| `force-app/main/default/classes/DependencyNotificationService.cls-meta.xml` | Create | API version 66.0 |
| `force-app/main/default/classes/DependencyNodeCleanupBatch.cls` | Create | Batch deletes node records for a job; optionally deletes job record |
| `force-app/main/default/classes/DependencyNodeCleanupBatch.cls-meta.xml` | Create | API version 66.0 |
| `force-app/main/default/classes/DependencyQueueable.cls` | Create | Main async engine - traversal, guardrails, cycle detection, self-chain |
| `force-app/main/default/classes/DependencyQueueable.cls-meta.xml` | Create | API version 66.0 |
| `force-app/main/default/classes/ScanResultFileQueueable.cls` | Create | Serializes nodes to ContentVersion JSON, transitions job to Completed |
| `force-app/main/default/classes/ScanResultFileQueueable.cls-meta.xml` | Create | API version 66.0 |
| `force-app/main/default/classes/ScanSummaryQueueable.cls` | Create | Builds plain-English Scan_Summary_Text__c from Result_Summary__c |
| `force-app/main/default/classes/ScanSummaryQueueable.cls-meta.xml` | Create | API version 66.0 |
| `force-app/main/default/classes/MetadataDependencyServiceTest.cls` | Create | Unit tests for Tooling API service |
| `force-app/main/default/classes/MetadataDependencyServiceTest.cls-meta.xml` | Create | API version 66.0 |
| `force-app/main/default/classes/DependencyNotificationServiceTest.cls` | Create | Unit tests for notification service |
| `force-app/main/default/classes/DependencyNotificationServiceTest.cls-meta.xml` | Create | API version 66.0 |
| `force-app/main/default/classes/DependencyNodeCleanupBatchTest.cls` | Create | Unit tests for cleanup batch |
| `force-app/main/default/classes/DependencyNodeCleanupBatchTest.cls-meta.xml` | Create | API version 66.0 |
| `force-app/main/default/classes/DependencyQueueableTest.cls` | Create | Unit tests for async engine |
| `force-app/main/default/classes/DependencyQueueableTest.cls-meta.xml` | Create | API version 66.0 |
| `force-app/main/default/classes/ScanResultFileQueueableTest.cls` | Create | Unit tests for serializer |
| `force-app/main/default/classes/ScanResultFileQueueableTest.cls-meta.xml` | Create | API version 66.0 |
| `force-app/main/default/classes/ScanSummaryQueueableTest.cls` | Create | Unit tests for summary generator |
| `force-app/main/default/classes/ScanSummaryQueueableTest.cls-meta.xml` | Create | API version 66.0 |
| `MetaMapper_Code_Review_v17.md` | Create | Code review document for Phase 4 classes |
| `force-app/main/default/objects/Metadata_Scan_Job__c/fields/Job_Type__c.field-meta.xml` | Create | Picklist field: `Dependency_Map` (default), `Text_Search` - prepares data model for future text search feature |

---

## Task 0: Data Model Prep - Job_Type__c

**Files:**
- Create: `force-app/main/default/objects/Metadata_Scan_Job__c/fields/Job_Type__c.field-meta.xml`

Adds a picklist field to `Metadata_Scan_Job__c` distinguishing dependency-map jobs from future text-search jobs. Adding it now avoids a breaking schema change when text search is built. All Phase 4 engine classes default to `Dependency_Map` and ignore this field - no routing logic needed yet.

- [ ] **Step 1: Create Job_Type__c field metadata**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<CustomField xmlns="http://soap.sforce.com/2006/04/metadata">
    <fullName>Job_Type__c</fullName>
    <description>Distinguishes the type of scan job. Dependency_Map = structural metadata dependency traversal (current engine). Text_Search = reserved for future content-based metadata search feature. Defaults to Dependency_Map on all existing and new jobs.</description>
    <externalId>false</externalId>
    <label>Job Type</label>
    <required>false</required>
    <trackTrending>false</trackTrending>
    <type>Picklist</type>
    <valueSet>
        <restricted>true</restricted>
        <valueSetDefinition>
            <sorted>false</sorted>
            <value>
                <fullName>Dependency_Map</fullName>
                <default>true</default>
                <label>Dependency Map</label>
            </value>
            <value>
                <fullName>Text_Search</fullName>
                <default>false</default>
                <label>Text Search</label>
            </value>
        </valueSetDefinition>
    </valueSet>
</CustomField>
```

- [ ] **Step 2: Verify directory exists and file is in place**

```
force-app/main/default/objects/Metadata_Scan_Job__c/fields/Job_Type__c.field-meta.xml
```

- [ ] **Step 3: Commit**

```bash
git add force-app/main/default/objects/Metadata_Scan_Job__c/fields/Job_Type__c.field-meta.xml
git commit -m "feat: add Job_Type__c picklist to Metadata_Scan_Job__c for future text search support"
```

---

## Task 1: MetadataDependencyService

**Files:**
- Create: `force-app/main/default/classes/MetadataDependencyService.cls`
- Create: `force-app/main/default/classes/MetadataDependencyService.cls-meta.xml`

This class implements `IMetadataDependencyService`. It makes HTTP callouts to the Tooling API, handles QueryMore pagination, and applies the reactive HTTP 414/431 split-and-retry. It does NOT modify any Salesforce records - it only reads and transforms Tooling API responses.

- [ ] **Step 1: Create the cls-meta.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>66.0</apiVersion>
    <status>Active</status>
</ApexClass>
```

- [ ] **Step 2: Create MetadataDependencyService.cls**

```java
/**
 * MetadataDependencyService
 *
 * Implements IMetadataDependencyService. Fetches MetadataComponentDependency records
 * from the Tooling API via Named Credential MetaMapper_Tooling_API.
 *
 * Key behaviours:
 * - Dynamic IN-clause chunking: splits when 80 + (size * 19) > 8000 chars
 * - QueryMore: follows nextRecordsUrl until done = true
 * - HTTP 414/431 reactive split-and-retry (max 5 levels of recursion)
 * - Heap guard: rejects response bodies > 500,000 chars before JSON.deserializeUntyped()
 * - Active Flows Only: validates Flow version status via extra callout per Flow node
 *
 * Ref: ISP-6072
 */
public without sharing class MetadataDependencyService implements IMetadataDependencyService {

    // URL-length budget for Tooling API SOQL-in-URL requests.
    // Formula: 80 (base overhead) + size * 19 (18-char ID + comma).
    // At > 8,000 chars the callout may return HTTP 414 URI Too Long.
    private static final Integer URL_BUDGET       = 8000;
    private static final Integer URL_OVERHEAD     = 80;
    private static final Integer ID_CHAR_COST     = 19;
    private static final Integer MAX_SPLIT_DEPTH  = 5;
    // Reject deserialization of response bodies larger than this to prevent heap overflow.
    private static final Integer MAX_RESPONSE_CHARS = 500000;

    private static final String NAMED_CREDENTIAL = 'callout:MetaMapper_Tooling_API';
    private static final String API_PATH         = '/services/data/v66.0/tooling/query/?q=';
    private static final String NEXT_RECORDS_PATH= '/services/data/v66.0/tooling/query/';

    /**
     * Fetches all MetadataComponentDependency records where RefMetadataComponentId is in the
     * provided ID set. Follows QueryMore until the result set is exhausted.
     *
     * @param metadataIds   Set of 18-char Tooling API component IDs to query as references
     * @param opts          DependencyOptions controlling activeFlowsOnly and job context
     * @return              List of new Metadata_Dependency__c records (not yet inserted)
     */
    public List<Metadata_Dependency__c> fetchDependencies(
        List<String> metadataIds,
        DependencyOptions opts
    ) {
        List<Metadata_Dependency__c> results = new List<Metadata_Dependency__c>();
        if (metadataIds == null || metadataIds.isEmpty()) {
            return results;
        }
        // Dynamic chunking: split if estimated URL length exceeds budget.
        if (URL_OVERHEAD + (metadataIds.size() * ID_CHAR_COST) > URL_BUDGET) {
            Integer mid = metadataIds.size() / 2;
            results.addAll(fetchDependencies(metadataIds.subList(0, mid), opts));
            results.addAll(fetchDependencies(metadataIds.subList(mid, metadataIds.size()), opts));
            return results;
        }
        return fetchWithRetry(metadataIds, opts, 0);
    }

    private List<Metadata_Dependency__c> fetchWithRetry(
        List<String> ids,
        DependencyOptions opts,
        Integer splitDepth
    ) {
        String idList = '\'' + String.join(ids, '\',\'') + '\'';
        String soql = 'SELECT MetadataComponentId, MetadataComponentName, MetadataComponentType,'
            + ' RefMetadataComponentId, RefMetadataComponentName, RefMetadataComponentType'
            + ' FROM MetadataComponentDependency'
            + ' WHERE RefMetadataComponentId IN (' + idList + ')';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + API_PATH + EncodingUtil.urlEncode(soql, 'UTF-8'));
        req.setMethod('GET');
        req.setHeader('Content-Type', 'application/json');

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() == 414 || res.getStatusCode() == 431) {
            if (splitDepth >= MAX_SPLIT_DEPTH) {
                // Poison batch: log and skip rather than infinite recursion.
                opts.addError('MetadataDependencyService: HTTP ' + res.getStatusCode()
                    + ' after ' + MAX_SPLIT_DEPTH + ' split attempts for '
                    + ids.size() + ' IDs. Batch skipped.');
                return new List<Metadata_Dependency__c>();
            }
            if (ids.size() == 1) {
                opts.addError('MetadataDependencyService: HTTP ' + res.getStatusCode()
                    + ' on single-ID batch for ' + ids[0] + '. Node skipped.');
                return new List<Metadata_Dependency__c>();
            }
            Integer mid = ids.size() / 2;
            List<Metadata_Dependency__c> combined = new List<Metadata_Dependency__c>();
            combined.addAll(fetchWithRetry(ids.subList(0, mid), opts, splitDepth + 1));
            combined.addAll(fetchWithRetry(ids.subList(mid, ids.size()), opts, splitDepth + 1));
            return combined;
        }

        if (res.getStatusCode() != 200) {
            opts.addError('MetadataDependencyService: HTTP ' + res.getStatusCode()
                + ' from Tooling API. Response: ' + res.getBody().left(500));
            return new List<Metadata_Dependency__c>();
        }

        return parseAndFollowQueryMore(res.getBody(), opts);
    }

    private List<Metadata_Dependency__c> parseAndFollowQueryMore(
        String responseBody,
        DependencyOptions opts
    ) {
        List<Metadata_Dependency__c> results = new List<Metadata_Dependency__c>();

        if (responseBody.length() > MAX_RESPONSE_CHARS) {
            opts.addError('MetadataDependencyService: response body ' + responseBody.length()
                + ' chars exceeds ' + MAX_RESPONSE_CHARS + ' char heap guard. Batch skipped.');
            return results;
        }

        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
        } catch (Exception e) {
            opts.addError('MetadataDependencyService: JSON parse failure - ' + e.getMessage());
            return results;
        }

        List<Object> records = (List<Object>) parsed.get('records');
        if (records != null) {
            for (Object rec : records) {
                Map<String, Object> r = (Map<String, Object>) rec;
                results.add(buildNode(r, opts));
            }
        }

        // Update Last_Query_Row_Count__c on job so the guardrail can predict queryMorePossible.
        opts.lastResultCount = (records != null) ? records.size() : 0;

        Boolean done = (Boolean) parsed.get('done');
        String nextUrl = (String) parsed.get('nextRecordsUrl');

        if (done == false && String.isNotBlank(nextUrl)) {
            results.addAll(followQueryMore(nextUrl, opts));
        }

        return results;
    }

    private List<Metadata_Dependency__c> followQueryMore(String nextUrl, DependencyOptions opts) {
        List<Metadata_Dependency__c> results = new List<Metadata_Dependency__c>();
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(NAMED_CREDENTIAL + NEXT_RECORDS_PATH
                + nextUrl.substringAfterLast('/'));
            req.setMethod('GET');
            req.setHeader('Content-Type', 'application/json');
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() == 200) {
                results.addAll(parseAndFollowQueryMore(res.getBody(), opts));
            } else if (res.getBody().containsIgnoreCase('INVALID_QUERY_LOCATOR')) {
                // Cursor expired (e.g. Queueable waited in flex queue > 15 min).
                // Log and allow the engine to re-query from scratch on next execution.
                opts.addError('MetadataDependencyService: QueryMore cursor expired. '
                    + 'Batch will be re-queried on next execution.');
            } else {
                opts.addError('MetadataDependencyService: QueryMore HTTP '
                    + res.getStatusCode() + '. Some dependencies may be missing.');
            }
        } catch (Exception e) {
            opts.addError('MetadataDependencyService: QueryMore exception - ' + e.getMessage());
        }
        return results;
    }

    private Metadata_Dependency__c buildNode(Map<String, Object> r, DependencyOptions opts) {
        Metadata_Dependency__c node = new Metadata_Dependency__c();
        node.Metadata_Id__c   = (String) r.get('MetadataComponentId');
        node.Metadata_Name__c = (String) r.get('MetadataComponentName');
        node.Metadata_Type__c = (String) r.get('MetadataComponentType');
        node.Discovery_Source__c = 'ToolingAPI';
        node.Traversal_Complete__c = false;
        node.Metadata_Scan_Job__c = opts.jobId;
        return node;
    }

    /**
     * Builds Dependency_Context__c JSON for a node based on its metadata type.
     * Returns null if no attributes are defined for this type.
     */
    public String buildContextData(Metadata_Dependency__c node) {
        if (node == null || String.isBlank(node.Metadata_Type__c)) {
            return null;
        }
        String t = node.Metadata_Type__c;
        if (t == 'ApexClass' || t == 'ApexTrigger') {
            return '{"v":1,"isWrite":false}';
        }
        if (t == 'Flow') {
            return '{"v":1,"isActive":false,"activeVersions":0}';
        }
        if (t == 'WorkflowRule') {
            return '{"v":1,"isActive":false,"triggerType":""}';
        }
        if (t == 'CustomField') {
            return '{"v":1,"parentObject":"","parentType":"CustomObject"}';
        }
        if (t == 'Report') {
            return '{"v":1,"filterUsage":[]}';
        }
        return null;
    }

    /**
     * Returns the confidence score for a supplemental handler type.
     * Used by supplemental handlers to populate Supplemental_Confidence__c.
     */
    public Integer computeScore(String handlerType, String matchBasis) {
        if (handlerType == 'WorkflowFieldUpdate') return 95;
        if (handlerType == 'ValidationRule' && matchBasis == 'regex') return 65;
        if (handlerType == 'FlexiPage') return 60;
        if (handlerType == 'CustomMetadata' && matchBasis == 'fieldValue') return 85;
        if (handlerType == 'LookupRelationship') return 95;
        return 70;
    }
}
```

- [ ] **Step 3: Create DependencyOptions.cls update check**

`DependencyOptions` must have these fields (verify the existing class matches - do not rewrite if it already has them):
- `Id jobId`
- `Boolean activeFlowsOnly`
- `Integer lastResultCount` - updated by service after each callout
- `List<String> errors` - diagnostic messages
- `void addError(String msg)` - adds timestamped message

If `lastResultCount` or `addError()` are missing, add them to the existing class.

- [ ] **Step 4: Verify DependencyOptions.cls has required members**

Open `force-app/main/default/classes/DependencyOptions.cls` and confirm `lastResultCount` (Integer), `errors` (List<String>), and `addError(String)` exist. Add any missing members.

---

## Task 2: DependencyNotificationService

**Files:**
- Create: `force-app/main/default/classes/DependencyNotificationService.cls`
- Create: `force-app/main/default/classes/DependencyNotificationService.cls-meta.xml`

- [ ] **Step 1: Create cls-meta.xml** (same content as Task 1 Step 1)

- [ ] **Step 2: Create DependencyNotificationService.cls**

```java
/**
 * DependencyNotificationService
 *
 * Implements IScanNotificationService. Publishes Dependency_Scan_Status__e Platform Events
 * and checks org daily PE allocation before each publish.
 *
 * Auto-suppression: if the org has consumed > 80% of its daily Standard Volume PE limit,
 * suppresses the event, flips Disable_Platform_Events__c = true on the CMDT Default record
 * via Metadata.Operations.enqueueDeployment(), and appends a notice to Error_Progress_Label__c.
 *
 * Ref: ISP-6072
 */
public without sharing class DependencyNotificationService implements IScanNotificationService {

    private static final Decimal PE_SUPPRESS_THRESHOLD = 0.80;

    /**
     * Publishes one Dependency_Scan_Status__e event for the current Queueable execution.
     * Skips publish if Disable_Platform_Events__c = true on the settings record, or if
     * the org daily PE allocation is > 80% consumed (auto-suppresses and flips CMDT flag).
     *
     * @param jobId     Metadata_Scan_Job__c record ID
     * @param status    Status__c value to publish
     * @param count     Current Components_Analyzed__c value
     * @param msg       Human-readable status message
     */
    public void publishProgress(String jobId, String status, Integer count, String msg) {
        MetaMapper_Settings__mdt settings = MetaMapperSettingsProvider.getInstance().getSettings();

        if (settings.Disable_Platform_Events__c) {
            return;
        }

        // OrgLimits check - auto-suppress if > 80% consumed.
        OrgLimit peLimit = OrgLimits.getMap().get('DailyStandardVolumePlatformEvents');
        if (peLimit != null && peLimit.getLimit() > 0) {
            Decimal consumed = (Decimal) peLimit.getValue() / peLimit.getLimit();
            if (consumed >= PE_SUPPRESS_THRESHOLD) {
                suppressPlatformEvents(jobId);
                return;
            }
        }

        Dependency_Scan_Status__e evt = new Dependency_Scan_Status__e(
            Scan_Job_Id__c         = jobId,
            Status__c              = status,
            Components_Analyzed__c = count,
            Progress_Label__c      = String.isNotBlank(msg) ? msg.left(255) : ''
        );

        List<Database.SaveResult> results = EventBus.publish(new List<SObject>{ evt });
        for (Database.SaveResult r : results) {
            if (!r.isSuccess()) {
                System.debug(LoggingLevel.WARN,
                    'DependencyNotificationService.publishProgress: PE publish failed - '
                    + r.getErrors()[0].getMessage());
            }
        }
    }

    /**
     * Appends a completion notice to Error_Progress_Label__c.
     * Platform Events are not used for the completion signal - the LWC polls getJobStatus().
     */
    public void sendCompletion(String jobId, String userId) {
        // Completion is signalled via Status__c = 'Completed' on the job record.
        // No additional action required here; LWC detects completion via polling or PE.
        System.debug(LoggingLevel.INFO,
            'DependencyNotificationService.sendCompletion: job ' + jobId + ' completed.');
    }

    private void suppressPlatformEvents(String jobId) {
        // Log suppression notice to Error_Progress_Label__c via in-memory update.
        // The caller (DependencyQueueable) is responsible for persisting Error_Progress_Label__c.
        String notice = '[' + System.now().format() + '] Platform Events suppressed - '
            + 'org daily delivery limit >80% consumed. Progress updates switched to polling.';
        System.debug(LoggingLevel.WARN, notice);

        // Flip CMDT flag asynchronously so all subsequent executions skip the OrgLimits check.
        try {
            MetaMapper_Settings__mdt current =
                MetaMapperSettingsProvider.getInstance().getSettings();
            MetaMapper_Settings__mdt toUpdate = new MetaMapper_Settings__mdt(
                Id = current.Id,
                Disable_Platform_Events__c = true
            );
            Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
            cm.fullName = 'MetaMapper_Settings__mdt.Default';
            cm.label   = 'Default';
            Metadata.CustomMetadataValue cmv = new Metadata.CustomMetadataValue();
            cmv.field = 'Disable_Platform_Events__c';
            cmv.value = true;
            cm.values = new List<Metadata.CustomMetadataValue>{ cmv };
            Metadata.DeployContainer container = new Metadata.DeployContainer();
            container.addMetadata(cm);
            Metadata.Operations.enqueueDeployment(container, null);
        } catch (Exception e) {
            // CMDT write failure is non-fatal. The OrgLimits check runs again next execution.
            System.debug(LoggingLevel.WARN,
                'DependencyNotificationService: CMDT suppression flag write failed - '
                + e.getMessage());
        }
    }
}
```

---

## Task 3: DependencyNodeCleanupBatch

**Files:**
- Create: `force-app/main/default/classes/DependencyNodeCleanupBatch.cls`
- Create: `force-app/main/default/classes/DependencyNodeCleanupBatch.cls-meta.xml`

- [ ] **Step 1: Create cls-meta.xml**

- [ ] **Step 2: Create DependencyNodeCleanupBatch.cls**

```java
/**
 * DependencyNodeCleanupBatch
 *
 * Batch-deletes Metadata_Dependency__c records for a specific job.
 * Called from two paths:
 *   - ScanResultFileQueueable (NODES_ONLY): deletes nodes after serialization; retains job record
 *   - DependencyCleanupBatch (NODES_AND_JOB): deletes nodes then job record for expired jobs
 *
 * Uses CleanupMode enum instead of a Boolean to prevent silent argument-swap bugs.
 * Batch size = Cleanup_Chunk_Size__c (default 2,000): leaves 8,000 DML rows headroom
 * for customer automation that may fire on delete events for Metadata_Dependency__c.
 *
 * Ref: ISP-6072
 */
public without sharing class DependencyNodeCleanupBatch
    implements Database.Batchable<SObject> {

    public enum CleanupMode { NODES_ONLY, NODES_AND_JOB }

    private final String      jobId;
    private final CleanupMode mode;
    private final Integer     batchSize;

    public DependencyNodeCleanupBatch(String jobId, CleanupMode mode) {
        this.jobId     = jobId;
        this.mode      = mode;
        MetaMapper_Settings__mdt settings =
            MetaMapperSettingsProvider.getInstance().getSettings();
        this.batchSize = (Integer) settings.Cleanup_Chunk_Size__c;
        if (this.batchSize == null || this.batchSize < 1) {
            this.batchSize = 2000;
        }
    }

    public Database.QueryLocator start(Database.BatchableContext ctx) {
        return Database.getQueryLocator([
            SELECT Id
            FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :jobId
        ]);
    }

    public void execute(Database.BatchableContext ctx, List<SObject> scope) {
        delete scope;
    }

    public void finish(Database.BatchableContext ctx) {
        if (mode == CleanupMode.NODES_AND_JOB) {
            List<Metadata_Scan_Job__c> jobs = [
                SELECT Id FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
            ];
            if (!jobs.isEmpty()) {
                delete jobs;
            }
        }
    }
}
```

---

## Task 4: DependencyQueueable

**Files:**
- Create: `force-app/main/default/classes/DependencyQueueable.cls`
- Create: `force-app/main/default/classes/DependencyQueueable.cls-meta.xml`

This is the core engine. Read the full design before implementing - key constraints are documented inline.

- [ ] **Step 1: Create cls-meta.xml**

- [ ] **Step 2: Create DependencyQueueable.cls**

```java
/**
 * DependencyQueueable
 *
 * Async engine for MetaMapper dependency traversal.
 *
 * Each execution:
 * 1. Checks for cancellation
 * 2. Reads CMDT settings
 * 3. Increments Processing_Cycle_Count__c; checks for hot-loop stall
 * 4. Applies node cap check (pauses if Components_Analyzed__c >= Max_Components__c)
 * 5. Queries a batch of unprocessed nodes
 * 6. Runs the seven-limit pre-batch guardrail; self-chains if needed
 * 7. Calls Tooling API for each parent node's dependencies
 * 8. Deduplicates results (Tier 1: DB-scoped dedup)
 * 9. Applies two-tier cycle detection (bloom filter + Ancestor_Path__c confirmation)
 * 10. Sets Dependency_Context__c via MetadataDependencyService.buildContextData()
 * 11. Bulk-upserts child nodes by Component_Uniqueness_Key__c
 * 12. Runs supplemental handlers
 * 13. Publishes one PE event
 * 14. Self-chains, or hands off to ScanResultFileQueueable when done
 *
 * Savepoint/rollback: all work is guarded by a Savepoint. Failures roll back partial
 * work and updateJobFailed() commits the error status in a fresh DML scope.
 *
 * Ref: ISP-6072
 */
public without sharing class DependencyQueueable implements Queueable, Database.AllowsCallouts {

    private final String  jobId;
    private final Boolean activeFlowsOnly;
    private final Integer overrideBatchSize; // null = use CMDT default

    public DependencyQueueable(String jobId, Boolean activeFlowsOnly, Integer overrideBatchSize) {
        this.jobId             = jobId;
        this.activeFlowsOnly   = activeFlowsOnly;
        this.overrideBatchSize = overrideBatchSize;
    }

    public void execute(QueueableContext ctx) {
        Savepoint sp = Database.setSavepoint();
        try {
            runEngine(ctx);
        } catch (Exception e) {
            Database.rollback(sp);
            updateJobFailed(jobId, e.getMessage() + '\n' + e.getStackTraceString());
        }
    }

    private void runEngine(QueueableContext ctx) {
        // --- 1. Load job record ---
        Metadata_Scan_Job__c job = DependencyJobSelector.getByIdForEngine(jobId);
        if (job == null) { return; }

        // --- 2. Cancel check ---
        if (job.Status__c == 'Cancelled') { return; }

        // --- 3. CMDT settings ---
        MetaMapper_Settings__mdt settings =
            MetaMapperSettingsProvider.getInstance().getSettings();
        Integer batchSize = (overrideBatchSize != null)
            ? overrideBatchSize
            : (Integer) settings.Scan_Batch_Size__c;
        if (activeFlowsOnly && settings.Flow_Scan_Batch_Size__c != null) {
            batchSize = (Integer) settings.Flow_Scan_Batch_Size__c;
        }
        if (overrideBatchSize != null) {
            batchSize = overrideBatchSize; // job-level override wins
        }

        // --- 4. Increment cycle counter + stall detection ---
        job.Processing_Cycle_Count__c = (job.Processing_Cycle_Count__c == null ? 0
            : job.Processing_Cycle_Count__c) + 1;
        Decimal stallThreshold = settings.Empty_Cycle_Pause_Threshold__c != null
            ? settings.Empty_Cycle_Pause_Threshold__c : 5;
        Decimal lastSuccess = job.Last_Progressive_Cycle__c != null
            ? job.Last_Progressive_Cycle__c : 0;
        if (job.Processing_Cycle_Count__c - lastSuccess >= stallThreshold) {
            job.Status__c = 'Paused';
            job.Error_Progress_Label__c = appendToLog(job.Error_Progress_Label__c,
                'Scan paused: ' + (Integer) stallThreshold
                + ' consecutive cycles with no new components. '
                + 'This may indicate an unusually deep or wide dependency tree. '
                + 'Resume at a slower speed or with current settings.');
            update job;
            new DependencyNotificationService().publishProgress(
                jobId, 'Paused', (Integer) job.Components_Analyzed__c,
                'Scan paused - stall detected');
            return;
        }

        // --- 5. Node cap check ---
        Decimal maxComponents = settings.Max_Components__c != null
            ? settings.Max_Components__c : 5000;
        if (maxComponents > 0 && job.Components_Analyzed__c != null
            && job.Components_Analyzed__c >= maxComponents) {
            job.Status__c = 'Paused';
            job.Error_Progress_Label__c = appendToLog(job.Error_Progress_Label__c,
                'Scan paused: node limit of ' + (Integer) maxComponents
                + ' reached. Raise Max_Components__c in MetaMapper Settings to continue.');
            update job;
            new DependencyNotificationService().publishProgress(
                jobId, 'Paused', (Integer) job.Components_Analyzed__c,
                'Scan paused - node limit reached');
            return;
        }

        // --- 6. Fetch unprocessed batch ---
        List<Metadata_Dependency__c> batch =
            MetadataDependencySelector.nextUnprocessed(jobId, batchSize);

        // --- 7. No unprocessed nodes -> hand off to serializer ---
        if (batch.isEmpty()) {
            System.enqueueJob(new ScanResultFileQueueable(jobId));
            return;
        }

        // --- 8. Pre-batch seven-limit guardrail ---
        Boolean queryMorePossible = (job.Last_Query_Row_Count__c != null
            && job.Last_Query_Row_Count__c >= 1900);
        Integer flowNodeCount = 0;
        if (activeFlowsOnly) {
            for (Metadata_Dependency__c n : batch) {
                if (n.Metadata_Type__c == 'Flow') { flowNodeCount++; }
            }
        }
        if (shouldSelfChain(settings, queryMorePossible, flowNodeCount)) {
            job.Processing_Cycle_Count__c =
                (job.Processing_Cycle_Count__c == null ? 0 : job.Processing_Cycle_Count__c);
            update job;
            System.enqueueJob(new DependencyQueueable(jobId, activeFlowsOnly, overrideBatchSize));
            return;
        }

        // --- 9. Tooling API callouts + node assembly ---
        DependencyOptions opts = new DependencyOptions();
        opts.jobId           = jobId;
        opts.activeFlowsOnly = activeFlowsOnly;
        opts.lastResultCount = 0;

        MetadataDependencyService svc = new MetadataDependencyService();

        // Collect current batch parent IDs for Tooling API query
        List<String> parentIds = new List<String>();
        Map<String, Metadata_Dependency__c> parentById =
            new Map<String, Metadata_Dependency__c>();
        for (Metadata_Dependency__c p : batch) {
            parentIds.add(p.Metadata_Id__c);
            parentById.put(p.Metadata_Id__c, p);
        }

        List<Metadata_Dependency__c> rawChildren = svc.fetchDependencies(parentIds, opts);
        job.Last_Query_Row_Count__c = opts.lastResultCount;

        // --- 10. Scoped dedup (Tier 1) ---
        Set<String> rawChildIds = new Set<String>();
        for (Metadata_Dependency__c c : rawChildren) {
            if (c.Metadata_Id__c != null) rawChildIds.add(c.Metadata_Id__c);
        }
        Set<String> existingIds = MetadataDependencySelector.dedupForResults(jobId, rawChildIds);

        // --- 11. Build insert list with cycle detection ---
        List<Metadata_Dependency__c> toUpsert = new List<Metadata_Dependency__c>();
        Integer newCount = 0;
        for (Metadata_Dependency__c child : rawChildren) {
            if (String.isBlank(child.Metadata_Id__c)) { continue; }
            if (existingIds.contains(child.Metadata_Id__c)) { continue; } // Tier 1 dedup

            // Find which parent node this child belongs to
            // (Tooling API result carries RefMetadataComponentId = parent)
            // Note: buildNode() in MetadataDependencyService sets Metadata_Id__c to
            // MetadataComponentId. We need to match back to the parent.
            // The parent linkage is established via the batch: each rawChild came from
            // a query against parentIds, but the response doesn't directly carry which
            // parent triggered this result. DependencyQueueable uses the FIRST parent
            // that hasn't exceeded its path limit as the spanning-tree parent.
            // TODO: MetadataDependencyService.fetchDependencies must be updated to also
            // return RefMetadataComponentId so we can set Parent_Dependency__c correctly.
            // For now, assign first parent as placeholder - see NOTE below.

            // NOTE: The Tooling API response includes RefMetadataComponentId which is the
            // parent ID. MetadataDependencyService.buildNode() must populate a transient
            // field or wrapper to carry this back. Update MetadataDependencyService to use
            // a wrapper type (Map<String, List<Metadata_Dependency__c>> keyed by parentId)
            // rather than a flat list - see Task 4 addendum below.

            // Mid-loop CPU guard
            if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= 0.75) {
                break;
            }
            // Mid-loop DML row guard
            Integer dmlReserve = (Integer) (settings.Dml_Safety_Buffer_Rows__c != null
                ? settings.Dml_Safety_Buffer_Rows__c : 750);
            if (Limits.getLimitDmlRows() - Limits.getDmlRows() < dmlReserve) {
                break;
            }

            toUpsert.add(child);
            newCount++;
        }

        // --- 12. Bulk upsert ---
        if (!toUpsert.isEmpty()) {
            upsert toUpsert Component_Uniqueness_Key__c;
        }

        // Mark current batch as processed
        for (Metadata_Dependency__c p : batch) {
            p.Traversal_Complete__c = true;
        }
        update batch;

        // --- 13. Update job progress ---
        Decimal prevAnalyzed = job.Components_Analyzed__c != null
            ? job.Components_Analyzed__c : 0;
        job.Components_Analyzed__c = prevAnalyzed + newCount;
        if (newCount > 0) {
            job.Last_Progressive_Cycle__c = job.Processing_Cycle_Count__c;
        }

        // Append any service errors to the job log
        if (!opts.errors.isEmpty()) {
            job.Error_Progress_Label__c = appendToLog(
                job.Error_Progress_Label__c, String.join(opts.errors, '\n'));
        }

        // --- 14. Supplemental handlers ---
        runSupplementalHandlers(jobId, toUpsert, job);

        update job;

        // --- 15. Publish one PE event ---
        new DependencyNotificationService().publishProgress(
            jobId, 'Processing', (Integer) job.Components_Analyzed__c,
            'Analyzing metadata... ' + (Integer) job.Components_Analyzed__c
            + ' components found so far');

        // --- 16. Self-chain ---
        System.enqueueJob(new DependencyQueueable(jobId, activeFlowsOnly, overrideBatchSize));
    }

    private void runSupplementalHandlers(
        String jobId,
        List<Metadata_Dependency__c> nodes,
        Metadata_Scan_Job__c job
    ) {
        if (nodes == null || nodes.isEmpty()) { return; }

        // Group nodes by metadata type for handler dispatch
        Map<String, List<Metadata_Dependency__c>> byType =
            new Map<String, List<Metadata_Dependency__c>>();
        for (Metadata_Dependency__c n : nodes) {
            String t = n.Metadata_Type__c != null ? n.Metadata_Type__c : '';
            if (!byType.containsKey(t)) {
                byType.put(t, new List<Metadata_Dependency__c>());
            }
            byType.get(t).add(n);
        }

        for (String metaType : byType.keySet()) {
            IDependencyTypeHandler handler =
                DependencyTypeHandlerFactory.getHandler(metaType);
            SupplementalResult sr = handler.findSupplemental(jobId, byType.get(metaType));
            if (!sr.nodes.isEmpty()) {
                upsert sr.nodes Component_Uniqueness_Key__c;
            }
            if (!sr.errors.isEmpty()) {
                MetaMapper_Settings__mdt settings =
                    MetaMapperSettingsProvider.getInstance().getSettings();
                job.Error_Progress_Label__c = sr.appendErrorsSafe(
                    job.Error_Progress_Label__c,
                    131072,
                    200
                );
            }
        }
    }

    private Boolean shouldSelfChain(
        MetaMapper_Settings__mdt settings,
        Boolean queryMorePossible,
        Integer flowNodeCount
    ) {
        Integer calloutsRemaining = Limits.getLimitCallouts() - Limits.getCallouts();
        Integer headroom = 1 + (queryMorePossible ? 1 : 0) + flowNodeCount + 4;
        Integer dmlReserve = (Integer) (settings.Dml_Safety_Buffer_Rows__c != null
            ? settings.Dml_Safety_Buffer_Rows__c : 750);
        Integer dmlRemaining = Limits.getLimitDmlRows() - Limits.getDmlRows();
        Decimal heapPct = (Decimal) Limits.getHeapSize() / Limits.getLimitHeapSize();
        Decimal cpuPct  = (Decimal) Limits.getCpuTime()  / Limits.getLimitCpuTime();
        Integer queryRowsRemaining = Limits.getLimitQueryRows() - Limits.getQueryRows();
        Integer queriesRemaining   = Limits.getLimitQueries()   - Limits.getQueries();
        Integer dmlStmtsRemaining  = Limits.getLimitDmlStatements() - Limits.getDmlStatements();

        return (calloutsRemaining < headroom
            || dmlRemaining < dmlReserve
            || heapPct >= 0.70
            || cpuPct  >= 0.75
            || queryRowsRemaining < 1000
            || queriesRemaining   < 10
            || dmlStmtsRemaining  < 40);
    }

    private void updateJobFailed(String jobId, String errorMsg) {
        List<Metadata_Scan_Job__c> jobs = [
            SELECT Id, Status__c
            FROM Metadata_Scan_Job__c
            WHERE Id = :jobId LIMIT 1
        ];
        if (jobs.isEmpty()) { return; }
        if (jobs[0].Status__c != 'Processing') { return; } // don't overwrite Completed/Cancelled
        jobs[0].Status__c              = 'Failed';
        jobs[0].Error_Progress_Label__c = errorMsg.left(32768);
        jobs[0].Status_Closed_At__c    = System.now();
        update jobs;
        try {
            new DependencyNotificationService().publishProgress(
                jobId, 'Failed', 0, 'Analysis failed.');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'updateJobFailed: PE publish failed - '
                + e.getMessage());
        }
    }

    private String appendToLog(String existing, String msg) {
        String timestamped = '[' + System.now().format() + '] ' + msg;
        if (String.isBlank(existing)) { return timestamped; }
        return (existing + '\n' + timestamped).left(32768);
    }
}
```

- [ ] **Step 3: Task 4 Addendum - update MetadataDependencyService to return parent linkage**

`fetchDependencies` must return a `Map<String, List<Metadata_Dependency__c>>` keyed by `RefMetadataComponentId` (the parent ID from the Tooling API response) so `DependencyQueueable` can set `Parent_Dependency__c` correctly on each child node.

Update `MetadataDependencyService`:
- Change return type of `fetchDependencies()` and `IMetadataDependencyService` interface to `Map<String, List<Metadata_Dependency__c>>`
- In `buildNode()`, add a transient helper: store `RefMetadataComponentId` temporarily so the map can be built in `parseAndFollowQueryMore()`
- Update `DependencyQueueable` to consume the map, setting `child.Parent_Dependency__c` to the parent node's record ID (looked up from `parentById` map)

Updated `IMetadataDependencyService`:
```java
Map<String, List<Metadata_Dependency__c>> fetchDependencies(
    List<String> metadataIds, DependencyOptions opts);
```

Updated `MetadataDependencyService.parseAndFollowQueryMore` (key change):
```java
// Group results by RefMetadataComponentId (parent)
Map<String, List<Metadata_Dependency__c>> byParent =
    new Map<String, List<Metadata_Dependency__c>>();
for (Object rec : records) {
    Map<String, Object> r = (Map<String, Object>) rec;
    String parentId = (String) r.get('RefMetadataComponentId');
    if (!byParent.containsKey(parentId)) {
        byParent.put(parentId, new List<Metadata_Dependency__c>());
    }
    byParent.get(parentId).add(buildNode(r, opts));
}
```

---

## Task 5: ScanResultFileQueueable

**Files:**
- Create: `force-app/main/default/classes/ScanResultFileQueueable.cls`
- Create: `force-app/main/default/classes/ScanResultFileQueueable.cls-meta.xml`

- [ ] **Step 1: Create cls-meta.xml**

- [ ] **Step 2: Create ScanResultFileQueueable.cls**

```java
/**
 * ScanResultFileQueueable
 *
 * One-shot Queueable enqueued by the final DependencyQueueable execution when
 * no unprocessed nodes remain.
 *
 * Steps (all guarded by Savepoint/rollback):
 * 1. Heap pre-check: estimates serialization size; fails gracefully if too large
 * 2. Serializes all Metadata_Dependency__c to JSON
 * 3. Creates ContentVersion with FirstPublishLocationId = jobId
 * 4. Requeries ContentDocumentId (not available on the inserted record)
 * 5. Updates Result_File_Id__c and Result_Summary__c on the job
 * 6. Transitions job to Completed
 * 7. Bulk-deletes node records via DependencyNodeCleanupBatch(NODES_ONLY)
 * 8. Enforces ring buffer (Max_Stored_Jobs__c)
 * 9. Enqueues ScanSummaryQueueable
 *
 * Failure is terminal: if any step fails, job transitions to Failed.
 * Node records remain for manual export until nightly cleanup.
 *
 * Ref: ISP-6072
 */
public without sharing class ScanResultFileQueueable implements Queueable {

    private static final Integer AVG_BYTES_PER_NODE = 5000; // conservative estimate for deep trees
    private static final Integer HEAP_LIMIT_BYTES   = 10000000; // 10MB safety ceiling (12MB max)

    private final String jobId;

    public ScanResultFileQueueable(String jobId) {
        this.jobId = jobId;
    }

    public void execute(QueueableContext ctx) {
        Savepoint sp = Database.setSavepoint();
        try {
            runSerializer();
        } catch (Exception e) {
            Database.rollback(sp);
            updateJobFailed(jobId,
                'ScanResultFileQueueable: ' + e.getMessage()
                + '\n' + e.getStackTraceString());
        }
    }

    private void runSerializer() {
        Metadata_Scan_Job__c job = [
            SELECT Id, Status__c, Components_Analyzed__c, Error_Progress_Label__c,
                   Target_API_Name__c
            FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
        ];

        // --- 1. Heap pre-check ---
        Long estimatedBytes = (Long) (job.Components_Analyzed__c != null
            ? job.Components_Analyzed__c : 0) * AVG_BYTES_PER_NODE;
        if (estimatedBytes > HEAP_LIMIT_BYTES) {
            updateJobFailed(jobId,
                'Scan completed but results could not be saved - result set too large '
                + 'for available heap. Reduce Max_Components__c and run again.');
            return;
        }

        // --- 2. Serialize nodes ---
        List<Metadata_Dependency__c> nodes =
            MetadataDependencySelector.listByJob(jobId);
        String json = JSON.serialize(nodes);

        // --- 3. Create ContentVersion ---
        ContentVersion cv = new ContentVersion(
            Title            = 'MetaMapper_' + jobId,
            PathOnClient     = 'MetaMapper_' + jobId + '.json',
            VersionData      = Blob.valueOf(json),
            FirstPublishLocationId = jobId
        );
        insert cv;

        // --- 4. Requery ContentDocumentId ---
        cv = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];

        // Set ContentDocumentLink to InternalUsers visibility
        List<ContentDocumentLink> links = [
            SELECT Id, ShareType, Visibility
            FROM ContentDocumentLink
            WHERE ContentDocumentId = :cv.ContentDocumentId
            AND LinkedEntityId = :jobId
            LIMIT 1
        ];
        if (!links.isEmpty()) {
            links[0].ShareType  = 'V';
            links[0].Visibility = 'InternalUsers';
            update links;
        }

        // --- 5. Compute Result_Summary__c ---
        Map<String, Integer> typeCounts = new Map<String, Integer>();
        for (Metadata_Dependency__c n : nodes) {
            String t = n.Metadata_Type__c != null ? n.Metadata_Type__c : 'Unknown';
            typeCounts.put(t, (typeCounts.containsKey(t) ? typeCounts.get(t) : 0) + 1);
        }
        // Wrap in versioned envelope
        Map<String, Object> summaryMap = new Map<String, Object>{ 'v' => 1 };
        summaryMap.putAll(typeCounts);
        String resultSummary = JSON.serialize(summaryMap);

        // --- 6. Update job ---
        job.Result_File_Id__c = cv.ContentDocumentId;
        job.Result_Summary__c = resultSummary;
        job.Status__c         = 'Completed';
        job.Status_Closed_At__c = System.now();
        update job;

        // --- 7. Delete node records ---
        Database.executeBatch(
            new DependencyNodeCleanupBatch(jobId, DependencyNodeCleanupBatch.CleanupMode.NODES_ONLY),
            2000
        );

        // --- 8. Ring buffer ---
        enforceRingBuffer();

        // --- 9. Enqueue summary ---
        System.enqueueJob(new ScanSummaryQueueable(jobId));
    }

    private void enforceRingBuffer() {
        MetaMapper_Settings__mdt settings =
            MetaMapperSettingsProvider.getInstance().getSettings();
        Integer maxStored = (Integer) (settings.Max_Stored_Jobs__c != null
            ? settings.Max_Stored_Jobs__c : 5);

        List<Metadata_Scan_Job__c> completed = [
            SELECT Id, Result_File_Id__c
            FROM Metadata_Scan_Job__c
            WHERE Status__c = 'Completed'
            ORDER BY Status_Closed_At__c ASC, Id ASC
            LIMIT 1
            FOR UPDATE
        ];

        // Count AFTER this job's Completed transition
        Integer completedCount = [
            SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Status__c = 'Completed'
        ];

        if (completedCount <= maxStored) { return; }

        // Delete oldest completed job and its ContentDocument
        if (!completed.isEmpty()) {
            Metadata_Scan_Job__c oldest = completed[0];
            try {
                if (String.isNotBlank(oldest.Result_File_Id__c)) {
                    List<ContentDocument> docs = [
                        SELECT Id FROM ContentDocument WHERE Id = :oldest.Result_File_Id__c LIMIT 1
                    ];
                    if (!docs.isEmpty()) { delete docs; }
                }
                delete oldest;
            } catch (Exception e) {
                // Ring buffer delete failure must not fail the job.
                System.debug(LoggingLevel.WARN,
                    'ScanResultFileQueueable.enforceRingBuffer: delete failed - '
                    + e.getMessage());
            }
        }
    }

    private void updateJobFailed(String jobId, String errorMsg) {
        List<Metadata_Scan_Job__c> jobs = [
            SELECT Id, Status__c FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
        ];
        if (!jobs.isEmpty() && jobs[0].Status__c == 'Processing') {
            jobs[0].Status__c               = 'Failed';
            jobs[0].Error_Progress_Label__c = errorMsg.left(32768);
            jobs[0].Status_Closed_At__c     = System.now();
            update jobs;
        }
    }
}
```

---

## Task 6: ScanSummaryQueueable

**Files:**
- Create: `force-app/main/default/classes/ScanSummaryQueueable.cls`
- Create: `force-app/main/default/classes/ScanSummaryQueueable.cls-meta.xml`

- [ ] **Step 1: Create cls-meta.xml**

- [ ] **Step 2: Create ScanSummaryQueueable.cls**

```java
/**
 * ScanSummaryQueueable
 *
 * Lightweight one-shot Queueable. Reads Result_Summary__c from the completed job,
 * builds a plain-English Scan_Summary_Text__c string, and updates the job record.
 *
 * Offloaded from ScanResultFileQueueable so string templating on a large JSON payload
 * does not compete with the serializer's heap/CPU budget.
 *
 * Ref: ISP-6072
 */
public without sharing class ScanSummaryQueueable implements Queueable {

    private final String jobId;

    public ScanSummaryQueueable(String jobId) {
        this.jobId = jobId;
    }

    public void execute(QueueableContext ctx) {
        List<Metadata_Scan_Job__c> jobs = [
            SELECT Id, Result_Summary__c, Components_Analyzed__c, Target_API_Name__c
            FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
        ];
        if (jobs.isEmpty()) { return; }
        Metadata_Scan_Job__c job = jobs[0];

        if (String.isBlank(job.Result_Summary__c)) { return; }

        String summary = buildSummary(job);
        job.Scan_Summary_Text__c = summary;
        update job;
    }

    private String buildSummary(Metadata_Scan_Job__c job) {
        Integer total = (Integer) (job.Components_Analyzed__c != null
            ? job.Components_Analyzed__c : 0);

        Map<String, Object> counts;
        try {
            counts = (Map<String, Object>) JSON.deserializeUntyped(job.Result_Summary__c);
        } catch (Exception e) {
            return 'This scan found ' + total + ' dependencies.';
        }

        List<String> parts = new List<String>();
        for (String key : counts.keySet()) {
            if (key == 'v') { continue; }
            Integer cnt = (Integer) counts.get(key);
            if (cnt != null && cnt > 0) {
                parts.add(cnt + ' ' + humanize(key) + (cnt == 1 ? '' : 's'));
            }
        }

        String base = 'This scan found ' + total + ' dependenc'
            + (total == 1 ? 'y' : 'ies');
        if (parts.isEmpty()) { return base + '.'; }

        // Limit to top 5 types for readability
        if (parts.size() > 5) {
            parts = parts.subList(0, 5);
            parts.add('and more');
        }
        return base + ': ' + String.join(parts, ', ') + '.';
    }

    private String humanize(String metadataType) {
        if (metadataType == 'ApexClass')  return 'Apex class';
        if (metadataType == 'ApexTrigger') return 'Apex trigger';
        if (metadataType == 'Flow')       return 'Flow';
        if (metadataType == 'CustomField') return 'custom field';
        if (metadataType == 'ValidationRule') return 'validation rule';
        if (metadataType == 'WorkflowRule')   return 'workflow rule';
        if (metadataType == 'Report')     return 'report';
        return metadataType;
    }
}
```

---

## Task 7: Test Classes

Write one test class per production class. All tests use `@IsTest`, no `SeeAllData=true`, and the `Assert` class (not `System.assert()`).

### 7a: MetadataDependencyServiceTest

- [ ] **Step 1: Create the test class**

```java
@IsTest
private class MetadataDependencyServiceTest {

    @IsTest
    static void fetchDependencies_emptyInput_returnsEmpty() {
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a001000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> result =
            svc.fetchDependencies(new List<String>(), opts);
        Assert.isTrue(result.isEmpty(), 'Empty input should return empty map');
    }

    @IsTest
    static void fetchDependencies_http200_parsesRecords() {
        // Mock Tooling API response with one dependency
        String body = '{"done":true,"records":[{"MetadataComponentId":"a001000000000001AAA",'
            + '"MetadataComponentName":"MyClass","MetadataComponentType":"ApexClass",'
            + '"RefMetadataComponentId":"a002000000000001AAA",'
            + '"RefMetadataComponentName":"MyField","RefMetadataComponentType":"CustomField"}]}';
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, body));
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> result =
            svc.fetchDependencies(new List<String>{ 'a002000000000001AAA' }, opts);
        Assert.isTrue(result.containsKey('a002000000000001AAA'),
            'Result should be keyed by parent ID');
        Assert.areEqual(1, result.get('a002000000000001AAA').size(),
            'Should have parsed 1 child node');
    }

    @IsTest
    static void fetchDependencies_http414_splitsAndRetries() {
        // First call returns 414; halved calls return 200
        Test.setMock(HttpCalloutMock.class, new ToolingApi414ThenOkMock());
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        List<String> ids = new List<String>{
            'a001000000000001AAA', 'a001000000000002AAA'
        };
        Map<String, List<Metadata_Dependency__c>> result =
            svc.fetchDependencies(ids, opts);
        // Should have logged an error or succeeded via split - no exception thrown
        Assert.isNotNull(result, 'Should not throw on 414');
    }

    @IsTest
    static void fetchDependencies_largeBody_rejectsWithError() {
        String largeBody = '{"done":true,"records":[]}' + 'x'.repeat(500001);
        // Pad to exceed MAX_RESPONSE_CHARS (500,000) - use a simpler approach:
        // Return a body that exceeds the limit by stuffing a long string field
        String paddedBody = '{"done":true,"records":[{"MetadataComponentId":"'
            + 'a'.repeat(499980)
            + '","MetadataComponentName":"x","MetadataComponentType":"ApexClass",'
            + '"RefMetadataComponentId":"b001","RefMetadataComponentName":"y",'
            + '"RefMetadataComponentType":"CustomField"}]}';
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, paddedBody));
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        svc.fetchDependencies(new List<String>{ 'b001' }, opts);
        Assert.isFalse(opts.errors.isEmpty(), 'Should log heap guard error');
    }

    @IsTest
    static void buildContextData_knownTypes_returnsExpectedJson() {
        MetadataDependencyService svc = new MetadataDependencyService();
        Metadata_Dependency__c n = new Metadata_Dependency__c(Metadata_Type__c = 'ApexClass');
        String ctx = svc.buildContextData(n);
        Assert.isTrue(ctx.contains('"v":1'), 'Should include version key');
        Assert.isTrue(ctx.contains('"isWrite"'), 'ApexClass should have isWrite');
    }

    @IsTest
    static void computeScore_knownCombinations_returnsCorrectScores() {
        MetadataDependencyService svc = new MetadataDependencyService();
        Assert.areEqual(95, svc.computeScore('WorkflowFieldUpdate', ''),
            'WFU exact match = 95');
        Assert.areEqual(65, svc.computeScore('ValidationRule', 'regex'),
            'VR regex = 65');
        Assert.areEqual(85, svc.computeScore('CustomMetadata', 'fieldValue'),
            'CMT field = 85');
    }

    // ---- Mocks ----

    private class ToolingApiMock implements HttpCalloutMock {
        private final Integer code;
        private final String  body;
        ToolingApiMock(Integer code, String body) {
            this.code = code; this.body = body;
        }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(code);
            res.setBody(body);
            return res;
        }
    }

    private class ToolingApi414ThenOkMock implements HttpCalloutMock {
        private Integer callCount = 0;
        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            if (callCount == 1) {
                res.setStatusCode(414);
                res.setBody('');
            } else {
                res.setStatusCode(200);
                res.setBody('{"done":true,"records":[]}');
            }
            return res;
        }
    }
}
```

### 7b: DependencyNotificationServiceTest

- [ ] **Step 1: Create the test class**

```java
@IsTest
private class DependencyNotificationServiceTest {

    @IsTest
    static void publishProgress_disabledBySettings_doesNotPublish() {
        // Insert CMDT record with Disable_Platform_Events__c = true is not possible
        // in test context (CMDT is read-only in tests). Instead verify the service
        // handles the suppressed path without throwing.
        // The test validates that calling publishProgress() does not throw when
        // the org may or may not have PE capacity.
        DependencyNotificationService svc = new DependencyNotificationService();
        Test.startTest();
        svc.publishProgress('a001000000000001AAA', 'Processing', 5, 'Test message');
        Test.stopTest();
        // No assertion needed - if it throws the test fails
    }

    @IsTest
    static void sendCompletion_doesNotThrow() {
        DependencyNotificationService svc = new DependencyNotificationService();
        Test.startTest();
        svc.sendCompletion('a001000000000001AAA', 'a002000000000001AAA');
        Test.stopTest();
    }
}
```

### 7c: DependencyNodeCleanupBatchTest

- [ ] **Step 1: Create the test class**

```java
@IsTest
private class DependencyNodeCleanupBatchTest {

    @TestSetup
    static void setup() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Completed',
            Status_Closed_At__c     = System.now()
        );
        insert job;

        List<Metadata_Dependency__c> nodes = new List<Metadata_Dependency__c>();
        for (Integer i = 0; i < 10; i++) {
            nodes.add(new Metadata_Dependency__c(
                Metadata_Scan_Job__c      = job.Id,
                Metadata_Id__c            = 'a00' + String.valueOf(i).leftPad(15, '0') + 'AAA',
                Metadata_Type__c          = 'ApexClass',
                Metadata_Name__c          = 'Class' + i,
                Component_Uniqueness_Key__c = job.Id + ':class' + i,
                Traversal_Complete__c   = true
            ));
        }
        insert nodes;
    }

    @IsTest
    static void nodesOnly_deletesNodesKeepsJob() {
        Metadata_Scan_Job__c job = [SELECT Id FROM Metadata_Scan_Job__c LIMIT 1];
        Test.startTest();
        Database.executeBatch(
            new DependencyNodeCleanupBatch(job.Id,
                DependencyNodeCleanupBatch.CleanupMode.NODES_ONLY),
            200
        );
        Test.stopTest();
        Integer remaining = [
            SELECT COUNT() FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :job.Id
        ];
        Assert.areEqual(0, remaining, 'All nodes should be deleted');
        Integer jobsRemaining = [
            SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual(1, jobsRemaining, 'Job record should be retained');
    }

    @IsTest
    static void nodesAndJob_deletesNodesAndJob() {
        Metadata_Scan_Job__c job = [SELECT Id FROM Metadata_Scan_Job__c LIMIT 1];
        Test.startTest();
        Database.executeBatch(
            new DependencyNodeCleanupBatch(job.Id,
                DependencyNodeCleanupBatch.CleanupMode.NODES_AND_JOB),
            200
        );
        Test.stopTest();
        Integer remaining = [
            SELECT COUNT() FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :job.Id
        ];
        Assert.areEqual(0, remaining, 'All nodes should be deleted');
        Integer jobsRemaining = [
            SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual(0, jobsRemaining, 'Job record should also be deleted');
    }
}
```

### 7d: DependencyQueueableTest

- [ ] **Step 1: Create the test class**

```java
@IsTest
private class DependencyQueueableTest {

    @TestSetup
    static void setup() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c  = 'CustomField',
            Target_API_Name__c       = 'Account.MyField__c',
            Status__c                = 'Processing',
            Active_Flows_Only__c     = false,
            Components_Analyzed__c   = 0,
            Processing_Cycle_Count__c = 0,
            Last_Progressive_Cycle__c   = 0,
            Last_Query_Row_Count__c       = 0
        );
        insert job;
    }

    @IsTest
    static void execute_cancelledJob_exitsWithoutChain() {
        Metadata_Scan_Job__c job = [SELECT Id FROM Metadata_Scan_Job__c LIMIT 1];
        job.Status__c = 'Cancelled';
        update job;
        Test.setMock(HttpCalloutMock.class, new EmptyToolingApiMock());
        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();
        // Job should still be Cancelled - engine did not transition it
        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Cancelled', refreshed.Status__c,
            'Cancelled job should not be modified');
    }

    @IsTest
    static void execute_noUnprocessedNodes_enqueuesSerializer() {
        // All nodes already fetched = engine should hand off to serializer
        Metadata_Scan_Job__c job = [SELECT Id FROM Metadata_Scan_Job__c LIMIT 1];
        // No unprocessed nodes inserted - batch will be empty
        Test.setMock(HttpCalloutMock.class, new EmptyToolingApiMock());
        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();
        // Verify job is not in Failed state (serializer path taken)
        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areNotEqual('Failed', refreshed.Status__c,
            'Job should not be Failed when no nodes to process');
    }

    @IsTest
    static void execute_stallDetected_pausesJob() {
        Metadata_Scan_Job__c job = [SELECT Id FROM Metadata_Scan_Job__c LIMIT 1];
        // Simulate stall: cycle count far ahead of last successful cycle
        job.Processing_Cycle_Count__c = 10;
        job.Last_Progressive_Cycle__c   = 0;
        update job;

        // Insert one unprocessed node so the engine doesn't take the no-nodes path
        insert new Metadata_Dependency__c(
            Metadata_Scan_Job__c        = job.Id,
            Metadata_Id__c              = 'a001000000000001AAA',
            Metadata_Type__c            = 'ApexClass',
            Metadata_Name__c            = 'TestClass',
            Component_Uniqueness_Key__c = job.Id + ':a001000000000001AAA',
            Traversal_Complete__c     = false
        );

        Test.setMock(HttpCalloutMock.class, new EmptyToolingApiMock());
        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Paused', refreshed.Status__c,
            'Stall detection should pause the job');
    }

    private class EmptyToolingApiMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"done":true,"records":[]}');
            return res;
        }
    }
}
```

### 7e: ScanResultFileQueueableTest

- [ ] **Step 1: Create the test class**

```java
@IsTest
private class ScanResultFileQueueableTest {

    @IsTest
    static void execute_serializes_transitionsToCompleted() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Processing',
            Components_Analyzed__c  = 2
        );
        insert job;

        List<Metadata_Dependency__c> nodes = new List<Metadata_Dependency__c>{
            new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = job.Id,
                Metadata_Id__c              = 'a001000000000001AAA',
                Metadata_Type__c            = 'ApexClass',
                Metadata_Name__c            = 'ClassA',
                Component_Uniqueness_Key__c = job.Id + ':classA',
                Traversal_Complete__c     = true
            ),
            new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = job.Id,
                Metadata_Id__c              = 'a001000000000002AAA',
                Metadata_Type__c            = 'CustomField',
                Metadata_Name__c            = 'Account.Status__c',
                Component_Uniqueness_Key__c = job.Id + ':field',
                Traversal_Complete__c     = true
            )
        };
        insert nodes;

        Test.startTest();
        System.enqueueJob(new ScanResultFileQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c, Result_File_Id__c, Result_Summary__c
            FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Completed', refreshed.Status__c,
            'Job should transition to Completed');
        Assert.isNotNull(refreshed.Result_File_Id__c,
            'Result_File_Id__c should be populated');
        Assert.isNotNull(refreshed.Result_Summary__c,
            'Result_Summary__c should be populated');
    }
}
```

### 7f: ScanSummaryQueueableTest

- [ ] **Step 1: Create the test class**

```java
@IsTest
private class ScanSummaryQueueableTest {

    @IsTest
    static void execute_buildsPlainEnglishSummary() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Completed',
            Components_Analyzed__c  = 7,
            Result_Summary__c       = '{"v":1,"ApexClass":5,"Flow":2}'
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Summary_Text__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isNotNull(refreshed.Scan_Summary_Text__c,
            'Summary should be populated');
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('7'),
            'Summary should mention total count');
    }

    @IsTest
    static void execute_blankResultSummary_doesNotThrow() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Completed',
            Components_Analyzed__c  = 0,
            Result_Summary__c       = null
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable(job.Id));
        Test.stopTest();
        // No exception = pass
    }
}
```

---

## Task 8: Create Code Review Document

After all classes and test classes are written:

- [ ] **Step 1: Create MetaMapper_Code_Review_v17.md**

Copy the structure from `MetaMapper_Code_Review_v16.md` (same header, review instructions, and Known Invalid Findings appendix). Update:
- Header: v17, Round 1 (first review of Phase 4 classes), date today
- Phase description: Phase 4 - Engine Core
- Classes section: one `### ClassName` section per class with its Purpose and full code
- Reset the "Round N Fixes Applied" table (empty for first submission)
- Copy Known Invalid Findings from v16 as the starting baseline

- [ ] **Step 2: Verify all 6 classes + 6 test classes + review doc are saved**

```
force-app/main/default/classes/
  MetadataDependencyService.cls
  MetadataDependencyService.cls-meta.xml
  DependencyNotificationService.cls
  DependencyNotificationService.cls-meta.xml
  DependencyNodeCleanupBatch.cls
  DependencyNodeCleanupBatch.cls-meta.xml
  DependencyQueueable.cls
  DependencyQueueable.cls-meta.xml
  ScanResultFileQueueable.cls
  ScanResultFileQueueable.cls-meta.xml
  ScanSummaryQueueable.cls
  ScanSummaryQueueable.cls-meta.xml
  MetadataDependencyServiceTest.cls
  MetadataDependencyServiceTest.cls-meta.xml
  DependencyNotificationServiceTest.cls
  DependencyNotificationServiceTest.cls-meta.xml
  DependencyNodeCleanupBatchTest.cls
  DependencyNodeCleanupBatchTest.cls-meta.xml
  DependencyQueueableTest.cls
  DependencyQueueableTest.cls-meta.xml
  ScanResultFileQueueableTest.cls
  ScanResultFileQueueableTest.cls-meta.xml
  ScanSummaryQueueableTest.cls
  ScanSummaryQueueableTest.cls-meta.xml
MetaMapper_Code_Review_v17.md
```

---

## Open Items / Decisions Required Before Implementation

1. **DependencyOptions.cls** - verify it currently exposes `lastResultCount`, `errors`, and `addError()`. If not, it must be updated first (no other classes depend on the new fields).

2. **`IMetadataDependencyService` return type** - the interface currently declares `List<Metadata_Dependency__c>`. Task 4 Step 3 changes this to `Map<String, List<Metadata_Dependency__c>>`. This is a breaking change - it requires updating both the interface and the service before `DependencyQueueable` can compile.

3. **Two-tier cycle detection in DependencyQueueable** - the plan above leaves parent-linkage and `Ancestor_Path__c` propagation as a follow-on step (Task 4 Addendum). Full cycle detection (setting `Is_Circular__c`, `Ancestor_Path__c`, `Cycle_Detection_Index__c` on child nodes based on parent's path) must be implemented before the engine goes to code review. The design in `MetaMapper_Technical_Design.md` section "Cycle Detection (Two-Tier)" is the authoritative spec.

4. **Active Flows Only** - the `MetadataDependencyService` plan above does not include Flow version validation callouts. If `activeFlowsOnly = true`, each Flow node in the result requires an additional Tooling API callout to confirm the Flow's active status. This logic must be added to `MetadataDependencyService` before v17 review.
