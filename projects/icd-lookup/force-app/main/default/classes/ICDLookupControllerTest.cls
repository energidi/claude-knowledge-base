@isTest
private class ICDLookupControllerTest {

    private class MockHttpSuccess implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('[12, ["A001", "I10"], null, [["A001", "Cholera due to Vibrio cholerae 01, biovar cholerae"], ["I10", "Essential (primary) hypertension"]]]');
            return res;
        }
    }

    private class MockHttpNoResults implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('[0, [], null, []]');
            return res;
        }
    }

    private class MockHttpError implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(503);
            res.setStatus('Service Unavailable');
            return res;
        }
    }

    @isTest
    static void testSearchReturnsResults() {
        Test.setMock(HttpCalloutMock.class, new MockHttpSuccess());
        Test.startTest();
        List<ICDLookupController.ICDResult> results = ICDLookupController.searchIcd10('hypertension');
        Test.stopTest();
        System.assertEquals(2, results.size(), 'Expected 2 results');
        System.assertEquals('A001', results[0].code);
        System.assertEquals('I10', results[1].code);
        System.assertEquals('Essential (primary) hypertension', results[1].description);
    }

    @isTest
    static void testSearchNoResultsReturnsEmpty() {
        Test.setMock(HttpCalloutMock.class, new MockHttpNoResults());
        Test.startTest();
        List<ICDLookupController.ICDResult> results = ICDLookupController.searchIcd10('zzz');
        Test.stopTest();
        System.assert(results.isEmpty(), 'Expected empty results for no-match search');
    }

    @isTest
    static void testSearchBlankReturnsEmpty() {
        Test.startTest();
        List<ICDLookupController.ICDResult> results = ICDLookupController.searchIcd10('');
        Test.stopTest();
        System.assert(results.isEmpty(), 'Expected empty results for blank search');
    }

    @isTest
    static void testSearchShortTermReturnsEmpty() {
        Test.startTest();
        List<ICDLookupController.ICDResult> results = ICDLookupController.searchIcd10('ab');
        Test.stopTest();
        System.assert(results.isEmpty(), 'Expected empty results for short search term');
    }

    @isTest
    static void testSearchTermTooLongThrows() {
        String longTerm = 'a'.repeat(101);
        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            ICDLookupController.searchIcd10(longTerm);
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();
        System.assert(exceptionThrown, 'Expected AuraHandledException for search term over 100 characters');
    }

    @isTest
    static void testNon200ResponseThrows() {
        Test.setMock(HttpCalloutMock.class, new MockHttpError());
        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            ICDLookupController.searchIcd10('hypertension');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();
        System.assert(exceptionThrown, 'Expected AuraHandledException for non-200 HTTP response');
    }

    @isTest
    static void testGetConfigReturnsNullForBlank() {
        Test.startTest();
        ICD_Lookup__mdt config = ICDLookupController.getIcdLookupConfig('');
        Test.stopTest();
        Assert.isNull(config, 'Expected null for blank automationApiName');
    }

    @isTest
    static void testGetConfigReturnsNullForNoMatch() {
        Test.startTest();
        ICD_Lookup__mdt config = ICDLookupController.getIcdLookupConfig('NonExistent_Flow_That_Should_Not_Exist');
        Test.stopTest();
        Assert.isNull(config, 'Expected null for unmatched API name');
    }
}
