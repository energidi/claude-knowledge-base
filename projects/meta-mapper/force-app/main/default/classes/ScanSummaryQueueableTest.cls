/**
 * ScanSummaryQueueableTest
 *
 * Unit tests for ScanSummaryQueueable. Covers plain-English summary generation
 * from Component_Type_Counts__c JSON, Scan_Summary_Text__c field update, and no-op behavior
 * when the job record is missing or Component_Type_Counts__c is blank.
 */
@IsTest
private class ScanSummaryQueueableTest {

    @IsTest
    static void execute_buildsPlainEnglishSummary() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Completed',
            Components_Analyzed__c  = 7,
            Component_Type_Counts__c       = '{"v":1,"ApexClass":5,"Flow":2}'
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Summary_Text__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isNotNull(refreshed.Scan_Summary_Text__c, 'Summary should be populated');
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('7'),
            'Summary should mention total count');
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('Apex class'),
            'Summary should humanize ApexClass');
    }

    @IsTest
    static void execute_blankResultSummary_doesNotUpdate() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Completed',
            Components_Analyzed__c  = 0,
            Component_Type_Counts__c       = null
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Summary_Text__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isNull(refreshed.Scan_Summary_Text__c,
            'No update should occur when Component_Type_Counts__c is blank');
    }

    @IsTest
    static void execute_invalidJson_fallsBackToSimpleSummary() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Completed',
            Components_Analyzed__c  = 3,
            Component_Type_Counts__c       = 'not-valid-json'
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Summary_Text__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isNotNull(refreshed.Scan_Summary_Text__c, 'Fallback summary should be written');
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('3'),
            'Fallback should include total count');
    }

    @IsTest
    static void execute_jobStatusFailed_doesNotWriteSummary() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Failed',
            Components_Analyzed__c  = 7,
            Component_Type_Counts__c       = '{"v":1,"ApexClass":5,"Flow":2}'
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Summary_Text__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isNull(refreshed.Scan_Summary_Text__c,
            'Summary must not be written when job status is not Completed');
    }

    @IsTest
    static void execute_jobNotFound_doesNotThrow() {
        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable('a000000000000001AAA'));
        Test.stopTest();

        AsyncApexJob asyncJob = [
            SELECT Status, NumberOfErrors
            FROM AsyncApexJob
            WHERE ApexClass.Name = 'ScanSummaryQueueable'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        Assert.areEqual('Completed', asyncJob.Status,
            'Queueable must complete successfully (not fail) when the job record does not exist');
        Assert.areEqual(0, asyncJob.NumberOfErrors,
            'The null-job guard must return cleanly with zero errors');
    }

    @IsTest
    static void execute_decimalValuesInSummary_coercedWithoutException() {
        // Finding #24: JSON.deserializeUntyped() returns Decimal (not Integer) when
        // JSON numbers carry a decimal point (e.g. "5.0"). The coercion chain must
        // handle Integer, Long, and Decimal without throwing a TypeException.
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Completed',
            Components_Analyzed__c  = 7,
            Component_Type_Counts__c       = '{"v":1,"ApexClass":5.0,"Flow":2.0}'
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Summary_Text__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isNotNull(refreshed.Scan_Summary_Text__c,
            'Summary should be populated even when type counts are Decimal');
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('7'),
            'Total count should appear in summary');
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('Apex class'),
            'Humanized type name should appear in summary');
    }

    @IsTest
    static void execute_moreThanFiveTypes_truncatesToFivePlusMore() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Completed',
            Components_Analyzed__c  = 12,
            Component_Type_Counts__c       = '{"v":1,"ApexClass":2,"Flow":2,"CustomField":2,"ValidationRule":2,"WorkflowRule":2,"Report":2}'
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Summary_Text__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('and more'),
            'More than 5 types should append "and more"');
    }
}
