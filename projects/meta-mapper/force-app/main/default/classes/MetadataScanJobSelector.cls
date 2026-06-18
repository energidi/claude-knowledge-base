/**
 * MetadataScanJobSelector
 *
 * Centralizes all SOQL queries against Metadata_Scan_Job__c and AsyncApexJob.
 * All queries run in SYSTEM_MODE - this selector is consumed by engine classes
 * (DependencyQueueable, DependencyCleanupBatch) that require reliable internal access
 * regardless of the running user's permissions.
 *
 *
 */
public without sharing class MetadataScanJobSelector {

    /**
     * Returns the minimal set of job fields needed by the scan engine per execution.
     * Keeps heap cost low - does not fetch result or summary fields.
     *
     * @param jobId  ID of the Metadata_Scan_Job__c record
     * @return       The job record, or null if not found
     */
    public Metadata_Scan_Job__c getByIdForEngine(String jobId) {
        List<Metadata_Scan_Job__c> results = [
            SELECT Id,
                   Status__c,
                   Active_Flows_Only__c,
                   Components_Analyzed__c,
                   Processing_Cycle_Count__c,
                   Last_Progress_Cycle__c,
                   Batch_Size_Override__c,
                   Last_Query_Row_Count__c,
                   Scan_Diagnostic_Log__c,
                   Target_Metadata_Type__c,
                   Target_API_Name__c,
                   Target_Parent_Object__c,
                   OwnerId
            FROM Metadata_Scan_Job__c
            WHERE Id = :jobId
            LIMIT 1
        ];
        return results.isEmpty() ? null : results[0];
    }

    /**
     * Returns Failed and Cancelled jobs whose Status_Closed_At__c is older than
     * the given threshold. Used by DependencyCleanupBatch to find expired jobs.
     * Never returns Completed, Initializing, Processing, or Paused jobs.
     *
     * @param threshold  DateTime cutoff - jobs closed before this are returned
     * @return           QueryLocator scoped to expired Failed/Cancelled jobs
     */
    public Database.QueryLocator getClosedJobsBefore(DateTime threshold) {
        return Database.getQueryLocator([
            SELECT Id
            FROM Metadata_Scan_Job__c
            WHERE Status__c IN ('Failed', 'Cancelled')
            AND Status_Closed_At__c < :threshold
        ]);
    }

    /**
     * Counts active DependencyQueueable jobs in the Salesforce flex queue.
     * Used by DependencyJobController.createJob() to enforce Max_Concurrent_Jobs__c.
     *
     * Uses ApexClassId (indexed foreign key) rather than ApexClass.Name (cross-object
     * filter) for selectivity on orgs where AsyncApexJob holds millions of rows.
     * Pre-queries the ApexClass Id to enable the indexed filter.
     *
     * LIMIT is set to maxConcurrent + 1: SELECT COUNT() with LIMIT is silently ignored
     * by Salesforce - COUNT() aggregates always scan all matching rows regardless of LIMIT,
     * causing a full-table scan on LDV orgs with millions of AsyncApexJob rows. Using
     * SELECT Id + results.size() respects the LIMIT and bounds query cost.
     *
     * @param maxConcurrent  Max_Concurrent_Jobs__c threshold; LIMIT is set to this + 1
     * @return               Number of DependencyQueueable jobs currently active
     */
    // Cached once per transaction - ApexClass records are immutable during execution
    private static Id cachedQueueableClassId;

    public Integer countActiveQueueables(Integer maxConcurrent) {
        if (cachedQueueableClassId == null) {
            List<ApexClass> classes = [
                SELECT Id FROM ApexClass
                WHERE Name = 'DependencyQueueable'
                // NamespacePrefix = null scopes to MetaMapper's own unmanaged class.
                // Without this, another managed package deploying a class with the same name
                // would pollute the concurrency count, allowing createJob() to bypass
                // Max_Concurrent_Jobs__c. MetaMapper is deployed as unmanaged (open-source).
                AND NamespacePrefix = null
                LIMIT 1
            ];
            if (classes.isEmpty()) {
                return 0;
            }
            cachedQueueableClassId = classes[0].Id;
        }
        Integer queryLimit = maxConcurrent + 1;
        List<AsyncApexJob> results = [
            SELECT Id
            FROM AsyncApexJob
            WHERE JobType = 'Queueable'
            AND ApexClassId = :cachedQueueableClassId
            // 'Holding' is included: when the flex queue is full, newly enqueued Queueable jobs
            // enter Holding status. Omitting it allows createJob() to bypass Max_Concurrent_Jobs__c
            // when the org is under heavy async load, potentially exceeding the 100 Holding limit.
            AND Status IN ('Processing', 'Preparing', 'Queued', 'Holding')
            LIMIT :queryLimit
        ];
        return results.size();
    }

    /**
     * Returns Completed jobs ordered by Status_Closed_At__c ascending, up to maxRows records.
     * Used by the ring buffer to find the oldest job to delete when Max_Stored_Jobs__c is exceeded.
     *
     * Two-step lock pattern:
     *   Step 1 - ORDER BY query to get the correct oldest IDs (ORDER BY is incompatible with FOR UPDATE).
     *   Step 2 - Re-query those IDs WITH FOR UPDATE to serialize concurrent ScanResultFileQueueable
     *            executions. This prevents two concurrent serializers from independently selecting and
     *            deleting the same oldest job.
     *
     * Pass Max_Stored_Jobs__c + 10 as maxRows to ensure the oldest record is always captured when
     * the ring buffer is slightly over limit.
     *
     * @param maxRows  Maximum number of Completed job records to lock and return
     * @return         Completed Metadata_Scan_Job__c records, oldest first, locked FOR UPDATE
     */
    public List<Metadata_Scan_Job__c> getCompletedJobsOldestFirst(Integer maxRows) {
        // Step 1: ORDER BY to identify the correct oldest IDs
        List<Metadata_Scan_Job__c> ordered = [
            SELECT Id
            FROM Metadata_Scan_Job__c
            WHERE Status__c = 'Completed'
            ORDER BY Status_Closed_At__c ASC, Id ASC
            LIMIT :maxRows
        ];
        if (ordered.isEmpty()) {
            return new List<Metadata_Scan_Job__c>();
        }
        Set<Id> orderedIds = new Map<Id, Metadata_Scan_Job__c>(ordered).keySet();
        // Step 2: Lock the identified records to serialize concurrent ring-buffer deletions.
        // ORDER BY is omitted here - SOQL does not guarantee order when both ORDER BY and
        // FOR UPDATE are combined, and the IN :orderedIds set does not preserve insertion order.
        // Sort in Apex after the lock to ensure deterministic oldest-first ordering.
        List<Metadata_Scan_Job__c> locked = [
            SELECT Id, Status_Closed_At__c, Result_File_Id__c
            FROM Metadata_Scan_Job__c
            WHERE Id IN :orderedIds
            FOR UPDATE
        ];
        locked.sort(new StatusClosedAtComparator());
        return locked;
    }

    /**
     * Comparator for ascending Status_Closed_At__c order with Id as tiebreaker.
     * Applied to the FOR UPDATE result set to restore deterministic oldest-first ordering
     * after the database lock (SOQL ORDER BY + FOR UPDATE ordering is unreliable).
     */
    private class StatusClosedAtComparator implements Comparator<Metadata_Scan_Job__c> {
        public Integer compare(Metadata_Scan_Job__c a, Metadata_Scan_Job__c b) {
            DateTime closedA = a.Status_Closed_At__c;
            DateTime closedB = b.Status_Closed_At__c;
            // Null-safe: treat null as "most recent" (sorts last in ascending order) to
            // prevent NPE on legacy Completed records where Status_Closed_At__c was not
            // stamped (e.g. jobs completed before the field was added). Sorting null last
            // means legacy records are retained over newer ones rather than being
            // incorrectly treated as the oldest and deleted first.
            if (closedA == null && closedB == null) {
                return a.Id < b.Id ? -1 : (a.Id > b.Id ? 1 : 0);
            }
            if (closedA == null) { return 1; }
            if (closedB == null) { return -1; }
            if (closedA == closedB) {
                return a.Id < b.Id ? -1 : (a.Id > b.Id ? 1 : 0);
            }
            return closedA < closedB ? -1 : 1;
        }
    }

    /**
     * Returns Status__c only. Used by the three concurrent-status re-verify checks
     * inside DependencyQueueable.runEngine() (stall guard, cap guard, cancel guard).
     *
     * Each call is a fresh, unlocked read - no FOR UPDATE. A TOCTOU race window exists
     * between the initial status read and any subsequent DML on the job record. This is
     * an accepted design trade-off for an admin tool: the re-verify only prevents
     * overwriting a terminal status (Cancelled, Completed, Failed) with a mid-traversal
     * state update. The window is near-zero in practice.
     *
     * @param jobId  ID of the Metadata_Scan_Job__c record
     * @return       Current Status__c value, or null if the record does not exist
     */
    public String getStatusOnly(String jobId) {
        List<Metadata_Scan_Job__c> rows = [
            SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0].Status__c;
    }

    /**
     * Returns the fields needed by updateJobFailed() in DependencyQueueable.
     * No row lock - used outside any locking context.
     *
     * @param jobId  ID of the Metadata_Scan_Job__c record
     * @return       The job record, or null if not found
     */
    public Metadata_Scan_Job__c getForFailedUpdate(String jobId) {
        List<Metadata_Scan_Job__c> rows = [
            SELECT Id, Status__c, Scan_Diagnostic_Log__c, Components_Analyzed__c
            FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * Same as getForFailedUpdate but WITH FOR UPDATE to serialize concurrent
     * ScanResultFileQueueable instances in updateJobFailed().
     *
     * @param jobId  ID of the Metadata_Scan_Job__c record
     * @return       The job record locked FOR UPDATE, or null if not found
     */
    public Metadata_Scan_Job__c getForFailedUpdateLocked(String jobId) {
        List<Metadata_Scan_Job__c> rows = [
            SELECT Id, Status__c, Scan_Diagnostic_Log__c, Components_Analyzed__c
            FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1 FOR UPDATE
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * Returns the job record WITH FOR UPDATE lock for ScanResultFileQueueable's
     * main serialization path. Acquired immediately to serialize concurrent instances.
     *
     * @param jobId  ID of the Metadata_Scan_Job__c record
     * @return       The job record locked FOR UPDATE, or null if not found
     */
    public Metadata_Scan_Job__c getByIdForLock(String jobId) {
        List<Metadata_Scan_Job__c> rows = [
            SELECT Id, Status__c, Components_Analyzed__c, Scan_Diagnostic_Log__c,
                   Target_API_Name__c
            FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1 FOR UPDATE
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * Returns Id and Scan_Diagnostic_Log__c for log-append operations.
     * Used by DependencyNotificationService, DependencyJobController, ScanSummaryQueueable,
     * DependencyCleanupBatch, and ScanResultFileQueueable.
     *
     * @param jobId  ID of the Metadata_Scan_Job__c record
     * @return       The job record, or null if not found
     */
    public Metadata_Scan_Job__c getByIdForLogAppend(String jobId) {
        List<Metadata_Scan_Job__c> rows = [
            SELECT Id, Scan_Diagnostic_Log__c
            FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * Returns the fields needed by ScanSummaryQueueable to build the plain-English summary.
     *
     * @param jobId  ID of the Metadata_Scan_Job__c record
     * @return       The job record, or null if not found
     */
    public Metadata_Scan_Job__c getByIdForSummary(String jobId) {
        List<Metadata_Scan_Job__c> rows = [
            SELECT Id, Status__c, Component_Type_Counts__c, Components_Analyzed__c, Target_API_Name__c,
                   Scan_Diagnostic_Log__c, Scan_Summary_Text__c
            FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * Counts active Metadata_Scan_Job__c records in Initializing or Processing state.
     * Used as the secondary soft lock in DependencyJobController.createJob() to narrow
     * the TOCTOU race window alongside countActiveQueueables().
     *
     * Uses SELECT Id + results.size() rather than SELECT COUNT() to respect LIMIT.
     * SELECT COUNT() with LIMIT is silently ignored in Salesforce - aggregate COUNT()
     * always scans all matching rows regardless of LIMIT.
     *
     * @param maxConcurrent  Max_Concurrent_Jobs__c threshold; LIMIT is set to this + 1
     * @return               Number of jobs currently in Initializing or Processing state
     */
    public Integer countActiveJobRecords(Integer maxConcurrent) {
        Integer queryLimit = maxConcurrent + 1;
        List<Metadata_Scan_Job__c> results = [
            SELECT Id
            FROM Metadata_Scan_Job__c
            WHERE Status__c IN ('Initializing', 'Processing')
            LIMIT :queryLimit
        ];
        return results.size();
    }

    /**
     * Returns all UI-relevant fields for the progress and results views.
     * Enforces WITH USER_MODE so FLS and CRUD are respected at the controller boundary.
     * Used by DependencyJobController.getJobStatus() and getNodeHierarchy().
     *
     * @param jobId  ID of the Metadata_Scan_Job__c record
     * @return       The job record, or null if not found or inaccessible to the running user
     */
    public Metadata_Scan_Job__c getByIdForStatusView(String jobId) {
        List<Metadata_Scan_Job__c> rows = [
            SELECT Id,
                   Status__c,
                   Target_Metadata_Type__c,
                   Target_API_Name__c,
                   Components_Analyzed__c,
                   Scan_Diagnostic_Log__c,
                   Scan_Summary_Text__c,
                   Component_Type_Counts__c,
                   Result_File_Id__c,
                   Status_Closed_At__c,
                   Batch_Size_Override__c,
                   Pause_Reason__c,
                   Result_Save_Attempted__c,
                   Platform_Events_Auto_Suppressed__c,
                   CreatedDate
            FROM Metadata_Scan_Job__c
            WHERE Id = :jobId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    /**
     * Returns the fields needed by DependencyJobController.resumeJob() to validate
     * the job state and enqueue a new DependencyQueueable instance.
     * Enforces WITH USER_MODE at the controller boundary.
     *
     * @param jobId  ID of the Metadata_Scan_Job__c record
     * @return       The job record, or null if not found or inaccessible to the running user
     */
    public Metadata_Scan_Job__c getByIdForResume(String jobId) {
        List<Metadata_Scan_Job__c> rows = [
            SELECT Id, Status__c, Active_Flows_Only__c, Processing_Cycle_Count__c
            FROM Metadata_Scan_Job__c
            WHERE Id = :jobId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }
}
