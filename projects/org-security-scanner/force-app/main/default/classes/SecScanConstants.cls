public class SecScanConstants {

    // Finding limits
    public static final Integer MAX_FINDINGS_PER_CATEGORY    = 9000;
    public static final Integer MAX_BULK_UPDATE_FINDINGS     = 5000;

    // Search / input
    public static final Integer MAX_SEARCH_TERM_LENGTH       = 100;

    // CSV export
    public static final Integer MAX_CSV_FINDINGS_BEFORE_TRUNCATE = 3000;
    public static final Integer CSV_FIELD_TRUNCATE_LENGTH    = 500;

    // Error accumulation
    public static final Integer MAX_ERROR_DETAILS_LENGTH     = 32000;

    // Evidence handling
    public static final Integer EVIDENCE_MAX_LENGTH          = 10000;
    public static final Integer EVIDENCE_CONTEXT_WINDOW      = 5000;

    // Heap guard
    public static final Integer HEAP_GUARD_THRESHOLD_PCT     = 70;

    // Retention defaults (used when CMT not yet deployed)
    public static final Integer DEFAULT_MAX_SCAN_RUNS        = 5;
    public static final Integer DEFAULT_SCORE_FLOOR          = 5;

    // Orphan cleanup cutoff
    public static final Integer ORPHAN_CUTOFF_HOURS          = 24;

    // Severity rank mapping (used by buildFinding in SecScanCategoryRunner)
    public static final Map<String, Integer> SEVERITY_RANK = new Map<String, Integer>{
        'Critical'      => 1,
        'High'          => 2,
        'Medium'        => 3,
        'Low'           => 4,
        'Informational' => 5
    };

    // Valid picklist values (used by buildFinding for normalization)
    public static final Set<String> VALID_SEVERITIES = new Set<String>{
        'Critical', 'High', 'Medium', 'Low', 'Informational'
    };

    public static final Set<String> VALID_FINDING_TYPES = new Set<String>{
        'Automated', 'Recommendation'
    };

    public static final Set<String> VALID_STATUSES = new Set<String>{
        'Open', 'Acknowledged', 'Remediated', 'Risk Accepted', 'False Positive'
    };

    public static final Set<String> SCORE_EXCLUDED_STATUSES = new Set<String>{
        'Remediated', 'False Positive'
    };

    // Scan terminal statuses
    public static final Set<String> TERMINAL_STATUSES = new Set<String>{
        'Completed', 'Failed', 'Cancelled'
    };

    // Category codes (no-comma rule - comma is delimiter in FailedCategories__c / CompletedCategories__c)
    public static final Set<String> VALID_CATEGORY_CODES = new Set<String>{
        'UA', 'GU', 'SRA', 'SA', 'CAI', 'AA', 'LA', 'AGA', 'MS', 'FUE', 'CE', 'MON', 'HCB'
    };
}
