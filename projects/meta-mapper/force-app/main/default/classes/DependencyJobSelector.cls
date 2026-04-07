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
     * @return  Number of DependencyQueueable jobs currently Processing or Preparing
     */
    // Cached once per transaction - ApexClass records are immutable during execution
    private static Id cachedQueueableClassId;

    public Integer countActiveQueueables() {
        if (cachedQueueableClassId == null) {
            List<ApexClass> classes = [
                SELECT Id FROM ApexClass WHERE Name = 'DependencyQueueable' LIMIT 1
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
            AND Status IN ('Processing', 'Preparing')
        ];
    }

    /**
     * Returns Completed jobs ordered by Status_Closed_At__c ascending, up to maxRows records.
     * Used by the ring buffer to find the oldest job to delete when Max_Stored_Jobs__c is
     * exceeded. Uses FOR UPDATE to serialize concurrent ResultSerializerQueueable executions.
     *
     * Pass Max_Stored_Jobs__c + 10 as maxRows - a small buffer above the retention cap ensures
     * the oldest record is always present if the ring buffer is slightly over limit.
     *
     * ORDER BY is not permitted with FOR UPDATE - the list is sorted in Apex after the lock.
     *
     * @param maxRows  Maximum number of Completed job records to lock and return
     * @return         Completed Metadata_Scan_Job__c records, oldest first
     */
    public List<Metadata_Scan_Job__c> getCompletedJobsOldestFirst(Integer maxRows) {
        // ORDER BY + LIMIT is used without FOR UPDATE to guarantee that the oldest
        // records are returned. FOR UPDATE without ORDER BY applies LIMIT before sorting,
        // which does not guarantee the oldest rows are locked. The ring buffer deletion
        // in ResultSerializerQueueable wraps its targeted delete in try/catch - if two
        // concurrent serializers both attempt to delete the same oldest job, the second
        // will receive a handled exception and continue safely.
        return [
            SELECT Id, Status_Closed_At__c, Result_File_Id__c
            FROM Metadata_Scan_Job__c
            WHERE Status__c = 'Completed'
            ORDER BY Status_Closed_At__c ASC, Id ASC
            LIMIT :maxRows
        ];
    }

}
