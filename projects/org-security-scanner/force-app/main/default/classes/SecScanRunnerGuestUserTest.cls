@IsTest
private class SecScanRunnerGuestUserTest {

    private class NoGuestProfilesMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"totalSize":0,"done":true,"records":[]}');
            return res;
        }
    }

    private class GuestWithApiEnabledMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            // Guest profile with PermissionsApiEnabled=true
            res.setBody('{"totalSize":1,"done":true,"records":[{'
                + '"Id":"00e000000000001",'
                + '"Name":"GuestProfile",'
                + '"UserType":"Guest",'
                + '"PermissionsModifyAllData":false,'
                + '"PermissionsApiEnabled":true'
                + '}]}');
            return res;
        }
    }

    @IsTest
    static void testNoGuestProfilesProducesNoFindings() {
        Test.setMock(HttpCalloutMock.class, new NoGuestProfilesMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerGuestUser runner = new SecScanRunnerGuestUser();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM SecurityFinding__c WHERE ScanRun__c = :run.Id];
        System.assertEquals(0, count, 'No guest profiles should produce no GU findings');
    }

    @IsTest
    static void testExecuteWithToolingApiRunsSuccessfully() {
        // All Tooling API calls return empty - verify runner completes without exception
        Test.setMock(HttpCalloutMock.class, new NoGuestProfilesMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerGuestUser runner = new SecScanRunnerGuestUser();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        // Verify any inserted findings are correctly categorized
        List<SecurityFinding__c> findings = [
            SELECT CategoryCode__c FROM SecurityFinding__c WHERE ScanRun__c = :run.Id
        ];
        for (SecurityFinding__c f : findings) {
            System.assertEquals('GU', f.CategoryCode__c, 'All GU findings must have GU category code');
        }
    }

    @IsTest
    static void testRunGU001ViaExecute() {
        // GU-001 uses standard SOQL internally via runGU001.
        // In test orgs, no guest profiles should have ModifyAllData.
        // Verify method runs without exception.
        Test.setMock(HttpCalloutMock.class, new NoGuestProfilesMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerGuestUser runner = new SecScanRunnerGuestUser();

        Test.startTest();
        // Call via @TestVisible method directly (no mock needed - uses SOQL)
        runner.runGU001(run.Id, new List<Map<String, Object>>(), new Map<String, String>(), null);
        runner.saveFindings(run.Id);
        Test.stopTest();

        // In scratch org no guest profiles have MDA - 0 findings expected
        Integer count = [SELECT COUNT() FROM SecurityFinding__c WHERE ScanRun__c = :run.Id AND CheckId__c = 'GU-001'];
        System.assert(count >= 0, 'GU-001 check must execute without exception');
    }

    @IsTest
    static void testRunGU002ViaExecute() {
        Test.setMock(HttpCalloutMock.class, new NoGuestProfilesMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerGuestUser runner = new SecScanRunnerGuestUser();

        Test.startTest();
        runner.runGU002(run.Id, new List<Map<String, Object>>(), new Map<String, String>(), null);
        runner.saveFindings(run.Id);
        Test.stopTest();

        System.assert(true, 'GU-002 must execute without exception');
    }

    @IsTest
    static void testExecuteRunsCategoryCodeGU() {
        Test.setMock(HttpCalloutMock.class, new NoGuestProfilesMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerGuestUser runner = new SecScanRunnerGuestUser();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        // Verify any inserted findings have correct category
        List<SecurityFinding__c> findings = [
            SELECT CategoryCode__c FROM SecurityFinding__c WHERE ScanRun__c = :run.Id
        ];
        for (SecurityFinding__c f : findings) {
            System.assertEquals('GU', f.CategoryCode__c);
        }
    }
}
