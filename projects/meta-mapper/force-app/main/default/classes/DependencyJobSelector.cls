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
     * Scoped to DependencyQueueable by ApexClass.Name for query selectivity on
     * orgs where AsyncApexJob holds millions of rows.
     *
     * @return  Number of DependencyQueueable jobs currently Processing or Preparing
     */
    public Integer countActiveQueueables() {
        return [
            SELECT COUNT()
            FROM AsyncApexJob
            WHERE JobType = 'Queueable'
            AND ApexClass.Name = 'DependencyQueueable'
            AND Status IN ('Processing', 'Preparing')
        ];
    }

    /**
     * Returns all Completed jobs ordered by Status_Closed_At__c ascending.
     * Used by the ring buffer to find the oldest job to delete when
     * Max_Stored_Jobs__c is exceeded. Uses FOR UPDATE to serialize concurrent
     * ResultSerializerQueueable executions.
     *
     * @return  List of Completed Metadata_Scan_Job__c records, oldest first
     */
    public List<Metadata_Scan_Job__c> getCompletedJobsOldestFirst() {
        // ORDER BY is not permitted with FOR UPDATE - sort in Apex after acquiring the lock.
        List<Metadata_Scan_Job__c> jobs = [
            SELECT Id, Status_Closed_At__c, Result_File_Id__c
            FROM Metadata_Scan_Job__c
            WHERE Status__c = 'Completed'
            FOR UPDATE
        ];
        jobs.sort(new CompletedJobComparator());
        return jobs;
    }

    /**
     * Sorts completed jobs by Status_Closed_At__c ASC, then Id ASC for determinism
     * when two jobs share an identical closed timestamp.
     */
    private class CompletedJobComparator implements Comparator<Metadata_Scan_Job__c> {
        public Integer compare(Metadata_Scan_Job__c a, Metadata_Scan_Job__c b) {
            if (a.Status_Closed_At__c != b.Status_Closed_At__c) {
                return a.Status_Closed_At__c < b.Status_Closed_At__c ? -1 : 1;
            }
            return a.Id < b.Id ? -1 : (a.Id > b.Id ? 1 : 0);
        }
    }
}
