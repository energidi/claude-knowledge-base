/**
 * SupplementalResult
 *
 * Return type for IDependencyTypeHandler.findSupplemental().
 * Encapsulates both the discovered supplemental dependency nodes and any diagnostic
 * error messages encountered during the handler scan.
 *
 * Errors are accumulated in-memory rather than persisted via DML inside the handler.
 * This removes unbulkified read-then-write DML from handler catch blocks and ensures
 * errors survive Queueable transaction rollbacks. DependencyQueueable performs a single
 * bulk update to Error_Status_Message__c after all handlers have completed.
 *
 * Ref: ISP-6072
 */
public class SupplementalResult {

    // Length of the truncation notice appended when the log reaches capacity.
    // '\n[TRUNCATED: MAX LOG SIZE REACHED]' = 34 chars.
    // The floor in appendErrorsSafe adds 6 chars of margin above this value.
    private static final Integer TRUNCATION_NOTICE_LENGTH = 34;

    /** Supplemental Metadata_Dependency__c records ready for upsert by the caller. */
    public List<Metadata_Dependency__c> nodes  { get; private set; }

    /** Diagnostic error strings to be appended to Error_Status_Message__c by the caller. */
    public List<String>                 errors { get; private set; }

    public SupplementalResult() {
        this.nodes  = new List<Metadata_Dependency__c>();
        this.errors = new List<String>();
    }

    public void addNode(Metadata_Dependency__c node) {
        nodes.add(node);
    }

    public void addNodes(List<Metadata_Dependency__c> nodesToAdd) {
        if (nodesToAdd != null) {
            nodes.addAll(nodesToAdd);
        }
    }

    /**
     * Adds a timestamped diagnostic error string. The caller appends these to
     * Metadata_Scan_Job__c.Error_Status_Message__c in a single DML update.
     */
    public void addError(String message) {
        errors.add('[' + System.now().format() + '] [Supplemental] ' + message);
    }

    public Boolean hasErrors() {
        return !errors.isEmpty();
    }

    /**
     * Appends all accumulated error strings to an existing log string, guarding against
     * Metadata_Scan_Job__c.Error_Status_Message__c overflow (Long Text 131,072 char limit).
     *
     * When the combined length would exceed the safe threshold, a single truncation notice
     * is appended and no further errors are written - avoiding a STRING_TOO_LONG DmlException
     * that would crash the Queueable near the end of a long scan.
     *
     * @param existing      Current value of Error_Status_Message__c (may be null)
     * @param maxLength     Field length ceiling (default: 131072)
     * @param safeThreshold Characters to reserve for the truncation notice (default: 200)
     * @return              Updated log string, safe to assign to Error_Status_Message__c
     */
    public String appendErrorsSafe(String existing, Integer maxLength, Integer safeThreshold) {
        if (errors.isEmpty()) {
            return existing;
        }
        // Use List<String> + String.join() instead of += in a loop.
        // Apex strings are immutable: each += allocates a new string and abandons the old one,
        // producing O(N^2) heap consumption if the error list is large. List + join is O(N).
        // Floor: safeThreshold must be at least TRUNCATION_NOTICE_LENGTH + 6 so that appending
        // the notice itself never overflows maxLength (the +6 is a safety margin above the exact
        // 34-char notice length, guarding against off-by-one if the notice text ever changes).
        Integer safeLimit = maxLength - Math.max(safeThreshold, TRUNCATION_NOTICE_LENGTH + 6);
        List<String> parts = new List<String>();
        Boolean truncated  = false;

        // Guard: existing log may already exceed maxLength (possible after many prior Queueable
        // appends or a very long stack trace). Truncate it first so appending the notice does not
        // produce a string longer than maxLength, which would cause STRING_TOO_LONG on DML update.
        String safeExisting;
        if (String.isNotBlank(existing)) {
            safeExisting = existing.length() > safeLimit
                ? existing.substring(0, safeLimit) + '\n[PRE-TRUNCATED]'
                : existing;
        } else {
            safeExisting = '';
        }
        parts.add(safeExisting);
        Integer currentLen = safeExisting.length();

        // appended tracks base messages written during THIS call so that duplicate strings
        // within the same errors list are also deduplicated, not just duplicates against
        // the pre-existing log. Without this, 20 identical notices emitted within one
        // Queueable execution all pass the safeExisting.contains() check (the snapshot
        // never updates) and are all written to parts.
        Set<String> appended = new Set<String>();

        for (String msg : errors) {
            // Dedup: strip the timestamp prefix and compare the base message against both
            // the pre-existing log AND the messages already appended in this call.
            // Cross-execution dedup (safeExisting): the same notice emitted by every chain
            // execution is deduplicated against the persisted field value.
            // Intra-execution dedup (appended Set): multiple identical notices emitted within
            // one execution (e.g. one per CustomField node in a large batch) are deduplicated
            // before they reach the string-join step.
            String baseMsg = msg.substringAfter('[Supplemental] ');
            if (String.isNotBlank(baseMsg)) {
                if ((String.isNotBlank(safeExisting) && safeExisting.contains(baseMsg))
                    || appended.contains(baseMsg)) {
                    continue;
                }
            }
            String line = '\n' + msg;
            if (currentLen + line.length() > safeLimit) {
                truncated = true;
                break;
            }
            parts.add(line);
            currentLen += line.length();
            if (String.isNotBlank(baseMsg)) {
                appended.add(baseMsg);
            }
        }
        if (truncated) {
            parts.add('\n[TRUNCATED: MAX LOG SIZE REACHED]');
        }
        return String.join(parts, '');
    }
}
