@IsTest
private class SecScanCategoryRunnerTest {

    // Concrete test runner - minimal subclass to expose base behavior
    private class TestRunner extends SecScanCategoryRunner {
        public TestRunner() {
            this.categoryCode = 'TEST';
        }
        public override void execute(Id scanRunId, String sessionId) {
            addFinding(buildFinding(scanRunId,
                'TEST-001', 'Test Check', 'User & Access', 'UA', 'Critical', 'Automated',
                'TestComponent', 'Profile',
                'Test description', 'Test impact', 'Test remediation',
                null, null
            ));
            saveFindings(scanRunId);
        }
    }

    // Runner that produces a finding with blank severity to test normalization
    private class BlankSeverityRunner extends SecScanCategoryRunner {
        public BlankSeverityRunner() {
            this.categoryCode = 'TEST';
        }
        public override void execute(Id scanRunId, String sessionId) {
            addFinding(buildFinding(scanRunId,
                'TEST-002', 'Blank Severity Check', 'User & Access', 'UA',
                '', // blank severity - should default to 'Low'
                'Automated', 'TestComponent', 'Profile',
                'Test description', 'Test impact', 'Test remediation',
                null, null
            ));
            saveFindings(scanRunId);
        }
    }

    // Runner that produces a finding with blank FindingType
    private class BlankTypeRunner extends SecScanCategoryRunner {
        public BlankTypeRunner() {
            this.categoryCode = 'TEST';
        }
        public override void execute(Id scanRunId, String sessionId) {
            addFinding(buildFinding(scanRunId,
                'TEST-003', 'Blank Type Check', 'User & Access', 'UA',
                'High',
                '', // blank FindingType - should default to 'Automated'
                'TestComponent', 'Profile',
                'Test description', 'Test impact', 'Test remediation',
                null, null
            ));
            saveFindings(scanRunId);
        }
    }

    // Runner that produces a finding with blank Description/Impact/Remediation
    private class BlankTextRunner extends SecScanCategoryRunner {
        public BlankTextRunner() {
            this.categoryCode = 'TEST';
        }
        public override void execute(Id scanRunId, String sessionId) {
            addFinding(buildFinding(scanRunId,
                'TEST-004', 'Blank Text Check', 'User & Access', 'UA',
                'Medium', 'Automated', 'TestComponent', 'Profile',
                '', '', '', // blank description, impact, remediation
                null, null
            ));
            saveFindings(scanRunId);
        }
    }

    // Runner that pushes past the 9,000 cap
    private class CapTestRunner extends SecScanCategoryRunner {
        private Integer findingCount;
        public CapTestRunner(Integer count) {
            this.categoryCode = 'TEST';
            this.findingCount = count;
        }
        public override void execute(Id scanRunId, String sessionId) {
            for (Integer i = 0; i < findingCount; i++) {
                addFinding(buildFinding(scanRunId,
                    'TEST-' + String.valueOf(i).leftPad(3, '0'),
                    'Check ' + i, 'User & Access', 'UA',
                    'Low', 'Automated', 'Comp' + i, 'Profile',
                    'Desc', 'Impact', 'Remed', null, null
                ));
            }
            saveFindings(scanRunId);
        }
    }

    @IsTest
    static void testBuildFindingInsertsCorrectly() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        Test.startTest();
        new TestRunner().execute(run.Id, null);
        Test.stopTest();

        List<SecurityFinding__c> findings = [
            SELECT CheckId__c, Severity__c, SeverityRank__c, FindingType__c,
                   Description__c, Impact__c, Remediation__c
            FROM SecurityFinding__c WHERE ScanRun__c = :run.Id
        ];
        System.assertEquals(1, findings.size());
        System.assertEquals('TEST-001', findings[0].CheckId__c);
        System.assertEquals('Critical', findings[0].Severity__c);
        System.assertEquals(1, (Integer)findings[0].SeverityRank__c, 'Critical rank must be 1');
        System.assertEquals('Automated', findings[0].FindingType__c);
        System.assertNotEquals(null, findings[0].Description__c);
    }

    @IsTest
    static void testBlankSeverityDefaultsToLow() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        Test.startTest();
        new BlankSeverityRunner().execute(run.Id, null);
        Test.stopTest();

        SecurityFinding__c f = [SELECT Severity__c, SeverityRank__c FROM SecurityFinding__c WHERE ScanRun__c = :run.Id LIMIT 1];
        System.assertEquals('Low', f.Severity__c, 'Blank severity must default to Low');
        System.assertEquals(4, (Integer)f.SeverityRank__c, 'Low rank must be 4');
    }

    @IsTest
    static void testBlankFindingTypeDefaultsToAutomated() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        Test.startTest();
        new BlankTypeRunner().execute(run.Id, null);
        Test.stopTest();

        SecurityFinding__c f = [SELECT FindingType__c FROM SecurityFinding__c WHERE ScanRun__c = :run.Id LIMIT 1];
        System.assertEquals('Automated', f.FindingType__c, 'Blank FindingType must default to Automated');
    }

    @IsTest
    static void testBlankTextFieldsFallback() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        Test.startTest();
        new BlankTextRunner().execute(run.Id, null);
        Test.stopTest();

        SecurityFinding__c f = [SELECT Description__c, Impact__c, Remediation__c FROM SecurityFinding__c WHERE ScanRun__c = :run.Id LIMIT 1];
        System.assert(!String.isBlank(f.Description__c), 'Description fallback must be set');
        System.assert(!String.isBlank(f.Impact__c), 'Impact fallback must be set');
        System.assert(!String.isBlank(f.Remediation__c), 'Remediation fallback must be set');
        System.assert(f.Description__c.contains('TEST-004'), 'Fallback must reference CheckId');
    }

    @IsTest
    static void testCapEnforcement() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        Integer overCap = SecScanConstants.MAX_FINDINGS_PER_CATEGORY + 50;
        Test.startTest();
        new CapTestRunner(overCap).execute(run.Id, null);
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM SecurityFinding__c WHERE ScanRun__c = :run.Id];
        // Should be capped at MAX + 1 synthetic cap finding
        System.assert(count <= SecScanConstants.MAX_FINDINGS_PER_CATEGORY + 1,
            'Findings must not exceed MAX_FINDINGS_PER_CATEGORY + 1 cap finding');

        // Verify synthetic cap finding exists
        List<SecurityFinding__c> capFindings = [
            SELECT CheckId__c FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c LIKE '%-CAP'
        ];
        System.assertEquals(1, capFindings.size(), 'One cap-finding must be inserted');
        System.assertEquals('TEST-CAP', capFindings[0].CheckId__c);
    }

    @IsTest
    static void testSeverityRankMappingAllValues() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();

        String[] severities   = new String[]{ 'Critical', 'High', 'Medium', 'Low', 'Informational' };
        Integer[] expectedRanks = new Integer[]{ 1, 2, 3, 4, 5 };

        List<SecurityFinding__c> toInsert = new List<SecurityFinding__c>();
        for (String sev : severities) {
            toInsert.add(SecScanTestDataFactory.buildFinding(run.Id, sev.substring(0,1) + '-001', sev));
        }
        insert toInsert;

        List<SecurityFinding__c> inserted = [
            SELECT Severity__c, SeverityRank__c FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id ORDER BY SeverityRank__c ASC
        ];
        for (Integer i = 0; i < inserted.size(); i++) {
            System.assertEquals(expectedRanks[i], (Integer)inserted[i].SeverityRank__c,
                'Rank mismatch for ' + inserted[i].Severity__c);
        }
    }
}
