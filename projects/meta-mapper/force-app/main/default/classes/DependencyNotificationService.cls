/**
 * DependencyNotificationService
 *
 * Implements IScanNotificationService. Publishes Dependency_Scan_Status__e Platform Events
 * and enforces automatic suppression when the org daily PE allocation exceeds 80%.
 *
 * Auto-suppression path (two-phase, split across the callout boundary):
 *
 * Phase 1 - checkAndSuppressIfNeeded (called BEFORE Database.setSavepoint / before any DML):
 *   Checks OrgLimits. If >80% consumed: calls deploySuppressionFlag() which queues the
 *   CMDT deployment via Metadata.Operations.enqueueDeployment() (async, non-DML).
 *   Stores any deployment failure in deferredDeploymentError for Phase 2 to write.
 *   No DML here - this method must stay DML-free because it runs before the engine's
 *   callouts. Any DML before a callout triggers "uncommitted work pending".
 *
 * Phase 2 - publishProgress (called at step 19, AFTER all callouts and final DML):
 *   Re-checks OrgLimits (or short-circuits via Disable_Platform_Events__c).
 *   If still >80%: calls autoSuppressAndLog() which writes the suppression notice (plus
 *   any deferred CMDT failure message) to the job record via appendNoticeToJob, then
 *   returns without publishing the Platform Event.
 *
 * Edge case: if the daily limit crosses 80% between Phase 1 and Phase 2 (e.g. due to
 * a PE burst during the engine's Tooling API callouts), the CMDT flag is not set this
 * execution. The OrgLimits check re-runs on the next execution and attempts the flag
 * write then. The suppression notice IS written via Phase 2 in this execution.
 *
 * The CMDT write failure is non-fatal: deferredDeploymentError is written to the job
 * record so admins have visibility. The OrgLimits check re-runs next execution and
 * attempts the write again.
 *
 *
 */
public without sharing class DependencyNotificationService implements IScanNotificationService {

    private static final Decimal PE_SUPPRESS_THRESHOLD = 0.80;

    // Idempotency guard: only enqueue one CMDT deployment per Apex transaction.
    // A busy Queueable can call publishProgress() multiple times; without this guard
    // each call would queue a separate metadata deployment, exhausting the daily limit.
    private static Boolean suppressionDeploymentQueued = false;

    // Idempotency guard: only write the suppression notice to the job record once per
    // Apex transaction. Without this, multiple publishProgress() calls in the same
    // transaction each try to append the notice, causing duplicate diagnostic entries.
    private static Boolean suppressionNoticeWritten = false;

    // Deferred PE publish failure notices. When EventBus.publish() fails, we cannot
    // call appendNoticeToJob() (DML) inside the same for-loop as publish() because
    // DML inside an EventBus callback is disallowed in some governor contexts. Instead,
    // accumulate notices here and let DependencyQueueable drain them via
    // getAndClearPendingNotices() after the PE section completes.
    private static List<String> pendingPublishFailureNotices = new List<String>();

    /**
     * Returns and clears the accumulated PE publish failure notices.
     * Called by DependencyQueueable after publishProgress() to drain deferred notices
     * and append them to the job's Scan_Diagnostic_Log__c in a safe DML context.
     *
     * @return  List of notice strings accumulated since the last drain; may be empty
     */
    public static List<String> getAndClearPendingNotices() {
        List<String> notices = pendingPublishFailureNotices;
        pendingPublishFailureNotices = new List<String>();
        return notices;
    }

    // Stores the CMDT deployment failure message from deploySuppressionFlag() so it can
    // be written to the job record by autoSuppressAndLog() in Phase 2 (after callouts).
    // Null when no failure has occurred or when deployment succeeded.
    private static String deferredDeploymentError = null;

    /**
     * Called from DependencyQueueable.execute() BEFORE Database.setSavepoint().
     * Checks if auto-suppression is needed and, if so, queues the CMDT flag deployment.
     * DML-free by design: this method runs before the engine's Tooling API callouts, and
     * any DML before a callout triggers "uncommitted work pending". The suppression notice
     * is written later by autoSuppressAndLog() when publishProgress() is called (step 19).
     */
    public void checkAndSuppressIfNeeded(String jobId) {
        if (suppressionDeploymentQueued) { return; }
        MetaMapper_Settings__mdt settings = new MetaMapperSettingsProvider().getSettings();
        if (settings.Disable_Platform_Events__c) { return; }
        if (shouldAutoSuppress()) {
            deploySuppressionFlag();
            // Notice is written by autoSuppressAndLog() when publishProgress() fires at
            // step 19 - after all DML and callouts. No DML here.
        }
    }

    /**
     * Publishes one Dependency_Scan_Status__e event for the current Queueable execution.
     * Skips publish if Disable_Platform_Events__c = true, or auto-suppresses if the org
     * daily PE allocation is > 80% consumed.
     */
    public void publishProgress(String jobId, String status, Integer componentsAnalyzed, String message) {
        MetaMapper_Settings__mdt settings =
            new MetaMapperSettingsProvider().getSettings();

        if (settings.Disable_Platform_Events__c) {
            return;
        }

        if (shouldAutoSuppress()) {
            autoSuppressAndLog(jobId);
            return;
        }

        Dependency_Scan_Status__e peEvent = new Dependency_Scan_Status__e(
            Scan_Job_Id__c         = jobId,
            Status__c              = status,
            Components_Analyzed__c = componentsAnalyzed,
            Progress_Message__c    = String.isNotBlank(message) ? message.left(255) : ''
        );

        List<Database.SaveResult> results =
            EventBus.publish(new List<SObject>{ peEvent });
        for (Database.SaveResult r : results) {
            if (!r.isSuccess()) {
                String errMsg = r.getErrors()[0].getMessage();
                System.debug(LoggingLevel.WARN,
                    'DependencyNotificationService.publishProgress: PE publish failed for job '
                    + jobId + ' - ' + errMsg);
                // Defer the notice write: DML after EventBus.publish() in the same loop
                // is disallowed in some governor contexts. DependencyQueueable drains
                // pendingPublishFailureNotices via getAndClearPendingNotices() after this
                // method returns, then appends the notices in a safe DML window.
                String notice = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] '
                    + 'WARNING: Platform Event publish failed - ' + errMsg
                    + '. Progress event may not have reached the UI; consider enabling '
                    + 'Disable_Platform_Events__c to switch to polling mode.';
                pendingPublishFailureNotices.add(notice);
            }
        }
    }

    /**
     * No-op: completion is signalled via Status__c = 'Completed' on the job record.
     * The LWC detects this via Platform Event or polling.
     */
    public void sendCompletion(String jobId, String userId) {
        System.debug(LoggingLevel.INFO,
            'DependencyNotificationService.sendCompletion: job ' + jobId + ' completed.');
    }

    /**
     * Queues the CMDT deployment that flips Disable_Platform_Events__c = true.
     * Called from checkAndSuppressIfNeeded() (before any DML) to stay clear of the
     * "callout with uncommitted DML" platform restriction. Must NOT be called after DML.
     * Stores failure details in deferredDeploymentError for later write by autoSuppressAndLog().
     */
    private void deploySuppressionFlag() {
        if (suppressionDeploymentQueued) { return; }
        try {
            Metadata.CustomMetadata mdRecord = new Metadata.CustomMetadata();
            mdRecord.fullName = 'MetaMapper_Settings__mdt.Default';
            mdRecord.label    = 'Default';
            Metadata.CustomMetadataValue fieldValue = new Metadata.CustomMetadataValue();
            fieldValue.field   = 'Disable_Platform_Events__c';
            fieldValue.value   = true;
            mdRecord.values   = new List<Metadata.CustomMetadataValue>{ fieldValue };
            Metadata.DeployContainer container = new Metadata.DeployContainer();
            container.addMetadata(mdRecord);
            Metadata.Operations.enqueueDeployment(container, null);
            suppressionDeploymentQueued = true;
            deferredDeploymentError = null; // clear any stale failure from a prior attempt
        } catch (Exception e) {
            // Store for deferred write: autoSuppressAndLog() will append this to the job
            // record at step 19 (after callouts) where DML is safe.
            String timestamp = System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
            deferredDeploymentError =
                '[' + timestamp + '] WARNING: Auto-suppress CMDT write failed - '
                + e.getMessage()
                + '. Disable_Platform_Events__c was NOT set. The OrgLimits check will re-run on the next execution.';
            System.debug(LoggingLevel.WARN,
                'DependencyNotificationService.deploySuppressionFlag: CMDT write failed - '
                + e.getMessage());
        }
    }

    private Boolean shouldAutoSuppress() {
        OrgLimit peLimit =
            OrgLimits.getMap().get('DailyStandardVolumePlatformEvents');
        if (peLimit == null || peLimit.getLimit() == 0 || peLimit.getValue() == null) {
            return false;
        }
        return ((Decimal) peLimit.getValue() / peLimit.getLimit()) >= PE_SUPPRESS_THRESHOLD;
    }

    private void autoSuppressAndLog(String jobId) {
        String timestamp = System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        String notice = '[' + timestamp + '] AUTO-SUPPRESS: Platform Events suppressed - '
            + 'org daily delivery limit >80% consumed. '
            + 'Progress updates switched to polling.';
        System.debug(LoggingLevel.WARN, notice);

        // deploySuppressionFlag() is NOT called here: this method is invoked from
        // publishProgress() at step 19, after DML (update job). Calling
        // Metadata.Operations.enqueueDeployment() after DML would throw
        // "uncommitted work pending". The deployment is handled by deploySuppressionFlag()
        // in checkAndSuppressIfNeeded() (before any DML). If that call failed, the error
        // is stored in deferredDeploymentError and written below so admins have visibility.

        // Append suppression notice (plus any deferred CMDT failure) to the job's
        // Scan_Diagnostic_Log__c. The static guard prevents duplicate entries when
        // autoSuppressAndLog is called multiple times within the same transaction.
        if (!suppressionNoticeWritten) {
            String fullNotice = deferredDeploymentError != null
                ? notice + '\n' + deferredDeploymentError
                : notice;
            appendNoticeToJob(jobId, fullNotice);
            suppressionNoticeWritten = true;
        }
    }

    private void appendNoticeToJob(String jobId, String notice) {
        try {
            Metadata_Scan_Job__c job = new MetadataScanJobSelector().getByIdForLogAppend(jobId);
            if (job != null) {
                job.Scan_Diagnostic_Log__c = SupplementalScanResult.appendNoticeSafe(
                        job.Scan_Diagnostic_Log__c, notice);
                job.Platform_Events_Auto_Suppressed__c = true;
                update job;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'DependencyNotificationService.appendNoticeToJob: job update failed - '
                + e.getMessage());
        }
    }
}
