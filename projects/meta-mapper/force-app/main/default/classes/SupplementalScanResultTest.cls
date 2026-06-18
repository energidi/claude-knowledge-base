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
}
