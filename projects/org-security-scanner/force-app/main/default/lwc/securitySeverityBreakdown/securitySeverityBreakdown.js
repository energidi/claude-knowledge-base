import { LightningElement, api } from 'lwc';

const SEVERITY_CONFIG = [
    { key: 'critical', label: 'Critical',      color: '#c23934', scoreKey: 'criticalOpen', runKey: 'CriticalCount__c' },
    { key: 'high',     label: 'High',          color: '#dd7a01', scoreKey: 'highOpen',     runKey: 'HighCount__c'     },
    { key: 'medium',   label: 'Medium',        color: '#f4bc25', scoreKey: 'mediumOpen',   runKey: 'MediumCount__c'   },
    { key: 'low',      label: 'Low',           color: '#54698d', scoreKey: 'lowOpen',      runKey: 'LowCount__c'      },
    { key: 'info',     label: 'Informational', color: '#b0adab', scoreKey: 'infoOpen',     runKey: 'InfoCount__c'     }
];

export default class SecuritySeverityBreakdown extends LightningElement {
    @api scanRun;
    @api scoreCounts;

    // ----- Severity rows -----

    get severityRows() {
        if (!this.scanRun) return [];

        const total = this._totalFindings();

        return SEVERITY_CONFIG.map(cfg => {
            const count = this._countFor(cfg);
            const rawPct = total > 0 ? (count / total) * 100 : 0;
            const progressValue = Math.min(100, Math.max(0, rawPct));

            return {
                key:           cfg.key,
                label:         cfg.label,
                count,
                progressValue,
                dotStyle:      `background-color: ${cfg.color};`,
                progressStyle: `--sds-c-progress-bar-color-background-fill: ${cfg.color};`,
                ariaLabel:     `Filter by ${cfg.label}`
            };
        });
    }

    // ----- Quick stats -----

    get openCount() {
        if (this.scoreCounts) {
            const sc = this.scoreCounts;
            return (
                (sc.criticalOpen || 0) +
                (sc.highOpen     || 0) +
                (sc.mediumOpen   || 0) +
                (sc.lowOpen      || 0) +
                (sc.infoOpen     || 0)
            );
        }
        return this.scanRun ? (this.scanRun.TotalFindings__c || 0) : 0;
    }

    get criticalOpenCount() {
        if (this.scoreCounts) return this.scoreCounts.criticalOpen || 0;
        return this.scanRun ? (this.scanRun.CriticalCount__c || 0) : 0;
    }

    // Recommendations not derivable from current inputs - reserved for v2
    get recommendationCount() {
        return '-';
    }

    get hasScanRun() {
        return !!this.scanRun;
    }

    // ----- Event handlers -----

    handleRowClick(event) {
        const severity = event.currentTarget.dataset.severity;
        this.dispatchEvent(
            new CustomEvent('severityfilterselect', {
                detail:   { severity },
                bubbles:  true,
                composed: true
            })
        );
    }

    // ----- Private helpers -----

    _totalFindings() {
        return this.scanRun.TotalFindings__c || 0;
    }

    _countFor(cfg) {
        if (this.scoreCounts) {
            return this.scoreCounts[cfg.scoreKey] || 0;
        }
        return this.scanRun[cfg.runKey] || 0;
    }
}
