@IsTest
private class SecScanApiResponseTest {

    @IsTest
    static void testOkResponse() {
        SecScanApiResponse r = SecScanApiResponse.ok('hello');
        System.assertEquals(true, r.success);
        System.assertEquals('hello', r.data);
        System.assertEquals(null, r.errorMessage);
    }

    @IsTest
    static void testOkResponseWithNull() {
        SecScanApiResponse r = SecScanApiResponse.ok(null);
        System.assertEquals(true, r.success);
        System.assertEquals(null, r.data);
        System.assertEquals(null, r.errorMessage);
    }

    @IsTest
    static void testErrorResponse() {
        SecScanApiResponse r = SecScanApiResponse.error('something went wrong');
        System.assertEquals(false, r.success);
        System.assertEquals(null, r.data);
        System.assertEquals('something went wrong', r.errorMessage);
    }

    @IsTest
    static void testErrorResponseSpecialChars() {
        String msg = 'Error: "quotes" & <tags>';
        SecScanApiResponse r = SecScanApiResponse.error(msg);
        System.assertEquals(msg, r.errorMessage);
    }

    @IsTest
    static void testPartialResponse() {
        SecScanApiResponse r = SecScanApiResponse.partial(42, 'warning message');
        System.assertEquals(true, r.success);
        System.assertEquals(42, r.data);
        System.assertEquals('warning message', r.errorMessage);
    }

    @IsTest
    static void testFindingsPageDTO() {
        SecScanApiResponse.FindingsPageDTO dto = new SecScanApiResponse.FindingsPageDTO();
        dto.findings   = new List<SecurityFinding__c>();
        dto.hasMore    = false;
        dto.lastSeenId = 'abc';
        dto.lastRank   = 2;

        System.assertEquals(0, dto.findings.size());
        System.assertEquals(false, dto.hasMore);
        System.assertEquals('abc', dto.lastSeenId);
        System.assertEquals(2, dto.lastRank);
    }

    @IsTest
    static void testScanStatusDTO() {
        SecScanApiResponse.ScanStatusDTO dto = new SecScanApiResponse.ScanStatusDTO();
        dto.status              = 'Running';
        dto.failedCategories    = 'AA';
        dto.completedCategories = 'UA,GU';
        dto.isPartialScan       = true;
        dto.totalFindings       = 15;

        System.assertEquals('Running', dto.status);
        System.assertEquals('AA', dto.failedCategories);
        System.assertEquals('UA,GU', dto.completedCategories);
        System.assertEquals(true, dto.isPartialScan);
        System.assertEquals(15, dto.totalFindings);
    }

    @IsTest
    static void testOrgInfoDTO() {
        SecScanApiResponse.OrgInfoDTO dto = new SecScanApiResponse.OrgInfoDTO();
        dto.isSandbox = true;
        dto.orgId     = '00D000000000001';
        dto.orgName   = 'Test Org';

        System.assertEquals(true, dto.isSandbox);
        System.assertEquals('00D000000000001', dto.orgId);
        System.assertEquals('Test Org', dto.orgName);
    }

    @IsTest
    static void testOrgSecuritySettingsDTO() {
        SecScanApiResponse.OrgSecuritySettingsDTO dto = new SecScanApiResponse.OrgSecuritySettingsDTO();
        dto.maxScanRuns         = 5;
        dto.allowProductionScan = false;
        dto.scoreFloor          = 5;
        dto.scoreDeductCritical = 10;
        dto.scoreCriticalCap    = 40;

        System.assertEquals(5, dto.maxScanRuns);
        System.assertEquals(false, dto.allowProductionScan);
        System.assertEquals(5, dto.scoreFloor);
        System.assertEquals(10, dto.scoreDeductCritical);
        System.assertEquals(40, dto.scoreCriticalCap);
    }

    @IsTest
    static void testScoreCountsDTO() {
        SecScanApiResponse.ScoreCountsDTO dto = new SecScanApiResponse.ScoreCountsDTO();
        dto.criticalOpen = 3;
        dto.highOpen     = 7;
        dto.mediumOpen   = 12;
        dto.lowOpen      = 0;
        dto.infoOpen     = 1;

        System.assertEquals(3, dto.criticalOpen);
        System.assertEquals(7, dto.highOpen);
        System.assertEquals(12, dto.mediumOpen);
        System.assertEquals(0, dto.lowOpen);
        System.assertEquals(1, dto.infoOpen);
    }

    @IsTest
    static void testOkWithTypedDTO() {
        SecScanApiResponse.OrgInfoDTO orgDto = new SecScanApiResponse.OrgInfoDTO();
        orgDto.isSandbox = true;
        orgDto.orgId     = '00D000000000001';
        orgDto.orgName   = 'My Org';

        SecScanApiResponse r = SecScanApiResponse.ok(orgDto);
        System.assertEquals(true, r.success);
        System.assertNotEquals(null, r.data);
        System.assertEquals(null, r.errorMessage);
    }
}
