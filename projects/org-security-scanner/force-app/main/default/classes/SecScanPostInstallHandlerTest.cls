@IsTest
private class SecScanPostInstallHandlerTest {

    @IsTest
    static void testFreshInstallSchedulesJob() {
        // Abort any pre-existing job with the same name
        for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'SecScan Nightly Cleanup']) {
            System.abortJob(ct.Id);
        }

        Test.startTest();
        Test.testInstall(new SecScanPostInstallHandler(), null, false);
        Test.stopTest();

        List<CronTrigger> jobs = [
            SELECT Id, State FROM CronTrigger WHERE CronJobDetail.Name = 'SecScan Nightly Cleanup'
        ];
        System.assertEquals(1, jobs.size(), 'Fresh install must schedule exactly one cleanup job');
    }

    @IsTest
    static void testUpgradeAbortsAndReschedulesJob() {
        // Simulate pre-existing scheduled job
        for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'SecScan Nightly Cleanup']) {
            System.abortJob(ct.Id);
        }
        System.schedule('SecScan Nightly Cleanup', '0 0 3 * * ?', new SecScanOrphanCleanupSchedulable());

        Test.startTest();
        Test.testInstall(new SecScanPostInstallHandler(), new Version(1, 0), true);
        Test.stopTest();

        List<CronTrigger> jobs = [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'SecScan Nightly Cleanup'
        ];
        System.assertEquals(1, jobs.size(), 'Upgrade must replace existing job - exactly 1 must remain');
    }

    @IsTest
    static void testIdempotentInstall() {
        for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'SecScan Nightly Cleanup']) {
            System.abortJob(ct.Id);
        }

        Test.startTest();
        Test.testInstall(new SecScanPostInstallHandler(), null, false);
        Test.testInstall(new SecScanPostInstallHandler(), new Version(1, 0), true);
        Test.stopTest();

        List<CronTrigger> jobs = [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'SecScan Nightly Cleanup'
        ];
        System.assertEquals(1, jobs.size(), 'Running install twice must not create duplicate jobs');
    }

    @IsTest
    static void testUninstallAbortsJob() {
        for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'SecScan Nightly Cleanup']) {
            System.abortJob(ct.Id);
        }
        System.schedule('SecScan Nightly Cleanup', '0 0 2 * * ?', new SecScanOrphanCleanupSchedulable());

        Test.startTest();
        Test.testUninstall(new SecScanPostUninstallHandler());
        Test.stopTest();

        List<CronTrigger> jobs = [
            SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'SecScan Nightly Cleanup'
        ];
        System.assertEquals(0, jobs.size(), 'Uninstall must abort the scheduled job');
    }

    @IsTest
    static void testUninstallSilentWhenJobAbsent() {
        // Ensure job doesn't exist, then uninstall - must not throw
        for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'SecScan Nightly Cleanup']) {
            System.abortJob(ct.Id);
        }

        Test.startTest();
        Boolean threw = false;
        try {
            Test.testUninstall(new SecScanPostUninstallHandler());
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(false, threw, 'Uninstall when job is absent must not throw');
    }
}
