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
        Database.emptyRecycleBin(scope);
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
