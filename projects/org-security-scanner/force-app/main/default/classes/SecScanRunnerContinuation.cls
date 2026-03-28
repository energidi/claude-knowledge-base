public without sharing class SecScanRunnerContinuation implements Queueable, Database.AllowsCallouts {

    private Id scanRunId;
    private List<String> runners;
    private Integer currentIndex;
    private String sessionId;
    private Integer pageOffset;

    public SecScanRunnerContinuation(
        Id scanRunId,
        List<String> runners,
        Integer currentIndex,
        String sessionId,
        Integer pageOffset
    ) {
        this.scanRunId    = scanRunId;
        this.runners      = runners;
        this.currentIndex = currentIndex;
        this.sessionId    = sessionId;
        this.pageOffset   = pageOffset;
    }

    public void execute(QueueableContext ctx) {
        // Cancellation check - same pattern as SecScanRunnerChain
        SecurityScanRun__c run = [
            SELECT Status__c
            FROM SecurityScanRun__c
            WHERE Id = :scanRunId
            LIMIT 1
        ];

        if (run.Status__c == 'Cancelled') {
            SecScanOrchestrator.finalizeScan(scanRunId);
            return;
        }

        String runnerClassName = runners[currentIndex];
        try {
            // Instantiate the runner and tell it to resume from pageOffset
            // Runners that support continuation must implement resumeFromPage(Id, String, Integer)
            SecScanCategoryRunner runner =
                (SecScanCategoryRunner) Type.forName(runnerClassName).newInstance();

            // Use the continuation interface for heap-split runners (AA, LA)
            if (runner instanceof IResumable) {
                ((IResumable) runner).resumeFromPage(scanRunId, sessionId, pageOffset, runners, currentIndex);
            } else {
                // Non-resumable runner called from continuation - treat as complete for this category
                // (should not happen in normal flow)
                runner.execute(scanRunId, sessionId);
                appendCompletedCategory(scanRunId, deriveCategoryCode(runnerClassName));
                advanceChain();
            }
        } catch (SecScanSessionExpiredException se) {
            logSessionError(scanRunId, deriveCategoryCode(runnerClassName), se);
            markRemainingFailed(scanRunId, runners, currentIndex);
            SecScanOrchestrator.finalizeScan(scanRunId);
        } catch (Exception e) {
            logError(scanRunId, deriveCategoryCode(runnerClassName), e);
            advanceChain();
        }
    }

    /**
     * Interface for category runners that support heap-safe continuation (AA, LA).
     * resumeFromPage() resumes Tooling API paging from pageOffset, saves additional findings,
     * then either enqueues another continuation (if still heap-pressured) or advances the chain.
     */
    public interface IResumable {
        void resumeFromPage(
            Id scanRunId,
            String sessionId,
            Integer pageOffset,
            List<String> runners,
            Integer currentIndex
        );
    }

    // --- helpers ---

    private void advanceChain() {
        Boolean isLast = (currentIndex + 1 >= runners.size());
        if (isLast) {
            SecScanOrchestrator.finalizeScan(scanRunId);
        } else {
            System.enqueueJob(new SecScanRunnerChain(scanRunId, runners, currentIndex + 1, sessionId));
        }
    }

    private static void appendCompletedCategory(Id scanRunId, String categoryCode) {
        SecurityScanRun__c run = [
            SELECT CompletedCategories__c
            FROM SecurityScanRun__c
            WHERE Id = :scanRunId
            LIMIT 1
        ];
        String existing = run.CompletedCategories__c;
        String updated = String.isBlank(existing)
            ? categoryCode
            : existing + ',' + categoryCode;
        update new SecurityScanRun__c(
            Id = scanRunId,
            CompletedCategories__c = updated
        );
    }

    private void logSessionError(Id scanRunId, String categoryCode, SecScanSessionExpiredException se) {
        String msg = 'Session expired during continuation (page ' + pageOffset + '). '
            + 'Re-run the scan. If this recurs, the scan duration may exceed the org session timeout.';
        logError(scanRunId, categoryCode, (Exception) se);
    }

    private void logError(Id scanRunId, String categoryCode, Exception e) {
        SecurityScanRun__c run = [
            SELECT FailedCategories__c, ErrorDetails__c
            FROM SecurityScanRun__c
            WHERE Id = :scanRunId
            LIMIT 1
        ];

        String failedExisting = run.FailedCategories__c;
        String failedUpdated = String.isBlank(failedExisting)
            ? categoryCode
            : failedExisting + ',' + categoryCode;

        String newEntry = '[' + categoryCode + '-CONTINUATION] '
            + e.getTypeName() + ': ' + e.getMessage()
            + '\n' + e.getStackTraceString()
            + '\n---\n';

        String existing = run.ErrorDetails__c == null ? '' : run.ErrorDetails__c;
        String appended;
        if (existing.length() >= SecScanConstants.MAX_ERROR_DETAILS_LENGTH) {
            appended = existing;
        } else if (existing.length() + newEntry.length() > SecScanConstants.MAX_ERROR_DETAILS_LENGTH) {
            appended = existing + '[truncated - additional errors omitted]';
        } else {
            appended = existing + newEntry;
        }

        update new SecurityScanRun__c(
            Id                  = scanRunId,
            FailedCategories__c = failedUpdated,
            ErrorDetails__c     = appended
        );
    }

    private void markRemainingFailed(Id scanRunId, List<String> allRunners, Integer fromIndex) {
        for (Integer i = fromIndex; i < allRunners.size(); i++) {
            String cc = deriveCategoryCode(allRunners[i]);
            SecurityScanRun__c run = [
                SELECT FailedCategories__c
                FROM SecurityScanRun__c
                WHERE Id = :scanRunId
                LIMIT 1
            ];
            String existing = run.FailedCategories__c;
            update new SecurityScanRun__c(
                Id = scanRunId,
                FailedCategories__c = String.isBlank(existing) ? cc : existing + ',' + cc
            );
        }
    }

    private static final Map<String, String> CLASS_TO_CODE = new Map<String, String>{
        'SecScanRunnerUserAccess'     => 'UA',
        'SecScanRunnerGuestUser'      => 'GU',
        'SecScanRunnerSharingAccess'  => 'SRA',
        'SecScanRunnerSessionAuth'    => 'SA',
        'SecScanRunnerConnectedApps'  => 'CAI',
        'SecScanRunnerApexAutomation' => 'AA',
        'SecScanRunnerLwcAura'        => 'LA',
        'SecScanRunnerAgentforce'     => 'AGA',
        'SecScanRunnerMetadataSecrets'=> 'MS',
        'SecScanRunnerFileUpload'     => 'FUE',
        'SecScanRunnerCertEncryption' => 'CE',
        'SecScanRunnerMonitoring'     => 'MON',
        'SecScanRunnerHealthCheck'    => 'HCB'
    };

    private static String deriveCategoryCode(String className) {
        return CLASS_TO_CODE.containsKey(className)
            ? CLASS_TO_CODE.get(className)
            : className;
    }
}
