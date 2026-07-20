/**
 * ScanSummaryQueueable
 *
 * Lightweight one-shot Queueable enqueued by ScanResultFileQueueable after the
 * job transitions to Completed. Reads Component_Type_Counts__c, builds a plain-English
 * Scan_Summary_Text__c string, and updates the job record.
 *
 * Offloaded from ScanResultFileQueueable so string templating on a large JSON
 * payload does not compete with the serializer's heap/CPU budget.
 *
 *
 */
public without sharing class ScanSummaryQueueable implements Queueable {
  private final String jobId;

  public ScanSummaryQueueable(String jobId) {
    this.jobId = jobId;
  }

  public void execute(QueueableContext ctx) {
    // Declared outside try so the catch block can reuse the loaded record
    // without a second SOQL query when the failure occurred after the SELECT.
    Metadata_Scan_Job__c job = null;
    try {
      job = new MetadataScanJobSelector().getByIdForSummary(jobId);
      if (job == null) {
        return;
      }

      // Required guard (per CLAUDE.md): if ScanResultFileQueueable rolled back
      // after this Queueable was enqueued (e.g. LimitException in post-completion
      // tasks caused the savepoint to roll back), the job ends in Failed state.
      // Writing a summary to a Failed job would be misleading.
      if (job.Status__c != 'Completed') {
        System.debug(
          LoggingLevel.INFO,
          'ScanSummaryQueueable: skipping summary for job ' +
            jobId +
            ' - Status is ' +
            job.Status__c +
            ', expected Completed.'
        );
        return;
      }

      if (String.isBlank(job.Component_Type_Counts__c)) {
        return;
      }

      job.Scan_Summary_Text__c = buildSummary(job);
      update job;
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'ScanSummaryQueueable: failed to generate summary for job ' +
          jobId +
          ' - ' +
          e.getMessage()
      );
      try {
        String warn =
          '[' +
          System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') +
          '] ' +
          'WARNING: Scan_Summary_Text__c was not populated - summary generation failed: ' +
          e.getMessage();
        if (job != null) {
          // Reuse the in-memory record; avoids a second SOQL query.
          // Clear any partial summary value that may have been set before the throw.
          job.Scan_Summary_Text__c = null;
          job.Scan_Diagnostic_Log__c = SupplementalScanResult.appendNoticeSafe(
            job.Scan_Diagnostic_Log__c,
            warn
          );
          update job;
        } else {
          // Initial SELECT failed; re-query is required to write the warning.
          Metadata_Scan_Job__c errJob = new MetadataScanJobSelector()
            .getByIdForLogAppend(jobId);
          if (errJob != null) {
            errJob.Scan_Diagnostic_Log__c = SupplementalScanResult.appendNoticeSafe(
              errJob.Scan_Diagnostic_Log__c,
              warn
            );
            update errJob;
          }
        }
      } catch (Exception updateEx) {
        System.debug(
          LoggingLevel.WARN,
          'ScanSummaryQueueable: job error update also failed - ' +
          updateEx.getMessage()
        );
      }
    }
  }

  private String buildSummary(Metadata_Scan_Job__c job) {
    Integer total = job.Components_Analyzed__c != null
      ? ((Decimal) job.Components_Analyzed__c).intValue()
      : 0;

    Map<String, Object> counts;
    try {
      counts = (Map<String, Object>) JSON.deserializeUntyped(
        job.Component_Type_Counts__c
      );
    } catch (Exception e) {
      return 'This scan found ' +
        total +
        ' dependenc' +
        (total == 1 ? 'y' : 'ies') +
        '.';
    }

    List<String> parts = new List<String>();
    List<Integer> partCounts = new List<Integer>();
    for (String key : counts.keySet()) {
      if (key == 'v') {
        continue;
      }
      Object val = counts.get(key);
      if (val == null) {
        continue;
      }
      // JSON.deserializeUntyped can return Integer, Long, or Decimal for numeric values
      // depending on the magnitude. A plain Integer.valueOf(String.valueOf(val)) throws
      // TypeException when val is "5.0" (Decimal). Handle all three numeric types.
      Integer cnt;
      if (val instanceof Integer) {
        cnt = (Integer) val;
      } else if (val instanceof Long) {
        cnt = ((Long) val).intValue();
      } else if (val instanceof Decimal) {
        cnt = ((Decimal) val).intValue();
      } else {
        try {
          cnt = Integer.valueOf(String.valueOf(val));
        } catch (TypeException te) {
          continue;
        }
      }
      if (cnt != null && cnt > 0) {
        parts.add(cnt + ' ' + humanizePlural(key, cnt));
        partCounts.add(cnt);
      }
    }

    String base =
      'This scan found ' +
      total +
      ' dependenc' +
      (total == 1 ? 'y' : 'ies');
    if (parts.isEmpty()) {
      return base + '.';
    }

    // Sort by count descending (selection sort) so the most significant types
    // are always retained when the list is truncated to 5 entries. Map.keySet()
    // iteration order is non-deterministic; without sorting, which types are
    // dropped is undefined and changes across executions.
    for (Integer i = 0; i < partCounts.size() - 1; i++) {
      Integer maxIdx = i;
      for (Integer j = i + 1; j < partCounts.size(); j++) {
        if (partCounts[j] > partCounts[maxIdx]) {
          maxIdx = j;
        }
      }
      if (maxIdx != i) {
        Integer tmpCnt = partCounts[i];
        partCounts[i] = partCounts[maxIdx];
        partCounts[maxIdx] = tmpCnt;
        String tmpPart = parts[i];
        parts[i] = parts[maxIdx];
        parts[maxIdx] = tmpPart;
      }
    }

    // Truncate to top 5 using an explicit copy. subList() returns a view in some
    // Apex runtime versions; calling add() on a view can throw UnsupportedOperationException.
    if (parts.size() > 5) {
      List<String> truncated = new List<String>();
      for (Integer i = 0; i < 5; i++) {
        truncated.add(parts[i]);
      }
      truncated.add('and more');
      parts = truncated;
    }
    return base + ': ' + String.join(parts, ', ') + '.';
  }

  private String humanize(String metadataType) {
    if (metadataType == 'ApexClass')
      return 'Apex class';
    if (metadataType == 'ApexTrigger')
      return 'Apex trigger';
    if (metadataType == 'Flow')
      return 'Flow';
    if (metadataType == 'CustomField')
      return 'custom field';
    if (metadataType == 'ValidationRule')
      return 'validation rule';
    if (metadataType == 'WorkflowRule')
      return 'workflow rule';
    if (metadataType == 'Report')
      return 'report';
    // Fallback: insert spaces before camelCase boundaries so unknown Tooling API type
    // names render readably. "CustomLabel" -> "Custom Label", "FieldSet" -> "Field Set".
    // Returning raw camelCase ("CustomLabel") as a user-facing label is confusing.
    return metadataType.replaceAll('(?<=[a-z])(?=[A-Z])', ' ');
  }

  private String humanizePlural(String metadataType, Integer cnt) {
    String singular = humanize(metadataType);
    if (cnt == 1) {
      return singular;
    }
    if (metadataType == 'ApexClass') {
      return 'Apex classes';
    }
    // Avoid triple-s (e.g. "Process" + "s" = "Processs") and other wrong plurals for
    // types that end in s, x, or z. English rule: add "es" for those endings.
    if (
      singular.endsWith('s') ||
      singular.endsWith('x') ||
      singular.endsWith('z')
    ) {
      return singular + 'es';
    }
    return singular + 's';
  }
}
