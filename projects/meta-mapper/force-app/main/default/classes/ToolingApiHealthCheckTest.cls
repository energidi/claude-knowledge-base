/**
 * ToolingApiHealthCheckTest
 *
 * Unit tests for ToolingApiHealthCheck.verify(). Uses mock HTTP responses to
 * cover all five HealthStatus return values without making real callouts.
 * Covers the permission guard (fires before any callout), each HTTP status code
 * path, and both CalloutException variants (timeout vs generic network error).
 */
@IsTest
private class ToolingApiHealthCheckTest {

    // -----------------------------------------------------------------------
    // Mock HTTP responses
    // -----------------------------------------------------------------------

    private class MockResponse implements HttpCalloutMock {
        private final Integer statusCode;
        private final String  body;

        MockResponse(Integer code, String body) {
            this.statusCode = code;
            this.body       = body;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(body);
            return res;
        }
    }

    private class TimeoutMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            throw new System.CalloutException('Read timed out');
        }
    }

    private class GenericCalloutErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            throw new System.CalloutException('Connection refused');
        }
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    // PERMISSION_SET_MISSING: does not set skipPermissionCheck so the guard fires normally.
    // In test context FeatureManagement.checkPermission() returns false (no permission assigned).
    @IsTest
    static void verify_missingPermission_returnsPermissionSetMissing() {
        Test.startTest();
        ToolingApiHealthCheck.HealthResult result = ToolingApiHealthCheck.verify();
        Test.stopTest();

        Assert.areEqual('PERMISSION_SET_MISSING', result.status);
        Assert.isTrue(result.message.contains('MetaMapper Admin permission set'));
    }

    @IsTest
    static void verify_200_returnsAuthorized() {
        ToolingApiHealthCheck.skipPermissionCheck = true;
        Test.setMock(HttpCalloutMock.class, new MockResponse(200, '{"done":true}'));
        Test.startTest();
        ToolingApiHealthCheck.HealthResult result = ToolingApiHealthCheck.verify();
        Test.stopTest();

        Assert.areEqual('AUTHORIZED', result.status);
        Assert.isNull(result.message);
    }

    @IsTest
    static void verify_401_returnsUnauthorized() {
        ToolingApiHealthCheck.skipPermissionCheck = true;
        Test.setMock(HttpCalloutMock.class, new MockResponse(401, ''));
        Test.startTest();
        ToolingApiHealthCheck.HealthResult result = ToolingApiHealthCheck.verify();
        Test.stopTest();

        Assert.areEqual('UNAUTHORIZED', result.status);
        Assert.isTrue(result.message.contains('one-time setup'));
    }

    @IsTest
    static void verify_403_returnsCalloutForbidden() {
        ToolingApiHealthCheck.skipPermissionCheck = true;
        Test.setMock(HttpCalloutMock.class, new MockResponse(403, ''));
        Test.startTest();
        ToolingApiHealthCheck.HealthResult result = ToolingApiHealthCheck.verify();
        Test.stopTest();

        Assert.areEqual('CALLOUT_FORBIDDEN', result.status);
        Assert.isTrue(result.message.contains('OAuth scopes'));
    }

    @IsTest
    static void verify_500_returnsUnreachable() {
        ToolingApiHealthCheck.skipPermissionCheck = true;
        Test.setMock(HttpCalloutMock.class, new MockResponse(500, ''));
        Test.startTest();
        ToolingApiHealthCheck.HealthResult result = ToolingApiHealthCheck.verify();
        Test.stopTest();

        Assert.areEqual('UNREACHABLE', result.status);
        Assert.isTrue(result.message.contains('temporary org issue'));
    }

    @IsTest
    static void verify_timeout_returnsTimeout() {
        ToolingApiHealthCheck.skipPermissionCheck = true;
        Test.setMock(HttpCalloutMock.class, new TimeoutMock());
        Test.startTest();
        ToolingApiHealthCheck.HealthResult result = ToolingApiHealthCheck.verify();
        Test.stopTest();

        Assert.areEqual('TIMEOUT', result.status);
        Assert.isTrue(result.message.contains('network'));
    }

    @IsTest
    static void verify_genericCalloutError_returnsUnreachable() {
        ToolingApiHealthCheck.skipPermissionCheck = true;
        Test.setMock(HttpCalloutMock.class, new GenericCalloutErrorMock());
        Test.startTest();
        ToolingApiHealthCheck.HealthResult result = ToolingApiHealthCheck.verify();
        Test.stopTest();

        Assert.areEqual('UNREACHABLE', result.status);
    }
}
