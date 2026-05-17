# MetaMapper - Code Review v17

**Project:** MetaMapper - Salesforce Metadata Dependency Scanner  
**Phase:** 4 - Engine Core  
**Review Round:** 17 (first submission for Phase 4)  
**Date:** 2026-05-17

---

Review Instructions
Paste this prompt at the start of your message when submitting to an external AI review tool.

Suggested prompt:
You are a Senior Salesforce Platform Architect with 10+ years of enterprise Salesforce
development experience. You specialize in Apex governor limits, async processing patterns,
security model enforcement, and large data volume (LDV) org design.
 
You are performing a production readiness code review on a Salesforce application called
MetaMapper. The document you are reviewing contains the project background, architecture
decisions, and the full Apex source code for Phase 4 (engine core: Tooling API service,
async traversal engine, result serialization, notification service, node cleanup batch,
and all supporting test classes).
 
Your review must be exhaustive and unforgiving. Do not praise the code. Focus exclusively
on finding problems. Do not tell me what you think I want to hear. If the code is bad,
say so directly.
 
For each issue found, provide:
  - Class name
  - Method or line reference (if applicable)
  - Issue description (clear and specific)
  - Severity: Critical / High / Medium / Low
  - Suggested fix (concrete code or approach, not vague advice)
 
Review against these categories (and any other architecture aspect you see fit):
  - Governor limits: SOQL/DML in loops, callout budget violations, N+1 query patterns
  - Bulk safety: all methods handle bulk inputs correctly, no single-record assumptions
  - Security: correct sharing model, USER_MODE scope, no privilege escalation
  - Error handling: silent catch blocks, missing null checks, exception propagation
  - Salesforce platform specifics: deprecated APIs, incorrect async patterns, DML/callout ordering
  - Performance: unnecessary describe calls, missing static caching, heap waste
  - Architecture: interface contract violations, hidden side effects, single responsibility
  - Completeness: deferred placeholders that represent real production risk
 
IMPORTANT: Before raising any finding, read the "Known Invalid Findings" section at the
end of this document. These are design decisions that have been explicitly chosen and
reviewed. Do not re-raise them.
 
At the end, provide a GO / NO-GO verdict with a one-line justification.


## Project Background

MetaMapper is a 100% native Salesforce application that maps reachable metadata dependencies using the Tooling API. It targets enterprise/LDV orgs where synchronous Governor Limits are a hard constraint. All runtime data stays within the Salesforce trust boundary.

**Architecture summary:**

1. User submits a search via LWC. The `@AuraEnabled` controller creates a `Metadata_Scan_Job__c` record, inserts the root `Metadata_Dependency__c` node, and enqueues `DependencyQueueable`.
2. Each `DependencyQueueable` execution queries a batch of unprocessed nodes, calls the Tooling API via Named Credential, inserts child nodes, marks current nodes processed, and self-chains when governor limits approach.
3. When no unprocessed nodes remain, `ResultSerializerQueueable` serializes all nodes to a `ContentVersion` JSON file, bulk-deletes the node records, and transitions the job to Completed.
4. `ScanSummaryQueueable` is enqueued by `ResultSerializerQueueable` after the Completed transition to build a plain-English summary without competing with the serializer's heap/CPU budget.
5. Supplemental handlers (`CustomFieldHandler`, `ApexClassHandler`, `FlowHandler`) run after each Tooling API batch to fill dependency categories that `MetadataComponentDependency` does not track.

**Phase 4 scope (this review):** The engine core layer - `DependencyOptions`, `IMetadataDependencyService`, `MetadataDependencyService`, `INotificationService`, `DependencyNotificationService`, `DependencyNodeCleanupBatch`, `DependencyQueueable`, `ResultSerializerQueueable`, `ScanSummaryQueueable`, and all six test classes.

---

## Phase 4 Changes

### Round 17 - First Submission

No prior fixes for Phase 4. This is the initial review submission.

---

## Classes

### DependencyOptions

Mutable context object passed to `IMetadataDependencyService.fetchDependencies()`. Consolidates per-callout execution context and accumulates diagnostic errors so the Tooling API layer can continue processing other ID batches after a single-batch failure.

```apex
/**
 * DependencyOptions
 *
 * Mutable context object passed to IMetadataDependencyService.fetchDependencies().
 * Consolidates per-callout execution context and accumulates diagnostic errors.
 *
 * Errors are accumulated here rather than thrown so the Tooling API layer can
 * continue processing other ID batches after a single-batch failure.
 *
 * Ref: ISP-6072
 */
public class DependencyOptions {

    /** ID of the parent Metadata_Scan_Job__c record. */
    public String jobId;

    /**
     * When true, the service validates Flow version status via a secondary callout
     * and drops inactive versions from results.
     */
    public Boolean activeFlowsOnly;

    /**
     * Number of records returned by the most recent Tooling API callout.
     * Updated by MetadataDependencyService after each parseAndFollowQueryMore() call.
     * DependencyQueueable reads this to update Last_Result_Count__c on the job record,
     * which drives the queryMorePossible flag in the guardrail.
     */
    public Integer lastResultCount;

    /** Diagnostic error messages accumulated during fetchDependencies(). */
    public List<String> errors;

    public DependencyOptions() {
        this.activeFlowsOnly  = false;
        this.lastResultCount  = 0;
        this.errors           = new List<String>();
    }

    /**
     * Adds a timestamped diagnostic message to the errors list.
     * The caller (DependencyQueueable) appends these to Error_Status_Message__c
     * after all callouts complete.
     */
    public void addError(String message) {
        errors.add('[' + System.now().format() + '] ' + message);
    }
}
```

---

### IMetadataDependencyService

Interface for the Tooling API dependency service layer. Abstracts callout execution, context data building, and confidence scoring to enable testability via mock injection.

```apex
/**
 * IMetadataDependencyService
 *
 * Interface for the Tooling API dependency service layer.
 * Abstracts callout execution, context data building, and confidence scoring
 * to enable testability via mock injection.
 *
 * Implementations: MetadataDependencyService
 * Consumers: DependencyQueueable
 *
 * Ref: ISP-6072
 */
public interface IMetadataDependencyService {

    /**
     * Executes Tooling API callouts for the given list of Metadata IDs and returns
     * dependency results grouped by parent ID (RefMetadataComponentId).
     *
     * Handles chunking (URL-budget-driven), QueryMore pagination, and reactive
     * HTTP 414/431 split-and-retry internally.
     *
     * @param ids        List of 18-char Tooling API Metadata IDs to query dependencies for
     * @param opts       Mutable options object - errors accumulated via opts.addError()
     * @return           Map<parentMetadataId, List<child Metadata_Dependency__c>>.
     *                   Each child has Metadata_Id__c, Metadata_Type__c, Metadata_Name__c,
     *                   Discovery_Source__c = 'ToolingAPI' pre-populated.
     *                   Parent_Dependency__c is NOT set here - DependencyQueueable sets it
     *                   after looking up the parent's record ID.
     */
    Map<String, List<Metadata_Dependency__c>> fetchDependencies(
        List<String> ids, DependencyOptions opts);

    /**
     * Builds the Component_Attributes__c JSON payload for a given node.
     * Output is type-specific (see CLAUDE.md Pills table).
     * Always includes root "v": 1 version key.
     */
    String buildContextData(Metadata_Dependency__c node);

    /**
     * Returns a 0-100 confidence score for supplemental handler matches.
     */
    Integer computeScore(String handlerType, String matchBasis);
}
```

---

### MetadataDependencyService

Implements `IMetadataDependencyService`. Fetches `MetadataComponentDependency` records from the Tooling API via Named Credential `MetaMapper_Tooling_API`. Handles dynamic URL-budget chunking, QueryMore pagination, HTTP 414/431 reactive split-and-retry (max 5 levels), and heap guard (rejects responses > 500,000 chars before deserialization). Results are keyed by `RefMetadataComponentId` for parent linkage in `DependencyQueueable`.

```apex
/**
 * MetadataDependencyService
 *
 * Implements IMetadataDependencyService. Fetches MetadataComponentDependency records
 * from the Tooling API via Named Credential MetaMapper_Tooling_API.
 *
 * Key behaviours:
 * - Dynamic URL-budget chunking: splits when 80 + (size * 19) > 8000 chars
 * - QueryMore: follows nextRecordsUrl until done = true
 * - HTTP 414/431 reactive split-and-retry (max 5 recursion levels)
 * - Heap guard: rejects response bodies > 500,000 chars before JSON.deserializeUntyped()
 * - Results keyed by RefMetadataComponentId (parent) for DependencyQueueable parent linkage
 *
 * Ref: ISP-6072
 */
public without sharing class MetadataDependencyService implements IMetadataDependencyService {

    private static final Integer URL_BUDGET         = 8000;
    private static final Integer URL_OVERHEAD       = 80;
    private static final Integer ID_CHAR_COST       = 19;
    private static final Integer MAX_SPLIT_DEPTH    = 5;
    private static final Integer MAX_RESPONSE_CHARS = 500000;

    private static final String NAMED_CREDENTIAL  = 'callout:MetaMapper_Tooling_API';
    private static final String API_PATH          = '/services/data/v66.0/tooling/query/?q=';
    private static final String NEXT_RECORDS_PATH = '/services/data/v66.0/tooling/';

    /**
     * Fetches all MetadataComponentDependency records where RefMetadataComponentId is in ids.
     * Returns results grouped by RefMetadataComponentId (the parent Tooling API ID).
     */
    public Map<String, List<Metadata_Dependency__c>> fetchDependencies(
        List<String> ids, DependencyOptions opts
    ) {
        Map<String, List<Metadata_Dependency__c>> results =
            new Map<String, List<Metadata_Dependency__c>>();
        if (ids == null || ids.isEmpty()) {
            return results;
        }
        // Dynamic chunking: split if estimated URL length exceeds budget.
        if (URL_OVERHEAD + (ids.size() * ID_CHAR_COST) > URL_BUDGET) {
            Integer mid = ids.size() / 2;
            mergeMaps(results, fetchDependencies(ids.subList(0, mid), opts));
            mergeMaps(results, fetchDependencies(ids.subList(mid, ids.size()), opts));
            return results;
        }
        mergeMaps(results, fetchWithRetry(ids, opts, 0));
        return results;
    }

    private Map<String, List<Metadata_Dependency__c>> fetchWithRetry(
        List<String> ids, DependencyOptions opts, Integer splitDepth
    ) {
        String idList = '\'' + String.join(ids, '\',\'') + '\'';
        String soql   = 'SELECT MetadataComponentId, MetadataComponentName, MetadataComponentType,'
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
                opts.addError('MetadataDependencyService: HTTP ' + res.getStatusCode()
                    + ' after ' + MAX_SPLIT_DEPTH + ' split attempts ('
                    + ids.size() + ' IDs). Batch skipped.');
                return new Map<String, List<Metadata_Dependency__c>>();
            }
            if (ids.size() == 1) {
                opts.addError('MetadataDependencyService: HTTP ' + res.getStatusCode()
                    + ' on single-ID batch for ' + ids[0] + '. Node skipped.');
                return new Map<String, List<Metadata_Dependency__c>>();
            }
            Integer mid = ids.size() / 2;
            Map<String, List<Metadata_Dependency__c>> combined =
                new Map<String, List<Metadata_Dependency__c>>();
            mergeMaps(combined, fetchWithRetry(ids.subList(0, mid), opts, splitDepth + 1));
            mergeMaps(combined, fetchWithRetry(ids.subList(mid, ids.size()), opts, splitDepth + 1));
            return combined;
        }

        if (res.getStatusCode() != 200) {
            opts.addError('MetadataDependencyService: HTTP ' + res.getStatusCode()
                + ' from Tooling API. Response: ' + res.getBody().left(500));
            return new Map<String, List<Metadata_Dependency__c>>();
        }

        return parseAndFollowQueryMore(res.getBody(), opts, true);
    }

    private Map<String, List<Metadata_Dependency__c>> parseAndFollowQueryMore(
        String responseBody, DependencyOptions opts, Boolean isFirstPage
    ) {
        Map<String, List<Metadata_Dependency__c>> results =
            new Map<String, List<Metadata_Dependency__c>>();

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
                String parentId = (String) r.get('RefMetadataComponentId');
                if (String.isBlank(parentId)) { continue; }
                if (!results.containsKey(parentId)) {
                    results.put(parentId, new List<Metadata_Dependency__c>());
                }
                Metadata_Dependency__c node = buildNode(r, opts);
                if (node != null) {
                    results.get(parentId).add(node);
                }
            }
            // Update lastResultCount with first-page count only.
            // QueryMore follow-up pages must not overwrite it (they return partial pages).
            if (isFirstPage) {
                opts.lastResultCount = records.size();
            }
        }

        Boolean done    = (Boolean) parsed.get('done');
        String  nextUrl = (String)  parsed.get('nextRecordsUrl');

        if (done == false && String.isNotBlank(nextUrl)) {
            mergeMaps(results, followQueryMore(nextUrl, opts));
        }

        return results;
    }

    private Map<String, List<Metadata_Dependency__c>> followQueryMore(
        String nextUrl, DependencyOptions opts
    ) {
        try {
            // nextRecordsUrl format: /services/data/vXX.0/tooling/query/queryId
            // Extract the last segment after /tooling/ and re-append the path prefix.
            String queryPath = nextUrl.substringAfter('/tooling/');
            HttpRequest req = new HttpRequest();
            req.setEndpoint(NAMED_CREDENTIAL + NEXT_RECORDS_PATH + queryPath);
            req.setMethod('GET');
            req.setHeader('Content-Type', 'application/json');
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() == 200) {
                return parseAndFollowQueryMore(res.getBody(), opts, false);
            }
            if (res.getStatusCode() == 400 && res.getBody().containsIgnoreCase('INVALID_QUERY_LOCATOR')) {
                opts.addError('MetadataDependencyService: QueryMore cursor expired. '
                    + 'Batch will be re-queried on next execution.');
            } else {
                opts.addError('MetadataDependencyService: QueryMore HTTP '
                    + res.getStatusCode() + '. Some dependencies may be missing.');
            }
        } catch (Exception e) {
            opts.addError('MetadataDependencyService: QueryMore exception - ' + e.getMessage());
        }
        return new Map<String, List<Metadata_Dependency__c>>();
    }

    private Metadata_Dependency__c buildNode(
        Map<String, Object> r, DependencyOptions opts
    ) {
        String metadataId = (String) r.get('MetadataComponentId');
        if (String.isBlank(metadataId)) {
            opts.addError('MetadataDependencyService: Tooling API record missing MetadataComponentId - skipped.');
            return null;
        }
        Metadata_Dependency__c node = new Metadata_Dependency__c();
        node.Metadata_Id__c          = metadataId;
        node.Metadata_Name__c        = (String) r.get('MetadataComponentName');
        node.Metadata_Type__c        = (String) r.get('MetadataComponentType');
        node.Discovery_Source__c     = 'ToolingAPI';
        node.Dependencies_Fetched__c = false;
        node.Metadata_Scan_Job__c    = opts.jobId;
        return node;
    }

    /**
     * Builds Component_Attributes__c JSON for a node based on its metadata type.
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
     */
    public Integer computeScore(String handlerType, String matchBasis) {
        if (handlerType == 'WorkflowFieldUpdate')                          return 95;
        if (handlerType == 'ValidationRule' && matchBasis == 'regex')      return 65;
        if (handlerType == 'FlexiPage')                                    return 60;
        if (handlerType == 'CustomMetadata' && matchBasis == 'fieldValue') return 85;
        if (handlerType == 'LookupRelationship')                           return 95;
        return 70;
    }

    // Merges src into dest (appends to existing lists rather than overwriting).
    private void mergeMaps(
        Map<String, List<Metadata_Dependency__c>> dest,
        Map<String, List<Metadata_Dependency__c>> src
    ) {
        for (String key : src.keySet()) {
            if (!dest.containsKey(key)) {
                dest.put(key, new List<Metadata_Dependency__c>());
            }
            dest.get(key).addAll(src.get(key));
        }
    }
}
```

---

### INotificationService

Interface for scan progress and completion notifications. Abstracts Platform Event publishing and Custom Notification dispatch to enable testability via mock injection.

```apex
/**
 * INotificationService
 *
 * Interface for scan progress and completion notifications.
 * Abstracts Platform Event publishing and Custom Notification dispatch
 * to enable testability via mock injection.
 *
 * Implementations: DependencyNotificationService
 * Consumers: DependencyQueueable, ResultSerializerQueueable
 *
 * Ref: ISP-6072
 */
public interface INotificationService {

    /**
     * Publishes a Dependency_Scan_Status__e Platform Event for the given job.
     * Called once per Queueable execution - not per inner batch loop iteration.
     * Suppressed automatically when the org has consumed >80% of its daily
     * Platform Event delivery limit; falls back to polling in that case.
     *
     * @param jobId             ID of the Metadata_Scan_Job__c record
     * @param status            Current Status__c value (e.g. 'Processing', 'Completed')
     * @param componentsAnalyzed Running count of components found so far
     * @param message           Human-readable status message for the progress LWC
     */
    void publishProgress(String jobId, String status, Integer componentsAnalyzed, String message);

    /**
     * Sends a Custom Notification (bell icon) and email to the user who initiated
     * the scan when the job transitions to Completed.
     * Called by ResultSerializerQueueable after the Completed transition.
     *
     * @param jobId     ID of the completed Metadata_Scan_Job__c record
     * @param userId    ID of the user to notify (the job owner)
     */
    void sendCompletion(String jobId, String userId);
}
```

---

### DependencyNotificationService

Implements `INotificationService`. Publishes `Dependency_Scan_Status__e` Platform Events with automatic suppression when the org daily PE allocation exceeds 80%. When suppressed, flips `Disable_Platform_Events__c = true` on the CMDT Default record via `Metadata.Operations.enqueueDeployment()` (async, non-DML) and appends a suppression notice to the job's `Error_Status_Message__c`.

```apex
/**
 * DependencyNotificationService
 *
 * Implements INotificationService. Publishes Dependency_Scan_Status__e Platform Events
 * and enforces automatic suppression when the org daily PE allocation exceeds 80%.
 *
 * Auto-suppression path:
 * 1. Checks OrgLimits.getMap().get('DailyStandardVolumePlatformEvents')
 * 2. If > 80% consumed: logs a suppression notice, flips Disable_Platform_Events__c = true
 *    on the MetaMapper_Settings__mdt Default record via Metadata.Operations.enqueueDeployment()
 *    (async, non-DML), and returns without publishing.
 * 3. Suppression notice is appended to the calling context via the returned String - the caller
 *    is responsible for persisting it to Error_Status_Message__c.
 *
 * The CMDT write failure is non-fatal: if the async deployment fails, the OrgLimits check
 * runs again on the next execution and will attempt the write again.
 *
 * Ref: ISP-6072
 */
public without sharing class DependencyNotificationService implements INotificationService {

    private static final Decimal PE_SUPPRESS_THRESHOLD = 0.80;

    /**
     * Publishes one Dependency_Scan_Status__e event for the current Queueable execution.
     * Skips publish if Disable_Platform_Events__c = true, or auto-suppresses if the org
     * daily PE allocation is > 80% consumed.
     *
     * @param jobId   Metadata_Scan_Job__c record ID
     * @param status  Status__c value to publish
     * @param count   Current Components_Analyzed__c value
     * @param msg     Human-readable status message (truncated to 255 chars)
     */
    public void publishProgress(String jobId, String status, Integer count, String msg) {
        MetaMapper_Settings__mdt settings =
            new MetaMapperSettingsProvider().getSettings();

        if (settings.Disable_Platform_Events__c) {
            return;
        }

        if (shouldAutoSuppress()) {
            autoSuppressAndLog(jobId);
            return;
        }

        Dependency_Scan_Status__e evt = new Dependency_Scan_Status__e(
            Scan_Job_Id__c         = jobId,
            Status__c              = status,
            Components_Analyzed__c = count,
            Status_Message__c      = String.isNotBlank(msg) ? msg.left(255) : ''
        );

        List<Database.SaveResult> results =
            EventBus.publish(new List<SObject>{ evt });
        for (Database.SaveResult r : results) {
            if (!r.isSuccess()) {
                System.debug(LoggingLevel.WARN,
                    'DependencyNotificationService.publishProgress: PE publish failed for job '
                    + jobId + ' - ' + r.getErrors()[0].getMessage());
            }
        }
    }

    /**
     * No-op: completion is signalled via Status__c = 'Completed' on the job record.
     * The LWC detects this via Platform Event or polling.
     */
    public void sendCompletion(String jobId, String userId) {
        System.debug(LoggingLevel.INFO,
            'DependencyNotificationService.sendCompletion: job ' + jobId + ' completed.');
    }

    private Boolean shouldAutoSuppress() {
        OrgLimit peLimit =
            OrgLimits.getMap().get('DailyStandardVolumePlatformEvents');
        if (peLimit == null || peLimit.getLimit() == 0) {
            return false;
        }
        return ((Decimal) peLimit.getValue() / peLimit.getLimit()) >= PE_SUPPRESS_THRESHOLD;
    }

    private void autoSuppressAndLog(String jobId) {
        String notice = '[' + System.now().format() + '] Platform Events suppressed - '
            + 'org daily delivery limit >80% consumed. '
            + 'Progress updates switched to polling.';
        System.debug(LoggingLevel.WARN, notice);

        // Flip CMDT flag asynchronously so subsequent executions skip the OrgLimits check.
        // Non-fatal: if the deployment fails, the OrgLimits check runs again next execution.
        try {
            Metadata.CustomMetadata cm = new Metadata.CustomMetadata();
            cm.fullName = 'MetaMapper_Settings__mdt.Default';
            cm.label    = 'Default';
            Metadata.CustomMetadataValue cmv = new Metadata.CustomMetadataValue();
            cmv.field   = 'Disable_Platform_Events__c';
            cmv.value   = true;
            cm.values   = new List<Metadata.CustomMetadataValue>{ cmv };
            Metadata.DeployContainer container = new Metadata.DeployContainer();
            container.addMetadata(cm);
            Metadata.Operations.enqueueDeployment(container, null);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'DependencyNotificationService.autoSuppressAndLog: CMDT write failed - '
                + e.getMessage());
        }

        // Append suppression notice to the job's Error_Status_Message__c.
        // Done via a direct DML update here since this is a fire-and-forget diagnostic.
        try {
            List<Metadata_Scan_Job__c> jobs = [
                SELECT Id, Error_Status_Message__c
                FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
            ];
            if (!jobs.isEmpty()) {
                String existing = jobs[0].Error_Status_Message__c;
                jobs[0].Error_Status_Message__c = String.isBlank(existing)
                    ? notice
                    : (existing + '\n' + notice).left(32768);
                update jobs;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'DependencyNotificationService.autoSuppressAndLog: job update failed - '
                + e.getMessage());
        }
    }
}
```

---

### DependencyNodeCleanupBatch

Batch-deletes `Metadata_Dependency__c` records for a specific job. Called from two paths: `ResultSerializerQueueable` (NODES_ONLY - deletes nodes, retains job record for result file pointer) and `DependencyCleanupBatch` (NODES_AND_JOB - deletes nodes then job record for expired jobs). Uses `CleanupMode` enum instead of a boolean to prevent silent argument-swap bugs. Batch size = `Cleanup_Chunk_Size__c` (default 2,000).

```apex
/**
 * DependencyNodeCleanupBatch
 *
 * Batch-deletes Metadata_Dependency__c records for a specific job.
 * Called from two paths:
 *   - ResultSerializerQueueable (NODES_ONLY): deletes nodes after serialization; retains job record
 *   - DependencyCleanupBatch (NODES_AND_JOB): deletes nodes then job record for expired jobs
 *
 * Uses CleanupMode enum instead of a Boolean parameter to prevent silent argument-swap bugs.
 * Batch size = Cleanup_Chunk_Size__c (default 2,000): leaves 8,000 DML rows headroom
 * for customer automation that may fire on delete events for Metadata_Dependency__c.
 *
 * No inner loops in execute(): each transaction deletes exactly one chunk.
 *
 * Ref: ISP-6072
 */
public without sharing class DependencyNodeCleanupBatch
    implements Database.Batchable<SObject> {

    public enum CleanupMode { NODES_ONLY, NODES_AND_JOB }

    private final String      jobId;
    private final CleanupMode mode;

    public DependencyNodeCleanupBatch(String jobId, CleanupMode mode) {
        this.jobId = jobId;
        this.mode  = mode;
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
            try {
                List<Metadata_Scan_Job__c> jobs = [
                    SELECT Id FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
                ];
                if (!jobs.isEmpty()) {
                    delete jobs;
                }
            } catch (Exception e) {
                // Non-fatal: job record may have already been deleted by a concurrent instance.
                System.debug(LoggingLevel.WARN,
                    'DependencyNodeCleanupBatch.finish: job delete failed for ' + jobId
                    + ' - ' + e.getMessage());
            }
        }
    }
}
```

---

### DependencyQueueable

The MetaMapper async traversal engine. Each execution queries a batch of unprocessed `Metadata_Dependency__c` nodes, calls the Tooling API to fetch their dependencies, deduplicates and inserts new child nodes via external-ID upsert, runs supplemental handlers, and self-chains until no unprocessed nodes remain - at which point it enqueues `ResultSerializerQueueable`. Uses Savepoint/rollback, a seven-limit pre-batch guardrail, a mid-loop CPU+DML guard for high-fan-out nodes, and two-tier cycle detection (scoped DB dedup + `Ancestor_Path__c` bloom-filter confirm).

```apex
/**
 * DependencyQueueable
 *
 * The MetaMapper async traversal engine. Each execution queries a batch of
 * unprocessed Metadata_Dependency__c nodes, calls the Tooling API to fetch their
 * dependencies, deduplicates and inserts new child nodes, runs supplemental
 * handlers, and self-chains until no unprocessed nodes remain - at which point it
 * hands off to ResultSerializerQueueable.
 *
 * Governor strategy:
 *   - Savepoint/rollback so a partial failure never leaves corrupt intermediate state.
 *   - Pre-batch seven-limit guardrail self-chains before exhausting any limit.
 *   - Mid-loop CPU + DML guard catches high-fan-out nodes before the insert list overflows.
 *   - Two-tier cycle detection (scoped DB dedup + Ancestor_Path__c bloom-filter confirm).
 *
 * Runs without sharing - the engine requires reliable internal access regardless of
 * the running user's permissions. User-mode enforcement happens at the controller boundary.
 *
 * Ref: ISP-6072
 */
public without sharing class DependencyQueueable implements Queueable, Database.AllowsCallouts {

    private static final Integer LOG_FIELD_MAX        = 32768;
    private static final Integer SUPP_LOG_THRESHOLD   = 200;
    private static final Integer ANCESTOR_PATH_MAX    = 32000;
    private static final Integer ANCESTOR_PATH_MARGIN = 20;
    private static final Integer DEFAULT_STALL_THRESHOLD = 5;
    private static final Integer DEFAULT_BATCH_SIZE      = 50;
    private static final Integer DEFAULT_DML_RESERVE     = 750;
    private static final Integer QUERYMORE_ROW_THRESHOLD = 1900;

    private final String jobId;
    private final Boolean activeFlowsOnly;
    private final Integer overrideBatchSize;

    /**
     * @param jobId              ID of the Metadata_Scan_Job__c being processed
     * @param activeFlowsOnly    When true, Flow nodes require one extra validation callout each
     * @param overrideBatchSize  null for normal execution; set when resuming at a slower speed
     */
    public DependencyQueueable(String jobId, Boolean activeFlowsOnly, Integer overrideBatchSize) {
        this.jobId             = jobId;
        this.activeFlowsOnly   = activeFlowsOnly == true;
        this.overrideBatchSize = overrideBatchSize;
    }

    /**
     * Savepoint/rollback wrapper. Any uncaught exception in runEngine() rolls back
     * all partial engine work, then updateJobFailed() commits the Failed status in a
     * fresh DML scope so it survives the rollback.
     */
    public void execute(QueueableContext ctx) {
        Savepoint sp = Database.setSavepoint();
        try {
            runEngine();
        } catch (Exception e) {
            Database.rollback(sp);
            updateJobFailed(e.getMessage() + '\n' + e.getStackTraceString());
        }
    }

    private void runEngine() {
        DependencyJobSelector jobSelector  = new DependencyJobSelector();
        DependencyNodeSelector nodeSelector = new DependencyNodeSelector();

        // Step 1 - load job
        Metadata_Scan_Job__c job = jobSelector.getByIdForEngine(jobId);
        if (job == null) {
            return;
        }

        // Step 2 - cancel check (first operation after load)
        if (job.Status__c == 'Cancelled') {
            return;
        }

        // Step 3 - CMDT settings
        MetaMapper_Settings__mdt settings =
            new MetaMapperSettingsProvider().getSettings();

        // Step 4 - resolve batch size: override wins, else Flow-specific vs standard
        Integer batchSize = resolveBatchSize(settings, job);

        // Step 5 - increment cycle counter + stall detection
        Decimal cycles = job.Total_Processing_Cycles__c != null
            ? job.Total_Processing_Cycles__c : 0;
        cycles += 1;
        job.Total_Processing_Cycles__c = cycles;

        Decimal lastSuccess = job.Last_Successful_Cycle__c != null
            ? job.Last_Successful_Cycle__c : 0;
        Integer stallThreshold = settings.Stall_Detection_Threshold__c != null
            ? (Integer) settings.Stall_Detection_Threshold__c : DEFAULT_STALL_THRESHOLD;

        if ((cycles - lastSuccess) >= stallThreshold) {
            job.Status__c = 'Paused';
            job.Error_Status_Message__c = appendToLog(
                job.Error_Status_Message__c,
                'Scan paused: ' + stallThreshold + ' consecutive processing cycles with no '
                + 'progress. A component may have extremely deep or wide dependencies. '
                + 'Resume at a slower speed or with current settings.'
            );
            update job;
            publishSafe('Paused', intOf(job.Components_Analyzed__c),
                'Analysis paused - encountered a complex component.');
            return;
        }

        // Step 6 - node cap check
        Decimal analyzed = job.Components_Analyzed__c != null ? job.Components_Analyzed__c : 0;
        Integer maxComponents = settings.Max_Components__c != null
            ? (Integer) settings.Max_Components__c : 0;
        if (maxComponents > 0 && analyzed >= maxComponents) {
            job.Status__c = 'Paused';
            job.Error_Status_Message__c = appendToLog(
                job.Error_Status_Message__c,
                'Scan paused: node limit of ' + maxComponents + ' reached. This protects '
                + 'your org data storage. Raise Max_Components__c in MetaMapper Settings to continue.'
            );
            update job;
            publishSafe('Paused', intOf(job.Components_Analyzed__c),
                'Analysis paused - node limit reached.');
            return;
        }

        // Step 7 - fetch unprocessed batch
        List<Metadata_Dependency__c> batch = nodeSelector.nextUnprocessed(jobId, batchSize);

        // Step 8 - empty batch: hand off to serializer
        if (batch.isEmpty()) {
            update job; // persist cycle counter
            System.enqueueJob(new ResultSerializerQueueable(jobId));
            return;
        }

        // Step 9 - pre-batch seven-limit guardrail
        Integer flowNodeCount = 0;
        if (activeFlowsOnly) {
            for (Metadata_Dependency__c n : batch) {
                if (n.Metadata_Type__c == 'Flow') {
                    flowNodeCount++;
                }
            }
        }
        Boolean queryMorePossible = job.Last_Result_Count__c != null
            && job.Last_Result_Count__c >= QUERYMORE_ROW_THRESHOLD;

        Integer calloutsRemaining = Limits.getLimitCallouts() - Limits.getCallouts();
        Integer headroom = 1 + (queryMorePossible ? 1 : 0) + flowNodeCount + 4;
        Integer dmlReserve = settings.Dml_Reserve_Rows__c != null
            ? (Integer) settings.Dml_Reserve_Rows__c : DEFAULT_DML_RESERVE;
        Integer dmlRemaining = Limits.getLimitDmlRows() - Limits.getDmlRows();
        Decimal heapPct = (Decimal) Limits.getHeapSize() / Limits.getLimitHeapSize();
        Decimal cpuPct = (Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime();
        Integer queryRowsRemaining = Limits.getLimitQueryRows() - Limits.getQueryRows();
        Integer queriesRemaining = Limits.getLimitQueries() - Limits.getQueries();
        Integer dmlStmtsRemaining = Limits.getLimitDmlStatements() - Limits.getDmlStatements();

        if (calloutsRemaining < headroom
            || dmlRemaining < dmlReserve
            || heapPct >= 0.70
            || cpuPct >= 0.75
            || queryRowsRemaining < 1000
            || queriesRemaining < 10
            || dmlStmtsRemaining < 40) {
            update job; // persist cycle counter before chaining
            System.enqueueJob(new DependencyQueueable(jobId, activeFlowsOnly, overrideBatchSize));
            return;
        }

        // Step 10 - build options + fetch dependencies via Tooling API
        Map<String, Id> metadataIdToRecordId = new Map<String, Id>();
        Map<String, Metadata_Dependency__c> parentByMetadataId =
            new Map<String, Metadata_Dependency__c>();
        List<String> parentIds = new List<String>();
        for (Metadata_Dependency__c parent : batch) {
            if (String.isNotBlank(parent.Metadata_Id__c)) {
                metadataIdToRecordId.put(parent.Metadata_Id__c, parent.Id);
                parentByMetadataId.put(parent.Metadata_Id__c, parent);
                parentIds.add(parent.Metadata_Id__c);
            }
        }

        DependencyOptions opts = new DependencyOptions();
        opts.jobId           = jobId;
        opts.activeFlowsOnly = activeFlowsOnly;
        opts.lastResultCount = 0;

        IMetadataDependencyService service = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> resultsByParent =
            service.fetchDependencies(parentIds, opts);

        // Step 11 - scoped dedup (Tier 1)
        Set<String> currentResultIds = new Set<String>();
        for (String parentMetaId : resultsByParent.keySet()) {
            for (Metadata_Dependency__c child : resultsByParent.get(parentMetaId)) {
                if (String.isNotBlank(child.Metadata_Id__c)) {
                    currentResultIds.add(child.Metadata_Id__c);
                }
            }
        }
        Set<String> alreadyInserted = nodeSelector.dedupForResults(jobId, currentResultIds);

        // Step 12 + 13 - build insert list with Tier 2 cycle detection + mid-loop guard
        List<Metadata_Dependency__c> toUpsert = new List<Metadata_Dependency__c>();
        Set<String> stagedKeys = new Set<String>();
        MetadataDependencyService ctxBuilder = new MetadataDependencyService();
        Boolean midLoopChained = false;

        for (String parentMetaId : resultsByParent.keySet()) {
            if (midLoopChained) {
                break;
            }
            Metadata_Dependency__c parent = parentByMetadataId.get(parentMetaId);
            if (parent == null) {
                continue;
            }
            Id parentRecordId = metadataIdToRecordId.get(parentMetaId);

            for (Metadata_Dependency__c rawChild : resultsByParent.get(parentMetaId)) {
                // Mid-loop CPU + DML guard - a single high-fan-out node can return
                // thousands of children; stop adding before the limit is breached.
                Decimal midCpuPct = (Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime();
                Integer midDmlRemaining = Limits.getLimitDmlRows() - Limits.getDmlRows();
                if (midCpuPct >= 0.75
                    || (midDmlRemaining - toUpsert.size()) < dmlReserve) {
                    midLoopChained = true;
                    break;
                }

                String childId = rawChild.Metadata_Id__c;
                if (String.isBlank(childId)) {
                    continue;
                }

                String uniquenessKey = jobId + ':' + childId;

                // Tier 1 - already inserted in a prior execution: skip entirely.
                if (alreadyInserted.contains(childId)) {
                    continue;
                }
                // De-dup within this execution (same child under multiple parents in one batch).
                if (stagedKeys.contains(uniquenessKey)) {
                    continue;
                }

                Metadata_Dependency__c child = rawChild;
                child.Metadata_Scan_Job__c        = jobId;
                child.Parent_Dependency__c        = parentRecordId;
                child.Component_Uniqueness_Key__c = uniquenessKey;
                child.Dependency_Depth__c =
                    (parent.Dependency_Depth__c != null ? parent.Dependency_Depth__c : 0) + 1;
                if (String.isBlank(child.Discovery_Source__c)) {
                    child.Discovery_Source__c = 'ToolingAPI';
                }

                String parentPath  = parent.Ancestor_Path__c;
                String parentIndex = parent.Cycle_Detection_Index__c;

                // Ancestor path depth guard - capacity protection before building the path.
                Integer parentPathLen = parentPath != null ? parentPath.length() : 0;
                if ((parentPathLen + ANCESTOR_PATH_MARGIN) > ANCESTOR_PATH_MAX) {
                    child.Ancestor_Path__c          = parentPath;
                    child.Cycle_Detection_Index__c  = parentIndex;
                    child.Is_Circular__c            = true;
                    child.Dependencies_Fetched__c   = true;
                    job.Error_Status_Message__c = appendToLog(
                        job.Error_Status_Message__c,
                        'Max ancestor depth exceeded at ' + childId
                        + '; traversal stopped at this node.'
                    );
                    toUpsert.add(child);
                    stagedKeys.add(uniquenessKey);
                    continue;
                }

                // Build child's Ancestor_Path__c (chain of ancestor Metadata_Ids up to parent).
                child.Ancestor_Path__c =
                    (String.isBlank(parentPath) ? '' : parentPath + '|')
                    + parent.Metadata_Id__c;

                // Build child's Cycle_Detection_Index__c (append parent's 6-char prefix).
                String parentPrefix = parent.Metadata_Id__c != null
                    ? parent.Metadata_Id__c.left(6) : '';
                child.Cycle_Detection_Index__c =
                    (String.isBlank(parentIndex) ? '' : parentIndex + '|')
                    + parentPrefix;

                // Tier 2 - bloom-filter pre-screen then authoritative confirmation.
                String childPrefix = childId.left(6);
                Boolean possibleCycle = String.isNotBlank(child.Cycle_Detection_Index__c)
                    && ('|' + child.Cycle_Detection_Index__c + '|')
                        .contains('|' + childPrefix + '|');

                if (possibleCycle) {
                    String authoritativePath = '|' + child.Ancestor_Path__c + '|';
                    if (authoritativePath.contains('|' + childId + '|')) {
                        // Confirmed true ancestry cycle - insert with flags, do not traverse.
                        child.Is_Circular__c          = true;
                        child.Dependencies_Fetched__c = true;
                        child.Component_Attributes__c = mergeCycleAttribute(
                            child.Component_Attributes__c, parent.Metadata_Id__c);
                    }
                }

                // Type-specific context pills (skip if builder returns null).
                if (child.Component_Attributes__c == null) {
                    String ctxData = ctxBuilder.buildContextData(child);
                    if (String.isNotBlank(ctxData)) {
                        child.Component_Attributes__c = ctxData;
                    }
                }

                toUpsert.add(child);
                stagedKeys.add(uniquenessKey);
            }
        }

        // Step 14 - bulk upsert children by external ID
        if (!toUpsert.isEmpty()) {
            upsert toUpsert Component_Uniqueness_Key__c;
        }

        // Step 15 - mark current batch processed
        for (Metadata_Dependency__c parent : batch) {
            parent.Dependencies_Fetched__c = true;
        }
        update batch;

        // Step 16 - update job progress + accumulated callout errors
        Decimal newAnalyzed = analyzed + toUpsert.size();
        job.Components_Analyzed__c = newAnalyzed;
        if (toUpsert.size() > 0) {
            job.Last_Successful_Cycle__c = cycles;
        }
        job.Last_Result_Count__c = opts.lastResultCount != null ? opts.lastResultCount : 0;
        if (opts.errors != null && !opts.errors.isEmpty()) {
            job.Error_Status_Message__c = appendToLog(
                job.Error_Status_Message__c, String.join(opts.errors, '\n'));
        }

        // Step 17 - supplemental handlers (grouped by type)
        Map<String, List<Metadata_Dependency__c>> byType =
            new Map<String, List<Metadata_Dependency__c>>();
        for (Metadata_Dependency__c n : toUpsert) {
            if (n.Is_Circular__c == true) {
                continue; // do not run supplemental scans on cycle-closing nodes
            }
            String t = n.Metadata_Type__c != null ? n.Metadata_Type__c : '';
            if (!byType.containsKey(t)) {
                byType.put(t, new List<Metadata_Dependency__c>());
            }
            byType.get(t).add(n);
        }

        List<Metadata_Dependency__c> allSupplementalNodes = new List<Metadata_Dependency__c>();
        DependencyTypeHandlerFactory factory = new DependencyTypeHandlerFactory();
        for (String metaType : byType.keySet()) {
            IDependencyTypeHandler handler = factory.getHandler(metaType);
            SupplementalResult sr = handler.findSupplemental(jobId, byType.get(metaType));
            if (sr != null) {
                if (sr.nodes != null && !sr.nodes.isEmpty()) {
                    allSupplementalNodes.addAll(sr.nodes);
                    job.Components_Analyzed__c =
                        job.Components_Analyzed__c + sr.nodes.size();
                }
                job.Error_Status_Message__c = sr.appendErrorsSafe(
                    job.Error_Status_Message__c, LOG_FIELD_MAX, SUPP_LOG_THRESHOLD);
            }
        }
        if (!allSupplementalNodes.isEmpty()) {
            upsert allSupplementalNodes Component_Uniqueness_Key__c;
        }

        // Step 18 - persist job state
        update job;

        // Step 19 - one Platform Event per execution (after final commit)
        publishSafe('Processing', intOf(job.Components_Analyzed__c),
            'Analyzing metadata... ' + intOf(job.Components_Analyzed__c) + ' components found so far');

        // Step 20 - self-chain to process the next batch
        System.enqueueJob(new DependencyQueueable(jobId, activeFlowsOnly, overrideBatchSize));
    }

    /**
     * Resolves the effective batch size. Job-level Batch_Size_Override__c (set by
     * resumeJob at a slower speed) wins over the constructor override and CMDT.
     * When activeFlowsOnly is true, the Flow-specific CMDT setting applies.
     */
    private Integer resolveBatchSize(MetaMapper_Settings__mdt settings, Metadata_Scan_Job__c job) {
        if (overrideBatchSize != null && overrideBatchSize > 0) {
            return overrideBatchSize;
        }
        if (job.Batch_Size_Override__c != null && job.Batch_Size_Override__c > 0) {
            return (Integer) job.Batch_Size_Override__c;
        }
        if (activeFlowsOnly && settings.Flow_Scan_Batch_Size__c != null
            && settings.Flow_Scan_Batch_Size__c > 0) {
            return (Integer) settings.Flow_Scan_Batch_Size__c;
        }
        if (settings.Scan_Batch_Size__c != null && settings.Scan_Batch_Size__c > 0) {
            return (Integer) settings.Scan_Batch_Size__c;
        }
        return DEFAULT_BATCH_SIZE;
    }

    /**
     * Merges a {"cycleClosesAt": "<parentMetadataId>"} entry into the child's
     * Component_Attributes__c JSON, preserving any existing keys and the "v" version key.
     */
    private String mergeCycleAttribute(String existingJson, String parentMetadataId) {
        Map<String, Object> attrs;
        if (String.isNotBlank(existingJson)) {
            try {
                attrs = (Map<String, Object>) JSON.deserializeUntyped(existingJson);
            } catch (Exception e) {
                attrs = new Map<String, Object>();
            }
        } else {
            attrs = new Map<String, Object>();
        }
        if (!attrs.containsKey('v')) {
            attrs.put('v', 1);
        }
        attrs.put('cycleClosesAt', parentMetadataId);
        return JSON.serialize(attrs);
    }

    /**
     * Appends a single timestamped diagnostic line to a log field value,
     * capped at the Long Text field maximum.
     */
    private String appendToLog(String existing, String msg) {
        String timestamped = '[' + System.now().format() + '] ' + msg;
        if (String.isBlank(existing)) {
            return timestamped.left(LOG_FIELD_MAX);
        }
        return (existing + '\n' + timestamped).left(LOG_FIELD_MAX);
    }

    private Integer intOf(Decimal d) {
        return d != null ? d.intValue() : 0;
    }

    /**
     * Publishes a Platform Event without letting a publish failure abort the engine.
     * Never swallows the engine's own exceptions - only isolates PE delivery problems.
     */
    private void publishSafe(String status, Integer count, String msg) {
        try {
            new DependencyNotificationService().publishProgress(jobId, status, count, msg);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'DependencyQueueable.publishSafe: PE publish failed for job '
                + jobId + ' - ' + e.getMessage());
        }
    }

    /**
     * Commits the Failed status in a fresh DML scope after a rollback.
     * Skips the update if the job is no longer Processing (a concurrent instance may
     * have already moved it to Completed or Cancelled) to avoid a losing-race overwrite.
     */
    private void updateJobFailed(String errorMsg) {
        try {
            List<Metadata_Scan_Job__c> jobs = [
                SELECT Id, Status__c
                FROM Metadata_Scan_Job__c
                WHERE Id = :jobId
                LIMIT 1
            ];
            if (jobs.isEmpty() || jobs[0].Status__c != 'Processing') {
                return;
            }
            Metadata_Scan_Job__c job = jobs[0];
            job.Status__c              = 'Failed';
            job.Error_Status_Message__c = errorMsg != null
                ? errorMsg.left(LOG_FIELD_MAX) : 'An unexpected error stopped the analysis.';
            job.Status_Closed_At__c    = System.now();
            update job;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'DependencyQueueable.updateJobFailed: could not persist Failed status for job '
                + jobId + ' - ' + e.getMessage());
            return;
        }
        publishSafe('Failed', 0, 'Analysis failed.');
    }
}
```

---

### ResultSerializerQueueable

One-shot Queueable enqueued by the final `DependencyQueueable` execution when traversal is complete. Serializes all `Metadata_Dependency__c` records to a `ContentVersion` JSON file, sets `ContentDocumentLink` visibility to `InternalUsers`, computes `Result_Summary__c`, transitions the job to Completed, launches `DependencyNodeCleanupBatch` (NODES_ONLY), enforces the ring buffer, and enqueues `ScanSummaryQueueable`. Uses Savepoint/rollback; failure is terminal (job transitions to Failed).

```apex
/**
 * ResultSerializerQueueable
 *
 * One-shot Queueable enqueued by DependencyQueueable when traversal is complete.
 *
 * Steps (all guarded by Savepoint/rollback):
 * 1. Heap pre-check: estimates payload size; fails gracefully if too large
 * 2. Queries all Metadata_Dependency__c for the job via DependencyNodeSelector.listByJob()
 * 3. Serializes to JSON and creates ContentVersion (FirstPublishLocationId = jobId)
 * 4. Requeries ContentDocumentId (not populated on the inserted record)
 * 5. Sets ContentDocumentLink ShareType='V', Visibility='InternalUsers'
 * 6. Computes Result_Summary__c (versioned JSON map of {MetadataType: count})
 * 7. Updates job: Result_File_Id__c, Result_Summary__c, Status=Completed, Status_Closed_At__c
 * 8. Launches DependencyNodeCleanupBatch(NODES_ONLY) to delete node records
 * 9. Enforces ring buffer via DependencyJobSelector.getCompletedJobsOldestFirst()
 * 10. Enqueues ScanSummaryQueueable
 *
 * Failure is terminal: on exception the job transitions to Failed.
 * Node records remain for manual export until nightly cleanup.
 *
 * Ref: ISP-6072
 */
// without sharing is intentional: internal engine component invoked asynchronously.
// All user-facing DML is gated at DependencyJobController (WITH USER_MODE).
public without sharing class ResultSerializerQueueable implements Queueable {

    // At ~5KB per node (Ancestor_Path__c + Component_Attributes__c add significant size),
    // the 12MB async heap supports approximately 2,000-3,000 nodes safely.
    // Fail early at 10MB to leave headroom for the serialize + ContentVersion insert operations.
    private static final Integer AVG_BYTES_PER_NODE  = 5000;
    private static final Integer HEAP_SAFETY_CEILING = 10000000; // 10MB of 12MB async limit

    private final String jobId;

    public ResultSerializerQueueable(String jobId) {
        this.jobId = jobId;
    }

    public void execute(QueueableContext ctx) {
        Savepoint sp = Database.setSavepoint();
        try {
            runSerializer();
        } catch (Exception e) {
            Database.rollback(sp);
            updateJobFailed(jobId,
                'ResultSerializerQueueable: ' + e.getMessage()
                + '\n' + e.getStackTraceString());
        }
    }

    // -------------------------------------------------------------------------
    // Private - main serialization flow
    // -------------------------------------------------------------------------

    private void runSerializer() {
        Metadata_Scan_Job__c job = [
            SELECT Id, Status__c, Components_Analyzed__c, Error_Status_Message__c,
                   Target_API_Name__c
            FROM Metadata_Scan_Job__c
            WHERE Id = :jobId
            LIMIT 1
        ];

        // --- 1. Heap pre-check ---
        // Check estimated payload against the async heap ceiling BEFORE fetching nodes.
        // Limits.getHeapSize() does not reflect pending deserialization cost reliably;
        // using Components_Analyzed__c * avgBytesPerNode is the only reliable pre-check.
        Long estimatedBytes = (job.Components_Analyzed__c != null
            ? (Long) job.Components_Analyzed__c : 0L) * AVG_BYTES_PER_NODE;
        if (estimatedBytes > HEAP_SAFETY_CEILING) {
            updateJobFailed(jobId,
                'Scan completed but results could not be saved - result set too large '
                + 'for available heap. Reduce Max_Components__c and run again.');
            return;
        }

        // --- 2. Fetch all nodes ---
        IMetaMapperSettingsProvider settingsProvider = new MetaMapperSettingsProvider();
        MetaMapper_Settings__mdt settings = settingsProvider.getSettings();
        Integer maxComponents = settings.Max_Components__c != null
            ? (Integer) settings.Max_Components__c : 5000;
        // Clamp to selector ceiling so listByJob() never throws a DependencyJobException
        // when an admin raises Max_Components__c above MAX_NODE_QUERY_LIMIT.
        maxComponents = Math.min(maxComponents, DependencyNodeSelector.MAX_NODE_QUERY_LIMIT);

        DependencyNodeSelector nodeSelector = new DependencyNodeSelector();
        List<Metadata_Dependency__c> nodes = nodeSelector.listByJob(jobId, maxComponents);

        // Truncation detection: if result hits the cap, some nodes may be missing.
        // Cap is the lesser of DependencyNodeSelector.MAX_NODE_QUERY_LIMIT and maxComponents.
        Integer effectiveCap = Math.min(DependencyNodeSelector.MAX_NODE_QUERY_LIMIT, maxComponents);
        if (nodes.size() == effectiveCap) {
            String truncMsg = '[' + System.now().format() + '] Node list may be truncated; '
                + 'result size hit the query cap of ' + nodes.size()
                + '. Some nodes may be missing from the exported file.';
            job.Error_Status_Message__c = String.isBlank(job.Error_Status_Message__c)
                ? truncMsg
                : (job.Error_Status_Message__c + '\n' + truncMsg).left(32768);
        }

        // --- 3. Serialize to JSON and create ContentVersion ---
        // FirstPublishLocationId = jobId causes Salesforce to auto-create the
        // ContentDocumentLink tied to the job. Do NOT create the link manually -
        // a manual insert would create a duplicate and fail with a constraint violation.
        String jsonBody = JSON.serialize(nodes);
        ContentVersion cv = new ContentVersion(
            Title                  = 'MetaMapper_' + jobId,
            PathOnClient           = 'MetaMapper_' + jobId + '.json',
            VersionData            = Blob.valueOf(jsonBody),
            FirstPublishLocationId = jobId
        );
        insert cv;

        // --- 4. Requery ContentDocumentId ---
        // ContentDocumentId is NOT available on the inserted ContentVersion record directly.
        // It is populated by Salesforce after insert and must be retrieved via a fresh SOQL query.
        cv = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];

        // --- 5. Set ContentDocumentLink visibility ---
        // ShareType='V' (viewer) and Visibility='InternalUsers' ensure the file is
        // never visible to community or guest users even if a portal is granted access
        // to the job record. Do NOT use 'AllUsers' - that includes portal/community users.
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
        } else {
            String warn = '[' + System.now().format() + '] ContentDocumentLink not found for '
                + cv.ContentDocumentId + '; file visibility may not be restricted to InternalUsers.';
            job.Error_Status_Message__c = (String.isBlank(job.Error_Status_Message__c)
                ? warn : (job.Error_Status_Message__c + '\n' + warn)).left(32768);
        }

        // --- 6. Compute Result_Summary__c ---
        // Versioned envelope: {"v":1, "ApexClass":5, "Flow":3, ...}
        // v key enables the LWC stat tile to handle schema changes gracefully.
        Map<String, Integer> typeCounts = new Map<String, Integer>();
        for (Metadata_Dependency__c n : nodes) {
            String t = String.isNotBlank(n.Metadata_Type__c) ? n.Metadata_Type__c : 'Unknown';
            Integer current = typeCounts.get(t);
            typeCounts.put(t, (current != null ? current : 0) + 1);
        }
        Map<String, Object> summaryEnvelope = new Map<String, Object>{ 'v' => 1 };
        summaryEnvelope.putAll(typeCounts);
        String resultSummary = JSON.serialize(summaryEnvelope);

        // --- 7. Update job to Completed ---
        // Result_Summary__c must be populated BEFORE transitioning to Completed so that
        // ScanSummaryQueueable has data to work with when it reads the job record.
        job.Result_File_Id__c   = cv.ContentDocumentId;
        job.Result_Summary__c   = resultSummary.left(32768);
        job.Status__c           = 'Completed';
        job.Status_Closed_At__c = System.now();
        // Append any truncation notice accumulated above
        update job;

        // --- 8. Delete node records (NODES_ONLY - retain job record for result file pointer) ---
        Database.executeBatch(
            new DependencyNodeCleanupBatch(jobId, DependencyNodeCleanupBatch.CleanupMode.NODES_ONLY),
            2000
        );

        // --- 9. Ring buffer enforcement ---
        // Count AFTER the Completed transition above (inclusive) to avoid off-by-one.
        enforceRingBuffer(settings, job);

        // --- 10. Enqueue plain-English summary generator ---
        System.enqueueJob(new ScanSummaryQueueable(jobId));
    }

    // -------------------------------------------------------------------------
    // Private - ring buffer
    // -------------------------------------------------------------------------

    private void enforceRingBuffer(MetaMapper_Settings__mdt settings, Metadata_Scan_Job__c job) {
        Integer maxStored = settings.Max_Stored_Jobs__c != null
            ? (Integer) settings.Max_Stored_Jobs__c : 5;

        // Count must happen AFTER the Completed transition to include this job.
        // Counting before gives one fewer than the true total, causing an off-by-one
        // that gradually over-retains one extra job.
        Integer completedCount = [
            SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Status__c = 'Completed'
        ];
        if (completedCount <= maxStored) {
            return;
        }

        // getCompletedJobsOldestFirst uses a two-step ORDER BY + FOR UPDATE pattern
        // to serialize concurrent ResultSerializerQueueable executions.
        // Pass maxStored + 10 to ensure the oldest record is always captured when
        // the buffer is slightly over limit.
        DependencyJobSelector jobSelector = new DependencyJobSelector();
        List<Metadata_Scan_Job__c> candidates =
            jobSelector.getCompletedJobsOldestFirst(maxStored + 10);
        if (candidates.isEmpty()) {
            return;
        }

        // Delete the oldest completed job. Failure must NOT fail the serialization job.
        Metadata_Scan_Job__c oldest = candidates[0];
        try {
            if (String.isNotBlank(oldest.Result_File_Id__c)) {
                List<ContentDocument> docs = [
                    SELECT Id FROM ContentDocument
                    WHERE Id = :oldest.Result_File_Id__c
                    LIMIT 1
                ];
                if (!docs.isEmpty()) {
                    delete docs;
                }
            }
            delete oldest;
        } catch (Exception e) {
            // Ring buffer delete failure must NOT fail the current job.
            // Append to Error_Status_Message__c for admin visibility (debug logs may be off).
            String notice = '[' + System.now().format() + '] Ring buffer delete failed for job '
                + oldest.Id + ': ' + e.getMessage();
            job.Error_Status_Message__c = (String.isBlank(job.Error_Status_Message__c)
                ? notice : (job.Error_Status_Message__c + '\n' + notice)).left(32768);
            update job;
            System.debug(LoggingLevel.WARN, notice);
        }
    }

    // -------------------------------------------------------------------------
    // Private - failure transition
    // -------------------------------------------------------------------------

    /**
     * Transitions the job to Failed. Only updates if current Status is Processing
     * to avoid overwriting a Completed or Cancelled status set by a concurrent instance.
     * Does not re-throw so the calling catch block's DML commits cleanly.
     */
    private void updateJobFailed(String jId, String errorMsg) {
        List<Metadata_Scan_Job__c> jobs = [
            SELECT Id, Status__c
            FROM Metadata_Scan_Job__c
            WHERE Id = :jId
            LIMIT 1
        ];
        if (jobs.isEmpty() || jobs[0].Status__c != 'Processing') {
            return;
        }
        jobs[0].Status__c               = 'Failed';
        jobs[0].Error_Status_Message__c = errorMsg.left(32768);
        jobs[0].Status_Closed_At__c     = System.now();
        update jobs;
    }
}
```

---

### ScanSummaryQueueable

Lightweight one-shot Queueable enqueued by `ResultSerializerQueueable` after the Completed transition. Reads `Result_Summary__c`, builds a plain-English `Scan_Summary_Text__c` string, and updates the job record. Offloaded from the serializer so string templating on a large JSON payload does not compete with the serializer's heap/CPU budget.

```apex
/**
 * ScanSummaryQueueable
 *
 * Lightweight one-shot Queueable enqueued by ResultSerializerQueueable after the
 * job transitions to Completed. Reads Result_Summary__c, builds a plain-English
 * Scan_Summary_Text__c string, and updates the job record.
 *
 * Offloaded from ResultSerializerQueueable so string templating on a large JSON
 * payload does not compete with the serializer's heap/CPU budget.
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
            FROM Metadata_Scan_Job__c
            WHERE Id = :jobId
            LIMIT 1
        ];
        if (jobs.isEmpty()) { return; }
        Metadata_Scan_Job__c job = jobs[0];

        if (String.isBlank(job.Result_Summary__c)) { return; }

        job.Scan_Summary_Text__c = buildSummary(job);
        update job;
    }

    private String buildSummary(Metadata_Scan_Job__c job) {
        Integer total = job.Components_Analyzed__c != null
            ? (Integer) job.Components_Analyzed__c : 0;

        Map<String, Object> counts;
        try {
            counts = (Map<String, Object>) JSON.deserializeUntyped(job.Result_Summary__c);
        } catch (Exception e) {
            return 'This scan found ' + total + ' dependenc' + (total == 1 ? 'y' : 'ies') + '.';
        }

        List<String> parts = new List<String>();
        for (String key : counts.keySet()) {
            if (key == 'v') { continue; }
            Object val = counts.get(key);
            Integer cnt = val instanceof Integer ? (Integer) val : Integer.valueOf(String.valueOf(val));
            if (cnt != null && cnt > 0) {
                parts.add(cnt + ' ' + humanize(key) + (cnt == 1 ? '' : 's'));
            }
        }

        String base = 'This scan found ' + total + ' dependenc' + (total == 1 ? 'y' : 'ies');
        if (parts.isEmpty()) { return base + '.'; }

        if (parts.size() > 5) {
            parts = parts.subList(0, 5);
            parts.add('and more');
        }
        return base + ': ' + String.join(parts, ', ') + '.';
    }

    private String humanize(String metadataType) {
        if (metadataType == 'ApexClass')      return 'Apex class';
        if (metadataType == 'ApexTrigger')    return 'Apex trigger';
        if (metadataType == 'Flow')           return 'Flow';
        if (metadataType == 'CustomField')    return 'custom field';
        if (metadataType == 'ValidationRule') return 'validation rule';
        if (metadataType == 'WorkflowRule')   return 'workflow rule';
        if (metadataType == 'Report')         return 'report';
        return metadataType;
    }
}
```

---

## Test Classes

### ResultSerializerQueueableTest

Covers the three primary paths of `ResultSerializerQueueable`: successful serialization with Completed transition, heap pre-check failure with Failed transition, and zero-node completion.

```apex
@IsTest
private class ResultSerializerQueueableTest {

    @IsTest
    static void execute_serializes_transitionsToCompleted() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Processing',
            Components_Analyzed__c  = 2
        );
        insert job;

        insert new List<Metadata_Dependency__c>{
            new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = job.Id,
                Metadata_Id__c              = 'a001000000000001AAA',
                Metadata_Type__c            = 'ApexClass',
                Metadata_Name__c            = 'ClassA',
                Component_Uniqueness_Key__c = job.Id + ':classA',
                Dependencies_Fetched__c     = true
            ),
            new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = job.Id,
                Metadata_Id__c              = 'a001000000000002AAA',
                Metadata_Type__c            = 'CustomField',
                Metadata_Name__c            = 'Account.Status__c',
                Component_Uniqueness_Key__c = job.Id + ':field',
                Dependencies_Fetched__c     = true
            )
        };

        Test.startTest();
        System.enqueueJob(new ResultSerializerQueueable(job.Id));
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
        Assert.isTrue(refreshed.Result_Summary__c.contains('"v":1'),
            'Summary should include version envelope');
    }

    @IsTest
    static void execute_heapPreCheckFails_transitionsToFailed() {
        // Simulate a job that exceeds the heap ceiling: > 10MB / 5000 bytes = > 2000 components
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Processing',
            Components_Analyzed__c  = 3000 // 3000 * 5000 = 15MB > 10MB ceiling
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ResultSerializerQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c, Error_Status_Message__c
            FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Failed', refreshed.Status__c,
            'Job should transition to Failed when heap pre-check fails');
        Assert.isTrue(refreshed.Error_Status_Message__c.contains('too large'),
            'Error message should mention size issue');
    }

    @IsTest
    static void execute_noNodes_completesWithEmptySummary() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Processing',
            Components_Analyzed__c  = 0
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ResultSerializerQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Completed', refreshed.Status__c,
            'Zero-node job should complete successfully');
    }
}
```

---

### DependencyQueueableTest

Covers the four primary engine paths: cancelled job exits without modification, no unprocessed nodes triggers serializer handoff, stall detection pauses the job, and a normal unprocessed node is fetched and marked processed.

```apex
@IsTest
private class DependencyQueueableTest {

    private static Metadata_Scan_Job__c makeJob(String status) {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c    = 'CustomField',
            Target_API_Name__c         = 'Account.MyField__c',
            Status__c                  = status,
            Active_Flows_Only__c       = false,
            Components_Analyzed__c     = 0,
            Total_Processing_Cycles__c = 0,
            Last_Successful_Cycle__c   = 0,
            Last_Result_Count__c       = 0
        );
        insert job;
        return job;
    }

    @IsTest
    static void execute_cancelledJob_exitsWithoutModification() {
        Metadata_Scan_Job__c job = makeJob('Cancelled');
        Test.setMock(HttpCalloutMock.class, new EmptyToolingApiMock());

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Cancelled', refreshed.Status__c,
            'Cancelled job should not be modified by the engine');
    }

    @IsTest
    static void execute_noUnprocessedNodes_enqueuesSerializer() {
        Metadata_Scan_Job__c job = makeJob('Processing');
        Test.setMock(HttpCalloutMock.class, new EmptyToolingApiMock());

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        // Engine took the empty-batch path (enqueues ResultSerializerQueueable).
        // Job should not be Failed.
        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areNotEqual('Failed', refreshed.Status__c,
            'Job should not be Failed when no unprocessed nodes exist');
    }

    @IsTest
    static void execute_stallDetected_pausesJob() {
        Metadata_Scan_Job__c job = makeJob('Processing');
        // Simulate stall: Total_Processing_Cycles far ahead of Last_Successful_Cycle
        job.Total_Processing_Cycles__c = 10;
        job.Last_Successful_Cycle__c   = 0;
        update job;

        // Insert one unprocessed node so engine doesn't take the empty-batch path
        insert new Metadata_Dependency__c(
            Metadata_Scan_Job__c        = job.Id,
            Metadata_Id__c              = 'a001000000000001AAA',
            Metadata_Type__c            = 'ApexClass',
            Metadata_Name__c            = 'TestClass',
            Component_Uniqueness_Key__c = job.Id + ':a001000000000001AAA',
            Dependencies_Fetched__c     = false
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

    @IsTest
    static void execute_withUnprocessedNode_callsToolingApi() {
        Metadata_Scan_Job__c job = makeJob('Processing');

        insert new Metadata_Dependency__c(
            Metadata_Scan_Job__c        = job.Id,
            Metadata_Id__c              = 'a001000000000001AAA',
            Metadata_Type__c            = 'ApexClass',
            Metadata_Name__c            = 'TestClass',
            Component_Uniqueness_Key__c = job.Id + ':a001000000000001AAA',
            Dependencies_Fetched__c     = false
        );

        Test.setMock(HttpCalloutMock.class, new EmptyToolingApiMock());

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        // After processing, the node should be marked fetched
        Metadata_Dependency__c node = [
            SELECT Dependencies_Fetched__c
            FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :job.Id
            LIMIT 1
        ];
        Assert.isTrue(node.Dependencies_Fetched__c,
            'Processed node should be marked Dependencies_Fetched__c = true');
    }

    private class EmptyToolingApiMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"done":true,"totalSize":0,"records":[]}');
            return res;
        }
    }
}
```

---

### MetadataDependencyServiceTest

Covers `fetchDependencies` (null/empty input, HTTP 200 parse, HTTP 414 split exhaustion, HTTP 500 error logging, oversized body heap guard), `buildContextData` (ApexClass, unknown type, null node), and `computeScore` (all five score combinations).

```apex
@IsTest
private class MetadataDependencyServiceTest {

    // ---- fetchDependencies ----

    @IsTest
    static void fetchDependencies_nullInput_returnsEmptyMap() {
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a001000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> result = svc.fetchDependencies(null, opts);
        Assert.isTrue(result.isEmpty(), 'Null input should return empty map');
    }

    @IsTest
    static void fetchDependencies_emptyInput_returnsEmptyMap() {
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a001000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> result =
            svc.fetchDependencies(new List<String>(), opts);
        Assert.isTrue(result.isEmpty(), 'Empty input should return empty map');
    }

    @IsTest
    static void fetchDependencies_http200_parsesRecordKeyedByParent() {
        String body = '{"done":true,"totalSize":1,"records":['
            + '{"MetadataComponentId":"a001000000000001AAA",'
            + '"MetadataComponentName":"MyClass","MetadataComponentType":"ApexClass",'
            + '"RefMetadataComponentId":"a002000000000001AAA",'
            + '"RefMetadataComponentName":"MyField","RefMetadataComponentType":"CustomField"}'
            + ']}';
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, body));

        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> result =
            svc.fetchDependencies(new List<String>{ 'a002000000000001AAA' }, opts);

        Assert.isTrue(result.containsKey('a002000000000001AAA'),
            'Result should be keyed by RefMetadataComponentId');
        Assert.areEqual(1, result.get('a002000000000001AAA').size(),
            'Should have one child node');
        Assert.areEqual('MyClass',
            result.get('a002000000000001AAA')[0].Metadata_Name__c,
            'Node name should match');
        Assert.areEqual(1, opts.lastResultCount,
            'lastResultCount should reflect first page size');
    }

    @IsTest
    static void fetchDependencies_http414_splitsAndReturnsResult() {
        Test.setMock(HttpCalloutMock.class, new ToolingApi414ThenOkMock());
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        List<String> ids = new List<String>{
            'a001000000000001AAA', 'a001000000000002AAA'
        };
        Map<String, List<Metadata_Dependency__c>> result = svc.fetchDependencies(ids, opts);
        Assert.isNotNull(result, 'Should not throw on 414');
        Assert.isFalse(opts.errors.isEmpty(), 'Should log 414 error after max split depth');
    }

    @IsTest
    static void fetchDependencies_http500_logsErrorReturnsEmpty() {
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(500, 'Internal Server Error'));
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> result =
            svc.fetchDependencies(new List<String>{ 'a001000000000001AAA' }, opts);
        Assert.isTrue(result.isEmpty(), 'HTTP 500 should return empty map');
        Assert.isFalse(opts.errors.isEmpty(), 'HTTP 500 should log an error');
    }

    @IsTest
    static void fetchDependencies_largeResponseBody_rejectsWithError() {
        // Build a body that exceeds MAX_RESPONSE_CHARS (500,000)
        String paddedBody = '{"done":true,"totalSize":0,"records":[]}' + 'x'.repeat(500001);
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, paddedBody));
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        svc.fetchDependencies(new List<String>{ 'a001000000000001AAA' }, opts);
        Assert.isFalse(opts.errors.isEmpty(), 'Oversized body should log heap guard error');
    }

    // ---- buildContextData ----

    @IsTest
    static void buildContextData_apexClass_returnsIsWriteJson() {
        MetadataDependencyService svc = new MetadataDependencyService();
        Metadata_Dependency__c n = new Metadata_Dependency__c(Metadata_Type__c = 'ApexClass');
        String ctx = svc.buildContextData(n);
        Assert.isTrue(ctx.contains('"v":1'), 'Should include version key');
        Assert.isTrue(ctx.contains('"isWrite"'), 'ApexClass should have isWrite');
    }

    @IsTest
    static void buildContextData_unknownType_returnsNull() {
        MetadataDependencyService svc = new MetadataDependencyService();
        Metadata_Dependency__c n = new Metadata_Dependency__c(Metadata_Type__c = 'UnknownType');
        Assert.isNull(svc.buildContextData(n), 'Unknown type should return null');
    }

    @IsTest
    static void buildContextData_nullNode_returnsNull() {
        MetadataDependencyService svc = new MetadataDependencyService();
        Assert.isNull(svc.buildContextData(null), 'Null node should return null');
    }

    // ---- computeScore ----

    @IsTest
    static void computeScore_knownCombinations_returnsCorrectScores() {
        MetadataDependencyService svc = new MetadataDependencyService();
        Assert.areEqual(95, svc.computeScore('WorkflowFieldUpdate', ''));
        Assert.areEqual(65, svc.computeScore('ValidationRule', 'regex'));
        Assert.areEqual(60, svc.computeScore('FlexiPage', ''));
        Assert.areEqual(85, svc.computeScore('CustomMetadata', 'fieldValue'));
        Assert.areEqual(95, svc.computeScore('LookupRelationship', ''));
        Assert.areEqual(70, svc.computeScore('Unknown', ''));
    }

    // ---- Mocks ----

    private class ToolingApiMock implements HttpCalloutMock {
        private final Integer code;
        private final String  body;
        ToolingApiMock(Integer code, String body) { this.code = code; this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(code);
            res.setBody(body);
            return res;
        }
    }

    private class ToolingApi414ThenOkMock implements HttpCalloutMock {
        // Always returns 414 to exhaust all split attempts - confirms error logging
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(414);
            res.setBody('');
            return res;
        }
    }
}
```

---

### DependencyNotificationServiceTest

Covers `publishProgress` with a normal message, `publishProgress` with a null message, and `sendCompletion`. Validates that the service handles any org PE state without throwing (CMDT is read-only in tests so `Disable_Platform_Events__c` cannot be injected).

```apex
@IsTest
private class DependencyNotificationServiceTest {

    @IsTest
    static void publishProgress_doesNotThrow() {
        // CMDT is read-only in tests so we cannot inject Disable_Platform_Events__c = true.
        // Validates that the service handles any org PE state without throwing.
        DependencyNotificationService svc = new DependencyNotificationService();
        Test.startTest();
        svc.publishProgress('a001000000000001AAA', 'Processing', 5, 'Test message');
        Test.stopTest();
        // No assertion needed - exception = test failure
    }

    @IsTest
    static void publishProgress_withNullMessage_doesNotThrow() {
        DependencyNotificationService svc = new DependencyNotificationService();
        Test.startTest();
        svc.publishProgress('a001000000000001AAA', 'Completed', 10, null);
        Test.stopTest();
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

---

### DependencyNodeCleanupBatchTest

Covers NODES_ONLY (deletes nodes, retains job record), NODES_AND_JOB (deletes nodes and job record), and no-nodes case (batch completes without error). Uses `@TestSetup` to create one job with 10 nodes shared across all test methods.

```apex
@IsTest
private class DependencyNodeCleanupBatchTest {

    @TestSetup
    static void setup() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Failed',
            Status_Closed_At__c     = System.now()
        );
        insert job;

        List<Metadata_Dependency__c> nodes = new List<Metadata_Dependency__c>();
        for (Integer i = 0; i < 10; i++) {
            nodes.add(new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = job.Id,
                Metadata_Id__c              = 'a00' + String.valueOf(i).leftPad(15, '0') + 'AAA',
                Metadata_Type__c            = 'ApexClass',
                Metadata_Name__c            = 'Class' + i,
                Component_Uniqueness_Key__c = job.Id + ':class' + i,
                Dependencies_Fetched__c     = true
            ));
        }
        insert nodes;
    }

    @IsTest
    static void nodesOnly_deletesNodesKeepsJob() {
        Metadata_Scan_Job__c job = [SELECT Id FROM Metadata_Scan_Job__c LIMIT 1];

        Test.startTest();
        Database.executeBatch(
            new DependencyNodeCleanupBatch(job.Id, DependencyNodeCleanupBatch.CleanupMode.NODES_ONLY),
            200
        );
        Test.stopTest();

        Assert.areEqual(0,
            [SELECT COUNT() FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :job.Id],
            'All nodes should be deleted');
        Assert.areEqual(1,
            [SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Id = :job.Id],
            'Job record should be retained');
    }

    @IsTest
    static void nodesAndJob_deletesNodesAndJob() {
        Metadata_Scan_Job__c job = [SELECT Id FROM Metadata_Scan_Job__c LIMIT 1];

        Test.startTest();
        Database.executeBatch(
            new DependencyNodeCleanupBatch(job.Id, DependencyNodeCleanupBatch.CleanupMode.NODES_AND_JOB),
            200
        );
        Test.stopTest();

        Assert.areEqual(0,
            [SELECT COUNT() FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :job.Id],
            'All nodes should be deleted');
        Assert.areEqual(0,
            [SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Id = :job.Id],
            'Job record should also be deleted');
    }

    @IsTest
    static void noNodes_completesWithoutError() {
        Metadata_Scan_Job__c emptyJob = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'Flow',
            Target_API_Name__c      = 'EmptyFlow',
            Status__c               = 'Completed',
            Status_Closed_At__c     = System.now()
        );
        insert emptyJob;

        Test.startTest();
        Database.executeBatch(
            new DependencyNodeCleanupBatch(emptyJob.Id, DependencyNodeCleanupBatch.CleanupMode.NODES_ONLY),
            200
        );
        Test.stopTest();

        Assert.areEqual(1,
            [SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Id = :emptyJob.Id],
            'Empty job should still exist after nodes-only cleanup');
    }
}
```

---

### ScanSummaryQueueableTest

Covers plain-English summary generation, blank `Result_Summary__c` (no update), invalid JSON fallback, missing job record (no throw), and >5 metadata types truncation to "and more".

```apex
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
        Assert.isNotNull(refreshed.Scan_Summary_Text__c, 'Summary should be populated');
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('7'),
            'Summary should mention total count');
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('Apex class'),
            'Summary should humanize ApexClass');
    }

    @IsTest
    static void execute_blankResultSummary_doesNotUpdate() {
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

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Summary_Text__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isNull(refreshed.Scan_Summary_Text__c,
            'No update should occur when Result_Summary__c is blank');
    }

    @IsTest
    static void execute_invalidJson_fallsBackToSimpleSummary() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Completed',
            Components_Analyzed__c  = 3,
            Result_Summary__c       = 'not-valid-json'
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Summary_Text__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isNotNull(refreshed.Scan_Summary_Text__c, 'Fallback summary should be written');
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('3'),
            'Fallback should include total count');
    }

    @IsTest
    static void execute_jobNotFound_doesNotThrow() {
        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable('a000000000000001AAA'));
        Test.stopTest();
        // No exception = pass
    }

    @IsTest
    static void execute_moreThanFiveTypes_truncatesToFivePlusMore() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Completed',
            Components_Analyzed__c  = 12,
            Result_Summary__c       = '{"v":1,"ApexClass":2,"Flow":2,"CustomField":2,"ValidationRule":2,"WorkflowRule":2,"Report":2}'
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Summary_Text__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('and more'),
            'More than 5 types should append "and more"');
    }
}
```

---

## Known Invalid Findings

The following issues were raised in prior review rounds and are confirmed as non-issues. Do not re-raise them.

| Finding | Why it is not an issue |
|---|---|
| "Use `WITH USER_MODE` in handlers" | Supplemental handlers run in system context intentionally. USER_MODE belongs only at the `@AuraEnabled` controller boundary. Handlers are internal engine classes, not user-facing boundaries. |
| "Static caches in `MetaMapperDescribeCache` and `MetaMapperSettingsProvider` are not thread-safe" | Apex transactions are single-threaded. Each Queueable execution is an independent transaction. Static variables cannot be accessed concurrently within one transaction. This is not a concern. |
| "`DependencyTypeHandlerFactory` should use dependency injection" | The factory already implements the IDependencyTypeHandler interface pattern. Full DI framework is over-engineering for a handler factory with three concrete types. |
| "FlowHandler is empty / not useful" | FlowHandler is a known-gap placeholder that emits a diagnostic notice. Its purpose is to inform admins of the coverage gap, not to perform queries. This is intentional and documented. |
| "Use `instanceof` checks instead of String type comparisons in factory" | The factory uses lowercase String comparison intentionally to handle Tooling API type strings that may vary in casing. `instanceof` does not help here as the type name is a runtime String, not a compile-time type. |
| "`buildNode` should be on a utility class, not `CustomFieldHandler`" | `buildNode` is `public static` on `CustomFieldHandler` and reused by `ApexClassHandler`. Moving it to a third utility class adds an unnecessary dependency hop. The current placement is acceptable until a third handler needs it. |
| "soqlBudgetForCmt / scannedEntities pre-scan estimate" | Removed in Round 11. Both handlers now rely solely on real-time `Limits.getQueries()` guards. |
| "safeLimit stale across field-batch iterations" | Fixed in Round 11. `safeLimit` is now recalculated before each field-batch query inside the loop. |
| "Double-formatting of error strings from sub-results" | Fixed in Round 11. Sub-result errors are merged with `result.errors.addAll()`. |
| "soqlBudgetForCmt assumes 1 query per entity (wrong for field-batched entities)" | Fixed in Round 11. Pre-scan estimate removed entirely. |
| "`buildNode` missing `Ancestor_Path__c` depth guard (H1)" | Fixed in Round 13. `buildNode` returns null when `parentPathLen + 20 > 32000`. All 4 call sites updated with null-check + diagnostic. |
| "`buildNode` missing `Cycle_Detection_Index__c` (H2)" | Fixed in Round 13. `buildNode` now computes and sets pipe-delimited 6-char ID prefixes from `ancestorPath`. |
| "Mid-rule CPU break in `findValidationRuleReferences` is silent (H3)" | Fixed in Round 13. `result.addError()` emitted before `break`. |
| "`findSupplemental` uses `substringAfter` not `substringAfterLast` for field names (H4)" | Fixed in Round 13. Changed to `substringAfterLast('.')`. |
| "`buildNodeByFullName` accepts non-qualified names without dot filter (M2)" | Fixed in Round 13. Added `&& node.Metadata_Name__c.contains('.')`. |
| "`fallbackCpuReported` declared but never read or set (M3)" | Fixed in Round 13. Flag now gates the diagnostic message; reset in `clearCache()`. |
| "`findWorkflowFieldUpdates` passes `wfuId` as uniqueKeySuffix instead of `null` (L1)" | Fixed in Round 13. Changed to `null` following the documented contract. |
| "Sub-methods rebuild lookup maps independently (L3)" | Fixed in Round 13. Maps built once in `findSupplemental` and passed as parameters. |
| "Dead `nodes` parameter in `findCmtRecordReferences` (D1)" | Fixed in Round 14. Parameter removed from signature and call site. |
| "`maxLength` null guard missing in `appendErrorsSafe` (N1)" | Fixed in Round 14. Guard added before `safeLimit` subtraction. |
| "`getCmtEntities` returns up to 2000 rows with no truncation diagnostic (L2D)" | Fixed in Round 14. Size check added; diagnostic appended to `describeFailed` when result count equals LIMIT 2000. |
| "CPU exhaustion in `findValidationRuleReferences` inner field loop not detected (VR-CPU)" | Fixed in Round 14. `vrCpuExceeded` flag added; propagates break from inner loop to outer rule loop. |
| "CPU break in `preloadFieldMaps` only stops inner fallback loop (PL-CPU)" | Fixed in Round 14. `&& !fallbackCpuReported` added to outer chunk loop condition. |
| "Map lookups on raw (un-trimmed) CMT field values (TRIM)" | Fixed in Round 14. `.trim()` applied before lookups in `findCmtRecordReferences` and `ApexClassHandler.scanCmtEntity`. |
| "Truncation floor does not account for `\\n[PRE-TRUNCATED]` notice length (FLOOR)" | Fixed in Round 14. `PRE_TRUNCATION_NOTICE_LENGTH = 16` constant added; floor raised to `TRUNCATION_NOTICE_LENGTH + PRE_TRUNCATION_NOTICE_LENGTH + 4 = 54`. |
| "Cross-execution dedup in `appendErrorsSafe` is O(N×M) (DEDUP)" | Fixed in Round 14. `safeExisting` pre-parsed into `Set<String> existingBaseMsgs` before the loop for O(1) lookups. |
| "`ApexClassHandler.findSupplemental()` does not early-exit when `nodeByClassName` is empty (A)" | Fixed in Round 15. Added `if (nodeByClassName.isEmpty()) { return result; }` after building the map, mirroring `CustomFieldHandler`'s `fieldApiNames.isEmpty()` guard. |
| "`appendErrorsSafe` produces double-truncation notice when existing log is at capacity (E)" | Fixed in Round 15. Pre-truncation path now returns immediately: `return existing.substring(0, safeLimit) + '\n[PRE-TRUNCATED]'`. When the log is full there is no room for new messages; entering the loop served no purpose. |
| "`appendErrorsSafe` has no floor on `safeLimit` for unusually small `maxLength` and no null guard on `maxLength` (F)" | Fixed in Round 15. Added `if (maxLength == null) { maxLength = 131072; }` and `safeLimit = Math.max(0, safeLimit)`. Defensive utility guards - not triggered in production but prevent `StringException` and `NullPointerException` on unusual inputs. |
| "`without sharing` on engine classes is a security risk" | Intentional by design. `DependencyQueueable`, `ResultSerializerQueueable`, `DependencyNodeCleanupBatch`, and `DependencyNotificationService` are internal async engine components. They require reliable system-context access to function regardless of the running user's permissions. USER_MODE is enforced at the `DependencyJobController` boundary only. This is documented in each class header. |
| "`DependencyQueueable` should use `IMetadataDependencyService` reference type (not concrete class) when calling `buildContextData`" | `ctxBuilder` is declared as `MetadataDependencyService` because `buildContextData()` is a concrete utility method not defined on `IMetadataDependencyService` in the current interface contract. The interface exists for `fetchDependencies()` testability. `buildContextData()` is a pure function with no side effects and no callout dependency - it does not need mocking in tests. |
| "`DependencyQueueable` instantiates `MetaMapperSettingsProvider` directly instead of using `IMetaMapperSettingsProvider`" | `IMetaMapperSettingsProvider` is used in `ResultSerializerQueueable` where testability of settings is more critical (serializer behavior changes with `Max_Components__c`). `DependencyQueueable` reads CMDT settings for guardrail thresholds where the defaults are acceptable in test context. Using the concrete class is acceptable here for reduced boilerplate. |
| "Ring buffer does not use `FOR UPDATE` on the COUNT query" | The `FOR UPDATE` is applied in `getCompletedJobsOldestFirst()` on the candidate list query, not on the COUNT. The COUNT is a quick threshold check; if two instances both pass the threshold simultaneously, only one will successfully delete the oldest job (the other will catch a delete error, which is non-fatal). This race window is near-zero in practice for an admin tool. |
| "`sendCompletion` in `DependencyNotificationService` is a no-op" | The method is a placeholder in the current phase. Completion is signalled via `Status__c = 'Completed'` which the LWC detects via Platform Event or polling. A Custom Notification bell implementation is deferred to a future phase. The no-op is intentional and documented. |

---

## Ignored Findings (Round 15 - carried forward from v16)

The following findings from the Round 15 external review were assessed and rejected. Do not re-raise them.

| Source | Finding | Reason for rejection |
|---|---|---|
| ChatGPT | `getCmtEntities()` 2000-row hard cap has no paging or fallback path | Acknowledged design decision. The LIMIT 2000 cap was introduced in Round 14 (L2) specifically to bound query row consumption. A diagnostic is emitted when the cap is reached. Paging `EntityDefinition` adds significant complexity for an edge case that does not occur in the vast majority of orgs (CMT count rarely approaches 2000). This is acceptable as a documented limitation. |
| Gemini | `WorkflowFieldUpdate` is not queryable via standard Apex SOQL | False positive. `WorkflowFieldUpdate` is a setup sObject accessible via standard dynamic SOQL in Apex. The code comment ("not available as a compile-time Apex type in all editions") explains WHY dynamic SOQL is used - to avoid a compile-time type dependency that may not exist in all editions - not because the runtime query would fail. The same pattern is used for `ValidationRule` in the same handler without issue. |
| Gemini | CRLF bug in `appendErrorsSafe` dedup: `safeExisting.split('\n')` leaves trailing `\r` on extracted strings, defeating dedup | False positive. The code uses `safeExisting.contains(baseMsg)` and `existingBaseMsgs.contains(baseMsg)` - not split/set operations. Gemini described code that does not exist. Additionally, `Error_Status_Message__c` is only written by Apex code in MetaMapper (always using `\n`), so CRLF is not possible in this field under normal operation. |
| Gemini | `appendErrorsSafe` produces double-truncation notice when existing log is at capacity | Fixed in Round 15. Pre-truncation path returns immediately. |
| Grok | `IsCustomizable = true` filter in `getCmtEntities()` is wrong for `__mdt` types - returns zero rows | Disputed and likely false positive. Custom Metadata Types (`__mdt`) are designed specifically for customization (adding custom fields is their primary purpose), so `IsCustomizable = true` should be correct for user-defined CMT types. The filter has been in place through 14 prior review rounds without evidence of failure. The filter correctly excludes managed-package CMT types that have `IsCustomizable = false` - which is intentional, since those types typically restrict field access and cannot be queried for record values anyway. |

---

## Round 17 Fixes Applied

The following 21 fixes were applied to Phase 4 source files after the Round 17 external AI review (Gemini, ChatGPT, Claude 5-agent). 11 findings were rejected as false positives or acknowledged design decisions (see Known Invalid Findings above).

| # | File | Fix |
|---|---|---|
| 1 | `DependencyQueueable.cls` | Added `calloutMade` instance boolean; `execute()` catch skips `Database.rollback()` when a callout was already made (rollback throws after callout in same transaction). `updateJobFailed()` always called regardless. |
| 2 | `DependencyQueueable.cls` | Added `fullyProcessedParentMetaIds` tracking. Step 15 now only marks parents as `Dependencies_Fetched__c = true` when their entire child list was iterated without a mid-loop break. Parents with zero Tooling API results are pre-populated as fully processed. |
| 3 | `MetadataDependencyService.cls` | Wrapped `new Http().send(req)` in `try-catch (System.CalloutException)` in `fetchWithRetry()`. Adds error to `opts` and returns empty map on network failure instead of propagating an uncaught exception. |
| 4 | `ResultSerializerQueueable.cls` | Added `job.Status__c != 'Processing'` early-return check at start of `runSerializer()`. Prevents spurious Completed transition if the job was cancelled between `System.enqueueJob()` and this execution. |
| 5 | `DependencyQueueable.cls` | Supplemental nodes deduplicated via `Map<String, Metadata_Dependency__c>` keyed on `Component_Uniqueness_Key__c` before upsert. Prevents `System.ListException: Duplicate id in list` when multiple handlers discover the same child node. |
| 6 | `ResultSerializerQueueable.cls` | Heap pre-check formula changed from `estimatedBytes > 10MB` to `(estimatedBytes * 3) + Limits.getHeapSize() > 11MB`. Accounts for ~3x memory amplification during serialization (SObject list + JSON string + Blob copy) and current heap already consumed. |
| 7 | `DependencyOptions.cls` + `MetadataDependencyService.cls` + `DependencyQueueable.cls` | Added `queryMoreFailed` boolean to `DependencyOptions`. Set to `true` by `followQueryMore()` on `INVALID_QUERY_LOCATOR`. `DependencyQueueable` Step 15 skips marking batch parents as fetched when flag is true, so incomplete batches are re-processed on next execution. |
| 8 | `ResultSerializerQueueable.cls` | Removed `update job` DML call from `enforceRingBuffer()` catch block. A validation rule failure on that update would propagate to the outer savepoint catch and incorrectly fail the current job. Error now logged to `System.debug` only. |
| 9 | `MetadataDependencyService.cls` | Added callout budget guard at top of `followQueryMore()`: skips and logs if fewer than 2 callouts remain. Prevents silent QueryMore truncation when budget is exhausted. |
| 10 | `DependencyQueueable.cls` | Changed `left(6)` to `right(6)` in both `Cycle_Detection_Index__c` building and bloom-filter pre-screen. `left(6)` is the entity key prefix + instance pod (identical for all same-type components in an org), making it useless as a bloom-filter key. `right(6)` uses the unique auto-number portion. |
| 11 | `DependencyQueueable.cls` | Added `midHeapPct >= 0.75` to the mid-loop guard condition alongside the existing CPU and DML checks. Heap can spike significantly inside a high-fan-out inner loop as child nodes are built in memory. |
| 12 | `DependencyQueueable.cls` | Supplemental node counter now filtered against `stagedKeys` before counting: nodes already in `toUpsert` are excluded from the supplemental count to prevent `Components_Analyzed__c` double-counting. |
| 13 | `ScanSummaryQueueable.cls` | Added `humanizePlural(String metadataType, Integer cnt)` helper. Fixes `"Apex class" + "s" = "Apex classs"` pluralization bug. `"ApexClass"` with count > 1 now returns `"Apex classes"`. |
| 14 | `ScanSummaryQueueable.cls` | Wrapped `execute()` body in try-catch with `System.debug` fallback. Added `if (val == null) { continue; }` guard before `Integer.valueOf(String.valueOf(val))` to prevent `NumberFormatException` on null `Result_Summary__c` entries. |
| 15 | `DependencyQueueable.cls` | Restructured `updateJobFailed()`: removed `return` from catch block. `publishSafe('Failed', ...)` is now always called after the try-catch so the Platform Event is published even when the DML status update fails (e.g. permission error, lock timeout). Early return when job is not Processing is preserved. |
| 16 | `MetadataDependencyService.cls` | Added `String body = res.getBody() != null ? res.getBody() : ''` null guard in `fetchWithRetry()` before calling `.left(500)` on the response body. Prevents NPE when Tooling API returns a non-200 with no body. |
| 17 | `MetadataDependencyService.cls` | Added `nextUrl.contains('/tooling/')` validation in `followQueryMore()` before `substringAfter('/tooling/')`. Logs a diagnostic and returns empty map if the URL format is unexpected. |
| 18 | `DependencyNodeCleanupBatch.cls` | Added `Database.emptyRecycleBin(scope)` after `delete scope` in `execute()`. Prevents deleted `Metadata_Dependency__c` records from occupying Data Storage in the Recycle Bin during the retention window. |
| 19 | `DependencyOptions.cls` + `DependencyQueueable.cls` | Changed `System.now().format()` to `System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')` in `DependencyOptions.addError()` and `DependencyQueueable.appendToLog()`. `format()` is locale-dependent; ISO 8601 UTC is deterministic across all org locales. |
| 20 | `MetadataDependencyService.cls` | Added `static` modifier to `mergeMaps()`. It has no instance state dependency; marking it static enforces this and avoids unnecessary instance dispatch overhead. |
| 21 | `MetadataDependencyService.cls` | Applied `String.escapeSingleQuotes()` to each ID in `fetchWithRetry()` before building the SOQL IN clause string. Prevents SOQL injection if a malformed or adversarial ID contains a single-quote character. |
