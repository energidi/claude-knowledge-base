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
        List<String> parts   = new List<String>();
        Integer safeLimit    = maxLength - safeThreshold;
        Integer currentLen   = existing != null ? existing.length() : 0;
        Boolean truncated    = false;

        if (String.isNotBlank(existing)) {
            parts.add(existing);
        }
        for (String msg : errors) {
            String line = '\n' + msg;
            if (currentLen + line.length() > safeLimit) {
                truncated = true;
                break;
            }
            parts.add(line);
            currentLen += line.length();
        }
        if (truncated) {
            parts.add('\n[TRUNCATED: MAX LOG SIZE REACHED]');
        }
        return String.join(parts, '');
    }
}
