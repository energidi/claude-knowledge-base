public without sharing class SecScanOrphanCleanupSchedulable implements Schedulable {

    public void execute(SchedulableContext ctx) {
        OrgSecurityScanner_Setting__mdt settings = OrgSecurityScanner_Setting__mdt.getInstance('Default');
        Integer maxRuns = (settings != null && settings.MaxScanRuns__c != null)
            ? (Integer) settings.MaxScanRuns__c
            : SecScanConstants.DEFAULT_MAX_SCAN_RUNS;
        Database.executeBatch(new SecScanRetentionBatch(maxRuns), 1);
    }
}
