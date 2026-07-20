/**
 * IScanNotificationService
 *
 * Interface for scan progress and completion notifications.
 * Abstracts Platform Event publishing and Custom Notification dispatch
 * to enable testability via mock injection.
 *
 * Implementations: DependencyNotificationService
 * Consumers: DependencyQueueable, ScanResultFileQueueable
 *
 *
 */
public interface IScanNotificationService {
  /**
   * Called from DependencyQueueable.execute() BEFORE Database.setSavepoint().
   * Checks the org daily Platform Event allocation and, if >80% consumed, queues
   * the CMDT deployment that sets Is_Platform_Events_Disabled__c = true.
   * Must be DML-free: runs before the engine's Tooling API callouts, and any DML
   * before a callout triggers "uncommitted work pending".
   *
   * @param jobId ID of the Metadata_Scan_Job__c record being processed
   */
  void checkAndSuppressIfNeeded(String jobId);

  /**
   * Publishes a Dependency_Scan_Status__e Platform Event for the given job.
   * Called once per Queueable execution - not per inner batch loop iteration.
   * Suppressed automatically when the org has consumed >80% of its daily
   * Platform Event delivery limit; falls back to polling in that case.
   *
   * @param jobId             ID of the Metadata_Scan_Job__c record
   * @param status            Current Status__c value (e.g. 'Processing', 'Completed')
   * @param componentsAnalyzed Running count of components found so far
   * @param message           Human-readable status message for the progress LWC
   */
  void publishProgress(
    String jobId,
    String status,
    Integer componentsAnalyzed,
    String message
  );

  /**
   * Sends a Custom Notification (bell icon) and email to the user who initiated
   * the scan when the job transitions to Completed.
   * Called by ScanResultFileQueueable after the Completed transition.
   *
   * @param jobId     ID of the completed Metadata_Scan_Job__c record
   * @param userId    ID of the user to notify (the job owner)
   */
  void sendCompletion(String jobId, String userId);
}
