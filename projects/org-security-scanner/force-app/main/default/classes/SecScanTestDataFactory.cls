/**
 * Shared test utility - single source of truth for creating SecurityScanRun__c
 * and SecurityFinding__c test records. All test classes use this.
 * Field changes require updating this file only.
 */
@IsTest
public class SecScanTestDataFactory {

    // ------------------------------------------------------------------
    // SecurityScanRun__c builders
    // ------------------------------------------------------------------

    /**
     * Creates and inserts a SecurityScanRun__c with Status=Completed and all count fields populated.
     */
    public static SecurityScanRun__c createCompletedRun() {
        return createCompletedRun(false);
    }

    public static SecurityScanRun__c createCompletedRun(Boolean isProduction) {
        SecurityScanRun__c run = new SecurityScanRun__c(
            Status__c           = 'Completed',
            StartedBy__c        = UserInfo.getUserId(),
            OrgId__c            = UserInfo.getOrganizationId(),
            StartedAt__c        = Datetime.now().addMinutes(-5),
            CompletedAt__c      = Datetime.now(),
            TotalChecksRun__c   = 76,
            TotalFindings__c    = 0,
            CriticalCount__c    = 0,
            HighCount__c        = 0,
            MediumCount__c      = 0,
            LowCount__c         = 0,
            InfoCount__c        = 0,
            Score__c            = 100,
            Grade__c            = 'A',
            IsProductionScan__c = isProduction,
            IsPartialScan__c    = false
        );
        insert run;
        return run;
    }

    public static SecurityScanRun__c createRunWithStatus(String status) {
        SecurityScanRun__c run = new SecurityScanRun__c(
            Status__c    = status,
            StartedBy__c = UserInfo.getUserId(),
            OrgId__c     = UserInfo.getOrganizationId(),
            StartedAt__c = Datetime.now().addMinutes(-1)
        );
        insert run;
        return run;
    }

    public static SecurityScanRun__c createPendingRun() {
        return createRunWithStatus('Pending');
    }

    public static SecurityScanRun__c createRunningRun() {
        return createRunWithStatus('Running');
    }

    public static SecurityScanRun__c createCancelledRun() {
        return createRunWithStatus('Cancelled');
    }

    public static SecurityScanRun__c createFailedRun() {
        return createRunWithStatus('Failed');
    }

    // ------------------------------------------------------------------
    // SecurityFinding__c builders
    // ------------------------------------------------------------------

    /**
     * Creates a single finding with the specified severity. Does NOT insert.
     */
    public static SecurityFinding__c buildFinding(Id scanRunId, String checkId, String severity) {
        return buildFinding(scanRunId, checkId, severity, 'Open');
    }

    public static SecurityFinding__c buildFinding(
        Id scanRunId, String checkId, String severity, String status
    ) {
        Integer rank = severityToRank(severity);
        return new SecurityFinding__c(
            ScanRun__c              = scanRunId,
            CheckId__c              = checkId,
            CheckName__c            = 'Test Check - ' + checkId,
            Category__c             = 'User & Access',
            CategoryCode__c         = 'UA',
            Severity__c             = severity,
            SeverityRank__c         = rank,
            FindingType__c          = 'Automated',
            Status__c               = status,
            AffectedComponent__c    = 'Test Component',
            AffectedComponentType__c = 'Profile',
            Description__c          = 'Test description for ' + checkId,
            Impact__c               = 'Test impact for ' + checkId,
            Remediation__c          = 'Test remediation for ' + checkId
        );
    }

    /**
     * Creates and inserts N findings of the given severity for the run.
     */
    public static List<SecurityFinding__c> createFindings(
        Id scanRunId, String severity, Integer count
    ) {
        List<SecurityFinding__c> findings = new List<SecurityFinding__c>();
        for (Integer i = 0; i < count; i++) {
            findings.add(buildFinding(scanRunId, severity.substring(0, 1) + '-' + String.valueOf(i).leftPad(3, '0'), severity));
        }
        insert findings;
        return findings;
    }

    /**
     * Creates and inserts one finding of each severity level.
     */
    public static List<SecurityFinding__c> createOneFindingPerSeverity(Id scanRunId) {
        List<SecurityFinding__c> findings = new List<SecurityFinding__c>{
            buildFinding(scanRunId, 'UA-001', 'Critical'),
            buildFinding(scanRunId, 'UA-002', 'High'),
            buildFinding(scanRunId, 'UA-003', 'Medium'),
            buildFinding(scanRunId, 'UA-004', 'Low'),
            buildFinding(scanRunId, 'UA-005', 'Informational')
        };
        insert findings;
        return findings;
    }

    /**
     * Creates a finding for a specific category with a custom category code.
     */
    public static SecurityFinding__c buildFindingForCategory(
        Id scanRunId, String checkId, String category, String categoryCode, String severity
    ) {
        Integer rank = severityToRank(severity);
        return new SecurityFinding__c(
            ScanRun__c              = scanRunId,
            CheckId__c              = checkId,
            CheckName__c            = 'Test Check - ' + checkId,
            Category__c             = category,
            CategoryCode__c         = categoryCode,
            Severity__c             = severity,
            SeverityRank__c         = rank,
            FindingType__c          = 'Automated',
            Status__c               = 'Open',
            AffectedComponent__c    = 'Test Component',
            AffectedComponentType__c = 'OrgSetting',
            Description__c          = 'Test description for ' + checkId,
            Impact__c               = 'Test impact for ' + checkId,
            Remediation__c          = 'Test remediation for ' + checkId
        );
    }

    /**
     * Creates a Recommendation-type finding.
     */
    public static SecurityFinding__c buildRecommendationFinding(Id scanRunId, String checkId) {
        SecurityFinding__c f = buildFinding(scanRunId, checkId, 'Medium');
        f.FindingType__c = 'Recommendation';
        f.CheckName__c   = 'Recommendation Check - ' + checkId;
        return f;
    }

    /**
     * Creates a finding with RawEvidence populated.
     */
    public static SecurityFinding__c buildFindingWithEvidence(
        Id scanRunId, String checkId, String severity, String evidence
    ) {
        SecurityFinding__c f = buildFinding(scanRunId, checkId, severity);
        f.RawEvidence__c = evidence;
        return f;
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    private static Integer severityToRank(String severity) {
        Map<String, Integer> rankMap = new Map<String, Integer>{
            'Critical'      => 1,
            'High'          => 2,
            'Medium'        => 3,
            'Low'           => 4,
            'Informational' => 5
        };
        return rankMap.containsKey(severity) ? rankMap.get(severity) : 5;
    }
}
