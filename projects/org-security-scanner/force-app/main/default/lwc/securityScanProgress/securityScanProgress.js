import { LightningElement, api } from 'lwc';

// Ordered category definitions - source of truth for row order and labels
const CATEGORIES = [
    { code: 'UA',  label: 'User & Access'                  },
    { code: 'GU',  label: 'Guest User / Experience Cloud'  },
    { code: 'SRA', label: 'Sharing & Record Access'        },
    { code: 'SA',  label: 'Session & Auth'                 },
    { code: 'CAI', label: 'Connected Apps & Integrations'  },
    { code: 'AA',  label: 'Apex & Automation'              },
    { code: 'LA',  label: 'LWC & Aura'                     },
    { code: 'AGA', label: 'Agentforce & GenAI'             },
    { code: 'MS',  label: 'Metadata & Secrets'             },
    { code: 'FUE', label: 'File Upload & Execution'        },
    { code: 'CE',  label: 'Certificates & Encryption'      },
    { code: 'MON', label: 'Monitoring'                     },
    { code: 'HCB', label: 'Health Check Baseline'          }
];

const STATUS_RUNNING = 'Running';

export default class SecurityScanProgress extends LightningElement {
    @api scanRun;
    @api completedCategories = '';
    @api failedCategories    = '';
    @api lastCheckedTime;   // Date object set by parent on each poll

    // ── Computed row list ──────────────────────────────────────────────────

    get categoryRows() {
        const completedSet = this._parseSet(this.completedCategories);
        const failedSet    = this._parseSet(this.failedCategories);
        const isRunning    = this.scanRun && this.scanRun.Status__c === STATUS_RUNNING;

        // The first category not yet completed and not failed is "in-progress"
        let inProgressFound = false;

        return CATEGORIES.map(cat => {
            const isCompleted  = completedSet.has(cat.code);
            const isFailed     = failedSet.has(cat.code);
            const isInProgress = isRunning && !isCompleted && !isFailed && !inProgressFound;

            if (isInProgress) inProgressFound = true;

            let state;
            if (isCompleted)  state = 'completed';
            else if (isFailed) state = 'failed';
            else if (isInProgress) state = 'inprogress';
            else state = 'pending';

            return {
                key:          cat.code,
                label:        cat.label,
                state,
                isCompleted,
                isFailed,
                isInProgress,
                isPending:    state === 'pending',
                rowClass:     `category-row category-row--${state}`
            };
        });
    }

    // ── "Last checked" relative time ───────────────────────────────────────

    get lastCheckedLabel() {
        if (!this.lastCheckedTime) return null;
        const nowMs    = Date.now();
        const thenMs   = this.lastCheckedTime instanceof Date
            ? this.lastCheckedTime.getTime()
            : Number(this.lastCheckedTime);
        const diffSec  = Math.max(0, Math.round((nowMs - thenMs) / 1000));
        return `Last checked: ${diffSec}s ago`;
    }

    get hasLastChecked() {
        return !!this.lastCheckedTime;
    }

    // ── Progress counts for summary line ──────────────────────────────────

    get completedCount() {
        return this._parseSet(this.completedCategories).size;
    }

    get totalCount() {
        return CATEGORIES.length;
    }

    // ── Cancel ─────────────────────────────────────────────────────────────

    handleCancelClick() {
        this.dispatchEvent(
            new CustomEvent('cancelscan', { bubbles: true, composed: true })
        );
    }

    // ── Private helpers ────────────────────────────────────────────────────

    _parseSet(commaSeparated) {
        if (!commaSeparated) return new Set();
        return new Set(
            commaSeparated
                .split(',')
                .map(s => s.trim())
                .filter(Boolean)
        );
    }
}
