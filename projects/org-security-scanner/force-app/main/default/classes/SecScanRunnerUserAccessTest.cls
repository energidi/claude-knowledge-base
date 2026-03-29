@IsTest
private class SecScanRunnerUserAccessTest {

    @IsTest
    static void testCheckUA001ModifyAllDataProfile() {
        // Query if any non-sysadmin profile has ModifyAllData
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerUserAccess runner = new SecScanRunnerUserAccess();

        Test.startTest();
        runner.checkUA001(run.Id);
        Test.stopTest();

        // This check passes if no violation exists - just verify it runs without exception
        // In test orgs with non-sysadmin profiles with MDA, it would fire
        System.assert(true, 'checkUA001 must execute without exception');
    }

    @IsTest
    static void testCheckUA002ModifyAllDataPermissionSet() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerUserAccess runner = new SecScanRunnerUserAccess();

        Test.startTest();
        runner.checkUA002(run.Id);
        Test.stopTest();

        System.assert(true, 'checkUA002 must execute without exception');
    }

    @IsTest
    static void testCheckUA003ManageUsersProfile() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerUserAccess runner = new SecScanRunnerUserAccess();

        Test.startTest();
        runner.checkUA003(run.Id);
        Test.stopTest();

        System.assert(true, 'checkUA003 must execute without exception');
    }

    @IsTest
    static void testCheckUA005InactiveUsers() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerUserAccess runner = new SecScanRunnerUserAccess();

        Test.startTest();
        runner.checkUA005(run.Id);
        Test.stopTest();

        System.assert(true, 'checkUA005 must execute without exception');
    }

    @IsTest
    static void testCheckUA006MfaEnrollment() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerUserAccess runner = new SecScanRunnerUserAccess();

        Test.startTest();
        runner.checkUA006(run.Id);
        Test.stopTest();

        // Test org will typically have users without MFA - verify finding structure if fired
        List<SecurityFinding__c> findings = [
            SELECT CheckId__c, Severity__c
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'UA-006'
        ];
        for (SecurityFinding__c f : findings) {
            System.assertEquals('Medium', f.Severity__c, 'UA-006 must be Medium severity');
        }
    }

    @IsTest
    static void testExecuteRunsWithoutException() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerUserAccess runner = new SecScanRunnerUserAccess();

        Test.startTest();
        runner.execute(run.Id, null);
        Test.stopTest();

        // Verify findings have valid structure
        List<SecurityFinding__c> findings = [
            SELECT CheckId__c, Category__c, CategoryCode__c, Severity__c, FindingType__c,
                   Description__c, Impact__c, Remediation__c, ScanRun__c, SeverityRank__c
            FROM SecurityFinding__c WHERE ScanRun__c = :run.Id
        ];
        for (SecurityFinding__c f : findings) {
            System.assertEquals('User & Access', f.Category__c);
            System.assertEquals('UA', f.CategoryCode__c);
            System.assert(!String.isBlank(f.Description__c));
            System.assert(!String.isBlank(f.Remediation__c));
            System.assertNotEquals(null, f.SeverityRank__c);
        }
    }
}
