/**
 * SupplementalScanResult
 *
 * Return type for IDependencyTypeHandler.findSupplemental().
 * Encapsulates both the discovered supplemental dependency nodes and any diagnostic
 * error messages encountered during the handler scan.
 *
 * Errors are accumulated in-memory rather than persisted via DML inside the handler.
 * This removes unbulkified read-then-write DML from handler catch blocks and ensures
 * errors survive Queueable transaction rollbacks. DependencyQueueable performs a single
 * bulk update to Scan_Diagnostic_Log__c after all handlers have completed.
 *
 *
 */
public class SupplementalScanResult {
  // Length of the truncation notice appended when the log reaches capacity.
  // '\n[TRUNCATED: MAX LOG SIZE REACHED]' = 34 chars.
  // The floor in appendErrorsSafe adds 6 chars of margin above this value.
  private static final Integer TRUNCATION_NOTICE_LENGTH = 34;

  /** Supplemental Metadata_Dependency__c records ready for upsert by the caller. */
  public List<Metadata_Dependency__c> nodes { get; private set; }

  /** Diagnostic error strings to be appended to Scan_Diagnostic_Log__c by the caller. */
  public List<String> errors { get; private set; }

  public SupplementalScanResult() {
    this.nodes = new List<Metadata_Dependency__c>();
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
   * Metadata_Scan_Job__c.Scan_Diagnostic_Log__c in a single DML update.
   */
  public void addError(String message) {
    errors.add(
      '[' +
        System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') +
        '] [Supplemental] ' +
        message
    );
  }

  public Boolean hasErrors() {
    return !errors.isEmpty();
  }

  /**
   * Static 2-argument variant of the log-safe append. Appends a single notice string
   * to an existing Scan_Diagnostic_Log__c value, truncating the NOTICE (not the existing
   * log) so that the combined length never exceeds 32,768 characters.
   *
   * This is the ONLY permitted write path for engine-level log entries that are NOT
   * produced by supplemental handlers (e.g. PE suppression notices, truncation warnings,
   * system diagnostics). All direct string operations on Scan_Diagnostic_Log__c are
   * forbidden - call this method instead.
   *
   * Behavior: if the existing log leaves no budget for the notice, the existing log is
   * returned unchanged (unlike .right() which would discard the oldest entries).
   *
   * @param existing  Current value of Scan_Diagnostic_Log__c (may be null/blank)
   * @param notice    The notice string to append
   * @return          Updated log string, safe to assign to Scan_Diagnostic_Log__c
   */
  public static String appendNoticeSafe(String existing, String notice) {
    if (String.isBlank(notice)) {
      return existing;
    }
    Integer existingLen = String.isBlank(existing) ? 0 : existing.length();
    Integer separator = String.isBlank(existing) ? 0 : 1; // '\n'
    Integer budget = 32768 - existingLen - separator;
    if (budget <= 0) {
      return existing;
    }
    String safeNotice = notice.length() <= budget
      ? notice
      : notice.left(budget);
    return String.isBlank(existing)
      ? safeNotice
      : (existing + '\n' + safeNotice);
  }

  /**
   * Appends all accumulated error strings to an existing log string, guarding against
   * Metadata_Scan_Job__c.Scan_Diagnostic_Log__c overflow (Long Text 32,768 char limit).
   *
   * When the combined length would exceed the safe threshold, a single truncation notice
   * is appended and no further errors are written - avoiding a STRING_TOO_LONG DmlException
   * that would crash the Queueable near the end of a long scan.
   *
   * @param existing      Current value of Scan_Diagnostic_Log__c (may be null)
   * @param maxLength     Field length ceiling (default: 32768 — matches Scan_Diagnostic_Log__c Long Text 32768 field limit)
   * @param safeThreshold Characters to reserve for the truncation notice (default: 200)
   * @return              Updated log string, safe to assign to Scan_Diagnostic_Log__c
   */
  public String appendErrorsSafe(
    String existing,
    Integer maxLength,
    Integer safeThreshold
  ) {
    if (errors.isEmpty()) {
      return existing;
    }
    // Use List<String> + String.join() instead of += in a loop.
    // Apex strings are immutable: each += allocates a new string and abandons the old one,
    // producing O(N^2) heap consumption if the error list is large. List + join is O(N).
    // Floor: safeThreshold must be at least TRUNCATION_NOTICE_LENGTH + 6 so that appending
    // the notice itself never overflows maxLength (the +6 is a safety margin above the exact
    // 34-char notice length, guarding against off-by-one if the notice text ever changes).
    // M1: null guard - callers that omit safeThreshold (pass null) get the documented default.
    if (safeThreshold == null) {
      safeThreshold = 200;
    }
    // N1 (carried forward): null guard for maxLength. safeThreshold is guarded above;
    // maxLength must also be defaulted to prevent NPE on the subtraction below.
    if (maxLength == null) {
      maxLength = 32768;
    }
    Integer safeLimit =
      maxLength - Math.max(safeThreshold, TRUNCATION_NOTICE_LENGTH + 6);
    // F: defensive floor - prevents StringException in substring() if a caller passes
    // an unusually small maxLength (< 54, less than the combined truncation notice length).
    safeLimit = Math.max(0, safeLimit);
    List<String> parts = new List<String>();
    Boolean truncated = false;

    // Guard: existing log may already exceed maxLength (possible after many prior Queueable
    // appends or a very long stack trace). Truncate it first so appending the notice does not
    // produce a string longer than maxLength, which would cause STRING_TOO_LONG on DML update.
    String safeExisting;
    Integer currentLen;
    if (String.isNotBlank(existing)) {
      if (existing.length() > safeLimit) {
        // E: the existing log has already consumed all available capacity.
        // Setting currentLen = safeLimit (M5) still causes every new message to be
        // rejected immediately (line.length() > 0 always triggers the ceiling check),
        // producing [PRE-TRUNCATED] + [TRUNCATED] with nothing between them.
        // Correct behaviour: the log is at capacity - return immediately. No new
        // messages can fit and there is no point entering the loop.
        return existing.substring(0, safeLimit) + '\n[PRE-TRUNCATED]';
      } else {
        safeExisting = existing;
        parts.add(safeExisting);
        currentLen = safeExisting.length();
      }
    } else {
      // Do not add an empty string to parts: String.join would produce a leading '\n'
      // before the first message because each appended line is prefixed with '\n'.
      safeExisting = '';
      currentLen = 0;
    }

    // DEDUP: pre-process safeExisting into a Set<String> of base messages ONCE before
    // the error loop. The prior safeExisting.contains(baseMsg) call was O(existing_length)
    // per error message. At 500 unique errors x 131K-char log that is ~65M char comparisons,
    // a real CPU timeout risk. Splitting into lines and extracting base messages is O(M) once;
    // subsequent lookups are O(1).
    Set<String> existingBaseMsgs = new Set<String>();
    if (String.isNotBlank(safeExisting)) {
      for (String splitLine : safeExisting.split('\n')) {
        String b = splitLine.substringAfter('[Supplemental] ');
        if (String.isNotBlank(b)) {
          existingBaseMsgs.add(b);
        }
      }
    }

    // appended tracks base messages written during THIS call so that duplicate strings
    // within the same errors list are also deduplicated, not just duplicates against
    // the pre-existing log. Without this, 20 identical notices emitted within one
    // Queueable execution all pass the cross-execution check (the snapshot never updates)
    // and are all written to parts.
    Set<String> appended = new Set<String>();

    for (String msg : errors) {
      // Dedup: strip the timestamp prefix and compare the base message against both
      // the pre-existing log (O(1) Set lookup) AND the messages already appended in
      // this call (O(1) Set lookup).
      String baseMsg = msg.substringAfter('[Supplemental] ');
      if (String.isNotBlank(baseMsg)) {
        if (existingBaseMsgs.contains(baseMsg) || appended.contains(baseMsg)) {
          continue;
        }
      }
      // Prefix '\n' only when there is already content (existing log or a prior appended
      // line). When the log is empty and this is the first message, no leading newline.
      String line = (currentLen > 0) ? '\n' + msg : msg;
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
