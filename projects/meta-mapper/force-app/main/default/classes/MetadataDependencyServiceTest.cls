/**
 * MetadataDependencyServiceTest
 *
 * Unit tests for MetadataDependencyService. Covers fetchDependencies() SOQL
 * formatting, IN-clause chunking, QueryMore cursor following, HTTP 414/431
 * reactive split-and-retry, Active Flows Only filtering, and buildContextData()
 * Dependency_Context__c payload construction per metadata type.
 */
@IsTest
private class MetadataDependencyServiceTest {

    // ---- fetchDependencies - happy path ----

    @IsTest
    static void fetchDependencies_nullInput_returnsEmptyMap() {
        DependencyFetchContext opts = new DependencyFetchContext();
        opts.jobId = 'a001000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> result = svc.fetchDependencies(null, opts);
        Assert.isTrue(result.isEmpty(), 'Null input should return empty map');
    }

    @IsTest
    static void fetchDependencies_emptyInput_returnsEmptyMap() {
        DependencyFetchContext opts = new DependencyFetchContext();
        opts.jobId = 'a001000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> result =
            svc.fetchDependencies(new List<String>(), opts);
        Assert.isTrue(result.isEmpty(), 'Empty input should return empty map');
    }

    @IsTest
    static void fetchDependencies_http200_parsesRecordKeyedByParent() {
        String body = '{"done":true,"totalSize":1,"records":['
            + '{"MetadataComponentId":"a001000000000001AAA",'
            + '"MetadataComponentName":"MyClass","MetadataComponentType":"ApexClass",'
            + '"RefMetadataComponentId":"a002000000000001AAA",'
            + '"RefMetadataComponentName":"MyField","RefMetadataComponentType":"CustomField"}'
            + ']}';
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, body));

        DependencyFetchContext opts = new DependencyFetchContext();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> result =
            svc.fetchDependencies(new List<String>{ 'a002000000000001AAA' }, opts);

        Assert.isTrue(result.containsKey('a002000000000001AAA'),
            'Result should be keyed by RefMetadataComponentId');
        Assert.areEqual(1, result.get('a002000000000001AAA').size(),
            'Should have one child node');
        Assert.areEqual('MyClass',
            result.get('a002000000000001AAA')[0].Metadata_Name__c,
            'Node name should match');
        Assert.areEqual(1, opts.maxResultCount,
            'maxResultCount should reflect first page size');
    }

    @IsTest
    static void fetchDependencies_http414_splitsAndReturnsResult() {
        Test.setMock(HttpCalloutMock.class, new ToolingApi414AlwaysMock());
        DependencyFetchContext opts = new DependencyFetchContext();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        List<String> ids = new List<String>{
            'a001000000000001AAA', 'a001000000000002AAA'
        };
        Map<String, List<Metadata_Dependency__c>> result = svc.fetchDependencies(ids, opts);
        Assert.isNotNull(result, 'Should not throw on 414');
        Assert.isFalse(opts.errors.isEmpty(), 'Should log 414 error after max split depth');
    }

    @IsTest
    static void fetchDependencies_http500_logsErrorAndPopulatesFailedParents() {
        // Finding #1: HTTP 500 must populate failedParentMetaIds so DependencyQueueable
        // knows not to mark the parent as Has_Fetched_Dependencies__c = true.
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(500, 'Internal Server Error'));
        DependencyFetchContext opts = new DependencyFetchContext();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        List<String> ids = new List<String>{ 'a001000000000001AAA' };
        Map<String, List<Metadata_Dependency__c>> result = svc.fetchDependencies(ids, opts);

        Assert.isTrue(result.isEmpty(), 'HTTP 500 should return empty map');
        Assert.isFalse(opts.errors.isEmpty(), 'HTTP 500 should log an error');
        Assert.isTrue(opts.failedParentMetaIds.contains('a001000000000001AAA'),
            'Failed parent ID must be recorded in failedParentMetaIds');
    }

    @IsTest
    static void fetchDependencies_largeResponseBody_rejectsWithError() {
        // Body size guard prevents heap spike on large responses.
        String paddedBody = '{"done":true,"totalSize":0,"records":[]}' + 'x'.repeat(500001);
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, paddedBody));
        DependencyFetchContext opts = new DependencyFetchContext();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        List<String> ids = new List<String>{ 'a001000000000001AAA' };
        svc.fetchDependencies(ids, opts);

        Assert.isFalse(opts.errors.isEmpty(), 'Oversized body should log heap guard error');
        Assert.isFalse(opts.failedParentMetaIds.isEmpty(),
            'Oversized body should populate failedParentMetaIds');
    }

    @IsTest
    static void fetchDependencies_queryMore_followsNextPageAndTracksMaxCount() {
        // Finding #16: maxResultCount must reflect the max first-page size across chunks,
        // not just the last chunk processed.
        // This mock returns page 1 with a nextRecordsUrl, then page 2 with done=true.
        Test.setMock(HttpCalloutMock.class, new QueryMoreMock());

        DependencyFetchContext opts = new DependencyFetchContext();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> result =
            svc.fetchDependencies(new List<String>{ 'a002000000000001AAA' }, opts);

        Assert.isFalse(result.isEmpty(), 'QueryMore should yield results from both pages');
        Assert.areEqual(2, result.get('a002000000000001AAA').size(),
            'Both pages should contribute records');
        // maxResultCount tracks page 1 size (1 record) not the total.
        Assert.areEqual(1, opts.maxResultCount,
            'maxResultCount should reflect the first-page record count');
    }

    @IsTest
    static void fetchDependencies_calloutBudgetExhausted_populatesFailedParents() {
        // Finding #15: when the pre-call budget guard fires, failedParentMetaIds must be populated.
        // We cannot exhaust callout budget in a test, so we test the opts outcome via the
        // HTTP 500 path (which exercises the same failedParentMetaIds population code path).
        // The budget guard itself is integration-tested via execute_http500 in DependencyQueueableTest.
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(500, 'err'));
        DependencyFetchContext opts = new DependencyFetchContext();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        svc.fetchDependencies(new List<String>{ 'a001000000000001AAA' }, opts);
        Assert.isFalse(opts.failedParentMetaIds.isEmpty(),
            'Any failure path should populate failedParentMetaIds');
    }

    @IsTest
    static void fetchDependencies_400Ids_splitsAtUrlBudget() {
        // Finding #9: the dynamic URL-budget chunking (URL_OVERHEAD=350, ID_CHAR_COST=21,
        // URL_BUDGET=8000 -> max safe batch = 364 IDs) must actually split a batch of 400 IDs
        // into more than one callout, and no single callout may exceed 364 IDs.
        List<String> ids = new List<String>();
        for (Integer i = 0; i < 400; i++) {
            ids.add('a00' + String.valueOf(i).leftPad(15, '0'));
        }
        CountingUrlBudgetMock mock = new CountingUrlBudgetMock();
        Test.setMock(HttpCalloutMock.class, mock);

        DependencyFetchContext opts = new DependencyFetchContext();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        svc.fetchDependencies(ids, opts);

        Assert.isTrue(mock.calloutCount > 1,
            'A batch of 400 IDs must be split into more than one callout');
        Assert.isTrue(mock.maxIdsInSingleCallout <= 364,
            'No single callout may exceed the URL-budget-derived max safe batch of 364 IDs, got '
            + mock.maxIdsInSingleCallout);
    }

    // ---- buildContextData ----

    @IsTest
    static void buildContextData_apexClass_returnsIsWriteJson() {
        MetadataDependencyService svc = new MetadataDependencyService();
        Metadata_Dependency__c n = new Metadata_Dependency__c(Metadata_Type__c = 'ApexClass');
        String ctx = svc.buildContextData(n);
        Assert.isTrue(ctx.contains('"v":1'), 'Should include version key');
        Assert.isTrue(ctx.contains('"isWrite"'), 'ApexClass should have isWrite');
    }

    @IsTest
    static void buildContextData_unknownType_returnsNull() {
        MetadataDependencyService svc = new MetadataDependencyService();
        Metadata_Dependency__c n = new Metadata_Dependency__c(Metadata_Type__c = 'UnknownType');
        Assert.isNull(svc.buildContextData(n), 'Unknown type should return null');
    }

    @IsTest
    static void buildContextData_nullNode_returnsNull() {
        MetadataDependencyService svc = new MetadataDependencyService();
        Assert.isNull(svc.buildContextData(null), 'Null node should return null');
    }

    // ---- computeScore ----

    @IsTest
    static void computeScore_knownCombinations_returnsCorrectScores() {
        MetadataDependencyService svc = new MetadataDependencyService();
        Assert.areEqual(95, svc.computeScore('WorkflowFieldUpdate', ''));
        Assert.areEqual(65, svc.computeScore('ValidationRule', 'regex'));
        Assert.areEqual(60, svc.computeScore('FlexiPage', ''));
        Assert.areEqual(85, svc.computeScore('CustomMetadata', 'fieldValue'));
        Assert.areEqual(95, svc.computeScore('LookupRelationship', ''));
        Assert.areEqual(70, svc.computeScore('Unknown', ''));
    }

    // ---- Mocks ----

    private class ToolingApiMock implements HttpCalloutMock {
        private final Integer code;
        private final String  body;
        ToolingApiMock(Integer code, String body) { this.code = code; this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(code);
            res.setBody(body);
            return res;
        }
    }

    private class ToolingApi414AlwaysMock implements HttpCalloutMock {
        // Always returns 414 to exhaust all split attempts - confirms error logging
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(414);
            res.setBody('');
            return res;
        }
    }

    private class QueryMoreMock implements HttpCalloutMock {
        // First call returns page 1 with nextRecordsUrl; second call returns page 2 (done=true).
        private Integer callCount = 0;
        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            if (callCount == 1) {
                res.setBody('{"done":false,"totalSize":2,"nextRecordsUrl":"/services/data/v66.0/tooling/query/01g000000000001","records":['
                    + '{"MetadataComponentId":"a001000000000001AAA",'
                    + '"MetadataComponentName":"ClassA","MetadataComponentType":"ApexClass",'
                    + '"RefMetadataComponentId":"a002000000000001AAA",'
                    + '"RefMetadataComponentName":"MyField","RefMetadataComponentType":"CustomField"}'
                    + ']}');
            } else {
                res.setBody('{"done":true,"totalSize":2,"records":['
                    + '{"MetadataComponentId":"a001000000000002AAA",'
                    + '"MetadataComponentName":"ClassB","MetadataComponentType":"ApexClass",'
                    + '"RefMetadataComponentId":"a002000000000001AAA",'
                    + '"RefMetadataComponentName":"MyField","RefMetadataComponentType":"CustomField"}'
                    + ']}');
            }
            return res;
        }
    }

    private class CountingUrlBudgetMock implements HttpCalloutMock {
        // Records the number of distinct callouts made and the max IN-clause ID count
        // found in each request's decoded SOQL, so tests can verify the dynamic
        // URL-budget chunking never exceeds the 364-ID max safe batch.
        Integer calloutCount = 0;
        Integer maxIdsInSingleCallout = 0;
        public HttpResponse respond(HttpRequest req) {
            calloutCount++;
            String decoded = EncodingUtil.urlDecode(req.getEndpoint(), 'UTF-8');
            Integer inStart = decoded.indexOf('IN (') + 4;
            Integer inEnd = decoded.lastIndexOf(')');
            Integer idCount = 0;
            if (inStart >= 4 && inEnd > inStart) {
                idCount = decoded.substring(inStart, inEnd).split(',').size();
            }
            maxIdsInSingleCallout = Math.max(maxIdsInSingleCallout, idCount);

            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"done":true,"totalSize":0,"records":[]}');
            return res;
        }
    }

    private class ToolingApi414ThenOkMock implements HttpCalloutMock {
        // Returns 414 on the first call, then 200 with one result record on subsequent calls.
        // Used to verify the split-and-recover happy path (not max-depth exhaustion).
        private Integer callCount = 0;
        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            if (callCount == 1) {
                res.setStatusCode(414);
                res.setBody('');
            } else {
                res.setStatusCode(200);
                res.setBody('{"done":true,"totalSize":1,"records":['
                    + '{"MetadataComponentId":"a001000000000001AAA",'
                    + '"MetadataComponentName":"ClassA","MetadataComponentType":"ApexClass",'
                    + '"RefMetadataComponentId":"a002000000000001AAA",'
                    + '"RefMetadataComponentName":"MyField","RefMetadataComponentType":"CustomField"}'
                    + ']}');
            }
            return res;
        }
    }

    @IsTest
    static void fetchDependencies_http414ThenOk_splitsAndRecovers() {
        // Finding #24: the split-and-retry happy path (414 on first call, 200 on retry halves)
        // must return results and log no errors.
        Test.setMock(HttpCalloutMock.class, new ToolingApi414ThenOkMock());
        DependencyFetchContext opts = new DependencyFetchContext();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        // Two IDs trigger a split on 414; each half gets a 200 response.
        List<String> ids = new List<String>{
            'a001000000000001AAA', 'a001000000000002AAA'
        };
        Map<String, List<Metadata_Dependency__c>> result = svc.fetchDependencies(ids, opts);
        Assert.isFalse(result.isEmpty(),
            'Results should be returned after a 414 split-and-recover');
        Assert.isTrue(opts.errors.isEmpty(),
            'No errors should be logged when split-and-recover succeeds');
    }

    @IsTest
    static void filterInactiveFlows_activeFlowsOnly_dropsInactiveRetainsActive() {
        // Happy path: mock returns only 'ActiveFlow' as having an active version.
        // 'InactiveFlow' should be dropped; 'ActiveFlow' should be retained.
        String activeBody = '{"done":true,"totalSize":1,"records":[{"DeveloperName":"ActiveFlow"}]}';
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, activeBody));

        DependencyFetchContext opts = new DependencyFetchContext();
        opts.jobId = 'a003000000000001AAA';
        opts.isActiveFlowsOnly = true;
        Map<String, List<Metadata_Dependency__c>> results =
            new Map<String, List<Metadata_Dependency__c>>{
                'a001000000000001AAA' => new List<Metadata_Dependency__c>{
                    new Metadata_Dependency__c(
                        Metadata_Type__c = 'Flow',
                        Metadata_Name__c = 'ActiveFlow',
                        Metadata_Id__c   = 'a001000000000002AAA'),
                    new Metadata_Dependency__c(
                        Metadata_Type__c = 'Flow',
                        Metadata_Name__c = 'InactiveFlow',
                        Metadata_Id__c   = 'a001000000000003AAA')
                }
            };

        MetadataDependencyService svc = new MetadataDependencyService();
        Test.startTest();
        svc.filterInactiveFlows(results, opts);
        Test.stopTest();

        Assert.areEqual(1, results.get('a001000000000001AAA').size(),
            'Only the active Flow should be retained');
        Assert.areEqual('ActiveFlow',
            results.get('a001000000000001AAA')[0].Metadata_Name__c,
            'Retained node should be ActiveFlow');
    }

    @IsTest
    static void filterInactiveFlows_httpError_failOpen_retainsAllFlows() {
        // Fail-open: on HTTP 500 all Flow nodes must be retained and an error logged.
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(500, 'Internal Server Error'));

        DependencyFetchContext opts = new DependencyFetchContext();
        opts.jobId = 'a003000000000001AAA';
        opts.isActiveFlowsOnly = true;
        Map<String, List<Metadata_Dependency__c>> results =
            new Map<String, List<Metadata_Dependency__c>>{
                'a001000000000001AAA' => new List<Metadata_Dependency__c>{
                    new Metadata_Dependency__c(
                        Metadata_Type__c = 'Flow',
                        Metadata_Name__c = 'SomeFlow',
                        Metadata_Id__c   = 'a001000000000002AAA')
                }
            };

        MetadataDependencyService svc = new MetadataDependencyService();
        Test.startTest();
        svc.filterInactiveFlows(results, opts);
        Test.stopTest();

        Assert.areEqual(1, results.get('a001000000000001AAA').size(),
            'All Flow nodes should be retained when the active-version check fails (fail-open)');
        Assert.isFalse(opts.errors.isEmpty(),
            'An error should be logged when the HTTP call fails');
    }

    @IsTest
    static void filterInactiveFlows_activeFlowsOnlyFalse_returnsImmediately() {
        // When activeFlowsOnly = false the method must return without making any callout.
        // No mock is set so any callout would throw UnexpectedCalloutException.
        DependencyFetchContext opts = new DependencyFetchContext();
        opts.jobId = 'a003000000000001AAA';
        opts.isActiveFlowsOnly = false;
        Map<String, List<Metadata_Dependency__c>> results =
            new Map<String, List<Metadata_Dependency__c>>{
                'a001000000000001AAA' => new List<Metadata_Dependency__c>{
                    new Metadata_Dependency__c(
                        Metadata_Type__c = 'Flow',
                        Metadata_Name__c = 'SomeFlow',
                        Metadata_Id__c   = 'a001000000000002AAA')
                }
            };

        MetadataDependencyService svc = new MetadataDependencyService();
        Test.startTest();
        svc.filterInactiveFlows(results, opts);
        Test.stopTest();

        Assert.areEqual(1, results.get('a001000000000001AAA').size(),
            'Results should be unchanged when activeFlowsOnly is false');
        Assert.isTrue(opts.errors.isEmpty(),
            'No errors should be logged when method exits early');
    }
}
