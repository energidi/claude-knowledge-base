import { LightningElement, api, track } from 'lwc';
import { SEVERITY, FINDING_TYPE, CATEGORY_LABELS } from 'c/secScanConstants';

// Focusable selector for focus-trap cycling
const FOCUSABLE = [
    'button:not([disabled])',
    'a[href]',
    'input:not([disabled])',
    'select:not([disabled])',
    'textarea:not([disabled])',
    '[tabindex]:not([tabindex="-1"])'
].join(',');

export default class SecurityFindingDetail extends LightningElement {

    // ─── @api ──────────────────────────────────────────────────────────────

    @api finding            = null;
    @api findingIndex       = 0;
    @api totalFindings      = 0;
    @api isLastLoadedFinding = false;
    @api isHistoricalView   = false;
    @api activeTab          = 'details';

    // ─── Internal state ────────────────────────────────────────────────────

    @track _evidenceExpanded = false;

    // ─── Lifecycle ─────────────────────────────────────────────────────────

    connectedCallback() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const btn = this.template.querySelector('.close-btn');
            if (btn) btn.focus();
        }, 0);
    }

    // ─── Keyboard handling ─────────────────────────────────────────────────

    handleKeyDown(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            this._fireClose();
            return;
        }

        if (event.key === 'Tab') {
            const focusable = Array.from(
                this.template.querySelectorAll(FOCUSABLE)
            );
            if (!focusable.length) return;

            const first = focusable[0];
            const last  = focusable[focusable.length - 1];
            const active = this.template.activeElement;

            if (event.shiftKey) {
                if (active === first) {
                    event.preventDefault();
                    last.focus();
                }
            } else {
                if (active === last) {
                    event.preventDefault();
                    first.focus();
                }
            }
        }
    }

    // ─── Header derived ────────────────────────────────────────────────────

    get positionLabel() {
        return `Finding ${this.findingIndex + 1} of ${this.totalFindings}`;
    }

    get checkName() {
        return this.finding ? (this.finding.CheckName__c || this.finding.Name || '') : '';
    }

    get severity() {
        return this.finding ? (this.finding.Severity__c || '') : '';
    }

    get severityBadgeClass() {
        const base = 'severity-badge';
        const s = this.severity;
        if (s === SEVERITY.CRITICAL)    return `${base} badge-critical`;
        if (s === SEVERITY.HIGH)        return `${base} badge-high`;
        if (s === SEVERITY.MEDIUM)      return `${base} badge-medium`;
        if (s === SEVERITY.LOW)         return `${base} badge-low`;
        return `${base} badge-info`;
    }

    get findingType() {
        return this.finding ? (this.finding.FindingType__c || '') : '';
    }

    get isRecommendation() {
        return this.findingType === FINDING_TYPE.RECOMMENDATION;
    }

    get isAutomated() {
        return this.findingType === FINDING_TYPE.AUTOMATED;
    }

    get isPrevDisabled() {
        return this.findingIndex === 0;
    }

    get isNextDisabled() {
        return this.isLastLoadedFinding;
    }

    get nextTitle() {
        return this.isLastLoadedFinding
            ? 'Load more findings to continue'
            : 'Next finding';
    }

    // ─── Tab derived ───────────────────────────────────────────────────────

    get isDetailsTab() {
        return this.activeTab === 'details';
    }

    get isStatusTab() {
        return this.activeTab === 'status';
    }

    get detailsTabClass() {
        return `slds-tabs_default__item${this.activeTab === 'details' ? ' slds-is-active' : ''}`;
    }

    get statusTabClass() {
        return `slds-tabs_default__item${this.activeTab === 'status' ? ' slds-is-active' : ''}`;
    }

    // ─── Details tab derived ───────────────────────────────────────────────

    get categoryLabel() {
        if (!this.finding) return '';
        const code = this.finding.Category__c || '';
        return CATEGORY_LABELS[code] || code;
    }

    get affectedComponent() {
        return this.finding ? (this.finding.AffectedComponent__c || '-') : '';
    }

    get description() {
        return this.finding ? (this.finding.Description__c || '') : '';
    }

    get impact() {
        return this.finding ? (this.finding.Impact__c || '') : '';
    }

    get remediation() {
        return this.finding ? (this.finding.Remediation__c || '') : '';
    }

    get rawEvidence() {
        return this.finding ? (this.finding.RawEvidence__c || '') : '';
    }

    get hasEvidence() {
        return this.isAutomated && !!this.rawEvidence;
    }

    get salesforceDocUrl() {
        return this.finding ? (this.finding.SalesforceDocUrl__c || '') : '';
    }

    get hasSalesforceDocUrl() {
        return !!this.salesforceDocUrl;
    }

    get evidenceToggleLabel() {
        return this._evidenceExpanded ? 'Hide evidence' : 'Show evidence';
    }

    get evidenceToggleIcon() {
        return this._evidenceExpanded ? 'utility:chevrondown' : 'utility:chevronright';
    }

    // ─── Event handlers ────────────────────────────────────────────────────

    handleCloseClick() {
        this._fireClose();
    }

    handlePrevClick() {
        this.dispatchEvent(new CustomEvent('previousfinding', {
            bubbles:  true,
            composed: true
        }));
    }

    handleNextClick() {
        if (this.isLastLoadedFinding) return;
        this.dispatchEvent(new CustomEvent('nextfinding', {
            bubbles:  true,
            composed: true
        }));
    }

    handleDetailsTabClick() {
        if (this.activeTab === 'details') return;
        this.dispatchEvent(new CustomEvent('tabswitch', {
            bubbles:  true,
            composed: true,
            detail:   { tab: 'details' }
        }));
    }

    handleStatusTabClick() {
        if (this.activeTab === 'status') return;
        this.dispatchEvent(new CustomEvent('tabswitch', {
            bubbles:  true,
            composed: true,
            detail:   { tab: 'status' }
        }));
    }

    handleEvidenceToggle() {
        this._evidenceExpanded = !this._evidenceExpanded;
    }

    handleStatusChange(event) {
        // Re-fire upward without bubbling (parent-child only)
        this.dispatchEvent(new CustomEvent('statuschange', {
            bubbles:  false,
            composed: false,
            detail:   event.detail
        }));
    }

    // ─── Private helpers ───────────────────────────────────────────────────

    _fireClose() {
        this.dispatchEvent(new CustomEvent('closedetail', {
            bubbles:  true,
            composed: true
        }));
    }
}
