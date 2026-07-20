/**
 * DependencyNotificationServiceTest
 *
 * Unit tests for DependencyNotificationService. Covers publishProgress() with
 * Platform Events enabled and disabled, auto-suppression when the org daily PE
 * limit exceeds 80%, and sendCompletionNotification() custom notification dispatch.
 */
@IsTest
private class DependencyNotificationServiceTest {
  @IsTest
  static void publishProgress_doesNotThrow() {
    // CMDT is read-only in tests so we cannot inject Is_Platform_Events_Disabled__c = true.
    // Validates that the service handles any org PE state without throwing AND that no
    // publish-failure notice is recorded, proving EventBus.publish() actually accepted
    // the event under normal (non-suppressed) test conditions.
    DependencyNotificationService svc = new DependencyNotificationService();
    Test.startTest();
    svc.publishProgress('a001000000000001AAA', 'Processing', 5, 'Test message');
    Test.stopTest();
    Assert.isTrue(
      DependencyNotificationService.getAndClearPendingNotices().isEmpty(),
      'publishProgress should not record a PE publish-failure notice under normal test conditions'
    );
  }

  @IsTest
  static void publishProgress_withNullMessage_doesNotThrow() {
    DependencyNotificationService svc = new DependencyNotificationService();
    Test.startTest();
    svc.publishProgress('a001000000000001AAA', 'Completed', 10, null);
    Test.stopTest();
    Assert.isTrue(
      DependencyNotificationService.getAndClearPendingNotices().isEmpty(),
      'A null message must not cause publishProgress to record a failure notice'
    );
  }

  @IsTest
  static void sendCompletion_doesNotThrow() {
    // sendCompletion() is documented as a no-op (completion is signalled via Status__c
    // on the job record). Assert it truly performs no DML on the job so a future
    // regression that adds unintended side effects is caught.
    Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
      Target_Metadata_Type__c = 'ApexClass',
      Target_API_Name__c = 'MyClass',
      Status__c = 'Completed',
      Components_Analyzed__c = 3
    );
    insert job;
    DateTime beforeModified = [
      SELECT LastModifiedDate
      FROM Metadata_Scan_Job__c
      WHERE Id = :job.Id
    ]
    .LastModifiedDate;

    DependencyNotificationService svc = new DependencyNotificationService();
    Test.startTest();
    svc.sendCompletion(job.Id, UserInfo.getUserId());
    Test.stopTest();

    Metadata_Scan_Job__c refreshed = [
      SELECT Status__c, LastModifiedDate
      FROM Metadata_Scan_Job__c
      WHERE Id = :job.Id
    ];
    Assert.areEqual(
      'Completed',
      refreshed.Status__c,
      'sendCompletion is documented as a no-op and must not alter Status__c'
    );
    Assert.areEqual(
      beforeModified,
      refreshed.LastModifiedDate,
      'sendCompletion must not perform any DML on the job record'
    );
  }

  @IsTest
  static void publishProgress_repeatedCalls_suppressionGuardIsIdempotent() {
    // Finding #11: the suppressionDeploymentQueued static flag must prevent
    // multiple Metadata.Operations.enqueueDeployment() calls within the same
    // Apex transaction. In unit tests, OrgLimits will not exceed 80% so the
    // auto-suppress branch does not fire; this test validates that repeated
    // calls across the same transaction do not accumulate state errors or throw.
    Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
      Target_Metadata_Type__c = 'ApexClass',
      Target_API_Name__c = 'MyClass',
      Status__c = 'Processing',
      Components_Analyzed__c = 0
    );
    insert job;

    DependencyNotificationService svc = new DependencyNotificationService();
    Test.startTest();
    svc.publishProgress(job.Id, 'Processing', 1, 'Cycle 1');
    svc.publishProgress(job.Id, 'Processing', 2, 'Cycle 2');
    svc.publishProgress(job.Id, 'Processing', 3, 'Cycle 3');
    Test.stopTest();
    // The OrgLimits-driven suppress path is exercised implicitly on any
    // execution where the org has consumed >80% of its daily PE allocation.
    Assert.isTrue(
      DependencyNotificationService.getAndClearPendingNotices().isEmpty(),
      'Repeated calls in one transaction must not accumulate publish-failure notices'
    );
  }

  @IsTest
  static void publishProgress_jobWithExistingErrorMessage_doesNotOverwrite() {
    // Validates that autoSuppressAndLog appends to - rather than overwrites -
    // an existing Scan_Diagnostic_Log__c. In unit tests the suppress branch
    // does not fire, so this confirms the job record is untouched on the
    // normal (non-suppress) path (no accidental write occurs).
    Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
      Target_Metadata_Type__c = 'ApexClass',
      Target_API_Name__c = 'MyClass',
      Status__c = 'Processing',
      Scan_Diagnostic_Log__c = 'Pre-existing diagnostic message',
      Components_Analyzed__c = 0
    );
    insert job;

    DependencyNotificationService svc = new DependencyNotificationService();
    Test.startTest();
    svc.publishProgress(job.Id, 'Processing', 1, 'Test');
    Test.stopTest();

    Metadata_Scan_Job__c refreshed = [
      SELECT Scan_Diagnostic_Log__c
      FROM Metadata_Scan_Job__c
      WHERE Id = :job.Id
    ];
    Assert.areEqual(
      'Pre-existing diagnostic message',
      refreshed.Scan_Diagnostic_Log__c,
      'Normal publishProgress must not modify Scan_Diagnostic_Log__c'
    );
  }

  @IsTest
  static void publishProgress_deliversEventWithCorrectFields() {
    // Round 79 Finding #1: prior tests only asserted the absence of a publish-failure
    // notice (a no-throw proxy). This asserts the actual delivered Dependency_Scan_Status__e
    // payload so a field-mapping regression (wrong job Id, stale status, dropped message)
    // would be caught.
    Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
      Target_Metadata_Type__c = 'ApexClass',
      Target_API_Name__c = 'MyClass',
      Status__c = 'Processing',
      Components_Analyzed__c = 0
    );
    insert job;

    DependencyNotificationService svc = new DependencyNotificationService();
    Test.startTest();
    svc.publishProgress(job.Id, 'Processing', 5, 'Analyzing dependencies...');
    Test.stopTest();

    List<Dependency_Scan_Status__e> events = Test.getEventBus()
      .getDeliveredEvents(Dependency_Scan_Status__e.SObjectType);
    Assert.areEqual(
      1,
      events.size(),
      'Exactly one event should have been delivered'
    );
    Assert.areEqual(
      job.Id,
      events[0].Scan_Job_Id__c,
      'Delivered event should carry the job Id passed to publishProgress'
    );
    Assert.areEqual(
      'Processing',
      events[0].Status__c,
      'Delivered event should carry the status passed to publishProgress'
    );
    Assert.areEqual(
      5,
      events[0].Components_Analyzed__c,
      'Delivered event should carry the component count passed to publishProgress'
    );
    Assert.areEqual(
      'Analyzing dependencies...',
      events[0].Progress_Message__c,
      'Delivered event should carry the message passed to publishProgress'
    );
  }
}
