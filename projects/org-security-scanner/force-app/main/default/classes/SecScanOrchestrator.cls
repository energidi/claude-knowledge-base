public without sharing class SecScanOrchestrator implements Queueable, Database.AllowsCallouts {

    private Id scanRunId;
    private String sessionId;

    // Ordered list of runner class names - one per category, executed sequentially
    @TestVisible
    private static final List<String> RUNNER_CLASSES = new List<String>{
        'SecScanRunnerUserAccess',
        'SecScanRunnerGuestUser',
        'SecScanRunnerSharingAccess',
        'SecScanRunnerSessionAuth',
        'SecScanRunnerConnectedApps',
        'SecScanRunnerApexAutomation',
        'SecScanRunnerLwcAura',
        'SecScanRunnerAgentforce',
        'SecScanRunnerMetadataSecrets',
        'SecScanRunnerFileUpload',
        'SecScanRunnerCertEncryption',
        'SecScanRunnerMonitoring',
        'SecScanRunnerHealthCheck'
    };

    public SecScanOrchestrator(Id scanRunId, String sessionId) {
        this.scanRunId  = scanRunId;
        this.sessionId  = sessionId;
    }

    public void execute(QueueableContext ctx) {
        // Transition run to Running
        Database.update(
            new SecurityScanRun__c(Id = scanRunId, Status__c = 'Running', StartedAt__c = Datetime.now()),
            AccessLevel.SYSTEM_MODE
        );

        // Kick off the runner chain at index 0
        System.enqueueJob(new SecScanRunnerChain(scanRunId, RUNNER_CLASSES, 0, sessionId));
    }

    /**
     * Finalizes the scan run: computes score/grade, sets counts, triggers retention batch.
     * Called by SecScanRunnerChain after the last runner completes, or when scan is cancelled.
     *
     * CRITICAL: must NOT overwrite Status__c = 'Completed' if current status is 'Cancelled'.
     */
    public static void finalizeScan(Id scanRunId) {
        SecurityScanRun__c run = [
            SELECT Status__c
            FROM SecurityScanRun__c
            WHERE Id = :scanRunId
            LIMIT 1
        ];

        OrgSecurityScanner_Setting__mdt settings = OrgSecurityScanner_Setting__mdt.getInstance('Default');

        // Aggregate counts by severity (exclude nothing - these are the at-completion totals)
        Map<String, Integer> countsBySeverity = aggregateCounts(scanRunId);

        // Score computation: exclude Remediated and False Positive
        Map<String, Integer> openCounts = aggregateOpenCounts(scanRunId);
        Decimal score = computeScore(openCounts, settings);
        String grade = computeGrade(score);

        Integer totalFindings = 0;
        for (Integer c : countsBySeverity.values()) {
            totalFindings += c;
        }

        Integer totalChecksRun = [
            SELECT COUNT()
            FROM SecurityCheckDef__mdt
            WHERE IsActive__c = true
        ];

        // Build update record
        SecurityScanRun__c runUpdate = new SecurityScanRun__c(
            Id                = scanRunId,
            CompletedAt__c    = Datetime.now(),
            TotalChecksRun__c = totalChecksRun,
            TotalFindings__c  = totalFindings,
            CriticalCount__c  = countsBySeverity.containsKey('Critical')     ? countsBySeverity.get('Critical')     : 0,
            HighCount__c      = countsBySeverity.containsKey('High')         ? countsBySeverity.get('High')         : 0,
            MediumCount__c    = countsBySeverity.containsKey('Medium')       ? countsBySeverity.get('Medium')       : 0,
            LowCount__c       = countsBySeverity.containsKey('Low')          ? countsBySeverity.get('Low')          : 0,
            InfoCount__c      = countsBySeverity.containsKey('Informational')? countsBySeverity.get('Informational'): 0,
            Score__c          = score,
            Grade__c          = grade
        );

        // Only set Completed if not already Cancelled
        if (run.Status__c != 'Cancelled') {
            runUpdate.Status__c = 'Completed';
        }

        Database.update(runUpdate, AccessLevel.SYSTEM_MODE);

        // Trigger retention cleanup
        Integer maxRuns = (settings != null && settings.MaxScanRuns__c != null)
            ? (Integer) settings.MaxScanRuns__c
            : SecScanConstants.DEFAULT_MAX_SCAN_RUNS;
        Database.executeBatch(new SecScanRetentionBatch(maxRuns), 1);
    }

    // --- private score helpers ---

    private static Map<String, Integer> aggregateCounts(Id scanRunId) {
        Map<String, Integer> result = new Map<String, Integer>();
        for (AggregateResult ar : [
            SELECT Severity__c sev, COUNT(Id) cnt
            FROM SecurityFinding__c
            WHERE ScanRun__c = :scanRunId
            GROUP BY Severity__c
        ]) {
            result.put((String) ar.get('sev'), (Integer) ar.get('cnt'));
        }
        return result;
    }

    private static Map<String, Integer> aggregateOpenCounts(Id scanRunId) {
        Map<String, Integer> result = new Map<String, Integer>();
        for (AggregateResult ar : [
            SELECT Severity__c sev, COUNT(Id) cnt
            FROM SecurityFinding__c
            WHERE ScanRun__c = :scanRunId
              AND Status__c NOT IN ('Remediated', 'False Positive')
            GROUP BY Severity__c
        ]) {
            result.put((String) ar.get('sev'), (Integer) ar.get('cnt'));
        }
        return result;
    }

    @TestVisible
    static Decimal computeScore(Map<String, Integer> openCounts, OrgSecurityScanner_Setting__mdt s) {
        // Safe defaults when CMT is not yet deployed
        Decimal deductCritical = (s != null && s.ScoreDeductCritical__c != null) ? s.ScoreDeductCritical__c : 10;
        Decimal deductHigh     = (s != null && s.ScoreDeductHigh__c     != null) ? s.ScoreDeductHigh__c     : 4;
        Decimal deductMedium   = (s != null && s.ScoreDeductMedium__c   != null) ? s.ScoreDeductMedium__c   : 2;
        Decimal deductLow      = (s != null && s.ScoreDeductLow__c      != null) ? s.ScoreDeductLow__c      : 0.5;
        Decimal deductInfo     = (s != null && s.ScoreDeductInfo__c     != null) ? s.ScoreDeductInfo__c     : 0.1;

        Decimal capCritical = (s != null && s.ScoreCriticalCap__c != null) ? s.ScoreCriticalCap__c : 40;
        Decimal capHigh     = (s != null && s.ScoreHighCap__c     != null) ? s.ScoreHighCap__c     : 20;
        Decimal capMedium   = (s != null && s.ScoreMediumCap__c   != null) ? s.ScoreMediumCap__c   : 20;
        Decimal capLow      = (s != null && s.ScoreLowCap__c      != null) ? s.ScoreLowCap__c      : 10;
        Decimal capInfo     = (s != null && s.ScoreInfoCap__c     != null) ? s.ScoreInfoCap__c     : 5;
        Decimal floor       = (s != null && s.ScoreFloor__c       != null) ? s.ScoreFloor__c       : 5;

        Integer critCount = openCounts.containsKey('Critical')     ? openCounts.get('Critical')     : 0;
        Integer highCount = openCounts.containsKey('High')         ? openCounts.get('High')         : 0;
        Integer medCount  = openCounts.containsKey('Medium')       ? openCounts.get('Medium')       : 0;
        Integer lowCount  = openCounts.containsKey('Low')          ? openCounts.get('Low')          : 0;
        Integer infoCount = openCounts.containsKey('Informational')? openCounts.get('Informational'): 0;

        Decimal rawDeductCrit = critCount * deductCritical;
        Decimal rawDeductHigh = highCount * deductHigh;
        Decimal rawDeductMed  = medCount  * deductMedium;
        Decimal rawDeductLow  = lowCount  * deductLow;
        Decimal rawDeductInfo = infoCount * deductInfo;

        Decimal totalDeduction = Math.min(rawDeductCrit, capCritical)
            + Math.min(rawDeductHigh, capHigh)
            + Math.min(rawDeductMed,  capMedium)
            + Math.min(rawDeductLow,  capLow)
            + Math.min(rawDeductInfo, capInfo);

        Decimal score = 100 - totalDeduction;
        return Math.max(score, floor).setScale(2);
    }

    @TestVisible
    static String computeGrade(Decimal score) {
        if (score >= 90) return 'A';
        if (score >= 75) return 'B';
        if (score >= 60) return 'C';
        if (score >= 45) return 'D';
        return 'F';
    }
}
