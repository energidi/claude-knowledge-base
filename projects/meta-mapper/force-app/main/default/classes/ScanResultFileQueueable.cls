/**
 * ScanResultFileQueueable
 *
 * One-shot Queueable enqueued by DependencyQueueable when traversal is complete.
 *
 * Steps (core steps 1-7 guarded by Savepoint/rollback; post-completion steps run outside):
 * 1. Status guard: exits if job is no longer Processing
 * 2. Fetches all Metadata_Dependency__c for the job
 * 3. Sample-based heap check on actual node sizes (more accurate than fixed-byte estimate)
 * 4. Serializes to JSON and creates ContentVersion (FirstPublishLocationId = jobId)
 * 5. Requeries ContentDocumentId (not populated on the inserted record)
 * 6. Sets ContentDocumentLink ShareType='V', Visibility='InternalUsers'
 * 7. Computes Component_Type_Counts__c (versioned JSON map; trims lowest-count keys if needed)
 * 8. Updates job: Result_File_Id__c, Component_Type_Counts__c, Status=Completed, Status_Closed_At__c
 * [Savepoint released here - post-completion tasks below never roll back the Completed transition]
 * 9. Launches MetadataDependencyDeletionBatch(NODES_ONLY) to delete node records
 * 10. Enforces ring buffer via MetadataScanJobSelector.getCompletedJobsOldestFirst()
 * 11. Enqueues ScanSummaryQueueable
 *
 * Failure is terminal: on exception the job transitions to Failed.
 * Node records remain for manual export until nightly cleanup.
 *
 *
 */
// without sharing is intentional: internal engine component invoked asynchronously.
// All user-facing DML is gated at DependencyJobController (WITH USER_MODE).
public without sharing class ScanResultFileQueueable implements Queueable {

    // 2x amplification covers only NEW allocations: JSON.serialize() String + Blob.valueOf() copy.
    // The SObject list is already in the heap and already counted in Limits.getHeapSize(),
    // so including it in the amplification factor would double-count it, causing premature
    // rejection (previously 3x was used, which was too conservative by ~1x).
    // 11MB ceiling leaves 1MB of headroom within the 12MB async limit.
    private static final Integer HEAP_AMPLIFICATION  = 2;
    private static final Integer HEAP_SAFETY_CEILING = 11000000;
    // Number of nodes to sample for the per-node char estimate before full serialization.
    private static final Integer HEAP_SAMPLE_SIZE    = 50;

    // Thrown by the heap-check path so execute()'s catch block can roll back the
    // savepoint BEFORE calling updateJobFailed(). Calling updateJobFailed() inside
    // runSerializerCore() without first rolling back the savepoint would leave its DML
    // inside the savepoint scope - a subsequent rollback (triggered by any later exception)
    // would silently undo the Failed status transition, leaving the job stuck in Processing.
    private class HeapCheckException extends Exception {}

    // Thrown when the ContentDocumentLink visibility update fails. Reuses the
    // HeapCheckException pattern: execute()'s catch block rolls back the savepoint
    // (reverting the just-inserted ContentVersion/ContentDocument, since the insert
    // happened after the savepoint) before calling updateJobFailed(). This ensures the
    // file is never left in place with unconfirmed sharing visibility.
    private class LinkVisibilityException extends Exception {}

    private final String jobId;

    // Set by runSerializerCore() on success so execute() can call runPostCompletionTasks()
    // outside the savepoint scope. An exception inside runPostCompletionTasks() must never
    // roll back the Completed transition - keeping these outside the try block ensures that.
    private MetaMapper_Settings__mdt coreSettings;
    private Metadata_Scan_Job__c     completedJob;

    public ScanResultFileQueueable(String jobId) {
        this.jobId = jobId;
    }

    public void execute(QueueableContext ctx) {
        // Commit Result_Save_Attempted__c BEFORE the savepoint so a rollback cannot
        // revert this flag. The flag distinguishes serializer failures (traversal
        // completed but file creation failed) from mid-traversal engine failures in the
        // LWC error state decision tree, enabling the "Download Partial Results" button.
        try {
            update new Metadata_Scan_Job__c(Id = jobId, Result_Save_Attempted__c = true);
        } catch (Exception serAttemptEx) {
            System.debug(LoggingLevel.WARN,
                'ScanResultFileQueueable: could not set Result_Save_Attempted__c for job '
                + jobId + ': ' + serAttemptEx.getMessage());
        }
        Savepoint sp = Database.setSavepoint();
        try {
            runSerializerCore();
        } catch (Exception e) {
            Database.rollback(sp);
            updateJobFailed(jobId,
                'ScanResultFileQueueable: ' + e.getMessage()
                + '\n' + e.getStackTraceString());
            return;
        }
        // Post-completion tasks run OUTSIDE the savepoint scope.
        // A scheduling failure or ring-buffer error cannot roll back the Completed transition.
        if (coreSettings != null && completedJob != null) {
            runPostCompletionTasks(coreSettings, completedJob);
        }
    }

    // -------------------------------------------------------------------------
    // Private - core serialization flow (inside savepoint)
    // -------------------------------------------------------------------------

    private void runSerializerCore() {
        // FOR UPDATE acquired immediately: serializes concurrent ScanResultFileQueueable
        // instances before any heap-intensive or DML work begins. The second instance that
        // receives the lock will see Status__c != 'Processing' (set by the first) and exit.
        Metadata_Scan_Job__c lockedJob =
            new MetadataScanJobSelector().getByIdForLock(jobId);
        List<Metadata_Scan_Job__c> jobRows = lockedJob != null
            ? new List<Metadata_Scan_Job__c>{ lockedJob }
            : new List<Metadata_Scan_Job__c>();

        // Exit if job is no longer Processing (e.g. cancelled between enqueue and execution,
        // or a concurrent instance already transitioned to Completed).
        if (jobRows.isEmpty() || jobRows[0].Status__c != 'Processing') {
            return;
        }
        Metadata_Scan_Job__c job = jobRows[0];

        // --- 1. Fetch all nodes ---
        IMetaMapperSettingsProvider settingsProvider = new MetaMapperSettingsProvider();
        MetaMapper_Settings__mdt settings = settingsProvider.getSettings();
        Integer maxComponents = settings.Max_Components__c != null
            ? ((Decimal) settings.Max_Components__c).intValue() : 5000;
        maxComponents = Math.min(maxComponents, MetadataDependencySelector.MAX_NODE_QUERY_LIMIT);

        MetadataDependencySelector nodeSelector = new MetadataDependencySelector();
        List<Metadata_Dependency__c> nodes = nodeSelector.listByJob(jobId, maxComponents);

        // Truncation detection: if result hits the cap, some nodes may be missing.
        Integer effectiveCap = Math.min(MetadataDependencySelector.MAX_NODE_QUERY_LIMIT, maxComponents);
        if (nodes.size() == effectiveCap) {
            String truncMsg = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] Node list may be truncated; '
                + 'result size hit the query cap of ' + nodes.size()
                + '. Some nodes may be missing from the exported file.';
            job.Scan_Diagnostic_Log__c = SupplementalScanResult.appendNoticeSafe(
                job.Scan_Diagnostic_Log__c, truncMsg);
        }

        // --- 2. Sample-based heap check ---
        // Sample actual per-node serialization cost rather than relying on a fixed estimate.
        // A fixed 5KB/node average fires at ~666 nodes (far below the intended 2000-3000 ceiling);
        // sampling from real data gives an accurate estimate for the current scan's depth/breadth.
        // The SObject list is already in memory; the 2x factor covers the JSON String and Blob copy.
        if (!nodes.isEmpty()) {
            Integer sampleSize = Math.min(HEAP_SAMPLE_SIZE, nodes.size());
            Long totalSampleSerializedChars = 0;
            for (Integer i = 0; i < sampleSize; i++) {
                totalSampleSerializedChars += JSON.serialize(nodes[i]).length();
            }
            Long avgCharsPerNode = totalSampleSerializedChars / sampleSize;
            Long estimatedTotalChars = avgCharsPerNode * nodes.size();
            if ((estimatedTotalChars * HEAP_AMPLIFICATION) + Limits.getHeapSize() > HEAP_SAFETY_CEILING) {
                // Throw HeapCheckException so execute()'s catch block rolls back the savepoint
                // BEFORE calling updateJobFailed(). Calling updateJobFailed() here (inside the
                // savepoint scope) without a prior rollback would leave its DML inside the scope;
                // any subsequent rollback would silently undo the Failed status transition.
                // At this point no DML has occurred inside runSerializerCore(), so rollback is clean.
                throw new HeapCheckException(
                    'Scan completed but results could not be saved - result set too large '
                    + 'for available heap (estimated '
                    + (estimatedTotalChars * HEAP_AMPLIFICATION / 1000000)
                    + 'MB for ' + nodes.size() + ' nodes). Reduce Max_Components__c and run again.');
            }
        }

        // --- 3. Serialize to JSON and create ContentVersion ---
        // FirstPublishLocationId = jobId causes Salesforce to auto-create the
        // ContentDocumentLink tied to the job. Do NOT create the link manually.
        String jsonBody = JSON.serialize(nodes);
        ContentVersion contentVersion = new ContentVersion(
            Title                  = 'MetaMapper_' + jobId,
            PathOnClient           = 'MetaMapper_' + jobId + '.json',
            VersionData            = Blob.valueOf(jsonBody),
            FirstPublishLocationId = jobId
        );
        insert contentVersion;

        // --- 4. Requery ContentDocumentId ---
        contentVersion = nodeSelector.getVersionContentDocumentId(contentVersion.Id);

        // --- 5. Set ContentDocumentLink visibility ---
        List<ContentDocumentLink> links =
            new MetadataDependencySelector().getContentDocumentLinkForJob(
                contentVersion.ContentDocumentId, jobId
            );
        if (!links.isEmpty()) {
            links[0].ShareType  = 'V';
            links[0].Visibility = 'InternalUsers';
            List<Database.SaveResult> linkResults = Database.update(links, false);
            if (!linkResults[0].isSuccess()) {
                // Do not leave the file in place with unconfirmed sharing visibility.
                // Throwing here is caught by execute(), which rolls back the savepoint
                // (removing the just-inserted ContentVersion/ContentDocument) and fails
                // the job via the standard updateJobFailed() path.
                throw new LinkVisibilityException(
                    'Scan completed but the result file could not be saved - its sharing '
                    + 'visibility could not be confirmed: '
                    + linkResults[0].getErrors()[0].getMessage() + '. Run the scan again.');
            }
        } else {
            String warn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] ContentDocumentLink not found for '
                + contentVersion.ContentDocumentId + '; file visibility may not be restricted to InternalUsers.';
            job.Scan_Diagnostic_Log__c = SupplementalScanResult.appendNoticeSafe(
                job.Scan_Diagnostic_Log__c, warn);
        }

        // --- 6. Compute Component_Type_Counts__c ---
        // Versioned envelope: {"v":1, "ApexClass":5, "Flow":3, ...}
        Map<String, Integer> typeCounts = new Map<String, Integer>();
        for (Metadata_Dependency__c n : nodes) {
            String t = String.isNotBlank(n.Metadata_Type__c) ? n.Metadata_Type__c : 'Unknown';
            Integer current = typeCounts.get(t);
            typeCounts.put(t, (current != null ? current : 0) + 1);
        }
        Map<String, Object> summaryEnvelope = new Map<String, Object>{ 'v' => 1 };
        // putAll(Map<String,Integer>) is not a valid Apex signature for Map<String,Object>.
        // Iterate explicitly to avoid a compile-time type mismatch error.
        for (String key : typeCounts.keySet()) {
            summaryEnvelope.put(key, typeCounts.get(key));
        }
        String typeCountsJson = JSON.serialize(summaryEnvelope);

        // Trim lowest-count keys if the JSON exceeds the 32,768-char field limit.
        // Using .left() would shear off the closing JSON syntax, producing malformed JSON
        // that causes a parse exception in ScanSummaryQueueable.
        while (typeCountsJson.length() > 32768 && !typeCounts.isEmpty()) {
            String lowestKey = null;
            Integer lowestCount = null;
            for (String k : typeCounts.keySet()) {
                if (lowestCount == null || typeCounts.get(k) < lowestCount) {
                    lowestCount = typeCounts.get(k);
                    lowestKey = k;
                }
            }
            if (lowestKey != null) {
                typeCounts.remove(lowestKey);
                summaryEnvelope.remove(lowestKey);
                typeCountsJson = JSON.serialize(summaryEnvelope);
            } else {
                break;
            }
        }
        if (typeCountsJson.length() > 32768) {
            // Emergency fallback: all type keys were trimmed and the envelope still exceeds the limit.
            // This should never occur ({"v":1} is 7 chars) but is guarded to avoid a field truncation.
            String warn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] WARNING: Component_Type_Counts__c '
                + 'fell back to minimum envelope {"v":1} after all type keys were trimmed.';
            job.Scan_Diagnostic_Log__c = SupplementalScanResult.appendNoticeSafe(
                job.Scan_Diagnostic_Log__c, warn);
            typeCountsJson = '{"v":1}';
        }

        // --- 7. Update job to Completed ---
        // FOR UPDATE was acquired at entry to runSerializerCore(); no re-verify needed here.

        // Component_Type_Counts__c must be populated BEFORE transitioning to Completed so that
        // ScanSummaryQueueable has data to work with when it reads the job record.
        job.Result_File_Id__c        = contentVersion.ContentDocumentId;
        job.Component_Type_Counts__c = typeCountsJson;
        job.Status__c                = 'Completed';
        job.Status_Closed_At__c      = System.now();
        update job;

        // Expose settings and completed job to execute() so runPostCompletionTasks() can be
        // called AFTER the savepoint scope closes. This ensures no post-completion failure
        // can trigger a rollback of the Completed transition.
        this.coreSettings = settings;
        this.completedJob = job;
    }

    // -------------------------------------------------------------------------
    // Private - post-completion tasks (outside savepoint)
    // -------------------------------------------------------------------------

    private void runPostCompletionTasks(MetaMapper_Settings__mdt settings, Metadata_Scan_Job__c job) {
        // --- 8. Delete node records (NODES_ONLY - retain job record for result file pointer) ---
        // Read chunk size from CMDT so admins can tune it for orgs with heavy delete automation.
        Integer chunkSize = settings.Cleanup_Chunk_Size__c != null
            ? ((Decimal) settings.Cleanup_Chunk_Size__c).intValue() : 2000;
        // Database.executeBatch throws LimitException when batchSize > 2000.
        // Clamp to protect against admin misconfiguration in CMDT.
        chunkSize = Math.min(Math.max(chunkSize, 1), 2000);
        try {
            Database.executeBatch(
                new MetadataDependencyDeletionBatch(jobId, MetadataDependencyDeletionBatch.CleanupMode.NODES_ONLY),
                chunkSize
            );
        } catch (Exception e) {
            String warn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] WARNING: node cleanup batch '
                + 'scheduling failed - ' + e.getMessage()
                + '. Node records for this job were not deleted and will remain until the nightly cleanup runs.';
            System.debug(LoggingLevel.WARN,
                'ScanResultFileQueueable: cleanup batch scheduling failed for job '
                + jobId + ': ' + e.getMessage());
            // Use fresh-query overload: the in-memory job.Scan_Diagnostic_Log__c is stale at this point
            // (loaded at the start of execute() before the savepoint block committed its DML).
            appendWarningToJob(job, warn);
        }

        // --- 9. Ring buffer enforcement ---
        // DML statement budget guard: enforceRingBuffer() issues up to 3 DML statements
        // (ContentDocument delete, job record delete, diagnostic log update). Reserve 5
        // to provide headroom for any additional DML in the same transaction scope.
        // If fewer than 5 DML statements remain, skip ring buffer and log a notice.
        if (Limits.getLimitDmlStatements() - Limits.getDmlStatements() < 5) {
            String budgetWarn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] '
                + 'WARNING: ring buffer skipped - insufficient DML statement budget remaining ('
                + (Limits.getLimitDmlStatements() - Limits.getDmlStatements())
                + ' remaining). Oldest completed scan records may not have been deleted.';
            System.debug(LoggingLevel.WARN,
                'ScanResultFileQueueable: ring buffer skipped due to DML statement budget for job '
                + jobId);
            appendWarningToJob(job, budgetWarn);
        } else {
        // File delete and job delete are in separate try-catch blocks so a ContentDocument
        // deletion failure (e.g. file already removed) does not prevent the job record from
        // being cleaned up, and vice versa.
        try {
            enforceRingBuffer(settings, job);
        } catch (System.QueryException e) {
            String ringWarn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] WARNING: ring buffer enforcement failed - '
                + e.getMessage() + '. Oldest completed scan records may not have been deleted as expected.';
            System.debug(LoggingLevel.WARN,
                'ScanResultFileQueueable: ring buffer enforcement failed for job '
                + jobId + ': ' + e.getMessage());
            appendWarningToJob(job, ringWarn);
        } catch (System.DmlException e) {
            String ringWarn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] WARNING: ring buffer enforcement failed - '
                + e.getMessage() + '. Oldest completed scan records may not have been deleted as expected.';
            System.debug(LoggingLevel.WARN,
                'ScanResultFileQueueable: ring buffer enforcement failed for job '
                + jobId + ': ' + e.getMessage());
            appendWarningToJob(job, ringWarn);
        }
        } // end else (DML budget sufficient for ring buffer)

        // --- 10. Enqueue plain-English summary generator ---
        try {
            System.enqueueJob(new ScanSummaryQueueable(jobId));
        } catch (Exception e) {
            String warn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] WARNING: Scan_Summary_Text__c '
                + 'will not be populated - ScanSummaryQueueable enqueue failed: ' + e.getMessage() + '.';
            System.debug(LoggingLevel.WARN,
                'ScanResultFileQueueable: ScanSummaryQueueable enqueue failed for job '
                + jobId + ': ' + e.getMessage());
            // Set a minimal fallback Scan_Summary_Text__c so the LWC stops polling.
            // Without this, the LWC polls getJobStatus() indefinitely waiting for a
            // non-null Scan_Summary_Text__c that will never arrive.
            try {
                Metadata_Scan_Job__c fallbackJob =
                    new MetadataScanJobSelector().getByIdForSummary(jobId);
                if (fallbackJob != null) {
                    Integer total = fallbackJob.Components_Analyzed__c != null
                        ? ((Decimal) fallbackJob.Components_Analyzed__c).intValue() : 0;
                    fallbackJob.Scan_Summary_Text__c = 'This scan found ' + total
                        + ' dependenc' + (total == 1 ? 'y' : 'ies') + '.';
                    String existing = fallbackJob.Scan_Diagnostic_Log__c;
                    fallbackJob.Scan_Diagnostic_Log__c = SupplementalScanResult.appendNoticeSafe(
                        existing, warn);
                    if (Limits.getLimitDmlStatements() - Limits.getDmlStatements() >= 1
                            && Limits.getLimitDmlRows() - Limits.getDmlRows() >= 1) {
                        update fallbackJob;
                    } else {
                        appendWarningToJob(job, warn);
                    }
                }
            } catch (Exception fallbackEx) {
                System.debug(LoggingLevel.WARN,
                    'ScanResultFileQueueable: could not set fallback Scan_Summary_Text__c for job '
                    + jobId + ': ' + fallbackEx.getMessage());
                appendWarningToJob(job, warn);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Private - ring buffer
    // -------------------------------------------------------------------------

    // Ring buffer failure is non-fatal by design: the current job is already Completed
    // before this method is called. On any exception, the failure is logged to
    // Scan_Diagnostic_Log__c and execution continues. The oldest records will be pruned
    // on the next job completion. A failed ring buffer delete does NOT revert the Completed status.
    private void enforceRingBuffer(MetaMapper_Settings__mdt settings, Metadata_Scan_Job__c job) {
        Integer maxStored = settings.Max_Stored_Jobs__c != null
            ? ((Decimal) settings.Max_Stored_Jobs__c).intValue() : 5;

        // Avoid SELECT COUNT() without LIMIT: on orgs where cleanup has been disabled or
        // Completed jobs have accumulated, COUNT() can throw QueryException at >50,000 rows
        // (same risk that was fixed in MetadataDependencyDeletionBatch.finish() in Round 20).
        // Fetch enough candidates to detect excess and identify which jobs to prune.
        MetadataScanJobSelector jobSelector = new MetadataScanJobSelector();
        List<Metadata_Scan_Job__c> candidates =
            jobSelector.getCompletedJobsOldestFirst(maxStored + 10);
        if (candidates.size() <= maxStored) {
            return;
        }

        // Delete ALL excess records, not just the single oldest. Under normal operation
        // only one job is excess at a time (sequential completions). Under concurrent
        // completions, multiple records can accumulate and must all be pruned.
        Integer excessCount = candidates.size() - maxStored;
        // Wrap in a new List: Apex does not permit DML directly on a subList view
        // (throws ListException: DML operation on sublist is not permitted).
        List<Metadata_Scan_Job__c> toDelete = excessCount < candidates.size()
            ? new List<Metadata_Scan_Job__c>(candidates.subList(0, excessCount))
            : new List<Metadata_Scan_Job__c>(candidates);

        // Bulk-collect ContentDocument IDs before any deletion so we can issue a single
        // query (no SOQL inside loop).
        List<String> fileIds = new List<String>();
        for (Metadata_Scan_Job__c c : toDelete) {
            if (String.isNotBlank(c.Result_File_Id__c)) {
                fileIds.add(c.Result_File_Id__c);
            }
        }

        // Track which file IDs were successfully deleted so job records are only deleted
        // when their associated file is confirmed gone. A job whose file delete failed must
        // not be deleted - without the job record, the file has no pointer and becomes
        // permanently unreachable. The nightly batch retries on the next run.
        Set<String> successfullyDeletedFileIds = new Set<String>();
        if (!fileIds.isEmpty()) {
            try {
                List<ContentDocument> docs =
                    new MetadataDependencySelector().getContentDocumentsByIds(new Set<String>(fileIds));
                // Files absent from the query were already deleted (concurrent ring buffer
                // instance). Treat them as successfully deleted so their job records are
                // also cleaned up rather than over-retained.
                Set<String> foundFileIds = new Set<String>();
                for (ContentDocument doc : docs) {
                    foundFileIds.add(doc.Id);
                }
                for (String fId : fileIds) {
                    if (!foundFileIds.contains(fId)) {
                        successfullyDeletedFileIds.add(fId);
                    }
                }
                if (!docs.isEmpty()) {
                    // Partial-success delete: one already-deleted file (concurrent instance race)
                    // must not abort cleanup of the remaining files and their job records.
                    List<Database.DeleteResult> fileDeleteResults = Database.delete(docs, false);
                    for (Integer i = 0; i < fileDeleteResults.size(); i++) {
                        if (fileDeleteResults[i].isSuccess()) {
                            successfullyDeletedFileIds.add(docs[i].Id);
                        } else {
                            System.debug(LoggingLevel.WARN,
                                'ScanResultFileQueueable.enforceRingBuffer: ContentDocument delete '
                                + 'failed for ' + docs[i].Id + ': '
                                + fileDeleteResults[i].getErrors()[0].getMessage());
                        }
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'ScanResultFileQueueable.enforceRingBuffer: ContentDocument delete query failed - '
                    + e.getMessage());
            }
        }

        // Only delete job records whose files were successfully deleted or had no file.
        // Skipping jobs with failed file deletes preserves the file pointer for next nightly retry.
        List<Metadata_Scan_Job__c> jobsToDelete = new List<Metadata_Scan_Job__c>();
        for (Metadata_Scan_Job__c c : toDelete) {
            if (String.isBlank(c.Result_File_Id__c)
                || successfullyDeletedFileIds.contains(c.Result_File_Id__c)) {
                jobsToDelete.add(c);
            } else {
                System.debug(LoggingLevel.WARN,
                    'ScanResultFileQueueable.enforceRingBuffer: skipping job delete for '
                    + c.Id + ' - file delete failed for ContentDocument ' + c.Result_File_Id__c);
            }
        }
        if (!jobsToDelete.isEmpty()) {
            // Guard: do not delete a job that still has Metadata_Dependency__c child records.
            // If the NODES_ONLY cleanup batch failed or is still processing, deleting the job
            // record orphans child nodes permanently - the nightly batch discovers nodes via
            // their parent job record and cannot recover orphaned children without it.
            //
            // Single batched query replaces the previous per-job SOQL-in-loop pattern.
            // GROUP BY is still avoided (50k query-row risk on large jobs).
            // ORDER BY Metadata_Scan_Job__c groups rows by parent so the LIMIT is reached
            // only after at least one row per job with nodes is returned. Short-circuits once
            // all candidate job IDs are accounted for.
            Set<Id> toDeleteIds = new Map<Id, Metadata_Scan_Job__c>(jobsToDelete).keySet();
            Set<Id> jobsWithNodes = new Set<Id>();
            for (Metadata_Dependency__c n :
                new MetadataDependencySelector().getNodeExistenceByJobs(toDeleteIds)) {
                jobsWithNodes.add(n.Metadata_Scan_Job__c);
                if (jobsWithNodes.size() == toDeleteIds.size()) {
                    break; // all candidate jobs accounted for
                }
            }
            if (!jobsWithNodes.isEmpty()) {
                List<Metadata_Scan_Job__c> safe = new List<Metadata_Scan_Job__c>();
                for (Metadata_Scan_Job__c j : jobsToDelete) {
                    if (jobsWithNodes.contains(j.Id)) {
                        String nodeWarn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] '
                            + 'WARNING: ring buffer skipped delete of completed job ' + j.Id
                            + ' - child node records still exist. Node cleanup batch may still be '
                            + 'running or may have failed. Nightly cleanup will retry.';
                        System.debug(LoggingLevel.WARN,
                            'ScanResultFileQueueable.enforceRingBuffer: skipping job delete for '
                            + j.Id + ' - child node records still exist.');
                        appendWarningToJob(job, nodeWarn);
                    } else {
                        safe.add(j);
                    }
                }
                jobsToDelete = safe;
            }
            // Partial-success delete: one already-deleted record (concurrent instance race)
            // must not abort the cleanup of remaining excess records.
            if (!jobsToDelete.isEmpty()) {
                List<Database.DeleteResult> deleteResults = Database.delete(jobsToDelete, false);
                for (Integer i = 0; i < deleteResults.size(); i++) {
                    if (!deleteResults[i].isSuccess()) {
                        String deleteWarn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] '
                            + 'WARNING: ring buffer could not delete completed job ' + jobsToDelete[i].Id
                            + ': ' + deleteResults[i].getErrors()[0].getMessage()
                            + '. Ring buffer may retain one extra completed scan result.';
                        System.debug(LoggingLevel.WARN,
                            'ScanResultFileQueueable.enforceRingBuffer: job record delete failed for '
                            + jobsToDelete[i].Id + ': ' + deleteResults[i].getErrors()[0].getMessage());
                        appendWarningToJob(job, deleteWarn);
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Private - helpers
    // -------------------------------------------------------------------------

    /**
     * Appends a warning to an in-memory job record and persists it.
     * Use this overload from runPostCompletionTasks() where the job is already loaded —
     * it avoids a redundant SELECT + UPDATE pair per call.
     */
    private void appendWarningToJob(Metadata_Scan_Job__c job, String warning) {
        if (job == null) { return; }
        job.Scan_Diagnostic_Log__c = SupplementalScanResult.appendNoticeSafe(
            job.Scan_Diagnostic_Log__c, warning);
        try {
            update new Metadata_Scan_Job__c(
                Id = job.Id,
                Scan_Diagnostic_Log__c = job.Scan_Diagnostic_Log__c
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'ScanResultFileQueueable.appendWarningToJob: job update failed - '
                + e.getMessage());
        }
    }

    // -------------------------------------------------------------------------
    // Private - failure transition
    // -------------------------------------------------------------------------

    /**
     * Transitions the job to Failed. Only updates if current Status is Processing
     * to avoid overwriting a Completed or Cancelled status set by a concurrent instance.
     * Appends to Scan_Diagnostic_Log__c rather than overwriting to preserve prior diagnostics.
     * Publishes a PE failure event so the LWC stops polling and shows the error state.
     */
    private void updateJobFailed(String jobId, String errorMsg) {
        Boolean dmlSucceeded = false;
        // Declared outside the try block so the PE publish step can read the actual
        // analyzed count. The serializer runs after full traversal; hardcoding 0 would
        // show zero components in the LWC failure state even when thousands were found.
        Decimal analyzedCount = 0;
        try {
            // FOR UPDATE serializes concurrent ScanResultFileQueueable instances.
            // Without it, two concurrent instances could both SELECT, both see 'Processing',
            // and both attempt to set 'Failed' - creating a TOCTOU race where the second
            // instance could overwrite a 'Completed' status set by the first instance's
            // main path between the SELECT and the UPDATE.
            Metadata_Scan_Job__c lockedFailJob =
                new MetadataScanJobSelector().getForFailedUpdateLocked(jobId);
            List<Metadata_Scan_Job__c> jobs = lockedFailJob != null
                ? new List<Metadata_Scan_Job__c>{ lockedFailJob }
                : new List<Metadata_Scan_Job__c>();
            // Allow the Failed transition from any non-terminal status (Processing or Paused).
            // Paused is included: a Paused job that throws during serialization must transition
            // to Failed, not remain stuck in Paused with no recovery path.
            // Terminal statuses (Completed, Cancelled, Failed) must never be overwritten.
            if (jobs.isEmpty()
                || new Set<String>{ 'Completed', 'Cancelled', 'Failed' }
                       .contains(jobs[0].Status__c)) {
                return;
            }
            analyzedCount = jobs[0].Components_Analyzed__c != null
                ? jobs[0].Components_Analyzed__c : 0;
            String prior = jobs[0].Scan_Diagnostic_Log__c;
            jobs[0].Status__c = 'Failed';
            jobs[0].Scan_Diagnostic_Log__c = SupplementalScanResult.appendNoticeSafe(
                prior, errorMsg);
            jobs[0].Status_Closed_At__c = System.now();
            update jobs;
            dmlSucceeded = true;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'ScanResultFileQueueable.updateJobFailed: could not persist Failed status for job '
                + jobId + ' - ' + e.getMessage());
        }
        // Only fire the PE failure event when the DB update succeeded.
        // If DML failed, the DB still shows Processing and the LWC must keep polling.
        // Use EventBus.publish directly (not DependencyNotificationService.publishProgress)
        // to bypass the auto-suppress path: publishProgress can trigger appendNoticeToJob
        // (DML) and enqueueDeployment in a failure context where side-effects must be minimal.
        if (dmlSucceeded) {
            try {
                EventBus.publish(new List<SObject>{
                    new Dependency_Scan_Status__e(
                        Scan_Job_Id__c         = jobId,
                        Status__c              = 'Failed',
                        Components_Analyzed__c = analyzedCount.intValue(),
                        Progress_Message__c    = 'Analysis failed.'
                    )
                });
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'ScanResultFileQueueable.updateJobFailed: PE publish failed - ' + e.getMessage());
            }
        }
    }
}
