public class SecScanApiResponse {

    @AuraEnabled public Boolean success { get; set; }
    @AuraEnabled public Object data { get; set; }
    @AuraEnabled public String errorMessage { get; set; }

    private SecScanApiResponse() {}

    public static SecScanApiResponse ok(Object data) {
        SecScanApiResponse r = new SecScanApiResponse();
        r.success = true;
        r.data = data;
        r.errorMessage = null;
        return r;
    }

    public static SecScanApiResponse error(String message) {
        SecScanApiResponse r = new SecScanApiResponse();
        r.success = false;
        r.data = null;
        r.errorMessage = message;
        return r;
    }

    // Partial success: success=true with a warning message (e.g. bulk update with some failures)
    public static SecScanApiResponse partial(Object data, String warningMessage) {
        SecScanApiResponse r = new SecScanApiResponse();
        r.success = true;
        r.data = data;
        r.errorMessage = warningMessage;
        return r;
    }

    // DTO: paginated findings page
    public class FindingsPageDTO {
        @AuraEnabled public List<SecurityFinding__c> findings { get; set; }
        @AuraEnabled public Boolean hasMore { get; set; }
        @AuraEnabled public String lastSeenId { get; set; }
        @AuraEnabled public Integer lastRank { get; set; }
    }

    // DTO: scan run status (polled)
    public class ScanStatusDTO {
        @AuraEnabled public String status { get; set; }
        @AuraEnabled public String failedCategories { get; set; }
        @AuraEnabled public String completedCategories { get; set; }
        @AuraEnabled public Boolean isPartialScan { get; set; }
        @AuraEnabled public Integer totalFindings { get; set; }
    }

    // DTO: org security settings from OrgSecurityScanner_Setting__mdt
    public class OrgSecuritySettingsDTO {
        @AuraEnabled public Integer maxScanRuns { get; set; }
        @AuraEnabled public Boolean allowProductionScan { get; set; }
        @AuraEnabled public Integer portalHealthScoreThreshold { get; set; }
        @AuraEnabled public Integer scoreFloor { get; set; }
        @AuraEnabled public Decimal scoreDeductCritical { get; set; }
        @AuraEnabled public Decimal scoreDeductHigh { get; set; }
        @AuraEnabled public Decimal scoreDeductMedium { get; set; }
        @AuraEnabled public Decimal scoreDeductLow { get; set; }
        @AuraEnabled public Decimal scoreDeductInfo { get; set; }
        @AuraEnabled public Decimal scoreCriticalCap { get; set; }
        @AuraEnabled public Decimal scoreHighCap { get; set; }
        @AuraEnabled public Decimal scoreMediumCap { get; set; }
        @AuraEnabled public Decimal scoreLowCap { get; set; }
        @AuraEnabled public Decimal scoreInfoCap { get; set; }
    }

    // DTO: org identity info
    public class OrgInfoDTO {
        @AuraEnabled public Boolean isSandbox { get; set; }
        @AuraEnabled public String orgId { get; set; }
        @AuraEnabled public String orgName { get; set; }
    }

    // DTO: live finding counts excluding Remediated/False Positive
    public class ScoreCountsDTO {
        @AuraEnabled public Integer criticalOpen { get; set; }
        @AuraEnabled public Integer highOpen { get; set; }
        @AuraEnabled public Integer mediumOpen { get; set; }
        @AuraEnabled public Integer lowOpen { get; set; }
        @AuraEnabled public Integer infoOpen { get; set; }
    }
}
