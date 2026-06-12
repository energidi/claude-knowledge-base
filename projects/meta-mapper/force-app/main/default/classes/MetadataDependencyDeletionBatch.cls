/**
 * MetadataDependencyDeletionBatch
 *
 * Batch-deletes Metadata_Dependency__c records for a specific job.
 * Called from two paths:
 *   - ScanResultFileQueueable (NODES_ONLY): deletes nodes after serialization; retains job record
 *   - DependencyCleanupBatch (NODES_AND_JOB): deletes nodes then job record for expired jobs
 *
 * Uses CleanupMode enum instead of a Boolean parameter to prevent silent argument-swap bugs.
 * Batch size = Cleanup_Chunk_Size__c (default 2,000): leaves 8,000 DML rows headroom
 * for customer automation that may fire on delete events for Metadata_Dependency__c.
 *
 * No inner loops in execute(): each transaction deletes exactly one chunk.
 *
 *
 */
public without sharing class MetadataDependencyDeletionBatch
    implements Database.Batchable<SObject> {

    public enum CleanupMode { NODES_ONLY, NODES_AND_JOB }

    // Database.emptyRecycleBin() enforces a hard limit of 200 records per call.
    // Exceeding it throws a LimitException. This constant is used to chunk the
    // successfully-deleted records before passing them to emptyRecycleBin.
    private static final Integer RECYCLE_BIN_CHUNK_SIZE = 200;

    private final String      jobId;
    private final CleanupMode mode;

    public MetadataDependencyDeletionBatch(String jobId, CleanupMode mode) {
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
        // Partial-success delete: one corrupt or locked record must not abort the entire chunk.
        List<Database.DeleteResult> deleteResults = Database.delete(scope, false);
        List<SObject> deleted = new List<SObject>();
        for (Integer i = 0; i < deleteResults.size(); i++) {
            if (deleteResults[i].isSuccess()) {
                deleted.add(scope[i]);
            } else {
                System.debug(LoggingLevel.WARN,
                    'MetadataDependencyDeletionBatch.execute: failed to delete record '
                    + scope[i].Id + ': ' + deleteResults[i].getErrors()[0].getMessage());
            }
        }
        // emptyRecycleBin has a hard limit of 200 records per call. Chunk the list
        // so a large partial-success batch (e.g. chunk size 2,000) does not throw
        // LimitException when all records were successfully deleted.
        // DML statement budget guard: emptyRecycleBin() consumes one DML statement per chunk.
        // Reserve 2 statements for finish() (ContentDocument delete + job delete in NODES_AND_JOB mode).
        // If fewer than (chunks needed + 2) statements remain, skip recycle bin clearing.
        Integer chunksNeeded = deleted.isEmpty() ? 0 : (Integer) Math.ceil((Decimal) deleted.size() / RECYCLE_BIN_CHUNK_SIZE);
        if (Limits.getLimitDmlStatements() - Limits.getDmlStatements() < chunksNeeded + 2) {
            System.debug(LoggingLevel.WARN,
                'MetadataDependencyDeletionBatch.execute: skipping emptyRecycleBin - '
                + 'insufficient DML statement budget ('
                + (Limits.getLimitDmlStatements() - Limits.getDmlStatements())
                + ' remaining, ' + (chunksNeeded + 2) + ' needed).');
        } else {
        for (Integer i = 0; i < deleted.size(); i += RECYCLE_BIN_CHUNK_SIZE) {
            Integer end = Math.min(i + RECYCLE_BIN_CHUNK_SIZE, deleted.size());
            List<SObject> chunk = new List<SObject>(deleted.subList(i, end));
            try {
                Database.emptyRecycleBin(chunk);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'MetadataDependencyDeletionBatch.execute: emptyRecycleBin failed for chunk '
                    + (i / RECYCLE_BIN_CHUNK_SIZE) + ': ' + e.getMessage());
            }
        }
        } // end else (DML budget sufficient for emptyRecycleBin)
    }

    public void finish(Database.BatchableContext ctx) {
        if (mode == CleanupMode.NODES_AND_JOB) {
            // Safety check: verify all child nodes have been deleted before removing the
            // parent job record. A failed execute() chunk or a concurrent deletion race
            // could leave orphaned nodes; deleting the job while children remain would
            // make those nodes permanently unreachable to the cleanup batch.
            try {
                // Use LIMIT 1 existence check instead of SELECT COUNT(): COUNT() without LIMIT
                // throws a QueryException on tables with >50,000 rows (LDV orgs with many nodes).
                List<Metadata_Dependency__c> remaining = [
                    SELECT Id FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :jobId LIMIT 1
                ];
                if (!remaining.isEmpty()) {
                    System.debug(LoggingLevel.WARN,
                        'MetadataDependencyDeletionBatch.finish: child node(s) remain for job ' + jobId
                        + '. Job record retained to allow next cleanup run to reattempt.');
                    return;
                }
                List<Metadata_Scan_Job__c> jobs = [
                    SELECT Id, Result_File_Id__c FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
                ];
                if (!jobs.isEmpty()) {
                    // Delete associated ContentDocument (result file) before the job record.
                    // The ring buffer path deletes ContentDocuments for completed jobs; the nightly
                    // batch must do the same to avoid a silent, compounding File Storage leak.
                    if (String.isNotBlank(jobs[0].Result_File_Id__c)) {
                        try {
                            List<ContentDocument> docs = [
                                SELECT Id FROM ContentDocument WHERE Id = :jobs[0].Result_File_Id__c LIMIT 1
                            ];
                            if (!docs.isEmpty()) {
                                List<Database.DeleteResult> docResults = Database.delete(docs, false);
                                if (!docResults[0].isSuccess()) {
                                    // File delete failed. Abort job record deletion so the nightly
                                    // batch retains a pointer to the file and can retry tomorrow.
                                    // Deleting the job while the file survives makes the file
                                    // permanently unreachable - no record holds its ID.
                                    String fileErrMsg = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] '
                                        + 'Nightly cleanup: ContentDocument delete failed - '
                                        + docResults[0].getErrors()[0].getMessage()
                                        + '. Job record retained; cleanup will retry on the next nightly run.';
                                    System.debug(LoggingLevel.WARN,
                                        'MetadataDependencyDeletionBatch.finish: ContentDocument delete failed for job '
                                        + jobId + ' - ' + docResults[0].getErrors()[0].getMessage()
                                        + '. Job record retained to prevent orphaned file.');
                                    try {
                                        List<Metadata_Scan_Job__c> toUpdate = [
                                            SELECT Id, Scan_Diagnostic_Log__c
                                            FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
                                        ];
                                        if (!toUpdate.isEmpty()) {
                                            String existing = toUpdate[0].Scan_Diagnostic_Log__c;
                                            toUpdate[0].Scan_Diagnostic_Log__c = String.isBlank(existing)
                                                ? fileErrMsg.right(32768)
                                                : (existing + '\n' + fileErrMsg).right(32768);
                                            update toUpdate;
                                        }
                                    } catch (Exception updateEx) {
                                        System.debug(LoggingLevel.WARN,
                                            'MetadataDependencyDeletionBatch.finish: could not append to '
                                            + 'Scan_Diagnostic_Log__c for job ' + jobId
                                            + ' - ' + updateEx.getMessage());
                                    }
                                    return;
                                }
                            }
                        } catch (Exception docEx) {
                            String fileErrMsg = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] '
                                + 'Nightly cleanup: ContentDocument delete failed - '
                                + docEx.getMessage()
                                + '. Job record retained; cleanup will retry on the next nightly run.';
                            System.debug(LoggingLevel.WARN,
                                'MetadataDependencyDeletionBatch.finish: ContentDocument delete failed for job '
                                + jobId + ' - ' + docEx.getMessage()
                                + '. Job record retained to prevent orphaned file.');
                            try {
                                List<Metadata_Scan_Job__c> toUpdate = [
                                    SELECT Id, Scan_Diagnostic_Log__c
                                    FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
                                ];
                                if (!toUpdate.isEmpty()) {
                                    String existing = toUpdate[0].Scan_Diagnostic_Log__c;
                                    toUpdate[0].Scan_Diagnostic_Log__c = String.isBlank(existing)
                                        ? fileErrMsg.right(32768)
                                        : (existing + '\n' + fileErrMsg).right(32768);
                                    update toUpdate;
                                }
                            } catch (Exception updateEx) {
                                System.debug(LoggingLevel.WARN,
                                    'MetadataDependencyDeletionBatch.finish: could not append to '
                                    + 'Scan_Diagnostic_Log__c for job ' + jobId
                                    + ' - ' + updateEx.getMessage());
                            }
                            return;
                        }
                    }
                    // Partial-success delete: a trigger or validation on the job record must
                    // not abort the cleanup silently. On failure, log and exit; the nightly
                    // batch will re-discover and retry rather than looping on a hard throw.
                    List<Database.DeleteResult> jobDeleteResults = Database.delete(jobs, false);
                    List<SObject> deletedJobs = new List<SObject>();
                    for (Integer i = 0; i < jobDeleteResults.size(); i++) {
                        if (jobDeleteResults[i].isSuccess()) {
                            deletedJobs.add(jobs[i]);
                        } else {
                            System.debug(LoggingLevel.WARN,
                                'MetadataDependencyDeletionBatch.finish: job record delete failed for '
                                + jobId + ': ' + jobDeleteResults[i].getErrors()[0].getMessage());
                        }
                    }
                    // Hard-delete only the successfully deleted records. Passing the original
                    // list when a row failed would call emptyRecycleBin on a non-deleted record.
                    if (!deletedJobs.isEmpty()) {
                        try {
                            Database.emptyRecycleBin(deletedJobs);
                        } catch (Exception rbEx) {
                            System.debug(LoggingLevel.WARN,
                                'MetadataDependencyDeletionBatch.finish: emptyRecycleBin for job record failed - '
                                + rbEx.getMessage());
                        }
                    }
                }
            } catch (Exception e) {
                // Non-fatal: job record may have already been deleted by a concurrent instance.
                System.debug(LoggingLevel.WARN,
                    'MetadataDependencyDeletionBatch.finish: job delete failed for ' + jobId
                    + ' - ' + e.getMessage());
            }
        }
    }
}
