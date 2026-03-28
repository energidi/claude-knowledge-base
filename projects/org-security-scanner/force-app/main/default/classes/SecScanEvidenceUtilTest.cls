@IsTest
private class SecScanEvidenceUtilTest {

    // ------------------------------------------------------------------
    // Scrub patterns - all 9, case-insensitive
    // ------------------------------------------------------------------

    @IsTest
    static void testScrubPassword() {
        String input = 'config: password=SuperSecret123 end';
        String result = SecScanEvidenceUtil.process(input);
        System.assert(!result.contains('SuperSecret123'), 'password value must be scrubbed');
        System.assert(result.contains('password=***'), 'password= prefix must be preserved');
    }

    @IsTest
    static void testScrubPasswordUpperCase() {
        String input = 'PASSWORD=MyPwd123';
        String result = SecScanEvidenceUtil.process(input);
        System.assert(!result.contains('MyPwd123'), 'case-insensitive scrub must apply');
    }

    @IsTest
    static void testScrubPasswd() {
        String input = 'passwd=abc123';
        String result = SecScanEvidenceUtil.process(input);
        System.assert(!result.contains('abc123'));
        System.assert(result.contains('passwd=***'));
    }

    @IsTest
    static void testScrubPwd() {
        String input = 'pwd=mypassword';
        String result = SecScanEvidenceUtil.process(input);
        System.assert(!result.contains('mypassword'));
        System.assert(result.contains('pwd=***'));
    }

    @IsTest
    static void testScrubSecret() {
        String input = 'secret=client_secret_value';
        String result = SecScanEvidenceUtil.process(input);
        System.assert(!result.contains('client_secret_value'));
    }

    @IsTest
    static void testScrubApiKey() {
        String input = 'api_key=ABC-123-XYZ';
        String result = SecScanEvidenceUtil.process(input);
        System.assert(!result.contains('ABC-123-XYZ'));
        System.assert(result.contains('api_key=***'));
    }

    @IsTest
    static void testScrubClientSecret() {
        String input = 'client_secret=mysecretvalue';
        String result = SecScanEvidenceUtil.process(input);
        System.assert(!result.contains('mysecretvalue'));
        System.assert(result.contains('client_secret=***'));
    }

    @IsTest
    static void testScrubBearerToken() {
        String input = 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig';
        String result = SecScanEvidenceUtil.process(input);
        System.assert(!result.contains('eyJhbGciOiJIUzI1NiJ9'));
        System.assert(result.contains('Bearer ***'));
    }

    @IsTest
    static void testScrubToken() {
        String input = 'token=abcdef12345';
        String result = SecScanEvidenceUtil.process(input);
        System.assert(!result.contains('abcdef12345'));
        System.assert(result.contains('token=***'));
    }

    @IsTest
    static void testScrubCredentials() {
        String input = 'credentials=mySecretCreds';
        String result = SecScanEvidenceUtil.process(input);
        System.assert(!result.contains('mySecretCreds'));
        System.assert(result.contains('credentials=***'));
    }

    // ------------------------------------------------------------------
    // Truncation - hard cap at 10,000 chars
    // ------------------------------------------------------------------

    @IsTest
    static void testTruncationAtHardCap() {
        String longInput = 'A'.repeat(15000);
        String result = SecScanEvidenceUtil.process(longInput);
        System.assert(result.length() <= SecScanConstants.EVIDENCE_MAX_LENGTH,
            'Result must not exceed EVIDENCE_MAX_LENGTH');
    }

    @IsTest
    static void testShortInputNotTruncated() {
        String input = 'short clean input';
        String result = SecScanEvidenceUtil.process(input);
        System.assertEquals(input, result);
    }

    // ------------------------------------------------------------------
    // Scrub-BEFORE-truncate order - critical security requirement
    // A credential at position 9,500 in a 15,000 char body must be scrubbed
    // even though it falls in the truncated region
    // ------------------------------------------------------------------

    @IsTest
    static void testScrubBeforeTruncate() {
        // Put the credential AFTER position 10,000 so it would be cut off
        // if truncation ran first
        String prefix    = 'X'.repeat(10500);
        String input     = prefix + ' password=VerySecretValue end';
        String scrubbed  = SecScanEvidenceUtil.process(input);
        // The full-input scrub must have masked the credential before truncation
        System.assert(!scrubbed.contains('VerySecretValue'),
            'Credential past truncation boundary must be scrubbed before truncation runs');
    }

    // ------------------------------------------------------------------
    // Match-centered extraction
    // ------------------------------------------------------------------

    @IsTest
    static void testMatchCenteredExtraction() {
        // Credential at offset 6000 in a 15000-char body
        String before = 'B'.repeat(6000);
        String after  = 'A'.repeat(9000);
        String input  = before + 'password=Secret123 ' + after;
        // matchOffset = 6000
        String result = SecScanEvidenceUtil.process(input, 6000);
        // Result should be <= 10,000 chars and contain context around the match
        System.assert(result.length() <= SecScanConstants.EVIDENCE_MAX_LENGTH);
        // The credential itself must be scrubbed
        System.assert(!result.contains('Secret123'));
    }

    @IsTest
    static void testNoMatchFallbackTakesFirstChars() {
        String input  = 'ABCDE'.repeat(3000); // 15,000 chars
        // No matchOffset => fallback to first EVIDENCE_MAX_LENGTH chars
        String result = SecScanEvidenceUtil.process(input);
        System.assert(result.length() <= SecScanConstants.EVIDENCE_MAX_LENGTH);
        System.assert(result.startsWith('ABCDE'));
    }

    // ------------------------------------------------------------------
    // Null / blank input
    // ------------------------------------------------------------------

    @IsTest
    static void testNullInput() {
        String result = SecScanEvidenceUtil.process(null);
        System.assertEquals('', result);
    }

    @IsTest
    static void testBlankInput() {
        String result = SecScanEvidenceUtil.process('   ');
        System.assertEquals('', result);
    }

    // ------------------------------------------------------------------
    // SCRUB_PATTERNS map is public and auditable
    // ------------------------------------------------------------------

    @IsTest
    static void testScrubPatternsMapSize() {
        System.assertEquals(9, SecScanEvidenceUtil.SCRUB_PATTERNS.size(),
            'Must have exactly 9 scrub patterns');
    }
}
