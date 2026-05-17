/**
 * ScanSummaryQueueable
 *
 * Lightweight one-shot Queueable enqueued by ResultSerializerQueueable after the
 * job transitions to Completed. Reads Result_Summary__c, builds a plain-English
 * Scan_Summary_Text__c string, and updates the job record.
 *
 * Offloaded from ResultSerializerQueueable so string templating on a large JSON
 * payload does not compete with the serializer's heap/CPU budget.
 *
 * Ref: ISP-6072
 */
public without sharing class ScanSummaryQueueable implements Queueable {

    private final String jobId;

    public ScanSummaryQueueable(String jobId) {
        this.jobId = jobId;
    }

    public void execute(QueueableContext ctx) {
        try {
            List<Metadata_Scan_Job__c> jobs = [
                SELECT Id, Result_Summary__c, Components_Analyzed__c, Target_API_Name__c
                FROM Metadata_Scan_Job__c
                WHERE Id = :jobId
                LIMIT 1
            ];
            if (jobs.isEmpty()) { return; }
            Metadata_Scan_Job__c job = jobs[0];

            if (String.isBlank(job.Result_Summary__c)) { return; }

            job.Scan_Summary_Text__c = buildSummary(job);
            update job;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'ScanSummaryQueueable: failed to generate summary for job '
                + jobId + ' - ' + e.getMessage());
        }
    }

    private String buildSummary(Metadata_Scan_Job__c job) {
        Integer total = job.Components_Analyzed__c != null
            ? (Integer) job.Components_Analyzed__c : 0;

        Map<String, Object> counts;
        try {
            counts = (Map<String, Object>) JSON.deserializeUntyped(job.Result_Summary__c);
        } catch (Exception e) {
            return 'This scan found ' + total + ' dependenc' + (total == 1 ? 'y' : 'ies') + '.';
        }

        List<String> parts = new List<String>();
        for (String key : counts.keySet()) {
            if (key == 'v') { continue; }
            Object val = counts.get(key);
            if (val == null) { continue; }
            Integer cnt = val instanceof Integer ? (Integer) val : Integer.valueOf(String.valueOf(val));
            if (cnt != null && cnt > 0) {
                parts.add(cnt + ' ' + humanizePlural(key, cnt));
            }
        }

        String base = 'This scan found ' + total + ' dependenc' + (total == 1 ? 'y' : 'ies');
        if (parts.isEmpty()) { return base + '.'; }

        if (parts.size() > 5) {
            parts = parts.subList(0, 5);
            parts.add('and more');
        }
        return base + ': ' + String.join(parts, ', ') + '.';
    }

    private String humanize(String metadataType) {
        if (metadataType == 'ApexClass')      return 'Apex class';
        if (metadataType == 'ApexTrigger')    return 'Apex trigger';
        if (metadataType == 'Flow')           return 'Flow';
        if (metadataType == 'CustomField')    return 'custom field';
        if (metadataType == 'ValidationRule') return 'validation rule';
        if (metadataType == 'WorkflowRule')   return 'workflow rule';
        if (metadataType == 'Report')         return 'report';
        return metadataType;
    }

    private String humanizePlural(String metadataType, Integer cnt) {
        String singular = humanize(metadataType);
        if (cnt == 1) {
            return singular;
        }
        if (metadataType == 'ApexClass') {
            return 'Apex classes';
        }
        return singular + 's';
    }
}
