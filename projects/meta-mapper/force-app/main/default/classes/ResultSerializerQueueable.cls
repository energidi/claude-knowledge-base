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

    // At ~5KB per node, serialization peak is ~3x (SObject list + JSON string + Blob copy).
    // Check (estimatedBytes * 3) + current heap against 11MB so the serialize + ContentVersion
    // insert operations have room to complete within the 12MB async heap limit.
    private static final Integer AVG_BYTES_PER_NODE  = 5000;
    private static final Integer HEAP_SAFETY_CEILING = 11000000; // 11MB ceiling for 3x amplification

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

        // Fix 4: Skip if job is no longer Processing (e.g. cancelled between enqueue and execution).
        if (job.Status__c != 'Processing') {
            return;
        }

        // --- 1. Heap pre-check ---
        // Peak memory is ~3x estimated bytes: SObject list in memory + JSON.serialize() output
        // string + Blob.valueOf() copy. Check against current heap to account for already-used
        // memory at the point of invocation.
        Long estimatedBytes = (job.Components_Analyzed__c != null
            ? (Long) job.Components_Analyzed__c : 0L) * AVG_BYTES_PER_NODE;
        if ((estimatedBytes * 3) + Limits.getHeapSize() > HEAP_SAFETY_CEILING) {
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
            // Log to debug only - updating job here risks a validation rule failure
            // that would propagate to the outer catch and incorrectly fail the job.
            System.debug(LoggingLevel.WARN,
                'ResultSerializerQueueable.enforceRingBuffer: ring buffer delete failed for job '
                + oldest.Id + ': ' + e.getMessage());
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
