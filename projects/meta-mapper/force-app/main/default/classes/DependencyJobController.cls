/**
 * DependencyJobController
 *
 * @AuraEnabled controller for all MetaMapper LWC interactions. Enforces WITH USER_MODE
 * on all SOQL/DML so FLS and CRUD are respected for the running user.
 *
 * Entry-point guards (all in createJob()):
 *   - Async context guard: blocks invocation from Batch, Future, or Queueable contexts
 *   - Concurrency guard: rejects new jobs when active DependencyQueueable count >= Max_Concurrent_Jobs__c
 *   - Storage check: rejects when free Data Storage < Min_Free_Storage_MB__c
 *   - Input validation: required fields, supported metadata types
 *
 * getNodeHierarchy() routing:
 *   - Status = Completed  -> reads result JSON from ContentVersion (node records deleted)
 *   - All other statuses  -> queries live Metadata_Dependency__c records directly
 *
 * Must NOT be called from any async context. All engine-internal DML runs in SYSTEM_MODE
 * via the Queueable chain. This class is the sole user-mode boundary.
 *
 *
 */
public with sharing class DependencyJobController {

    // -----------------------------------------------------------------------
    // JobStatusResult wrapper
    // -----------------------------------------------------------------------

    /**
     * Returned by getJobStatus() so the LWC receives both the job record and the
     * Should_Disable_Platform_Events__c settings flag in a single callout. The flag tells
     * the LWC whether to activate polling fallback instead of waiting for PE events.
     */
    public class JobStatusResult {
        @AuraEnabled public Metadata_Scan_Job__c job;
        @AuraEnabled public Boolean peSuppressionActive;
        @AuraEnabled public Integer batchSizeInUse;
        @AuraEnabled public Integer maxComponentsCap;
        @AuraEnabled public Integer retentionHours;

        public JobStatusResult(Metadata_Scan_Job__c job, Boolean platformEventsDisabled, Integer batchSize, Integer maxCap, Integer retentionHrs) {
            this.job                = job;
            this.peSuppressionActive = platformEventsDisabled;
            this.batchSizeInUse     = batchSize;
            this.maxComponentsCap   = maxCap;
            this.retentionHours     = retentionHrs;
        }
    }

    // ---- createJob() constants ----
    private static final String STATUS_INITIALIZING = 'Initializing';

    // IsSandbox is immutable for the lifetime of a transaction; cache it to avoid
    // re-issuing a SOQL query on every createJob() call in the same transaction.
    private static Boolean isSandboxCached;

    // ---- getObjectList() ----
    private static final Integer OBJECT_LIST_LIMIT = 10;

    // ---- Supported metadata types (for input validation) ----
    private static final Set<String> SUPPORTED_TYPES = new Set<String>{
        'ApexClass', 'ApexTrigger', 'Flow', 'CustomField',
        'ValidationRule', 'WorkflowRule', 'Report'
    };

    // -----------------------------------------------------------------------
    // createJob
    // -----------------------------------------------------------------------

    /**
     * Creates a new Metadata_Scan_Job__c, inserts the root Metadata_Dependency__c,
     * and enqueues DependencyQueueable to begin traversal.
     *
     * @param metadataType    API type name (e.g. ApexClass, CustomField)
     * @param apiName         Developer name of the target component
     * @param targetObject    Parent object API name (required for CustomField)
     * @param activeFlowsOnly When true, Flow traversal skips inactive versions
     * @return                Id of the created Metadata_Scan_Job__c
     */
    @AuraEnabled
    public static Id createJob(
        String  metadataType,
        String  apiName,
        String  targetObject,
        Boolean activeFlowsOnly
    ) {
        // ---- Async context guard ----
        if (System.isQueueable() || System.isBatch() || System.isFuture()) {
            throw new DependencyJobException(
                'MetaMapper scans can only be started from a Lightning page. '
                + 'Invocation from Batch, Future, or Queueable contexts is not supported.'
            );
        }

        // ---- Input validation ----
        if (String.isBlank(metadataType) || String.isBlank(apiName)) {
            throw new DependencyJobException('Metadata type and API name are required.');
        }
        if (!SUPPORTED_TYPES.contains(metadataType)) {
            throw new DependencyJobException(
                'Unsupported metadata type: ' + metadataType
                + '. Supported types: ' + String.join(new List<String>(SUPPORTED_TYPES), ', ')
            );
        }
        if (metadataType == 'CustomField' && String.isBlank(targetObject)) {
            throw new DependencyJobException(
                'Target Object is required when scanning a CustomField.'
            );
        }

        // ---- Read CMDT settings ----
        MetaMapper_Settings__mdt settings = new MetaMapperSettingsProvider().getSettings();

        // ---- Sandbox detection: apply conservative first-install defaults when no admin
        //      has explicitly saved settings (Has_Admin_Customized__c = false). ----
        // Developer Sandbox has a 200MB hard Data Storage limit. Concurrent active scans
        // can simultaneously peak storage; one at a time keeps the peak bounded.
        // These overrides apply only in memory for this job submission - CMDT is not mutated.
        Boolean sandboxOverrideActive = false;
        if (settings.Has_Admin_Customized__c != true) {
            try {
                if (isSandboxCached == null) {
                    Organization org = [SELECT IsSandbox FROM Organization LIMIT 1];
                    isSandboxCached = org.IsSandbox == true;
                }
                sandboxOverrideActive = isSandboxCached;
            } catch (Exception e) {
                // Silently fall through to production defaults if the query fails.
                System.debug(LoggingLevel.WARN,
                    'DependencyJobController.createJob: IsSandbox query failed - '
                    + e.getMessage() + '. Using production defaults.');
            }
        }

        // ---- Concurrency guard (two-check TOCTOU narrowing) ----
        MetadataScanJobSelector jobSelector = new MetadataScanJobSelector();
        // Sandbox: limit to 1 concurrent job to bound peak Data Storage.
        Integer maxConcurrent = sandboxOverrideActive ? 1
            : (settings.Max_Concurrent_Jobs__c != null ? ((Decimal) settings.Max_Concurrent_Jobs__c).intValue() : 2);
        // Primary: count active Queueable jobs in AsyncApexJob (indexed by ApexClassId).
        Integer activeCount = jobSelector.countActiveQueueables(maxConcurrent);
        if (activeCount >= maxConcurrent) {
            throw new DependencyJobException(
                'Another MetaMapper scan is already running in this org. '
                + 'Wait for it to complete before starting a new one.'
            );
        }
        // Secondary soft lock: count job records in Initializing or Processing state.
        // Narrows the TOCTOU race window between the AsyncApexJob count and job insertion.
        Integer activeJobCount = jobSelector.countActiveJobRecords(maxConcurrent);
        if (activeJobCount >= maxConcurrent) {
            throw new DependencyJobException(
                'Another MetaMapper scan is already running in this org. '
                + 'Wait for it to complete before starting a new one.'
            );
        }

        // ---- Storage check ----
        OrgLimit storageLimit = OrgLimits.getMap().get('DataStorageMB');
        if (storageLimit != null) {
            Long freeStorageMB = storageLimit.getLimit() - storageLimit.getValue();
            // Sandbox: 50MB reserve (matches the scan peak for Max_Components__c = 5000).
            // Production: 200MB reserve to protect production data from scan peaks.
            Integer reserveMB = sandboxOverrideActive ? 50
                : (settings.Min_Free_Storage_MB__c != null ? ((Decimal) settings.Min_Free_Storage_MB__c).intValue() : 200);
            if (freeStorageMB < reserveMB) {
                throw new DependencyJobException(
                    'Not enough data storage to start a scan. '
                    + 'Free up storage or reduce the retention window in MetaMapper Settings.'
                );
            }
        }

        // ---- Create job record (WITH USER_MODE enforces FLS/CRUD) ----
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = metadataType,
            Target_API_Name__c      = apiName,
            Target_Parent_Object__c        = targetObject,
            Only_Include_Active_Flows__c    = activeFlowsOnly == true,
            Status__c               = STATUS_INITIALIZING,
            Job_Type__c             = 'Dependency_Map',
            Components_Analyzed__c  = 0,
            Processing_Cycle_Count__c = 0,
            Last_Progress_Cycle__c   = 0,
            Last_Query_Row_Count__c       = 0
        );
        insert as user job;

        // ---- Insert root node (separate DML - self-referential lookup constraint) ----
        // For CustomField, build "Object.Field" only when apiName doesn't already include the prefix.
        String fullApiName = (metadataType == 'CustomField' && String.isNotBlank(targetObject)
                && !apiName.startsWith(targetObject + '.'))
            ? targetObject + '.' + apiName
            : apiName;
        // Metadata_Id__c is left blank for the root node intentionally.
        // The validation rule Metadata_Id_Must_Be_18_Characters uses ISBLANK(Metadata_Id__c) as a guard
        // so that root (inserted without a Tooling API ID) passes the 18-char length check.
        // The engine populates Metadata_Id__c on the root node after the first Tooling API
        // callout resolves the component's real ID.
        Metadata_Dependency__c rootNode = new Metadata_Dependency__c(
            Metadata_Scan_Job__c        = job.Id,
            Metadata_Type__c            = metadataType,
            Metadata_Name__c            = fullApiName,
            Dependency_Depth__c         = 0,
            Has_Fetched_Dependencies__c   = false,
            Is_Circular__c              = false,
            Is_Dynamic_Reference__c     = false,
            Discovery_Source__c         = 'ToolingAPI',
            Ancestor_Path__c            = '',
            Unique_Component_Key__c = job.Id + ':root'
        );
        insert as user rootNode;

        // ---- Enqueue engine ----
        System.enqueueJob(new DependencyQueueable(
            job.Id,
            activeFlowsOnly == true,
            null
        ));

        return job.Id;
    }

    // -----------------------------------------------------------------------
    // getComponentCount
    // -----------------------------------------------------------------------

    /**
     * Returns an estimated complexity bucket for the given component API name by
     * counting MetadataComponentDependency rows. Used by the LWC to show a
     * non-blocking "Estimated scan scope" preview before the user submits.
     *
     * Bucket thresholds: 0-100 = Small, 101-500 = Medium, 501-2000 = Large, >2000 = Very Large.
     * Returns null (not an exception) on any error - the LWC suppresses the preview silently.
     *
     * @param apiName  Developer name of the component to preview
     * @return         Bucket label string, or null if unavailable
     */
    @AuraEnabled(cacheable=true)
    public static String getComponentCount(String apiName) {
        if (String.isBlank(apiName)) {
            return null;
        }
        try {
            Integer count = [
                SELECT COUNT()
                FROM MetadataComponentDependency
                WHERE RefMetadataComponentId IN (
                    SELECT MetadataComponentId
                    FROM MetadataComponentDependency
                    WHERE MetadataComponentId.Name = :apiName // bind variable prevents SOQL injection on user-supplied input
                )
                WITH USER_MODE
            ];
            if (count <= 100)  { return 'Small'; }
            if (count <= 500)  { return 'Medium'; }
            if (count <= 2000) { return 'Large'; }
            return 'Very Large';
        } catch (Exception e) {
            return null;
        }
    }

    // -----------------------------------------------------------------------
    // isCopilotEnabled
    // -----------------------------------------------------------------------

    /**
     * Returns true if Einstein Copilot is available in this org for the running user.
     * Used by the LWC to conditionally render the "Ask Copilot" button on the AI Summary card.
     * Cached for the component lifetime - called once on mount.
     *
     * @return  true when the Einstein_Copilot custom permission is assigned to the running user
     */
    @AuraEnabled(cacheable=true)
    public static Boolean isCopilotEnabled() {
        return FeatureManagement.checkPermission('Einstein_Copilot');
    }

    // -----------------------------------------------------------------------
    // getJobStatus
    // -----------------------------------------------------------------------

    /**
     * Returns the current state of a scan job for LWC progress polling and
     * post-completion rendering.
     *
     * @param jobId  Id of the Metadata_Scan_Job__c record
     * @return       The job record with all UI-relevant fields
     */
    @AuraEnabled(cacheable=false)
    public static JobStatusResult getJobStatus(Id jobId) {
        Metadata_Scan_Job__c statusJob = new MetadataScanJobSelector().getByIdForStatusView(jobId);
        if (statusJob == null) {
            return null;
        }
        MetaMapper_Settings__mdt settings = new MetaMapperSettingsProvider().getSettings();
        Boolean platformEventsDisabled = settings.Should_Disable_Platform_Events__c == true
            || statusJob.Is_Platform_Events_Auto_Suppressed__c == true;
        Integer batchSizeInUse = statusJob.Batch_Size_Override__c != null
            ? ((Decimal) statusJob.Batch_Size_Override__c).intValue()
            : (settings.Scan_Batch_Size__c != null ? ((Decimal) settings.Scan_Batch_Size__c).intValue() : 50);
        Integer maxComponentsCap = settings.Max_Components__c != null ? ((Decimal) settings.Max_Components__c).intValue() : 0;
        Integer retentionHrs = settings.Retention_Hours__c != null ? ((Decimal) settings.Retention_Hours__c).intValue() : 72;
        return new JobStatusResult(statusJob, platformEventsDisabled, batchSizeInUse, maxComponentsCap, retentionHrs);
    }

    // -----------------------------------------------------------------------
    // getNodeHierarchy
    // -----------------------------------------------------------------------

    /**
     * Returns the flat dependency node list for a job. Routes between two data sources:
     *   - Completed jobs: deserializes the result JSON from ContentVersion
     *     (Metadata_Dependency__c records no longer exist after serialization)
     *   - All other statuses: queries Metadata_Dependency__c records directly
     *     (partial nodes for in-progress, Paused, Cancelled, and Failed jobs)
     *
     * Both paths return the same List<Metadata_Dependency__c> shape so the LWC
     * does not need to distinguish between them.
     *
     * @param jobId  Id of the Metadata_Scan_Job__c record
     * @return       Flat list of dependency nodes
     */
    @AuraEnabled(cacheable=false)
    public static List<Metadata_Dependency__c> getNodeHierarchy(Id jobId) {
        Metadata_Scan_Job__c job = new MetadataScanJobSelector().getByIdForStatusView(jobId);
        if (job == null) {
            throw new DependencyJobException('Scan job not found: ' + jobId);
        }

        // ---- Completed: read from ContentVersion ----
        if (job.Status__c == 'Completed') {
            if (String.isBlank(job.Result_File_Id__c)
                || job.Result_File_Id__c.length() != 18
                || !job.Result_File_Id__c.startsWith('069')) {
                throw new DependencyJobException(
                    'The result file for this scan could not be found. It may have been deleted. Start a new scan.'
                );
            }
            ContentVersion cv = new MetadataDependencySelector().getResultFile(
                jobId, job.Result_File_Id__c
            );
            if (cv == null || cv.VersionData == null) {
                throw new DependencyJobException(
                    'The scan result file could not be loaded. It may have been deleted.'
                );
            }
            String json = cv.VersionData.toString();
            try {
                return (List<Metadata_Dependency__c>) JSON.deserialize(
                    json, List<Metadata_Dependency__c>.class
                );
            } catch (Exception e) {
                throw new DependencyJobException(
                    'The scan result file could not be loaded. It may have been deleted.'
                );
            }
        }

        // ---- All other statuses: query live records ----
        List<Metadata_Dependency__c> nodes =
            new MetadataDependencySelector().getNodeHierarchyForJob(jobId);
        if (nodes.size() == MetadataDependencySelector.MAX_NODE_QUERY_LIMIT) {
            writeQueryCapWarning(jobId);
        }
        return nodes;
    }

    /**
     * Appends a query-cap warning to the job's diagnostic log when the live node
     * query returns the maximum allowed rows. Extracted from getNodeHierarchy() so
     * that the public @AuraEnabled method itself contains no DML.
     */
    private static void writeQueryCapWarning(Id jobId) {
        try {
            Metadata_Scan_Job__c logTruncJob = new MetadataScanJobSelector().getByIdForLogAppend(jobId);
            if (logTruncJob != null) {
                String notice = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] '
                    + 'WARNING: result set hit the query cap of '
                    + MetadataDependencySelector.MAX_NODE_QUERY_LIMIT
                    + ' nodes. Some nodes may be missing from the live view. '
                    + 'Download the result file for the complete dataset.';
                logTruncJob.Scan_Diagnostic_Log__c = SupplementalScanResult.appendNoticeSafe(
                    logTruncJob.Scan_Diagnostic_Log__c, notice);
                update as user logTruncJob;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'DependencyJobController.writeQueryCapWarning: truncation notice write failed - '
                + e.getMessage());
        }
    }

    // -----------------------------------------------------------------------
    // getObjectList
    // -----------------------------------------------------------------------

    /**
     * Returns matching EntityDefinition records for the object typeahead on the
     * search form. Used when metadataType = CustomField to let the user pick a
     * parent object.
     *
     * @param searchTerm  Partial API name typed by the user (debounced 300 ms in LWC)
     * @return            Up to 10 matching EntityDefinition records
     */
    @AuraEnabled(cacheable=false)
    public static List<EntityDefinition> getObjectList(String searchTerm) {
        if (searchTerm == null || searchTerm.trim().length() < 2) {
            return new List<EntityDefinition>();
        }
        String term = String.escapeSingleQuotes(searchTerm.trim()) + '%';
        return [
            SELECT QualifiedApiName, Label
            FROM EntityDefinition
            WHERE QualifiedApiName LIKE :term
            AND IsCustomizable = true
            WITH USER_MODE
            ORDER BY QualifiedApiName ASC
            LIMIT :OBJECT_LIST_LIMIT
        ];
    }

    // -----------------------------------------------------------------------
    // cancelJob
    // -----------------------------------------------------------------------

    /**
     * Transitions a running job to Cancelled. DependencyQueueable checks Status__c
     * on entry and exits cooperatively when it sees Cancelled - there is no force-kill.
     *
     * @param jobId  Id of the Metadata_Scan_Job__c to cancel
     */
    @AuraEnabled
    public static void cancelJob(Id jobId) {
        // Explicit FLS pre-check: 'update as user' raises a generic exception when any
        // field in the record lacks FLS edit. Pre-checking gives the user (and admin) a
        // precise diagnostic instead of a misleading "insufficient permissions" catch-all.
        Map<String, Schema.SObjectField> fieldMap =
            Schema.sObjectType.Metadata_Scan_Job__c.fields.getMap();
        if (!fieldMap.get('Status__c').getDescribe().isUpdateable()
            || !fieldMap.get('Status_Closed_At__c').getDescribe().isUpdateable()) {
            throw new DependencyJobException(
                'Unable to cancel: your permission set lacks field-level edit access to '
                + 'Status__c or Status_Closed_At__c on Metadata_Scan_Job__c. '
                + 'Ask your admin to verify both fields are editable in the MetaMapper_Admin permission set.'
            );
        }
        try {
            // Read current status FOR UPDATE before writing to prevent overwriting a
            // Completed or Failed job that raced to a terminal state after the cancel click.
            List<Metadata_Scan_Job__c> jobs = [
                SELECT Id, Status__c
                FROM Metadata_Scan_Job__c
                WHERE Id = :jobId
                WITH USER_MODE
                LIMIT 1
                FOR UPDATE
            ];
            if (jobs.isEmpty()) {
                throw new DependencyJobException('Job not found or you do not have access to it.');
            }
            String currentStatus = jobs[0].Status__c;
            if (currentStatus == 'Completed' || currentStatus == 'Failed' || currentStatus == 'Cancelled') {
                return; // Already terminal - nothing to cancel.
            }
            Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
                Id        = jobId,
                Status__c = 'Cancelled',
                Status_Closed_At__c = System.now()
            );
            update as user job;
        } catch (DependencyJobException e) {
            throw e;
        } catch (Exception e) {
            throw new DependencyJobException(
                'Unable to cancel: insufficient permissions to update job status. '
                + 'Contact your admin.'
            );
        }
    }

    // -----------------------------------------------------------------------
    // resumeJob
    // -----------------------------------------------------------------------

    /**
     * Resumes a Paused job and enqueues a new DependencyQueueable instance.
     * Writes the batch size override to Batch_Size_Override__c on the job record
     * (persisted so each self-chain picks it up; does NOT write back to CMDT).
     *
     * @param jobId              Id of the Paused Metadata_Scan_Job__c
     * @param overrideBatchSize  Batch size for the resumed run; null = use CMDT default
     */
    @AuraEnabled
    public static void resumeJob(Id jobId, Integer overrideBatchSize) {
        // Explicit FLS pre-check: 'update as user' raises a generic exception when any
        // field lacks FLS edit. Pre-checking gives a precise diagnostic message.
        Map<String, Schema.SObjectField> fieldMap =
            Schema.sObjectType.Metadata_Scan_Job__c.fields.getMap();
        if (!fieldMap.get('Status__c').getDescribe().isUpdateable()
            || !fieldMap.get('Batch_Size_Override__c').getDescribe().isUpdateable()
            || !fieldMap.get('Last_Progress_Cycle__c').getDescribe().isUpdateable()
            || !fieldMap.get('Pause_Reason__c').getDescribe().isUpdateable()) {
            throw new DependencyJobException(
                'Unable to resume: your permission set lacks field-level edit access to '
                + 'Status__c, Batch_Size_Override__c, Last_Progress_Cycle__c, or Pause_Reason__c. '
                + 'Ask your admin to verify these fields are editable in the MetaMapper_Admin permission set.'
            );
        }

        // Row-locked read + in-lock re-verification prevents two concurrent resumeJob() calls
        // (double-click, two tabs) from both passing the Paused check and each spawning an
        // independent DependencyQueueable self-chain for the same job - mirrors the FOR UPDATE
        // guard already used by cancelJob().
        Metadata_Scan_Job__c job = new MetadataScanJobSelector().getByIdForResumeLocked(jobId);
        if (job == null) {
            throw new DependencyJobException('Scan job not found: ' + jobId);
        }
        if (job.Status__c != 'Paused') {
            throw new DependencyJobException(
                'Only Paused jobs can be resumed. Current status: ' + job.Status__c
            );
        }

        job.Status__c              = 'Processing';
        job.Batch_Size_Override__c = overrideBatchSize;
        job.Pause_Reason__c        = null;
        // Reset the stall counter so the first post-resume execution does not
        // immediately re-trigger stall detection. Without this reset, a job paused
        // by stall detection has (Total - LastSuccess) >= threshold already; the
        // next execution increments Total by 1 and the check fires instantly, causing
        // an infinite pause loop on every resume attempt.
        job.Last_Progress_Cycle__c = job.Processing_Cycle_Count__c;
        update as user job;

        System.enqueueJob(new DependencyQueueable(
            jobId,
            job.Only_Include_Active_Flows__c,
            overrideBatchSize
        ));
    }

    /**
     * Returns the ID of the first active scan job (Initializing or Processing).
     * Used by the concurrency error banner to navigate to the running scan.
     * Returns null when no active job exists (scan completed between rejection and click).
     */
    @AuraEnabled
    public static Id getActiveJobId() {
        return new MetadataScanJobSelector().getActiveJobId();
    }

    /**
     * Returns the 18-character org ID for the current org. Used by metaMapperApp to
     * construct "Open in Setup" deep-link URLs in metaMapperComponentDetailsPanel.
     * Cacheable because the org ID is immutable for the lifetime of the org.
     */
    @AuraEnabled(cacheable=true)
    public static String getOrgId() {
        return UserInfo.getOrganizationId();
    }
}
