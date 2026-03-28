@IsTest
private class SecScanRunnerFileUploadTest {

    // ------------------------------------------------------------------
    // Helpers: build Dom.Document responses that mimic SOAP readMetadata
    // for FileUploadAndDownloadSecuritySettings.
    // Structure the runner parses:
    //   Envelope > Body > readMetadataResponse > result
    //     > MaxUploadSizeInBytes
    //     > fileExtensionDispositions (repeating)
    //         > extension
    //         > dispositionType   (INLINE | DOWNLOAD_ONLY | DONT_ALLOW)
    // ------------------------------------------------------------------

    /**
     * Builds a Dom.Document where:
     * - MaxUploadSizeInBytes = 0 (triggers FUE-003)
     * - One disposition: extension=svg, dispositionType=INLINE (triggers FUE-002)
     */
    private static Dom.Document buildUnsafeDoc() {
        Dom.Document doc = new Dom.Document();
        Dom.XmlNode env   = doc.createRootElement('Envelope', null, null);
        Dom.XmlNode body  = env.addChildElement('Body', null, null);
        Dom.XmlNode resp  = body.addChildElement('readMetadataResponse', null, null);
        Dom.XmlNode result = resp.addChildElement('result', null, null);

        result.addChildElement('MaxUploadSizeInBytes', null, null).addTextNode('0');

        Dom.XmlNode disp = result.addChildElement('fileExtensionDispositions', null, null);
        disp.addChildElement('extension', null, null).addTextNode('svg');
        disp.addChildElement('dispositionType', null, null).addTextNode('INLINE');

        return doc;
    }

    /**
     * Builds a Dom.Document where:
     * - MaxUploadSizeInBytes = 26214400 (25 MB - safe)
     * - One disposition: extension=svg, dispositionType=DOWNLOAD_ONLY (safe)
     */
    private static Dom.Document buildSafeDoc() {
        Dom.Document doc = new Dom.Document();
        Dom.XmlNode env   = doc.createRootElement('Envelope', null, null);
        Dom.XmlNode body  = env.addChildElement('Body', null, null);
        Dom.XmlNode resp  = body.addChildElement('readMetadataResponse', null, null);
        Dom.XmlNode result = resp.addChildElement('result', null, null);

        result.addChildElement('MaxUploadSizeInBytes', null, null).addTextNode('26214400');

        Dom.XmlNode disp = result.addChildElement('fileExtensionDispositions', null, null);
        disp.addChildElement('extension', null, null).addTextNode('svg');
        disp.addChildElement('dispositionType', null, null).addTextNode('DOWNLOAD_ONLY');

        return doc;
    }

    // ------------------------------------------------------------------
    // Mock - delegates to a stored Doc so we can control content
    // ------------------------------------------------------------------

    private class SoapDocMock implements HttpCalloutMock {
        private String xmlBody;
        public SoapDocMock(Dom.Document d) {
            // Serialize to string so res.getBody() returns it correctly
            // (setBodyDocument does not populate getBody())
            this.xmlBody = d.toXmlString();
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'text/xml; charset=UTF-8');
            res.setBody(xmlBody);
            return res;
        }
    }

    // ------------------------------------------------------------------
    // checkFUE002 + checkFUE003 - unsafe doc fires both
    // ------------------------------------------------------------------

    @IsTest
    static void checkFUE002andFUE003_unsafeDoc_findingsFire() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerFileUpload runner = new SecScanRunnerFileUpload();
        Dom.Document doc = buildUnsafeDoc();

        Test.startTest();
        runner.checkFUE002(run.Id, doc);
        runner.checkFUE003(run.Id, doc);
        runner.saveFindings(run.Id);
        Test.stopTest();

        List<SecurityFinding__c> findings = [
            SELECT CheckId__c, CategoryCode__c
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id
            ORDER BY CheckId__c ASC
        ];

        Set<String> checkIds = new Set<String>();
        for (SecurityFinding__c f : findings) {
            checkIds.add(f.CheckId__c);
            System.assertEquals('FUE', f.CategoryCode__c,
                'All FUE runner findings must have CategoryCode__c = FUE');
        }

        System.assert(checkIds.contains('FUE-002'),
            'FUE-002 must fire when an SVG is set to INLINE disposition');
        System.assert(checkIds.contains('FUE-003'),
            'FUE-003 must fire when MaxUploadSizeInBytes = 0');
    }

    // ------------------------------------------------------------------
    // checkFUE002 + checkFUE003 - safe doc fires neither
    // ------------------------------------------------------------------

    @IsTest
    static void checkFUE002andFUE003_safeDoc_noFindings() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerFileUpload runner = new SecScanRunnerFileUpload();
        Dom.Document doc = buildSafeDoc();

        Test.startTest();
        runner.checkFUE002(run.Id, doc);
        runner.checkFUE003(run.Id, doc);
        runner.saveFindings(run.Id);
        Test.stopTest();

        Integer count = [
            SELECT COUNT()
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id
                AND CheckId__c IN ('FUE-002', 'FUE-003')
        ];
        System.assertEquals(0, count,
            'FUE-002 and FUE-003 must not fire when settings are safe');
    }

    // ------------------------------------------------------------------
    // checkFUE003 - non-zero size does not fire
    // ------------------------------------------------------------------

    @IsTest
    static void checkFUE003_nonZeroMaxSize_noFinding() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerFileUpload runner = new SecScanRunnerFileUpload();
        Dom.Document doc = buildSafeDoc(); // MaxUploadSizeInBytes = 26214400

        Test.startTest();
        runner.checkFUE003(run.Id, doc);
        runner.saveFindings(run.Id);
        Test.stopTest();

        Integer count = [
            SELECT COUNT()
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'FUE-003'
        ];
        System.assertEquals(0, count,
            'FUE-003 must not fire when a non-zero MaxUploadSizeInBytes is configured');
    }

    // ------------------------------------------------------------------
    // checkFUE002 - INLINE svg fires; DOWNLOAD_ONLY does not
    // ------------------------------------------------------------------

    @IsTest
    static void checkFUE002_inlineSvg_fires() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerFileUpload runner = new SecScanRunnerFileUpload();
        Dom.Document doc = buildUnsafeDoc();

        Test.startTest();
        runner.checkFUE002(run.Id, doc);
        runner.saveFindings(run.Id);
        Test.stopTest();

        List<SecurityFinding__c> findings = [
            SELECT CheckId__c, AffectedComponent__c
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'FUE-002'
        ];
        System.assertEquals(1, findings.size(),
            'FUE-002 must fire exactly once for one INLINE extension');
        System.assert(
            findings[0].AffectedComponent__c.containsIgnoreCase('svg'),
            'AffectedComponent must include the inline extension name'
        );
    }

    // ------------------------------------------------------------------
    // execute() via SOAP mock - no exception thrown
    // ------------------------------------------------------------------

    @IsTest
    static void execute_viaSoapMock_noException() {
        Dom.Document doc = buildUnsafeDoc();
        Test.setMock(HttpCalloutMock.class, new SoapDocMock(doc));
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerFileUpload runner = new SecScanRunnerFileUpload();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        System.assert(true, 'execute() completed without exception via SOAP mock');
    }
}
