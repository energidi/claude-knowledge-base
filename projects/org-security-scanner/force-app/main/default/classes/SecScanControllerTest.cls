@IsTest
private class SecScanControllerTest {

    // ------------------------------------------------------------------
    // getOrgInfo()
    // ------------------------------------------------------------------

    @IsTest
    static void testGetOrgInfo() {
        Test.startTest();
        SecScanApiResponse r = SecScanController.getOrgInfo();
        Test.stopTest();

        System.assertEquals(true, r.success);
        System.assertNotNull(r.data);
        // OrgInfoDTO fields are accessible on the response data object
        SecScanApiResponse.OrgInfoDTO dto = (SecScanApiResponse.OrgInfoDTO) r.data;
        System.assertNotNull(dto.orgId);
        System.assertNotNull(dto.orgName);
    }

    // ------------------------------------------------------------------
    // getOrgSecuritySettings()
    // ------------------------------------------------------------------

    @IsTest
    static void testGetOrgSecuritySettings() {
        Test.startTest();
        SecScanApiResponse r = SecScanController.getOrgSecuritySettings();
        Test.stopTest();

        System.assertEquals(true, r.success);
        SecScanApiResponse.OrgSecuritySettingsDTO dto = (SecScanApiResponse.OrgSecuritySettingsDTO) r.data;
        System.assertNotNull(dto.maxScanRuns);
        System.assertNotNull(dto.scoreFloor);
        System.assertNotNull(dto.scoreDeductCritical);
        System.assert(dto.maxScanRuns > 0, 'maxScanRuns must be positive');
        System.assert(dto.scoreFloor >= 0, 'scoreFloor must be non-negative');
    }

    // ------------------------------------------------------------------
    // getScanRuns()
    // ------------------------------------------------------------------

    @IsTest
    static void testGetScanRunsEmpty() {
        Test.startTest();
        SecScanApiResponse r = SecScanController.getScanRuns();
        Test.stopTest();

        System.assertEquals(true, r.success);
        List<SecurityScanRun__c> runs = (List<SecurityScanRun__c>) r.data;
        System.assertNotNull(runs);
    }

    @IsTest
    static void testGetScanRunsWithData() {
        SecurityScanRun__c run1 = SecScanTestDataFactory.createCompletedRun();
        SecurityScanRun__c run2 = SecScanTestDataFactory.createCompletedRun();

        Test.startTest();
        SecScanApiResponse r = SecScanController.getScanRuns();
        Test.stopTest();

        System.assertEquals(true, r.success);
        List<SecurityScanRun__c> runs = (List<SecurityScanRun__c>) r.data;
        System.assert(runs.size() >= 2);
    }

    // ------------------------------------------------------------------
    // getScanRunStatus()
    // ------------------------------------------------------------------

    @IsTest
    static void testGetScanRunStatusBlankId() {
        Test.startTest();
        SecScanApiResponse r = SecScanController.getScanRunStatus(null);
        Test.stopTest();

        System.assertEquals(false, r.success);
        System.assert(r.errorMessage.contains('required'));
    }

    @IsTest
    static void testGetScanRunStatusValid() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();

        Test.startTest();
        SecScanApiResponse r = SecScanController.getScanRunStatus(run.Id);
        Test.stopTest();

        System.assertEquals(true, r.success);
        SecScanApiResponse.ScanStatusDTO dto = (SecScanApiResponse.ScanStatusDTO) r.data;
        System.assertEquals('Running', dto.status);
    }

    // ------------------------------------------------------------------
    // cancelScan()
    // ------------------------------------------------------------------

    @IsTest
    static void testCancelScanBlankId() {
        Test.startTest();
        SecScanApiResponse r = SecScanController.cancelScan(null);
        Test.stopTest();

        System.assertEquals(false, r.success);
    }

    @IsTest
    static void testCancelScanRunning() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();

        Test.startTest();
        SecScanApiResponse r = SecScanController.cancelScan(run.Id);
        Test.stopTest();

        System.assertEquals(true, r.success);
        SecurityScanRun__c updated = [SELECT Status__c FROM SecurityScanRun__c WHERE Id = :run.Id];
        System.assertEquals('Cancelled', updated.Status__c);
    }

    @IsTest
    static void testCancelScanAlreadyCompleted() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();

        Test.startTest();
        SecScanApiResponse r = SecScanController.cancelScan(run.Id);
        Test.stopTest();

        System.assertEquals(false, r.success);
        System.assert(r.errorMessage.contains('already completed'));
        // Verify status unchanged
        SecurityScanRun__c check = [SELECT Status__c FROM SecurityScanRun__c WHERE Id = :run.Id];
        System.assertEquals('Completed', check.Status__c);
    }

    @IsTest
    static void testCancelScanAlreadyCancelled() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCancelledRun();

        Test.startTest();
        SecScanApiResponse r = SecScanController.cancelScan(run.Id);
        Test.stopTest();

        System.assertEquals(false, r.success);
    }

    // ------------------------------------------------------------------
    // exportFindingsCsv()
    // ------------------------------------------------------------------

    @IsTest
    static void testExportFindingsCsvBlankId() {
        Test.startTest();
        SecScanApiResponse r = SecScanController.exportFindingsCsv(null);
        Test.stopTest();

        System.assertEquals(false, r.success);
    }

    @IsTest
    static void testExportFindingsCsvEmpty() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();

        Test.startTest();
        SecScanApiResponse r = SecScanController.exportFindingsCsv(run.Id);
        Test.stopTest();

        System.assertEquals(true, r.success);
        // Returns ContentDocumentId
        System.assertNotNull(r.data);
        String docId = (String) r.data;
        System.assert(docId.startsWith('069') || docId.length() == 18);
    }

    @IsTest
    static void testExportFindingsCsvWithFindings() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        List<SecurityFinding__c> findings = SecScanTestDataFactory.createOneFindingPerSeverity(run.Id);

        Test.startTest();
        SecScanApiResponse r = SecScanController.exportFindingsCsv(run.Id);
        Test.stopTest();

        System.assertEquals(true, r.success);
        String docId = (String) r.data;

        // Verify ContentVersion was created
        List<ContentVersion> cvs = [SELECT Title, PathOnClient FROM ContentVersion WHERE ContentDocumentId = :docId];
        System.assertEquals(1, cvs.size());
        System.assert(cvs[0].PathOnClient.endsWith('.csv'));

        // Verify ContentDocumentLink links to scan run
        List<ContentDocumentLink> cdls = [
            SELECT LinkedEntityId FROM ContentDocumentLink WHERE ContentDocumentId = :docId
        ];
        Boolean linkedToRun = false;
        for (ContentDocumentLink cdl : cdls) {
            if (cdl.LinkedEntityId == run.Id) linkedToRun = true;
        }
        System.assert(linkedToRun, 'CSV must be linked to the SecurityScanRun__c record');
    }

    @IsTest
    static void testExportFindingsCsvCommaInField() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        SecurityFinding__c f = SecScanTestDataFactory.buildFinding(run.Id, 'UA-001', 'Critical');
        f.AffectedComponent__c = 'Component, With, Commas';
        f.Description__c = 'Description with "quotes" and\nnewlines';
        insert f;

        Test.startTest();
        SecScanApiResponse r = SecScanController.exportFindingsCsv(run.Id);
        Test.stopTest();

        System.assertEquals(true, r.success);
        // Retrieve CSV content and verify RFC 4180 encoding
        String docId = (String) r.data;
        ContentVersion cv = [SELECT VersionData FROM ContentVersion WHERE ContentDocumentId = :docId LIMIT 1];
        String csv = cv.VersionData.toString();
        System.assert(csv.contains('"Component, With, Commas"'), 'Fields with commas must be quoted');
        System.assert(csv.contains('""quotes""'), 'Double quotes must be escaped');
    }

    // ------------------------------------------------------------------
    // startScan() - permission validation
    // (concurrency guard tested separately; PS validation is implicit in test context)
    // ------------------------------------------------------------------

    @IsTest
    static void testStartScanWithoutPermissionSet() {
        // In test context running user does not have the PS assigned
        Test.startTest();
        SecScanApiResponse r = SecScanController.startScan();
        Test.stopTest();

        // Should fail with permission error
        System.assertEquals(false, r.success);
        System.assert(r.errorMessage.contains('OrgSecurityScanner_Admin'),
            'Error must reference the required permission set');
    }
}
