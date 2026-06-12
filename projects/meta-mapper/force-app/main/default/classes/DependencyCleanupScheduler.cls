/**
 * DependencyCleanupScheduler
 *
 * Schedulable entry point that fires DependencyCleanupBatch nightly at 02:00.
 * Schedule this class once via Setup > Apex Scheduler or anonymous Apex after install.
 * Does not run cleanup logic directly - delegates entirely to DependencyCleanupBatch.
 * Must NOT be invoked from DependencyQueueable or any other async Apex context.
 *
 *
 */
public without sharing class DependencyCleanupScheduler implements Schedulable {

    public void execute(SchedulableContext ctx) {
        Database.executeBatch(new DependencyCleanupBatch(), 10);
    }
}
