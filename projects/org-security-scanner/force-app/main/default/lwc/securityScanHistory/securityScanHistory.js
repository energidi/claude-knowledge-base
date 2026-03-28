import { LightningElement, api } from 'lwc';

// Status -> SLDS badge variant mapping
const STATUS_VARIANT = {
    Completed : 'success',
    Running   : 'brand',
    Failed    : 'error',
    Cancelled : 'warning',
    Pending   : 'inverse'
};

// Severity keys in display order
const SEVERITY_KEYS = [
    { key: 'CriticalCount__c', label: 'C', cssClass: 'sev-badge sev-badge--critical' },
    { key: 'HighCount__c',     label: 'H', cssClass: 'sev-badge sev-badge--high'     },
    { key: 'MediumCount__c',   label: 'M', cssClass: 'sev-badge sev-badge--medium'   },
    { key: 'LowCount__c',      label: 'L', cssClass: 'sev-badge sev-badge--low'      },
    { key: 'InfoCount__c',     label: 'I', cssClass: 'sev-badge sev-badge--info'     }
];

const DATE_FORMAT_OPTIONS = {
    year   : 'numeric',
    month  : 'short',
    day    : 'numeric',
    hour   : '2-digit',
    minute : '2-digit'
};

export default class SecurityScanHistory extends LightningElement {
    @api scanRuns   = [];
    @api currentScanId;
    @api maxScanRuns;

    // ── Computed rows ─────────────────────────────────────────────────────────

    get historyRows() {
        if (!this.scanRuns || this.scanRuns.length === 0) return [];

        return this.scanRuns.map(run => {
            const isActive = run.Id === this.currentScanId;

            // Date: prefer CompletedAt__c, fall back to StartedAt__c
            const rawDate = run.CompletedAt__c || run.StartedAt__c;
            const formattedDate = rawDate
                ? new Date(rawDate).toLocaleString(undefined, DATE_FORMAT_OPTIONS)
                : '-';

            // Operator name
            const operator = run.StartedBy__r && run.StartedBy__r.Name
                ? run.StartedBy__r.Name
                : (run.StartedBy__c || '-');

            // Score + Grade: null-safe; never show 0 for a crashed/failed run
            const hasScore = run.Score__c != null;
            const scoreDisplay = hasScore ? String(Math.round(run.Score__c)) : '-';
            const gradeDisplay = hasScore && run.Grade__c ? run.Grade__c : '-';

            // Grade badge CSS class
            const gradeBadgeClass = hasScore && run.Grade__c
                ? `grade-badge grade-badge--${run.Grade__c.toLowerCase()}`
                : 'grade-badge grade-badge--none';

            // Severity pill list
            const severityPills = SEVERITY_KEYS.map(s => {
                const count = run[s.key];
                return {
                    key      : s.key,
                    label    : s.label,
                    cssClass : s.cssClass,
                    display  : (count != null && count > 0) ? String(count) : '-'
                };
            });

            // Status badge variant
            const statusVariant = STATUS_VARIANT[run.Status__c] || 'inverse';

            // Production / Sandbox badge
            const isProd = !!run.IsProductionScan__c;
            const envBadgeClass = isProd ? 'env-badge env-badge--prod' : 'env-badge env-badge--sandbox';
            const envLabel = isProd ? 'PROD' : 'SANDBOX';

            // Row CSS: highlight currently-viewed row with blue left border
            const rowClass = isActive
                ? 'history-row history-row--active'
                : 'history-row';

            return {
                id             : run.Id,
                isActive,
                rowClass,
                formattedDate,
                operator,
                scoreDisplay,
                gradeDisplay,
                gradeBadgeClass,
                statusVariant,
                statusLabel    : run.Status__c || 'Unknown',
                severityPills,
                envBadgeClass,
                envLabel
            };
        });
    }

    get isEmpty() {
        return !this.scanRuns || this.scanRuns.length === 0;
    }

    get hasRows() {
        return !this.isEmpty;
    }

    // ── Retention notice ──────────────────────────────────────────────────────

    get retentionNotice() {
        const current = this.scanRuns ? this.scanRuns.length : 0;
        if (this.maxScanRuns != null) {
            return `Storing ${current} of ${this.maxScanRuns} max runs. Oldest auto-deleted.`;
        }
        return `Storing ${current} scan run${current !== 1 ? 's' : ''}.`;
    }

    // ── Event handling ────────────────────────────────────────────────────────

    handleRowClick(event) {
        const row = event.currentTarget;
        const scanRunId = row.dataset.id;

        // Keyboard: only activate on Enter or Space
        if (event.type === 'keydown') {
            const key = event.key;
            if (key !== 'Enter' && key !== ' ') return;
            event.preventDefault();
        }

        // Don't re-fire event for the currently-viewed scan
        if (scanRunId === this.currentScanId) return;

        this.dispatchEvent(
            new CustomEvent('viewhistoricalscan', {
                detail   : { scanRunId },
                bubbles  : true,
                composed : true
            })
        );
    }
}
