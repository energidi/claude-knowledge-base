public class SecScanPostUninstallHandler implements UninstallHandler {

    private static final String JOB_NAME = 'SecScan Nightly Cleanup';

    public void onUninstall(UninstallContext ctx) {
        try {
            List<CronTrigger> existingJobs = [
                SELECT Id
                FROM CronTrigger
                WHERE CronJobDetail.Name = :JOB_NAME
                LIMIT 1
            ];
            if (!existingJobs.isEmpty()) {
                System.abortJob(existingJobs[0].Id);
            }
        } catch (Exception e) {
            // Silent on failure - job may already be absent
        }
    }
}
