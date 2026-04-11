/**
 * DependencyJobSelector
 *
 * Centralizes all SOQL queries against Metadata_Scan_Job__c and AsyncApexJob.
 * All queries run in SYSTEM_MODE - this selector is consumed by engine classes
 * (DependencyQueueable, DependencyCleanupBatch) that require reliable internal access
 * regardless of the running user's permissions.
 *
 * Ref: ISP-6072
 */
public without sharing class DependencyJobSelector {

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
                   Total_Processing_Cycles__c,
                   Last_Successful_Cycle__c,
                   Batch_Size_Override__c,
                   Last_Result_Count__c,
                   Error_Status_Message__c,
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
     * @return  Number of DependencyQueueable jobs currently Queued, Processing, or Preparing
     */
    // Cached once per transaction - ApexClass records are immutable during execution
    private static Id cachedQueueableClassId;

    public Integer countActiveQueueables() {
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
        return [
            SELECT COUNT()
            FROM AsyncApexJob
            WHERE JobType = 'Queueable'
            AND ApexClassId = :cachedQueueableClassId
            // 'Holding' is included: when the flex queue is full, newly enqueued Queueable jobs
            // enter Holding status. Omitting it allows createJob() to bypass Max_Concurrent_Jobs__c
            // when the org is under heavy async load, potentially exceeding the 100 Holding limit.
            AND Status IN ('Processing', 'Preparing', 'Queued', 'Holding')
        ];
    }

    /**
     * Returns Completed jobs ordered by Status_Closed_At__c ascending, up to maxRows records.
     * Used by the ring buffer to find the oldest job to delete when Max_Stored_Jobs__c is exceeded.
     *
     * Two-step lock pattern:
     *   Step 1 - ORDER BY query to get the correct oldest IDs (ORDER BY is incompatible with FOR UPDATE).
     *   Step 2 - Re-query those IDs WITH FOR UPDATE to serialize concurrent ResultSerializerQueueable
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
            if (a.Status_Closed_At__c == b.Status_Closed_At__c) {
                return a.Id < b.Id ? -1 : (a.Id > b.Id ? 1 : 0);
            }
            return a.Status_Closed_At__c < b.Status_Closed_At__c ? -1 : 1;
        }
    }
}
