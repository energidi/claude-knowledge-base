public class SecScanPostInstallHandler implements InstallHandler {

    private static final String JOB_NAME = 'SecScan Nightly Cleanup';
    private static final String CRON_EXPR = '0 0 2 * * ?'; // Daily at 02:00

    public void onInstall(InstallContext ctx) {
        try {
            // Abort any existing job first (handles upgrade - prevents duplicate scheduled jobs)
            abortExistingJob();
            System.schedule(JOB_NAME, CRON_EXPR, new SecScanOrphanCleanupSchedulable());
        } catch (Exception e) {
            // Cannot throw from InstallHandler - a thrown exception rolls back the install.
            // Silent failure is logged to ErrorDetails__c on the first scan run instead.
            // Admin should check Setup > Scheduled Jobs after install.
        }
    }

    private void abortExistingJob() {
        List<CronTrigger> existingJobs = [
            SELECT Id
            FROM CronTrigger
            WHERE CronJobDetail.Name = :JOB_NAME
            LIMIT 1
        ];
        if (!existingJobs.isEmpty()) {
            System.abortJob(existingJobs[0].Id);
        }
    }
}
