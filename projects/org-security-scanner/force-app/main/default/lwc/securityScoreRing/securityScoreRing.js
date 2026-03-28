import { LightningElement, api, track } from 'lwc';

const CIRCUMFERENCE = 2 * Math.PI * 44; // 276.4601...

const GRADE_COLORS = {
    A: '#2e844a',
    B: '#3ba755',
    C: '#f4bc25',
    D: '#dd7a01',
    F: '#c23934'
};

const DEFAULT_ORG_SETTINGS = {
    CriticalDeduction__c: 20,
    CriticalCap__c:       60,
    HighDeduction__c:     10,
    HighCap__c:           30,
    MediumDeduction__c:   5,
    MediumCap__c:         15,
    LowDeduction__c:      2,
    LowCap__c:            6,
    InfoDeduction__c:     0,
    InfoCap__c:           0
};

export default class SecurityScoreRing extends LightningElement {
    @api score       = 0;
    @api grade       = 'F';
    @api scoreCounts = {};
    @api orgSettings = {};

    @track isPopoverOpen = false;

    // ─── SVG arc ────────────────────────────────────────────────────────────

    get arcStyle() {
        const safeScore = this._clamp(Number(this.score) || 0, 0, 100);
        const filled    = (safeScore / 100) * CIRCUMFERENCE;
        const offset    = CIRCUMFERENCE - filled;
        return `stroke-dasharray:${CIRCUMFERENCE.toFixed(4)};stroke-dashoffset:${offset.toFixed(4)};stroke:${this.arcColor};`;
    }

    get arcColor() {
        return GRADE_COLORS[this.grade] || GRADE_COLORS.F;
    }

    get safeScore() {
        return this._clamp(Number(this.score) || 0, 0, 100);
    }

    get safeGrade() {
        return this.grade || 'F';
    }

    get ariaLabel() {
        return `Security score ${this.safeScore}, Grade ${this.safeGrade}`;
    }

    // ─── Score label color matches arc ──────────────────────────────────────

    get scoreStyle() {
        return `fill:${this.arcColor};`;
    }

    // ─── Popover ─────────────────────────────────────────────────────────────

    get popoverRows() {
        const s  = this.scoreCounts  || {};
        const os = Object.assign({}, DEFAULT_ORG_SETTINGS, this.orgSettings || {});

        const critOpen   = Number(s.criticalOpen) || 0;
        const highOpen   = Number(s.highOpen)     || 0;
        const medOpen    = Number(s.mediumOpen)   || 0;
        const lowOpen    = Number(s.lowOpen)      || 0;
        const infoOpen   = Number(s.infoOpen)     || 0;

        const excluded =
            (Number(s.criticalRemediated) || 0) +
            (Number(s.criticalFalsePos)   || 0) +
            (Number(s.highRemediated)     || 0) +
            (Number(s.highFalsePos)       || 0) +
            (Number(s.mediumRemediated)   || 0) +
            (Number(s.mediumFalsePos)     || 0) +
            (Number(s.lowRemediated)      || 0) +
            (Number(s.lowFalsePos)        || 0) +
            (Number(s.infoRemediated)     || 0) +
            (Number(s.infoFalsePos)       || 0);

        const rows = [];

        rows.push({ key: 'start',    label: 'Starting score',   value: '100',         isHeader: true,  isDivider: false });

        rows.push(...this._deductRow('Critical', critOpen, os.CriticalDeduction__c, os.CriticalCap__c));
        rows.push(...this._deductRow('High',     highOpen, os.HighDeduction__c,     os.HighCap__c));
        rows.push(...this._deductRow('Medium',   medOpen,  os.MediumDeduction__c,   os.MediumCap__c));
        rows.push(...this._deductRow('Low',      lowOpen,  os.LowDeduction__c,      os.LowCap__c));
        rows.push(...this._deductRow('Info',     infoOpen, os.InfoDeduction__c,     os.InfoCap__c));

        rows.push({ key: 'divider',  label: '',                 value: '',            isHeader: false, isDivider: true  });
        rows.push({ key: 'excluded', label: 'Excluded',         value: `${excluded} Remediated / False Positive`, isHeader: false, isDivider: false });
        rows.push({ key: 'final',    label: 'Final',            value: `${this.safeScore} (Grade ${this.safeGrade})`, isHeader: true, isDivider: false });

        return rows;
    }

    get popoverClass() {
        return this.isPopoverOpen
            ? 'slds-popover slds-popover_small slds-nubbin_bottom score-popover'
            : 'slds-popover slds-popover_small slds-nubbin_bottom score-popover slds-hide';
    }

    // ─── Event handlers ──────────────────────────────────────────────────────

    handleTogglePopover() {
        this.isPopoverOpen = !this.isPopoverOpen;
    }

    handleKeyDown(event) {
        if (event.key === 'Escape' && this.isPopoverOpen) {
            this.isPopoverOpen = false;
        }
    }

    handlePopoverClose() {
        this.isPopoverOpen = false;
    }

    // ─── Private helpers ─────────────────────────────────────────────────────

    _clamp(val, min, max) {
        return Math.min(Math.max(val, min), max);
    }

    _deductRow(label, count, deductPer, cap) {
        if (!count || !deductPer) return [];
        const raw      = count * deductPer;
        const applied  = Math.min(raw, cap);
        const capNote  = raw > cap ? `, cap ${cap}` : '';
        return [{
            key:      `deduct-${label.toLowerCase()}`,
            label:    label,
            value:    `-${applied} (${count} x ${deductPer}${capNote})`,
            isHeader: false,
            isDivider: false
        }];
    }
}
