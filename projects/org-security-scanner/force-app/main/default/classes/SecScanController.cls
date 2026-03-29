public with sharing class SecScanController {

    private static final String JOB_NAME = 'OrgSecurityScanner_Admin';

    // ------------------------------------------------------------------
    // startScan()
    // ------------------------------------------------------------------
    @AuraEnabled(cacheable=false)
    public static SecScanApiResponse startScan() {
        try {
            // Permission set validation (defense-in-depth)
            validatePermissionSet();

            // Production gate check
            Organization org = [
                SELECT Id, IsSandbox, Name
                FROM Organization
                WITH USER_MODE
                LIMIT 1
            ];

            if (org.IsSandbox == false) {
                OrgSecurityScanner_Setting__mdt settings = OrgSecurityScanner_Setting__mdt.getInstance('Default');
                Boolean allowProd = settings != null && settings.AllowProductionScan__c == true;
                if (!allowProd) {
                    throw new SecScanException(
                        'Production scanning is disabled. Enable AllowProductionScan__c in OrgSecurityScanner_Setting__mdt to proceed.'
                    );
                }
            }

            // Concurrency guard: insert-first pattern
            SecurityScanRun__c newRun = new SecurityScanRun__c(
                Status__c = 'Pending',
                StartedBy__c = UserInfo.getUserId(),
                OrgId__c = UserInfo.getOrganizationId(),
                IsProductionScan__c = (org.IsSandbox == false),
                IsPartialScan__c = !currentUserHasFullMetadataVisibility()
            );
            Database.insert(newRun, AccessLevel.SYSTEM_MODE);

            // Check for concurrent runs
            Integer runningCount = [
                SELECT COUNT()
                FROM SecurityScanRun__c
                WHERE Status__c IN ('Pending', 'Running')
            ];
            if (runningCount > 1) {
                Database.delete(newRun, AccessLevel.SYSTEM_MODE);
                throw new SecScanException('A scan is already in progress. Wait for it to complete or cancel it first.');
            }

            // Capture session ID synchronously - returns null in async
            String sessionId = UserInfo.getSessionId();

            // Enqueue orchestrator
            System.enqueueJob(new SecScanOrchestrator(newRun.Id, sessionId));

            return SecScanApiResponse.ok(newRun.Id);

        } catch (SecScanException se) {
            return SecScanApiResponse.error(se.getMessage());
        } catch (Exception e) {
            return SecScanApiResponse.error('Unexpected error: ' + e.getMessage());
        }
    }

    // ------------------------------------------------------------------
    // getOrgInfo()
    // ------------------------------------------------------------------
    @AuraEnabled(cacheable=true)
    public static SecScanApiResponse getOrgInfo() {
        try {
            List<Organization> orgs = [
                SELECT Id, IsSandbox, Name
                FROM Organization
                WITH USER_MODE
                LIMIT 1
            ];

            SecScanApiResponse.OrgInfoDTO dto = new SecScanApiResponse.OrgInfoDTO();
            if (orgs.isEmpty()) {
                // Null result is unusual - default to sandbox (safe: prevents suppressing prod warning)
                dto.isSandbox = true;
                dto.orgId     = '';
                dto.orgName   = '';
            } else {
                Organization o = orgs[0];
                dto.isSandbox = o.IsSandbox != false; // null -> treat as sandbox
                dto.orgId     = o.Id;
                dto.orgName   = o.Name;
            }
            return SecScanApiResponse.ok(dto);
        } catch (Exception e) {
            // On failure treat as sandbox - safer than missing the production banner
            SecScanApiResponse.OrgInfoDTO dto = new SecScanApiResponse.OrgInfoDTO();
            dto.isSandbox = true;
            dto.orgId     = '';
            dto.orgName   = 'Unknown';
            return SecScanApiResponse.ok(dto);
        }
    }

    // ------------------------------------------------------------------
    // getScanRuns()
    // ------------------------------------------------------------------
    @AuraEnabled(cacheable=true)
    public static SecScanApiResponse getScanRuns() {
        try {
            List<SecurityScanRun__c> runs = [
                SELECT Id, Name, Status__c, StartedAt__c, CompletedAt__c,
                       TotalChecksRun__c, TotalFindings__c,
                       CriticalCount__c, HighCount__c, MediumCount__c, LowCount__c, InfoCount__c,
                       Score__c, Grade__c, IsProductionScan__c, IsPartialScan__c,
                       FailedCategories__c, CompletedCategories__c, OrgId__c,
                       StartedBy__r.Name
                FROM SecurityScanRun__c

                WITH USER_MODE

                ORDER BY CreatedDate DESC

                LIMIT 50
            ];
            return SecScanApiResponse.ok(runs);
        } catch (Exception e) {
            return SecScanApiResponse.error(e.getMessage());
        }
    }

    // ------------------------------------------------------------------
    // getOrgSecuritySettings()
    // ------------------------------------------------------------------
    @AuraEnabled(cacheable=true)
    public static SecScanApiResponse getOrgSecuritySettings() {
        OrgSecurityScanner_Setting__mdt s = OrgSecurityScanner_Setting__mdt.getInstance('Default');
        SecScanApiResponse.OrgSecuritySettingsDTO dto = new SecScanApiResponse.OrgSecuritySettingsDTO();

        dto.maxScanRuns                 = (s != null && s.MaxScanRuns__c            != null) ? (Integer)  s.MaxScanRuns__c            : SecScanConstants.DEFAULT_MAX_SCAN_RUNS;
        dto.allowProductionScan         = (s != null && s.AllowProductionScan__c    != null) ? s.AllowProductionScan__c               : false;
        dto.portalHealthScoreThreshold  = (s != null && s.PortalHealthScoreThreshold__c != null) ? (Integer) s.PortalHealthScoreThreshold__c : 70;
        dto.scoreFloor                  = (s != null && s.ScoreFloor__c             != null) ? (Integer)  s.ScoreFloor__c             : SecScanConstants.DEFAULT_SCORE_FLOOR;
        dto.scoreDeductCritical         = (s != null && s.ScoreDeductCritical__c    != null) ? s.ScoreDeductCritical__c               : 10;
        dto.scoreDeductHigh             = (s != null && s.ScoreDeductHigh__c        != null) ? s.ScoreDeductHigh__c                   : 4;
        dto.scoreDeductMedium           = (s != null && s.ScoreDeductMedium__c      != null) ? s.ScoreDeductMedium__c                 : 2;
        dto.scoreDeductLow              = (s != null && s.ScoreDeductLow__c         != null) ? s.ScoreDeductLow__c                    : 0.5;
        dto.scoreDeductInfo             = (s != null && s.ScoreDeductInfo__c        != null) ? s.ScoreDeductInfo__c                   : 0.1;
        dto.scoreCriticalCap            = (s != null && s.ScoreCriticalCap__c       != null) ? s.ScoreCriticalCap__c                  : 40;
        dto.scoreHighCap                = (s != null && s.ScoreHighCap__c           != null) ? s.ScoreHighCap__c                      : 20;
        dto.scoreMediumCap              = (s != null && s.ScoreMediumCap__c         != null) ? s.ScoreMediumCap__c                    : 20;
        dto.scoreLowCap                 = (s != null && s.ScoreLowCap__c            != null) ? s.ScoreLowCap__c                       : 10;
        dto.scoreInfoCap                = (s != null && s.ScoreInfoCap__c           != null) ? s.ScoreInfoCap__c                      : 5;

        return SecScanApiResponse.ok(dto);
    }

    // ------------------------------------------------------------------
    // getScanRunStatus() - polled, NOT cacheable
    // ------------------------------------------------------------------
    @AuraEnabled(cacheable=false)
    public static SecScanApiResponse getScanRunStatus(String scanRunId) {
        try {
            if (String.isBlank(scanRunId)) {
                return SecScanApiResponse.error('scanRunId is required');
            }
            SecurityScanRun__c run = [
                SELECT Status__c, FailedCategories__c, CompletedCategories__c,
                       IsPartialScan__c, TotalFindings__c
                FROM SecurityScanRun__c
                WHERE Id = :scanRunId
                WITH USER_MODE
                LIMIT 1
            ];
            SecScanApiResponse.ScanStatusDTO dto = new SecScanApiResponse.ScanStatusDTO();
            dto.status              = run.Status__c;
            dto.failedCategories    = run.FailedCategories__c;
            dto.completedCategories = run.CompletedCategories__c;
            dto.isPartialScan       = run.IsPartialScan__c;
            dto.totalFindings       = run.TotalFindings__c != null ? (Integer) run.TotalFindings__c : 0;
            return SecScanApiResponse.ok(dto);
        } catch (Exception e) {
            return SecScanApiResponse.error(e.getMessage());
        }
    }

    // ------------------------------------------------------------------
    // cancelScan()
    // ------------------------------------------------------------------
    @AuraEnabled(cacheable=false)
    public static SecScanApiResponse cancelScan(String scanRunId) {
        try {
            if (String.isBlank(scanRunId)) {
                return SecScanApiResponse.error('scanRunId is required');
            }
            SecurityScanRun__c run = [
                SELECT Status__c
                FROM SecurityScanRun__c
                WHERE Id = :scanRunId
                WITH USER_MODE
                LIMIT 1
            ];
            if (SecScanConstants.TERMINAL_STATUSES.contains(run.Status__c)) {
                return SecScanApiResponse.error(
                    'Scan has already completed and cannot be cancelled. Status: ' + run.Status__c
                );
            }
            Database.update(
                new SecurityScanRun__c(Id = scanRunId, Status__c = 'Cancelled'),
                AccessLevel.USER_MODE
            );
            return SecScanApiResponse.ok(null);
        } catch (Exception e) {
            return SecScanApiResponse.error(e.getMessage());
        }
    }

    // ------------------------------------------------------------------
    // exportFindingsCsv()
    // ------------------------------------------------------------------
    @AuraEnabled(cacheable=false)
    public static SecScanApiResponse exportFindingsCsv(String scanRunId) {
        try {
            if (String.isBlank(scanRunId)) {
                return SecScanApiResponse.error('scanRunId is required');
            }

            // Pre-emptive size guard: COUNT before building string (6MB heap limit)
            Integer findingCount = [
                SELECT COUNT()
                FROM SecurityFinding__c
                WHERE ScanRun__c = :scanRunId
                WITH USER_MODE
            ];
            Boolean truncateText = findingCount > SecScanConstants.MAX_CSV_FINDINGS_BEFORE_TRUNCATE;

            List<SecurityFinding__c> findings = [
                SELECT CheckId__c, CheckName__c, Category__c, Severity__c, FindingType__c,
                       Status__c, AffectedComponent__c, AffectedComponentType__c,
                       Description__c, Impact__c, Remediation__c,
                       AcknowledgedBy__r.Name, AcknowledgedDate__c, SalesforceDocUrl__c
                FROM SecurityFinding__c
                WHERE ScanRun__c = :scanRunId
                WITH USER_MODE
                ORDER BY SeverityRank__c ASC, Id ASC
            ];

            String csv = buildCsv(findings, truncateText);

            SecurityScanRun__c run = [
                SELECT Name FROM SecurityScanRun__c WHERE Id = :scanRunId WITH USER_MODE LIMIT 1
            ];

            ContentVersion cv = new ContentVersion(
                Title           = 'Security Scan Export - ' + run.Name + ' - ' + Date.today().format(),
                PathOnClient    = 'SecurityScanExport_' + run.Name + '.csv',
                VersionData     = Blob.valueOf(csv),
                IsMajorVersion  = true,
                Description     = truncateText
                    ? 'Text columns truncated - finding count (' + findingCount + ') exceeded safe export threshold.'
                    : 'Security scan findings export.'
            );
            Database.insert(cv, AccessLevel.USER_MODE);

            // Link to scan run record
            ContentVersion inserted = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];
            ContentDocumentLink cdl = new ContentDocumentLink(
                ContentDocumentId = inserted.ContentDocumentId,
                LinkedEntityId    = scanRunId,
                ShareType         = 'I',
                Visibility        = 'InternalUsers'
            );
            Database.insert(cdl, AccessLevel.USER_MODE);

            return SecScanApiResponse.ok(inserted.ContentDocumentId);

        } catch (Exception e) {
            return SecScanApiResponse.error(e.getMessage());
        }
    }

    // ------------------------------------------------------------------
    // private helpers
    // ------------------------------------------------------------------

    private static void validatePermissionSet() {
        List<PermissionSetAssignment> psa = [
            SELECT Id
            FROM PermissionSetAssignment
            WHERE AssigneeId = :UserInfo.getUserId()
              AND PermissionSet.Name = 'OrgSecurityScanner_Admin'
            WITH USER_MODE
            LIMIT 1
        ];
        if (psa.isEmpty()) {
            throw new SecScanException(
                'You need the OrgSecurityScanner_Admin permission set to run scans.'
            );
        }
    }

    private static Boolean currentUserHasFullMetadataVisibility() {
        List<PermissionSet> ps = [
            SELECT Id
            FROM PermissionSet
            WHERE IsOwnedByProfile = true
              AND Profile.Id = :UserInfo.getProfileId()
              AND PermissionsModifyAllData = true
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return !ps.isEmpty();
    }

    // RFC 4180 compliant CSV builder
    private static String buildCsv(List<SecurityFinding__c> findings, Boolean truncateText) {
        String[] headers = new String[]{
            'CheckId', 'CheckName', 'Category', 'Severity', 'FindingType',
            'Status', 'AffectedComponent', 'AffectedComponentType',
            'Description', 'Impact', 'Remediation',
            'AcknowledgedBy', 'AcknowledgedDate', 'SalesforceDocUrl'
        };

        List<String> rows = new List<String>();
        rows.add(csvRow(headers));

        for (SecurityFinding__c f : findings) {
            String descText    = truncateText ? truncField(f.Description__c) : f.Description__c;
            String impact      = truncateText ? truncField(f.Impact__c)      : f.Impact__c;
            String remediation = truncateText ? truncField(f.Remediation__c) : f.Remediation__c;

            rows.add(csvRow(new String[]{
                f.CheckId__c,
                f.CheckName__c,
                f.Category__c,
                f.Severity__c,
                f.FindingType__c,
                f.Status__c,
                f.AffectedComponent__c,
                f.AffectedComponentType__c,
                descText,
                impact,
                remediation,
                f.AcknowledgedBy__r != null ? f.AcknowledgedBy__r.Name : '',
                f.AcknowledgedDate__c != null ? String.valueOf(f.AcknowledgedDate__c) : '',
                f.SalesforceDocUrl__c != null ? f.SalesforceDocUrl__c : ''
            }));
        }
        return String.join(rows, '\n');
    }

    // RFC 4180: join fields, wrap fields containing commas/quotes/newlines in double-quotes
    private static String csvRow(String[] fields) {
        List<String> escaped = new List<String>();
        for (String f : fields) {
            String val = f == null ? '' : f;
            // Escape embedded double-quotes by doubling them
            val = val.replace('"', '""');
            // Wrap if contains comma, quote, newline, or carriage return
            if (val.contains(',') || val.contains('"') || val.contains('\n') || val.contains('\r')) {
                val = '"' + val + '"';
            }
            escaped.add(val);
        }
        return String.join(escaped, ',');
    }

    private static String truncField(String val) {
        if (String.isBlank(val)) return '';
        if (val.length() <= SecScanConstants.CSV_FIELD_TRUNCATE_LENGTH) return val;
        return val.substring(0, SecScanConstants.CSV_FIELD_TRUNCATE_LENGTH)
            + ' [truncated - see detail panel for full text]';
    }
}
