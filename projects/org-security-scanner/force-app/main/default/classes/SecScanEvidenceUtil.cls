public class SecScanEvidenceUtil {

    // Scrub patterns: keyword -> replacement. Case-insensitive at call site.
    // Public for testability - auditable list of all masked patterns.
    public static final Map<String, String> SCRUB_PATTERNS = new Map<String, String>{
        '(?i)(password\\s*=\\s*)\\S+'       => '$1***',
        '(?i)(passwd\\s*=\\s*)\\S+'         => '$1***',
        '(?i)(pwd\\s*=\\s*)\\S+'            => '$1***',
        '(?i)(secret\\s*=\\s*)\\S+'         => '$1***',
        '(?i)(api_key\\s*=\\s*)\\S+'        => '$1***',
        '(?i)(client_secret\\s*=\\s*)\\S+'  => '$1***',
        '(?i)(Bearer\\s+)\\S+'              => '$1***',
        '(?i)(token\\s*=\\s*)\\S+'          => '$1***',
        '(?i)(credentials\\s*=\\s*)\\S+'    => '$1***'
    };

    /**
     * Scrub secrets from evidence then apply match-centered truncation.
     * Operation order: SCRUB FIRST, then TRUNCATE.
     * If matchOffset is known (regex-based findings), centers the context window on the match.
     * If matchOffset is -1 (no match offset known), takes the first EVIDENCE_MAX_LENGTH chars.
     *
     * @param rawInput    Full raw string before any processing
     * @param matchOffset Character offset of the match in rawInput, or -1 if not applicable
     * @return            Scrubbed, match-centered string capped at EVIDENCE_MAX_LENGTH chars
     */
    public static String process(String rawInput, Integer matchOffset) {
        if (String.isBlank(rawInput)) {
            return '';
        }

        // Step 1: scrub on full input - must run before any truncation
        String scrubbed = scrub(rawInput);

        // Step 2: match-centered extraction
        return extractCentered(scrubbed, matchOffset);
    }

    /**
     * Convenience overload - no match offset (takes first EVIDENCE_MAX_LENGTH chars after scrub).
     */
    public static String process(String rawInput) {
        return process(rawInput, -1);
    }

    // --- private helpers ---

    @TestVisible
    private static String scrub(String input) {
        String result = input;
        for (String pattern : SCRUB_PATTERNS.keySet()) {
            result = result.replaceAll(pattern, SCRUB_PATTERNS.get(pattern));
        }
        return result;
    }

    @TestVisible
    private static String extractCentered(String input, Integer matchOffset) {
        if (matchOffset < 0 || matchOffset >= input.length()) {
            // No match offset - take first MAX chars
            return input.length() <= SecScanConstants.EVIDENCE_MAX_LENGTH
                ? input
                : input.substring(0, SecScanConstants.EVIDENCE_MAX_LENGTH);
        }

        Integer windowHalf = SecScanConstants.EVIDENCE_CONTEXT_WINDOW;
        Integer start = Math.max(0, matchOffset - windowHalf);
        Integer endIdx = Math.min(input.length(), matchOffset + windowHalf);

        String extracted = input.substring(start, endIdx);

        // Hard cap
        if (extracted.length() > SecScanConstants.EVIDENCE_MAX_LENGTH) {
            extracted = extracted.substring(0, SecScanConstants.EVIDENCE_MAX_LENGTH);
        }
        return extracted;
    }
}
