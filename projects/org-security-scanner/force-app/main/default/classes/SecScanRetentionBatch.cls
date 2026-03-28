public without sharing class SecScanRetentionBatch implements Database.Batchable<SObject> {

    private Integer maxScanRuns;

    public SecScanRetentionBatch(Integer maxScanRuns) {
        this.maxScanRuns = maxScanRuns;
    }

    /**
     * Two-step pattern (SOQL subquery with NOT IN + ORDER BY + LIMIT is not supported):
     * Step 1: query the N most recent Completed runs to keep.
     * Step 2: return a QueryLocator for all runs to delete:
     *   - Completed runs NOT in the keep-set
     *   - Orphaned Running/Cancelled runs older than 24h
     */
    public Database.QueryLocator start(Database.BatchableContext ctx) {
        // Step 1: build the keep set
        List<SecurityScanRun__c> recent = [
            SELECT Id
            FROM SecurityScanRun__c
            WHERE Status__c = 'Completed'
            ORDER BY CompletedAt__c DESC
            NULLS LAST
            LIMIT :maxScanRuns
        ];
        Set<Id> keepIds = new Map<Id, SecurityScanRun__c>(recent).keySet();

        // Orphan cutoff: runs stuck in Running/Cancelled for more than 24h
        Datetime cutoff = Datetime.now().addHours(-SecScanConstants.ORPHAN_CUTOFF_HOURS);

        // Step 2: QueryLocator combining both cleanup concerns
        return Database.getQueryLocator([
            SELECT Id
            FROM SecurityScanRun__c
            WHERE (Status__c = 'Completed' AND Id NOT IN :keepIds)
               OR (Status__c IN ('Running', 'Pending') AND StartedAt__c < :cutoff)
        ]);
    }

    /**
     * scope=1: one SecurityScanRun__c per execute() transaction.
     * Explicit child delete first prevents trigger overhead from accumulating:
     * at scope=200, cascade-delete triggers on 200 runs x 2,500+ findings in one transaction
     * risks exhausting SOQL/CPU limits in trigger code.
     */
    public void execute(Database.BatchableContext ctx, List<SecurityScanRun__c> scope) {
        Set<Id> runIds = new Map<Id, SecurityScanRun__c>(scope).keySet();
        delete [SELECT Id FROM SecurityFinding__c WHERE ScanRun__c IN :runIds];
        delete scope;
    }

    public void finish(Database.BatchableContext ctx) {
        // No post-processing needed
    }
}
