public without sharing class SecScanRunnerChain implements Queueable, Database.AllowsCallouts {

    private Id scanRunId;
    private List<String> runners;
    private Integer currentIndex;
    private String sessionId;

    // @TestVisible flag replaces Test.isRunningTest() anti-pattern.
    // Tests set this to false before calling execute() to prevent chaining.
    @TestVisible private Boolean chainEnabled = true;

    public SecScanRunnerChain(Id scanRunId, List<String> runners, Integer currentIndex, String sessionId) {
        this.scanRunId     = scanRunId;
        this.runners       = runners;
        this.currentIndex  = currentIndex;
        this.sessionId     = sessionId;
    }

    public void execute(QueueableContext ctx) {
        // Cancellation check - must be first
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
        String categoryCode = deriveCategoryCode(runnerClassName);

        try {
            SecScanCategoryRunner runner =
                (SecScanCategoryRunner) Type.forName(runnerClassName).newInstance();
            runner.execute(scanRunId, sessionId);
            appendCompletedCategory(scanRunId, categoryCode);
        } catch (SecScanSessionExpiredException se) {
            // Session expiry propagates to all remaining categories
            String msg = 'Session expired - re-run scan. If this recurs, your org\'s session timeout '
                + 'may be shorter than the scan duration, or your org\'s security settings restrict '
                + 'Tooling API access from Lightning sessions. Consider using Named Credential (v2).';
            logError(scanRunId, categoryCode, se, msg);
            // Mark all remaining categories as failed
            markRemainingFailed(scanRunId, runners, currentIndex);
            SecScanOrchestrator.finalizeScan(scanRunId);
            return;
        } catch (Exception e) {
            logError(scanRunId, categoryCode, e, null);
        }

        // Advance chain or finalize
        Boolean isLast = (currentIndex + 1 >= runners.size());
        if (isLast) {
            SecScanOrchestrator.finalizeScan(scanRunId);
        } else if (chainEnabled) {
            System.enqueueJob(new SecScanRunnerChain(scanRunId, runners, currentIndex + 1, sessionId));
        } else {
            // Test context: chainEnabled = false - finalize directly so test assertions work
            SecScanOrchestrator.finalizeScan(scanRunId);
        }
    }

    // --- private helpers ---

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

    private void logError(Id scanRunId, String categoryCode, Exception e, String overrideMessage) {
        SecurityScanRun__c run = [
            SELECT FailedCategories__c, ErrorDetails__c
            FROM SecurityScanRun__c
            WHERE Id = :scanRunId
            LIMIT 1
        ];

        // Append to FailedCategories__c
        String failedExisting = run.FailedCategories__c;
        String failedUpdated = String.isBlank(failedExisting)
            ? categoryCode
            : failedExisting + ',' + categoryCode;

        // Append to ErrorDetails__c with overflow protection
        String newEntry = '[' + categoryCode + '] '
            + e.getTypeName() + ': '
            + (String.isBlank(overrideMessage) ? e.getMessage() : overrideMessage)
            + '\n' + e.getStackTraceString()
            + '\n---\n';

        String existing = run.ErrorDetails__c == null ? '' : run.ErrorDetails__c;
        String appended;
        if (existing.length() >= SecScanConstants.MAX_ERROR_DETAILS_LENGTH) {
            appended = existing; // already at cap
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
        // Mark from currentIndex onwards (current + all remaining) as failed
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

    // Derive the category code from the runner class name
    // e.g. SecScanRunnerUserAccess -> UA, SecScanRunnerGuestUser -> GU
    private static Map<String, String> CLASS_TO_CODE = new Map<String, String>{
        'SecScanRunnerUserAccess'    => 'UA',
        'SecScanRunnerGuestUser'     => 'GU',
        'SecScanRunnerSharingAccess' => 'SRA',
        'SecScanRunnerSessionAuth'   => 'SA',
        'SecScanRunnerConnectedApps' => 'CAI',
        'SecScanRunnerApexAutomation'=> 'AA',
        'SecScanRunnerLwcAura'       => 'LA',
        'SecScanRunnerAgentforce'    => 'AGA',
        'SecScanRunnerMetadataSecrets'=> 'MS',
        'SecScanRunnerFileUpload'    => 'FUE',
        'SecScanRunnerCertEncryption'=> 'CE',
        'SecScanRunnerMonitoring'    => 'MON',
        'SecScanRunnerHealthCheck'   => 'HCB'
    };

    private static String deriveCategoryCode(String className) {
        return CLASS_TO_CODE.containsKey(className)
            ? CLASS_TO_CODE.get(className)
            : className;
    }
}
