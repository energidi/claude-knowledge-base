import { LightningElement, api } from 'lwc';

const DATE_FORMAT = new Intl.DateTimeFormat(undefined, {
    dateStyle: 'medium',
    timeStyle: 'short'
});

export default class ScanRunMetadata extends LightningElement {
    @api scanRun;

    get formattedDate() {
        if (!this.scanRun) return '-';
        const raw = this.scanRun.CompletedAt__c || this.scanRun.StartedAt__c;
        if (!raw) return '-';
        try {
            return DATE_FORMAT.format(new Date(raw));
        } catch {
            return '-';
        }
    }

    get operatorName() {
        if (!this.scanRun) return '-';
        const name = this.scanRun.StartedBy__c;
        return name || '-';
    }

    get totalFindings() {
        if (!this.scanRun) return 0;
        const val = this.scanRun.TotalFindings__c;
        return (val != null && !isNaN(val)) ? Number(val) : 0;
    }

    get findingLabel() {
        return `${this.totalFindings} findings`;
    }

    /** Base chip class - shared by all three chips */
    get findingChipClass() {
        return 'chip';
    }

    /** Color class applied to the finding count label text */
    get findingLabelClass() {
        const count = this.totalFindings;
        if (count === 0) return 'chip-label finding-green';
        if (count < 10) return 'chip-label finding-amber';
        return 'chip-label finding-red';
    }
}
