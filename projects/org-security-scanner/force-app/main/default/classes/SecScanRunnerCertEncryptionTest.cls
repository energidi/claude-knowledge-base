@IsTest
private class SecScanRunnerCertEncryptionTest {

    @IsTest
    static void testCheckCE001ExpiredCertificates() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerCertEncryption runner = new SecScanRunnerCertEncryption();

        Test.startTest();
        runner.checkCE001(run.Id);
        Test.stopTest();

        // Verify any CE-001 findings have correct severity
        List<SecurityFinding__c> findings = [
            SELECT CheckId__c, Severity__c FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'CE-001'
        ];
        for (SecurityFinding__c f : findings) {
            System.assertEquals('Critical', f.Severity__c, 'Expired cert must be Critical');
        }
    }

    @IsTest
    static void testCheckCE002SoonExpiringCertificates() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerCertEncryption runner = new SecScanRunnerCertEncryption();

        Test.startTest();
        runner.checkCE002(run.Id);
        Test.stopTest();

        List<SecurityFinding__c> findings = [
            SELECT CheckId__c, Severity__c FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'CE-002'
        ];
        for (SecurityFinding__c f : findings) {
            System.assertEquals('High', f.Severity__c, 'Soon-expiring cert must be High');
        }
    }

    @IsTest
    static void testExecuteRunsWithoutException() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerCertEncryption runner = new SecScanRunnerCertEncryption();

        Test.startTest();
        runner.execute(run.Id, null);
        Test.stopTest();

        List<SecurityFinding__c> findings = [
            SELECT CheckId__c, Category__c, CategoryCode__c
            FROM SecurityFinding__c WHERE ScanRun__c = :run.Id
        ];
        for (SecurityFinding__c f : findings) {
            System.assertEquals('Certificates & Encryption', f.Category__c);
            System.assertEquals('CE', f.CategoryCode__c);
        }
    }
}
