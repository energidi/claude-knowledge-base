import { LightningElement, api } from 'lwc';

const SEVERITY_ORDER = ['Critical', 'High'];
const MAX_RECENT = 5;

export default class SecurityDashboard extends LightningElement {
    @api scanRun;
    @api allFindings;
    @api isHistoricalView = false;

    // ----- Getters -----

    get hasScanRun() {
        return !!this.scanRun;
    }

    get recentCriticalHigh() {
        const findings = Array.isArray(this.allFindings) ? this.allFindings : [];
        return findings
            .filter(f => SEVERITY_ORDER.includes(f.Severity__c))
            .sort((a, b) => (a.SeverityRank__c ?? 99) - (b.SeverityRank__c ?? 99))
            .slice(0, MAX_RECENT);
    }

    get scanStats() {
        if (!this.scanRun) return null;

        const checksRun  = this.scanRun.TotalChecksRun__c ?? 76;
        const totalFindings = this.scanRun.TotalFindings__c ?? 0;
        const duration   = this._formatDuration(
            this.scanRun.StartedAt__c,
            this.scanRun.CompletedAt__c
        );
        const operator   = this.scanRun.StartedBy__c ?? '-';
        const startedAt  = this._formatDatetime(this.scanRun.StartedAt__c);

        return { checksRun, totalFindings, duration, operator, startedAt };
    }

    // ----- Helpers -----

    _formatDuration(startStr, endStr) {
        if (!startStr || !endStr) return '-';
        const startMs = new Date(startStr).getTime();
        const endMs   = new Date(endStr).getTime();
        if (isNaN(startMs) || isNaN(endMs) || endMs < startMs) return '-';
        const totalSeconds = Math.round((endMs - startMs) / 1000);
        const minutes = Math.floor(totalSeconds / 60);
        const seconds = totalSeconds % 60;
        return minutes > 0 ? `${minutes}m ${seconds}s` : `${seconds}s`;
    }

    _formatDatetime(dateStr) {
        if (!dateStr) return '-';
        try {
            return new Date(dateStr).toLocaleString(undefined, {
                year:   'numeric',
                month:  'short',
                day:    'numeric',
                hour:   '2-digit',
                minute: '2-digit'
            });
        } catch {
            return '-';
        }
    }
}
