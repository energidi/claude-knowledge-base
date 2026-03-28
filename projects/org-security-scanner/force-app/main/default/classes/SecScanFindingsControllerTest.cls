@IsTest
private class SecScanFindingsControllerTest {

    // ------------------------------------------------------------------
    // getCurrentScanFindings()
    // ------------------------------------------------------------------

    @IsTest
    static void testGetFindingsBlankRunId() {
        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.getCurrentScanFindings(null, null, null, 10, null);
        Test.stopTest();

        System.assertEquals(false, r.success);
        System.assert(r.errorMessage.contains('required'));
    }

    @IsTest
    static void testGetFindingsFirstPage() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        SecScanTestDataFactory.createFindings(run.Id, 'Critical', 5);
        SecScanTestDataFactory.createFindings(run.Id, 'High', 5);

        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.getCurrentScanFindings(run.Id, null, null, 100, null);
        Test.stopTest();

        System.assertEquals(true, r.success);
        SecScanApiResponse.FindingsPageDTO dto = (SecScanApiResponse.FindingsPageDTO) r.data;
        System.assertEquals(10, dto.findings.size());
        System.assertEquals(false, dto.hasMore);
        // Verify severity-first ordering: all Critical before High
        for (Integer i = 0; i < 5; i++) {
            System.assertEquals('Critical', dto.findings[i].Severity__c);
        }
        for (Integer i = 5; i < 10; i++) {
            System.assertEquals('High', dto.findings[i].Severity__c);
        }
    }

    @IsTest
    static void testGetFindingsKeysetPagination() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        SecScanTestDataFactory.createFindings(run.Id, 'Medium', 15);

        // Page 1 - 10 results
        Test.startTest();
        SecScanApiResponse r1 = SecScanFindingsController.getCurrentScanFindings(run.Id, null, null, 10, null);
        SecScanApiResponse.FindingsPageDTO p1 = (SecScanApiResponse.FindingsPageDTO) r1.data;
        System.assertEquals(10, p1.findings.size());
        System.assertEquals(true, p1.hasMore);
        System.assertNotNull(p1.lastSeenId);
        System.assertNotNull(p1.lastRank);

        // Page 2 - remaining 5
        SecScanApiResponse r2 = SecScanFindingsController.getCurrentScanFindings(
            run.Id, p1.lastSeenId, p1.lastRank, 10, null
        );
        Test.stopTest();

        SecScanApiResponse.FindingsPageDTO p2 = (SecScanApiResponse.FindingsPageDTO) r2.data;
        System.assertEquals(5, p2.findings.size());
        System.assertEquals(false, p2.hasMore);

        // No overlap between pages
        Set<Id> page1Ids = new Map<Id, SecurityFinding__c>(p1.findings).keySet();
        for (SecurityFinding__c f : p2.findings) {
            System.assert(!page1Ids.contains(f.Id), 'KEYSET must not return duplicate records');
        }
    }

    @IsTest
    static void testGetFindingsSearchFilter() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        SecurityFinding__c f = SecScanTestDataFactory.buildFinding(run.Id, 'UA-001', 'High');
        f.CheckName__c = 'Unique Check Alpha';
        f.AffectedComponent__c = 'Profile ABC';
        insert f;
        SecScanTestDataFactory.createFindings(run.Id, 'Low', 3);

        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.getCurrentScanFindings(run.Id, null, null, 100, 'Unique Check');
        Test.stopTest();

        SecScanApiResponse.FindingsPageDTO dto = (SecScanApiResponse.FindingsPageDTO) r.data;
        System.assertEquals(1, dto.findings.size());
        System.assertEquals('UA-001', dto.findings[0].CheckId__c);
    }

    @IsTest
    static void testGetFindingsSearchTermCappedAt100() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();

        // 150-char search term - should not throw
        String longTerm = 'X'.repeat(150);
        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.getCurrentScanFindings(run.Id, null, null, 100, longTerm);
        Test.stopTest();

        // Should succeed (no exception), just return 0 results
        System.assertEquals(true, r.success);
    }

    @IsTest
    static void testGetFindingsEmptyResult() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();

        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.getCurrentScanFindings(run.Id, null, null, 100, null);
        Test.stopTest();

        SecScanApiResponse.FindingsPageDTO dto = (SecScanApiResponse.FindingsPageDTO) r.data;
        System.assertEquals(0, dto.findings.size());
        System.assertEquals(false, dto.hasMore);
        System.assertNull(dto.lastSeenId);
    }

    // ------------------------------------------------------------------
    // getScoreCounts()
    // ------------------------------------------------------------------

    @IsTest
    static void testGetScoreCountsBlankId() {
        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.getScoreCounts(null);
        Test.stopTest();

        System.assertEquals(false, r.success);
    }

    @IsTest
    static void testGetScoreCountsAllOpen() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        SecScanTestDataFactory.createOneFindingPerSeverity(run.Id);

        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.getScoreCounts(run.Id);
        Test.stopTest();

        System.assertEquals(true, r.success);
        SecScanApiResponse.ScoreCountsDTO dto = (SecScanApiResponse.ScoreCountsDTO) r.data;
        System.assertEquals(1, dto.criticalOpen);
        System.assertEquals(1, dto.highOpen);
        System.assertEquals(1, dto.mediumOpen);
        System.assertEquals(1, dto.lowOpen);
        System.assertEquals(1, dto.infoOpen);
    }

    @IsTest
    static void testGetScoreCountsExcludesRemediated() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        SecurityFinding__c f1 = SecScanTestDataFactory.buildFinding(run.Id, 'UA-001', 'Critical', 'Open');
        SecurityFinding__c f2 = SecScanTestDataFactory.buildFinding(run.Id, 'UA-002', 'Critical', 'Remediated');
        SecurityFinding__c f3 = SecScanTestDataFactory.buildFinding(run.Id, 'UA-003', 'High', 'False Positive');
        insert new List<SecurityFinding__c>{ f1, f2, f3 };

        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.getScoreCounts(run.Id);
        Test.stopTest();

        SecScanApiResponse.ScoreCountsDTO dto = (SecScanApiResponse.ScoreCountsDTO) r.data;
        System.assertEquals(1, dto.criticalOpen, 'Remediated must be excluded');
        System.assertEquals(0, dto.highOpen, 'False Positive must be excluded');
    }

    @IsTest
    static void testGetScoreCountsAcknowledgedIncluded() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        SecurityFinding__c f = SecScanTestDataFactory.buildFinding(run.Id, 'UA-001', 'Critical', 'Acknowledged');
        insert f;

        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.getScoreCounts(run.Id);
        Test.stopTest();

        SecScanApiResponse.ScoreCountsDTO dto = (SecScanApiResponse.ScoreCountsDTO) r.data;
        System.assertEquals(1, dto.criticalOpen, 'Acknowledged must count as open for scoring');
    }

    // ------------------------------------------------------------------
    // getFindingDetail()
    // ------------------------------------------------------------------

    @IsTest
    static void testGetFindingDetailBlankId() {
        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.getFindingDetail(null);
        Test.stopTest();

        System.assertEquals(false, r.success);
    }

    @IsTest
    static void testGetFindingDetailValid() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        SecurityFinding__c f = SecScanTestDataFactory.buildFinding(run.Id, 'UA-001', 'Critical');
        insert f;

        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.getFindingDetail(f.Id);
        Test.stopTest();

        System.assertEquals(true, r.success);
        SecurityFinding__c returned = (SecurityFinding__c) r.data;
        System.assertEquals(f.Id, returned.Id);
        System.assertEquals('UA-001', returned.CheckId__c);
        System.assertEquals('Critical', returned.Severity__c);
    }

    // ------------------------------------------------------------------
    // updateFindingStatus()
    // ------------------------------------------------------------------

    @IsTest
    static void testUpdateFindingStatusBlankId() {
        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.updateFindingStatus(null, 'Acknowledged', null);
        Test.stopTest();

        System.assertEquals(false, r.success);
    }

    @IsTest
    static void testUpdateFindingStatusBlankStatus() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        SecurityFinding__c f = SecScanTestDataFactory.buildFinding(run.Id, 'UA-001', 'Critical');
        insert f;

        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.updateFindingStatus(f.Id, null, null);
        Test.stopTest();

        System.assertEquals(false, r.success);
    }

    @IsTest
    static void testUpdateFindingStatusOpenToAcknowledged() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        SecurityFinding__c f = SecScanTestDataFactory.buildFinding(run.Id, 'UA-001', 'Critical', 'Open');
        insert f;

        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.updateFindingStatus(f.Id, 'Acknowledged', 'Reviewed by admin');
        Test.stopTest();

        System.assertEquals(true, r.success);
        SecurityFinding__c updated = [
            SELECT Status__c, AcknowledgedBy__c, AcknowledgedDate__c, AcknowledgementNote__c
            FROM SecurityFinding__c WHERE Id = :f.Id
        ];
        System.assertEquals('Acknowledged', updated.Status__c);
        System.assertEquals(UserInfo.getUserId(), updated.AcknowledgedBy__c);
        System.assertNotNull(updated.AcknowledgedDate__c);
        System.assertEquals('Reviewed by admin', updated.AcknowledgementNote__c);
    }

    @IsTest
    static void testUpdateFindingStatusOpenToRemediated() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        SecurityFinding__c f = SecScanTestDataFactory.buildFinding(run.Id, 'UA-001', 'High', 'Open');
        insert f;

        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.updateFindingStatus(f.Id, 'Remediated', null);
        Test.stopTest();

        System.assertEquals(true, r.success);
        SecurityFinding__c updated = [SELECT Status__c FROM SecurityFinding__c WHERE Id = :f.Id];
        System.assertEquals('Remediated', updated.Status__c);
    }

    @IsTest
    static void testUpdateFindingStatusInvalidTransition() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        SecurityFinding__c f = SecScanTestDataFactory.buildFinding(run.Id, 'UA-001', 'High', 'Remediated');
        insert f;

        // Remediated -> Acknowledged is NOT allowed
        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.updateFindingStatus(f.Id, 'Acknowledged', null);
        Test.stopTest();

        System.assertEquals(false, r.success);
        System.assert(r.errorMessage.contains('Invalid status transition'));
        System.assert(r.errorMessage.contains('Remediated'));
        System.assert(r.errorMessage.contains('Acknowledged'));
        // Verify no DML occurred
        SecurityFinding__c check = [SELECT Status__c FROM SecurityFinding__c WHERE Id = :f.Id];
        System.assertEquals('Remediated', check.Status__c);
    }

    @IsTest
    static void testUpdateFindingStatusRemediatedToOpen() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        SecurityFinding__c f = SecScanTestDataFactory.buildFinding(run.Id, 'UA-001', 'High', 'Remediated');
        insert f;

        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.updateFindingStatus(f.Id, 'Open', null);
        Test.stopTest();

        System.assertEquals(true, r.success);
        SecurityFinding__c updated = [SELECT Status__c, AcknowledgedBy__c FROM SecurityFinding__c WHERE Id = :f.Id];
        System.assertEquals('Open', updated.Status__c);
        System.assertNull(updated.AcknowledgedBy__c, 'AcknowledgedBy must be cleared when reverting to Open');
    }

    @IsTest
    static void testAllAllowedTransitions() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();

        // Open -> Acknowledged -> Remediated
        SecurityFinding__c f = SecScanTestDataFactory.buildFinding(run.Id, 'UA-001', 'Medium', 'Open');
        insert f;

        Test.startTest();
        SecScanFindingsController.updateFindingStatus(f.Id, 'Acknowledged', null);
        SecScanFindingsController.updateFindingStatus(f.Id, 'Remediated', null);
        SecScanFindingsController.updateFindingStatus(f.Id, 'Open', null);
        SecScanFindingsController.updateFindingStatus(f.Id, 'Risk Accepted', 'Accepted');
        SecScanApiResponse r = SecScanFindingsController.updateFindingStatus(f.Id, 'Open', null);
        Test.stopTest();

        System.assertEquals(true, r.success);
        SecurityFinding__c final_ = [SELECT Status__c FROM SecurityFinding__c WHERE Id = :f.Id];
        System.assertEquals('Open', final_.Status__c);
    }

    // ------------------------------------------------------------------
    // bulkUpdateFindingStatus()
    // ------------------------------------------------------------------

    @IsTest
    static void testBulkUpdateEmptyList() {
        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.bulkUpdateFindingStatus(
            new List<String>(), 'Acknowledged', null
        );
        Test.stopTest();

        System.assertEquals(false, r.success);
        System.assert(r.errorMessage.contains('required'));
    }

    @IsTest
    static void testBulkUpdateExceedsCap() {
        List<String> ids = new List<String>();
        for (Integer i = 0; i < SecScanConstants.MAX_BULK_UPDATE_FINDINGS + 1; i++) {
            ids.add('000000000000000001');
        }
        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.bulkUpdateFindingStatus(ids, 'Acknowledged', null);
        Test.stopTest();

        System.assertEquals(false, r.success);
        System.assert(r.errorMessage.contains(String.valueOf(SecScanConstants.MAX_BULK_UPDATE_FINDINGS)));
    }

    @IsTest
    static void testBulkUpdateSuccess() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        List<SecurityFinding__c> findings = SecScanTestDataFactory.createFindings(run.Id, 'High', 5);

        List<String> ids = new List<String>();
        for (SecurityFinding__c f : findings) ids.add(f.Id);

        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.bulkUpdateFindingStatus(ids, 'Acknowledged', 'Bulk review');
        Test.stopTest();

        System.assertEquals(true, r.success);
        Integer successCount = (Integer) r.data;
        System.assertEquals(5, successCount);

        Integer updatedCount = [
            SELECT COUNT() FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND Status__c = 'Acknowledged'
        ];
        System.assertEquals(5, updatedCount);
    }

    @IsTest
    static void testBulkUpdatePartialInvalidTransition() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        SecurityFinding__c f1 = SecScanTestDataFactory.buildFinding(run.Id, 'UA-001', 'High', 'Open');
        SecurityFinding__c f2 = SecScanTestDataFactory.buildFinding(run.Id, 'UA-002', 'High', 'Remediated');
        insert new List<SecurityFinding__c>{ f1, f2 };

        // Trying to Acknowledge f2 which is Remediated - invalid transition
        List<String> ids = new List<String>{ f1.Id, f2.Id };

        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.bulkUpdateFindingStatus(ids, 'Acknowledged', null);
        Test.stopTest();

        // Partial success - success=true, data=1 (only f1 updated), errorMessage contains summary
        System.assertEquals(true, r.success);
        Integer successCount = (Integer) r.data;
        System.assertEquals(1, successCount);
        System.assertNotNull(r.errorMessage);
        System.assert(r.errorMessage.contains('1 of 2'));
    }

    @IsTest
    static void testBulkUpdateScoreExcludesAfterRemediation() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        List<SecurityFinding__c> crit = SecScanTestDataFactory.createFindings(run.Id, 'Critical', 3);

        List<String> ids = new List<String>();
        for (SecurityFinding__c f : crit) ids.add(f.Id);

        Test.startTest();
        SecScanFindingsController.bulkUpdateFindingStatus(ids, 'Remediated', null);
        SecScanApiResponse r = SecScanFindingsController.getScoreCounts(run.Id);
        Test.stopTest();

        SecScanApiResponse.ScoreCountsDTO dto = (SecScanApiResponse.ScoreCountsDTO) r.data;
        System.assertEquals(0, dto.criticalOpen, 'Remediated Criticals must not count in score');
    }

    // ------------------------------------------------------------------
    // SOQL injection guard on searchTerm
    // ------------------------------------------------------------------

    @IsTest
    static void testSearchTermInjectionGuard() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCompletedRun();
        SecScanTestDataFactory.createFindings(run.Id, 'High', 2);

        String injectionAttempt = "' OR '1'='1";
        Test.startTest();
        SecScanApiResponse r = SecScanFindingsController.getCurrentScanFindings(
            run.Id, null, null, 100, injectionAttempt
        );
        Test.stopTest();

        // Must succeed without exception - injection is escaped
        System.assertEquals(true, r.success);
        SecScanApiResponse.FindingsPageDTO dto = (SecScanApiResponse.FindingsPageDTO) r.data;
        // Returns 0 results (no findings match that literal pattern)
        System.assertEquals(0, dto.findings.size());
    }
}
