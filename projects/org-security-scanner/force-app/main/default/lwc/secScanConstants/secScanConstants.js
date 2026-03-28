// Single source of truth for all string constants used across LWC components.
// Import: import { SEVERITY, STATUS } from 'c/secScanConstants';

export const SEVERITY = {
    CRITICAL: 'Critical',
    HIGH: 'High',
    MEDIUM: 'Medium',
    LOW: 'Low',
    INFO: 'Informational'
};

export const STATUS = {
    OPEN: 'Open',
    ACKNOWLEDGED: 'Acknowledged',
    REMEDIATED: 'Remediated',
    RISK_ACCEPTED: 'Risk Accepted',
    FALSE_POSITIVE: 'False Positive'
};

export const CATEGORY_CODE = {
    UA: 'UA',
    GU: 'GU',
    SRA: 'SRA',
    SA: 'SA',
    CAI: 'CAI',
    AA: 'AA',
    LA: 'LA',
    AGA: 'AGA',
    MS: 'MS',
    FUE: 'FUE',
    CE: 'CE',
    MON: 'MON',
    HCB: 'HCB'
};

export const CATEGORY_LABELS = {
    UA: 'User & Access',
    GU: 'Guest User / Experience Cloud',
    SRA: 'Sharing & Record Access',
    SA: 'Session & Auth',
    CAI: 'Connected Apps & Integrations',
    AA: 'Apex & Automation',
    LA: 'LWC & Aura',
    AGA: 'Agentforce & GenAI',
    MS: 'Metadata & Secrets',
    FUE: 'File Upload & Execution',
    CE: 'Certificates & Encryption',
    MON: 'Monitoring',
    HCB: 'Health Check Baseline'
};

export const FINDING_TYPE = {
    AUTOMATED: 'Automated',
    RECOMMENDATION: 'Recommendation'
};

export const SCAN_STATUS = {
    PENDING: 'Pending',
    RUNNING: 'Running',
    COMPLETED: 'Completed',
    FAILED: 'Failed',
    CANCELLED: 'Cancelled'
};

// Grade bands - intentionally hardcoded (product policy, not admin-configurable)
export const SCORE_GRADE = [
    { min: 90, label: 'A' },
    { min: 75, label: 'B' },
    { min: 60, label: 'C' },
    { min: 45, label: 'D' },
    { min: 0,  label: 'F' }
];

export const HEATMAP = {
    WARN_THRESHOLD: 1,   // 1-9 findings = amber
    FAIL_THRESHOLD: 10   // 10+ findings = red
};

export const PAGE_SIZE = 100;

export const POLL_INTERVAL_INITIAL_MS = 2000;
export const POLL_INTERVAL_MEDIUM_MS  = 5000;
export const POLL_INTERVAL_SLOW_MS    = 10000;
export const POLL_MEDIUM_CUTOFF_MS    = 20000;
export const POLL_SLOW_CUTOFF_MS      = 60000;

export const SCAN_COOLDOWN_MS = 300000; // 5 minutes

// Allowed status transitions (mirrors server-side ALLOWED_TRANSITIONS map)
export const ALLOWED_TRANSITIONS = {
    'Open':          ['Acknowledged', 'Remediated', 'Risk Accepted', 'False Positive'],
    'Acknowledged':  ['Remediated', 'Risk Accepted', 'False Positive'],
    'Remediated':    ['Open'],
    'Risk Accepted': ['Open'],
    'False Positive':['Open']
};

// Statuses that require a note before saving
export const NOTE_REQUIRED_STATUSES = new Set(['Risk Accepted', 'False Positive']);

// Statuses excluded from live score (mirrors Apex SCORE_EXCLUDED_STATUSES)
export const SCORE_EXCLUDED_STATUSES = new Set(['Remediated', 'False Positive']);

/**
 * Compute a security grade from a numeric score using SCORE_GRADE bands.
 * @param {number} score - 0-100
 * @returns {string} - 'A', 'B', 'C', 'D', or 'F'
 */
export function computeGrade(score) {
    for (const band of SCORE_GRADE) {
        if (score >= band.min) return band.label;
    }
    return 'F';
}

/**
 * Format a datetime string for display.
 * @param {string} isoString
 * @returns {string}
 */
export function formatDateTime(isoString) {
    if (!isoString) return '-';
    try {
        return new Intl.DateTimeFormat(undefined, {
            dateStyle: 'medium',
            timeStyle: 'short'
        }).format(new Date(isoString));
    } catch {
        return isoString;
    }
}

/**
 * Return the CSS color variable name for a given severity string.
 * @param {string} severity
 * @returns {string} - CSS custom property reference
 */
export function severityColorVar(severity) {
    const map = {
        'Critical':      'var(--color-critical)',
        'High':          'var(--color-high)',
        'Medium':        'var(--color-medium)',
        'Low':           'var(--color-low)',
        'Informational': 'var(--color-info)'
    };
    return map[severity] || 'var(--color-info)';
}

/**
 * Return the SLDS icon name for a given severity string.
 * @param {string} severity
 * @returns {string}
 */
export function severityIcon(severity) {
    const map = {
        'Critical':      'utility:error',
        'High':          'utility:warning',
        'Medium':        'utility:info',
        'Low':           'utility:low_priority',
        'Informational': 'utility:info_alt'
    };
    return map[severity] || 'utility:info_alt';
}
