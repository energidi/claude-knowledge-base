/**
 * DependencyCleanupBatch
 *
 * Nightly batch that discovers and schedules deletion of expired Failed and Cancelled
 * scan jobs. Runs via DependencyCleanupScheduler at 02:00 each day.
 *
 * Two-class pattern:
 *   - DependencyCleanupBatch (this class): discovers expired job IDs, accumulates them
 *     across execute() chunks (Database.Stateful required), fires one
 *     MetadataDependencyDeletionBatch per job from finish().
 *   - MetadataDependencyDeletionBatch: performs the actual node + job deletion in chunks
 *     so Master-Detail cascade never exhausts the 10,000 DML-row limit.
 *
 * Lifecycle rules:
 *   - Only targets Failed and Cancelled jobs older than Retention_Hours__c.
 *   - Never deletes Initializing, Processing, Paused, or Completed jobs.
 *     Completed jobs are managed by the ScanResultFileQueueable ring buffer.
 *   - Maximum 5 MetadataDependencyDeletionBatch submissions per finish() call
 *     (Salesforce platform limit is 5 Database.executeBatch() calls per transaction).
 *     If more than 5 expired jobs accumulate, the remainder clear over subsequent
 *     nightly runs.
 *
 *
 */
public without sharing class DependencyCleanupBatch
    implements Database.Batchable<SObject>, Database.Stateful {

    // Maximum MetadataDependencyDeletionBatch submissions per finish() call.
    // Salesforce platform limit is exactly 5 Database.executeBatch() calls per transaction.
    private static final Integer MAX_BATCH_SUBMISSIONS = 5;

    // Accumulated expired job IDs across all execute() invocations.
    // Database.Stateful is required: without it, Apex discards instance state between
    // chunk invocations and finish() receives an empty list, firing zero child batches.
    private List<Id> expiredJobIds = new List<Id>();

    public Database.QueryLocator start(Database.BatchableContext ctx) {
        MetaMapper_Settings__mdt settings = new MetaMapperSettingsProvider().getSettings();
        Integer retentionHours = settings.Retention_Hours__c != null
            ? ((Decimal) settings.Retention_Hours__c).intValue() : 72;
        // Enforce minimum: a retention window of 0 would delete all Failed/Cancelled jobs
        // immediately, preventing any post-failure diagnostics.
        retentionHours = Math.max(retentionHours, 1);
        DateTime threshold = DateTime.now().addHours(-retentionHours);
        return new MetadataScanJobSelector().getClosedJobsBefore(threshold);
    }

    public void execute(Database.BatchableContext ctx, List<SObject> scope) {
        // No DML: accumulate IDs only. MetadataDependencyDeletionBatch handles all deletion.
        // Database.Stateful preserves expiredJobIds across chunk invocations.
        for (SObject record : scope) {
            expiredJobIds.add((Id) record.get('Id'));
        }
    }

    public void finish(Database.BatchableContext ctx) {
        if (expiredJobIds.isEmpty()) {
            return;
        }

        MetaMapper_Settings__mdt settings = new MetaMapperSettingsProvider().getSettings();
        Integer configuredChunkSize = settings.Cleanup_Chunk_Size__c != null
            ? ((Decimal) settings.Cleanup_Chunk_Size__c).intValue() : 2000;
        // Database.executeBatch throws LimitException when batchSize > 2000.
        Integer chunkSize = Math.min(Math.max(configuredChunkSize, 1), 2000);
        if (chunkSize != configuredChunkSize) {
            // Append admin-visible warning to the first expired job so it appears in the UI.
            // The job has not yet been deleted at this point (MetadataDependencyDeletionBatch runs after).
            String clampWarn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] '
                + 'Cleanup_Chunk_Size__c is set to ' + configuredChunkSize
                + ', which exceeds the Salesforce batch scope limit of 2,000. '
                + 'Clamped to 2,000. Update Cleanup_Chunk_Size__c in MetaMapper Settings to 2,000 or lower to suppress this warning.';
            System.debug(LoggingLevel.WARN, 'DependencyCleanupBatch.finish: ' + clampWarn);
            appendNoticeToJob(expiredJobIds[0], clampWarn);
        }

        Integer submitted = 0;
        for (Id jobId : expiredJobIds) {
            if (submitted >= MAX_BATCH_SUBMISSIONS) {
                Integer backlogCount = expiredJobIds.size() - submitted;
                String backlogMsg = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] '
                    + 'Cleanup backlog: ' + backlogCount
                    + ' additional expired job(s) will be processed in subsequent nightly runs.';
                System.debug(LoggingLevel.INFO, 'DependencyCleanupBatch.finish: ' + backlogMsg);
                // Write to the oldest remaining unsubmitted job so admins see the notice in the UI.
                appendNoticeToJob(jobId, backlogMsg);
                break;
            }
            try {
                Database.executeBatch(
                    new MetadataDependencyDeletionBatch(
                        jobId, MetadataDependencyDeletionBatch.CleanupMode.NODES_AND_JOB),
                    chunkSize
                );
                submitted++;
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'DependencyCleanupBatch.finish: failed to schedule MetadataDependencyDeletionBatch '
                    + 'for job ' + jobId + ': ' + e.getMessage());
            }
        }
    }

    // -------------------------------------------------------------------------
    // Private - helpers
    // -------------------------------------------------------------------------

    private void appendNoticeToJob(Id jobId, String notice) {
        try {
            Metadata_Scan_Job__c job =
                new MetadataScanJobSelector().getByIdForLogAppend(jobId);
            if (job != null) {
                String existing = job.Scan_Diagnostic_Log__c;
                job.Scan_Diagnostic_Log__c = String.isBlank(existing)
                    ? notice
                    : (existing + '\n' + notice).right(32768);
                update job;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'DependencyCleanupBatch.appendNoticeToJob: update failed for job '
                + jobId + ' - ' + e.getMessage());
        }
    }
}
