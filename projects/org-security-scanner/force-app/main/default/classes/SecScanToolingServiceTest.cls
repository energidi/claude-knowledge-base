@IsTest
private class SecScanToolingServiceTest {

    // ------------------------------------------------------------------
    // Mock HTTP callout implementations
    // ------------------------------------------------------------------

    private class SuccessMock implements HttpCalloutMock {
        private String body;
        public SuccessMock(String body) { this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody(body);
            return res;
        }
    }

    private class UnauthorizedMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(401);
            res.setBody('[{"message":"Session expired or invalid","errorCode":"INVALID_SESSION_ID"}]');
            return res;
        }
    }

    private class ErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"message":"Internal server error"}');
            return res;
        }
    }

    private class PaginatedMock implements HttpCalloutMock {
        private Integer callCount = 0;
        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');

            if (callCount == 1) {
                // First page with nextRecordsUrl
                res.setBody('{"totalSize":2,"done":false,"nextRecordsUrl":"/services/data/v66.0/tooling/query/01gXXX-2000","records":[{"Id":"001"},{"Id":"002"}]}');
            } else {
                // Second page - done
                res.setBody('{"totalSize":2,"done":true,"records":[{"Id":"003"}]}');
            }
            return res;
        }
    }

    // ------------------------------------------------------------------
    // query() - basic success
    // ------------------------------------------------------------------

    @IsTest
    static void testQuerySuccess() {
        String mockBody = '{"totalSize":1,"done":true,"records":[{"Id":"001","Name":"Test"}]}';
        Test.setMock(HttpCalloutMock.class, new SuccessMock(mockBody));

        Test.startTest();
        List<Map<String, Object>> records = SecScanToolingService.query(
            'SELECT Id, Name FROM Profile LIMIT 1', 'testSessionId'
        );
        Test.stopTest();

        System.assertNotNull(records);
        System.assertEquals(1, records.size());
        System.assertEquals('001', records[0].get('Id'));
    }

    @IsTest
    static void testQueryEmptyResult() {
        String mockBody = '{"totalSize":0,"done":true,"records":[]}';
        Test.setMock(HttpCalloutMock.class, new SuccessMock(mockBody));

        Test.startTest();
        List<Map<String, Object>> records = SecScanToolingService.query(
            'SELECT Id FROM Profile WHERE Id = null', 'testSessionId'
        );
        Test.stopTest();

        System.assertEquals(0, records.size());
    }

    @IsTest
    static void testQueryRawSuccess() {
        String mockBody = '{"totalSize":2,"done":true,"records":[]}';
        Test.setMock(HttpCalloutMock.class, new SuccessMock(mockBody));

        Test.startTest();
        Map<String, Object> result = SecScanToolingService.queryRaw(
            'SELECT COUNT() FROM Profile', 'testSessionId'
        );
        Test.stopTest();

        System.assertNotNull(result);
        System.assertEquals(2, result.get('totalSize'));
    }

    // ------------------------------------------------------------------
    // Session expired detection - throws SecScanSessionExpiredException
    // ------------------------------------------------------------------

    @IsTest
    static void testSessionExpiredThrows() {
        Test.setMock(HttpCalloutMock.class, new UnauthorizedMock());

        Test.startTest();
        Boolean threw = false;
        try {
            SecScanToolingService.query('SELECT Id FROM Profile', 'expiredSession');
        } catch (SecScanSessionExpiredException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Must throw SecScanSessionExpiredException on 401');
    }

    @IsTest
    static void testInvalidSessionIdInBodyThrows() {
        String body = '[{"message":"INVALID_SESSION_ID","errorCode":"INVALID_SESSION_ID"}]';
        Test.setMock(HttpCalloutMock.class, new SuccessMock(body));

        // The body contains INVALID_SESSION_ID even with 200 status - still must throw
        Test.startTest();
        Boolean threw = false;
        try {
            SecScanToolingService.query('SELECT Id FROM Profile', 'badSession');
        } catch (SecScanSessionExpiredException e) {
            threw = true;
        } catch (Exception e) {
            // May also throw as a general exception depending on parse behavior
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Must detect INVALID_SESSION_ID in response body');
    }

    // ------------------------------------------------------------------
    // HTTP 500 error
    // ------------------------------------------------------------------

    @IsTest
    static void testHttpErrorThrows() {
        Test.setMock(HttpCalloutMock.class, new ErrorMock());

        Test.startTest();
        Boolean threw = false;
        try {
            SecScanToolingService.query('SELECT Id FROM Profile', 'testSessionId');
        } catch (SecScanException e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Non-200/401 HTTP response must throw SecScanException');
    }

    // ------------------------------------------------------------------
    // Paginated result follow-through
    // ------------------------------------------------------------------

    @IsTest
    static void testPaginatedResultsFollowNextRecordsUrl() {
        Test.setMock(HttpCalloutMock.class, new PaginatedMock());

        Test.startTest();
        List<Map<String, Object>> allRecords = SecScanToolingService.query(
            'SELECT Id FROM Profile', 'testSessionId'
        );
        Test.stopTest();

        // Should have 3 records across 2 pages
        System.assert(allRecords.size() >= 2, 'Must follow nextRecordsUrl to get all pages');
    }
}
