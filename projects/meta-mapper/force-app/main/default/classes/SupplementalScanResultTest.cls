/**
 * SupplementalScanResultTest
 *
 * Unit tests for SupplementalScanResult. Covers the two permitted Scan_Diagnostic_Log__c
 * write paths: appendNoticeSafe (static single-notice append, including blank/oversized-log
 * truncation edge cases) and appendErrorsSafe (instance bulk-append of accumulated handler
 * errors, including dedup of identical base messages, overflow truncation, and pre-truncation
 * of an already-oversized existing log).
 */
@IsTest
private class SupplementalScanResultTest {

    @IsTest
    static void appendNoticeSafe_appendsToBlankLog() {
        String result = SupplementalScanResult.appendNoticeSafe(null, 'Hello');
        Assert.areEqual('Hello', result);
    }

    @IsTest
    static void appendNoticeSafe_appendsToExistingLog() {
        String result = SupplementalScanResult.appendNoticeSafe('Existing', 'New');
        Assert.areEqual('Existing\nNew', result);
    }

    @IsTest
    static void appendNoticeSafe_truncatesNoticeWhenBudgetInsufficient() {
        // Build a log that leaves only 5 chars of budget
        String existing = 'A'.repeat(32762); // 32768 - 1 separator - 5 budget = 32762
        String result = SupplementalScanResult.appendNoticeSafe(existing, 'ABCDEFGHIJ');
        Assert.areEqual(32768, result.length());
        Assert.isTrue(result.endsWith('\nABCDE'), 'Notice should be truncated to 5 chars');
    }

    @IsTest
    static void appendNoticeSafe_returnsExistingWhenNoBudget() {
        String existing = 'A'.repeat(32768);
        String result = SupplementalScanResult.appendNoticeSafe(existing, 'New');
        Assert.areEqual(existing, result, 'Log at capacity - existing should be returned unchanged');
    }

    @IsTest
    static void appendNoticeSafe_returnsExistingOnBlankNotice() {
        String result = SupplementalScanResult.appendNoticeSafe('Log', '');
        Assert.areEqual('Log', result);
    }

    // ---- appendErrorsSafe (instance bulk-append path) ----

    @IsTest
    static void appendErrorsSafe_happyPath_joinsAllErrors() {
        SupplementalScanResult result = new SupplementalScanResult();
        result.addError('First supplemental error');
        result.addError('Second supplemental error');
        String log = result.appendErrorsSafe(null, 32768, 200);
        Assert.isTrue(log.contains('First supplemental error'), 'Should contain first error');
        Assert.isTrue(log.contains('Second supplemental error'), 'Should contain second error');
    }

    @IsTest
    static void appendErrorsSafe_dedupsIdenticalBaseMessages() {
        SupplementalScanResult result = new SupplementalScanResult();
        result.addError('Duplicate error message');
        result.addError('Duplicate error message');
        String log = result.appendErrorsSafe(null, 32768, 200);
        Integer occurrences = 0;
        for (String line : log.split('\n')) {
            if (line.contains('Duplicate error message')) {
                occurrences++;
            }
        }
        Assert.areEqual(1, occurrences,
            'Identical base messages accumulated in the same call must be deduplicated');
    }

    @IsTest
    static void appendErrorsSafe_truncatesWhenOverflowing() {
        SupplementalScanResult result = new SupplementalScanResult();
        result.addError('X'.repeat(80));
        String log = result.appendErrorsSafe(null, 100, 40);
        Assert.isTrue(log.endsWith('[TRUNCATED: MAX LOG SIZE REACHED]'),
            'An error too large to fit the safe limit should produce the truncation suffix');
    }

    @IsTest
    static void appendErrorsSafe_preTruncatesOversizedExistingLog() {
        SupplementalScanResult result = new SupplementalScanResult();
        result.addError('New error');
        String existing = 'A'.repeat(90); // exceeds safeLimit (60) when maxLength=100/safeThreshold=40
        String log = result.appendErrorsSafe(existing, 100, 40);
        Assert.areEqual('A'.repeat(60) + '\n[PRE-TRUNCATED]', log,
            'An existing log already beyond the safe limit must be hard-truncated with a PRE-TRUNCATED marker');
    }

    @IsTest
    static void appendErrorsSafe_nullDefaults_doNotThrow() {
        SupplementalScanResult result = new SupplementalScanResult();
        result.addError('Defaults test error');
        String log = result.appendErrorsSafe(null, null, null);
        Assert.isTrue(log.contains('Defaults test error'),
            'Null maxLength/safeThreshold must default to 32768/200 without throwing');
    }

    @IsTest
    static void appendErrorsSafe_noErrors_returnsExistingUnchanged() {
        SupplementalScanResult result = new SupplementalScanResult();
        String log = result.appendErrorsSafe('Unchanged', 32768, 200);
        Assert.areEqual('Unchanged', log, 'No accumulated errors should leave the existing log untouched');
    }
}
