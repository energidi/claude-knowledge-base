public with sharing class SecScanFindingsController {

    // Server-side status transition map - immutable, not CMT-driven
    private static final Map<String, Set<String>> ALLOWED_TRANSITIONS = new Map<String, Set<String>>{
        'Open'           => new Set<String>{ 'Acknowledged', 'Remediated', 'Risk Accepted', 'False Positive' },
        'Acknowledged'   => new Set<String>{ 'Remediated', 'Risk Accepted', 'False Positive' },
        'Remediated'     => new Set<String>{ 'Open' },
        'Risk Accepted'  => new Set<String>{ 'Open' },
        'False Positive' => new Set<String>{ 'Open' }
    };

    // ------------------------------------------------------------------
    // getCurrentScanFindings() - KEYSET paginated, imperative (not cacheable)
    // ------------------------------------------------------------------
    @AuraEnabled(cacheable=false)
    public static SecScanApiResponse getCurrentScanFindings(
        String scanRunId,
        String lastSeenId,
        Integer lastRank,
        Integer pageSize,
        String searchTerm
    ) {
        try {
            if (String.isBlank(scanRunId)) {
                return SecScanApiResponse.error('scanRunId is required');
            }

            Integer ps = (pageSize != null && pageSize > 0) ? pageSize : 100;

            // Cap and escape search term
            String searchPattern = null;
            if (!String.isBlank(searchTerm)) {
                String capped = searchTerm.length() > SecScanConstants.MAX_SEARCH_TERM_LENGTH
                    ? searchTerm.substring(0, SecScanConstants.MAX_SEARCH_TERM_LENGTH)
                    : searchTerm;
                searchPattern = '%' + String.escapeSingleQuotes(capped) + '%';
            }

            List<SecurityFinding__c> findings;

            if (String.isBlank(lastSeenId) || lastRank == null) {
                // First page
                if (searchPattern != null) {
                    findings = [
                        SELECT Id, CheckId__c, CheckName__c, Category__c, CategoryCode__c,
                               Severity__c, SeverityRank__c, FindingType__c, Status__c,
                               AffectedComponent__c, AffectedComponentType__c,
                               Description__c, Impact__c, Remediation__c,
                               RawEvidence__c, SalesforceDocUrl__c,
                               AcknowledgedBy__r.Name, AcknowledgedDate__c, AcknowledgementNote__c,
                               ScanRun__c
                        FROM SecurityFinding__c
                        WHERE ScanRun__c = :scanRunId
                          AND (CheckName__c LIKE :searchPattern
                               OR AffectedComponent__c LIKE :searchPattern)
                        WITH USER_MODE
                        ORDER BY SeverityRank__c ASC, Id ASC
                        LIMIT :ps
                    ];
                } else {
                    findings = [
                        SELECT Id, CheckId__c, CheckName__c, Category__c, CategoryCode__c,
                               Severity__c, SeverityRank__c, FindingType__c, Status__c,
                               AffectedComponent__c, AffectedComponentType__c,
                               Description__c, Impact__c, Remediation__c,
                               RawEvidence__c, SalesforceDocUrl__c,
                               AcknowledgedBy__r.Name, AcknowledgedDate__c, AcknowledgementNote__c,
                               ScanRun__c
                        FROM SecurityFinding__c
                        WHERE ScanRun__c = :scanRunId
                        WITH USER_MODE
                        ORDER BY SeverityRank__c ASC, Id ASC
                        LIMIT :ps
                    ];
                }
            } else {
                // Subsequent pages - KEYSET composite cursor
                if (searchPattern != null) {
                    findings = [
                        SELECT Id, CheckId__c, CheckName__c, Category__c, CategoryCode__c,
                               Severity__c, SeverityRank__c, FindingType__c, Status__c,
                               AffectedComponent__c, AffectedComponentType__c,
                               Description__c, Impact__c, Remediation__c,
                               RawEvidence__c, SalesforceDocUrl__c,
                               AcknowledgedBy__r.Name, AcknowledgedDate__c, AcknowledgementNote__c,
                               ScanRun__c
                        FROM SecurityFinding__c
                        WHERE ScanRun__c = :scanRunId
                          AND (CheckName__c LIKE :searchPattern
                               OR AffectedComponent__c LIKE :searchPattern)
                          AND (SeverityRank__c > :lastRank
                               OR (SeverityRank__c = :lastRank AND Id > :lastSeenId))
                        WITH USER_MODE
                        ORDER BY SeverityRank__c ASC, Id ASC
                        LIMIT :ps
                    ];
                } else {
                    findings = [
                        SELECT Id, CheckId__c, CheckName__c, Category__c, CategoryCode__c,
                               Severity__c, SeverityRank__c, FindingType__c, Status__c,
                               AffectedComponent__c, AffectedComponentType__c,
                               Description__c, Impact__c, Remediation__c,
                               RawEvidence__c, SalesforceDocUrl__c,
                               AcknowledgedBy__r.Name, AcknowledgedDate__c, AcknowledgementNote__c,
                               ScanRun__c
                        FROM SecurityFinding__c
                        WHERE ScanRun__c = :scanRunId
                          AND (SeverityRank__c > :lastRank
                               OR (SeverityRank__c = :lastRank AND Id > :lastSeenId))
                        WITH USER_MODE
                        ORDER BY SeverityRank__c ASC, Id ASC
                        LIMIT :ps
                    ];
                }
            }

            SecScanApiResponse.FindingsPageDTO dto = new SecScanApiResponse.FindingsPageDTO();
            dto.findings  = findings;
            dto.hasMore   = findings.size() == ps;
            dto.lastSeenId = findings.isEmpty() ? null : findings[findings.size() - 1].Id;
            dto.lastRank   = findings.isEmpty() ? null
                : (findings[findings.size() - 1].SeverityRank__c != null
                    ? (Integer) findings[findings.size() - 1].SeverityRank__c
                    : null);

            return SecScanApiResponse.ok(dto);

        } catch (Exception e) {
            return SecScanApiResponse.error(e.getMessage());
        }
    }

    // ------------------------------------------------------------------
    // getScoreCounts() - live open-finding counts, NOT cacheable
    // Called after every status mutation to refresh score ring + left panel
    // ------------------------------------------------------------------
    @AuraEnabled(cacheable=false)
    public static SecScanApiResponse getScoreCounts(String scanRunId) {
        try {
            if (String.isBlank(scanRunId)) {
                return SecScanApiResponse.error('scanRunId is required');
            }

            Set<String> excluded = SecScanConstants.SCORE_EXCLUDED_STATUSES;

            AggregateResult[] agg = [
                SELECT Severity__c sev, COUNT(Id) cnt
                FROM SecurityFinding__c
                WHERE ScanRun__c = :scanRunId
                  AND Status__c NOT IN :excluded
                WITH USER_MODE
                GROUP BY Severity__c
            ];

            SecScanApiResponse.ScoreCountsDTO dto = new SecScanApiResponse.ScoreCountsDTO();
            for (AggregateResult ar : agg) {
                String sev   = (String)  ar.get('sev');
                Integer cnt  = (Integer) ar.get('cnt');
                if (sev == 'Critical')     dto.criticalOpen = cnt;
                else if (sev == 'High')    dto.highOpen     = cnt;
                else if (sev == 'Medium')  dto.mediumOpen   = cnt;
                else if (sev == 'Low')     dto.lowOpen      = cnt;
                else if (sev == 'Informational') dto.infoOpen = cnt;
            }
            return SecScanApiResponse.ok(dto);

        } catch (Exception e) {
            return SecScanApiResponse.error(e.getMessage());
        }
    }

    // ------------------------------------------------------------------
    // getFindingDetail() - cacheable, used with @wire
    // ------------------------------------------------------------------
    @AuraEnabled(cacheable=true)
    public static SecScanApiResponse getFindingDetail(String findingId) {
        try {
            if (String.isBlank(findingId)) {
                return SecScanApiResponse.error('findingId is required');
            }
            SecurityFinding__c f = [
                SELECT Id, CheckId__c, CheckName__c, Category__c, CategoryCode__c,
                       Severity__c, SeverityRank__c, FindingType__c, Status__c,
                       AffectedComponent__c, AffectedComponentType__c,
                       Description__c, Impact__c, Remediation__c,
                       RawEvidence__c, SalesforceDocUrl__c,
                       AcknowledgedBy__c, AcknowledgedBy__r.Name,
                       AcknowledgedDate__c, AcknowledgementNote__c,
                       ScanRun__c
                FROM SecurityFinding__c
                WHERE Id = :findingId
                WITH USER_MODE
                LIMIT 1
            ];
            return SecScanApiResponse.ok(f);
        } catch (Exception e) {
            return SecScanApiResponse.error(e.getMessage());
        }
    }

    // ------------------------------------------------------------------
    // updateFindingStatus() - NOT cacheable (mutation)
    // ------------------------------------------------------------------
    @AuraEnabled(cacheable=false)
    public static SecScanApiResponse updateFindingStatus(
        String findingId,
        String status,
        String note
    ) {
        try {
            if (String.isBlank(findingId)) {
                return SecScanApiResponse.error('findingId is required');
            }
            if (String.isBlank(status)) {
                return SecScanApiResponse.error('status is required');
            }

            SecurityFinding__c f = [
                SELECT Id, Status__c
                FROM SecurityFinding__c
                WHERE Id = :findingId
                WITH USER_MODE
                LIMIT 1
            ];

            // Validate transition
            Set<String> allowed = ALLOWED_TRANSITIONS.get(f.Status__c);
            if (allowed == null || !allowed.contains(status)) {
                return SecScanApiResponse.error(
                    'Invalid status transition from ' + f.Status__c + ' to ' + status
                );
            }

            f.Status__c = status;

            // Set or clear acknowledgement fields
            Boolean awayFromOpen = (status != 'Open');
            f.AcknowledgedBy__c   = awayFromOpen ? UserInfo.getUserId() : null;
            f.AcknowledgedDate__c = awayFromOpen ? Datetime.now()       : null;

            if (!String.isBlank(note)) {
                f.AcknowledgementNote__c = note;
            }

            Database.update(f, AccessLevel.USER_MODE);
            return SecScanApiResponse.ok(f.Id);

        } catch (Exception e) {
            return SecScanApiResponse.error(e.getMessage());
        }
    }

    // ------------------------------------------------------------------
    // bulkUpdateFindingStatus() - NOT cacheable, allOrNone=false
    // ------------------------------------------------------------------
    @AuraEnabled(cacheable=false)
    public static SecScanApiResponse bulkUpdateFindingStatus(
        List<String> findingIds,
        String status,
        String note
    ) {
        try {
            if (findingIds == null || findingIds.isEmpty()) {
                return SecScanApiResponse.error('findingIds is required and must not be empty');
            }
            if (findingIds.size() > SecScanConstants.MAX_BULK_UPDATE_FINDINGS) {
                return SecScanApiResponse.error(
                    'Bulk update is limited to ' + SecScanConstants.MAX_BULK_UPDATE_FINDINGS
                    + ' findings at a time. Select fewer findings and try again.'
                );
            }
            if (String.isBlank(status)) {
                return SecScanApiResponse.error('status is required');
            }

            // Re-query to apply transition validation per record
            List<SecurityFinding__c> findings = [
                SELECT Id, Status__c
                FROM SecurityFinding__c
                WHERE Id IN :findingIds
                WITH USER_MODE
            ];

            Datetime now = Datetime.now();
            Id runningUserId = UserInfo.getUserId();
            Boolean awayFromOpen = (status != 'Open');

            List<SecurityFinding__c> toUpdate = new List<SecurityFinding__c>();
            List<String> skippedIds = new List<String>();

            for (SecurityFinding__c f : findings) {
                Set<String> allowed = ALLOWED_TRANSITIONS.get(f.Status__c);
                if (allowed == null || !allowed.contains(status)) {
                    skippedIds.add(f.Id);
                    continue;
                }
                f.Status__c = status;
                f.AcknowledgedBy__c   = awayFromOpen ? runningUserId : null;
                f.AcknowledgedDate__c = awayFromOpen ? now           : null;
                if (!String.isBlank(note)) {
                    f.AcknowledgementNote__c = note;
                }
                toUpdate.add(f);
            }

            Integer successCount = 0;
            List<String> failedIds = new List<String>(skippedIds);

            if (!toUpdate.isEmpty()) {
                List<Database.SaveResult> results = Database.update(toUpdate, false, AccessLevel.USER_MODE);
                for (Integer i = 0; i < results.size(); i++) {
                    if (results[i].isSuccess()) {
                        successCount++;
                    } else {
                        failedIds.add(toUpdate[i].Id);
                    }
                }
            }

            String msg = null;
            if (!failedIds.isEmpty()) {
                msg = successCount + ' of ' + findingIds.size() + ' findings updated. '
                    + failedIds.size() + ' could not be updated: ' + String.join(failedIds, ', ');
            }

            if (msg != null) {
                return SecScanApiResponse.partial(successCount, msg);
            }
            return SecScanApiResponse.ok(successCount);

        } catch (Exception e) {
            return SecScanApiResponse.error(e.getMessage());
        }
    }
}
