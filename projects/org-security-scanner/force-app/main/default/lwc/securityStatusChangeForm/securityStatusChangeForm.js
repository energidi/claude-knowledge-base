import { LightningElement, api, track } from 'lwc';
import {
    STATUS,
    ALLOWED_TRANSITIONS,
    NOTE_REQUIRED_STATUSES,
    formatDateTime
} from 'c/secScanConstants';

export default class SecurityStatusChangeForm extends LightningElement {

    // ─── @api ─────────────────────────────────────────────────────────────

    @api isHistoricalView = false;

    /**
     * Setter watches for finding.Status__c changes to reset isSaving
     * once the parent has completed the Apex call and refreshed the prop.
     */
    _finding = null;
    _prevStatus = null;

    @api
    get finding() {
        return this._finding;
    }
    set finding(val) {
        const prev = this._finding;
        this._finding = val;

        // Reset isSaving whenever the status on the record changes -
        // this is the signal that the parent completed the Apex call.
        if (val && prev && val.Status__c !== prev.Status__c) {
            this._isSaving = false;
            this._noteError = null;
        }

        // When the prop is set for the first time (or status differs from
        // the previously selected radio), reset selectedStatus to the new status.
        if (!prev || (val && val.Status__c !== this._selectedStatus)) {
            this._selectedStatus = val ? val.Status__c : null;
            this._note = '';
            this._noteError = null;
            this._isSaving = false;
        }
    }

    // ─── Internal state ───────────────────────────────────────────────────

    @track _selectedStatus = null;  // currently selected radio button
    @track _note = '';
    @track _noteError = null;
    @track _isSaving = false;

    // ─── Derived: current status ──────────────────────────────────────────

    get currentStatus() {
        return this._finding ? this._finding.Status__c : null;
    }

    get currentStatusBadgeClass() {
        const base = 'slds-badge status-badge';
        const s = this.currentStatus;
        if (s === STATUS.OPEN)           return `${base} badge-open`;
        if (s === STATUS.ACKNOWLEDGED)   return `${base} badge-acknowledged`;
        if (s === STATUS.REMEDIATED)     return `${base} badge-remediated`;
        if (s === STATUS.RISK_ACCEPTED)  return `${base} badge-risk-accepted`;
        if (s === STATUS.FALSE_POSITIVE) return `${base} badge-false-positive`;
        return base;
    }

    // ─── Derived: radio options ───────────────────────────────────────────

    get transitionOptions() {
        if (!this.currentStatus) return [];
        const transitions = ALLOWED_TRANSITIONS[this.currentStatus] || [];
        return transitions.map(s => ({
            label:   s,
            value:   s,
            checked: s === this._selectedStatus
        }));
    }

    get hasTransitions() {
        return this.transitionOptions.length > 0;
    }

    // ─── Derived: note field ──────────────────────────────────────────────

    get showNoteField() {
        return this._selectedStatus !== null &&
               this._selectedStatus !== this.currentStatus;
    }

    get noteRequired() {
        return NOTE_REQUIRED_STATUSES.has(this._selectedStatus);
    }

    get noteLabel() {
        return this.noteRequired ? 'Note (required)' : 'Note (optional)';
    }

    get noteFieldClass() {
        return this._noteError
            ? 'slds-form-element slds-has-error'
            : 'slds-form-element';
    }

    // ─── Derived: save button ─────────────────────────────────────────────

    get saveDisabled() {
        if (this._isSaving) return true;
        if (this.isHistoricalView) return true;
        if (!this._selectedStatus || this._selectedStatus === this.currentStatus) return true;
        if (this.noteRequired && !this._note.trim()) return true;
        return false;
    }

    get cancelDisabled() {
        return this._isSaving || this.isHistoricalView;
    }

    get formDisabled() {
        return this._isSaving || this.isHistoricalView;
    }

    // ─── Derived: acknowledged info ───────────────────────────────────────

    get showAcknowledgedBy() {
        return !!(this._finding && this._finding.AcknowledgedBy__c);
    }

    get acknowledgedByText() {
        if (!this._finding) return '';
        const name = this._finding.AcknowledgedBy__c || '';
        const date = formatDateTime(this._finding.AcknowledgedDate__c);
        return `Last updated by: ${name} on ${date}`;
    }

    // ─── Derived: no-transition message ──────────────────────────────────

    get noTransitionMessage() {
        return 'No status transitions are available for this finding.';
    }

    // ─── Event handlers ───────────────────────────────────────────────────

    handleRadioChange(event) {
        this._selectedStatus = event.target.value;
        // Reset note error when selection changes; also reset note if
        // the new target does not require one.
        this._noteError = null;
        if (!NOTE_REQUIRED_STATUSES.has(this._selectedStatus)) {
            // Keep any typed note; only clear error.
        }
    }

    handleNoteChange(event) {
        this._note = event.target.value;
        if (this._noteError && this._note.trim()) {
            this._noteError = null;
        }
    }

    handleSave() {
        // Inline validation - show error on Save click, not on blur.
        if (this.noteRequired && !this._note.trim()) {
            this._noteError = 'Note is required for this status';
            return;
        }

        this._noteError = null;
        this._isSaving = true;

        this.dispatchEvent(new CustomEvent('statuschange', {
            bubbles:  false,
            composed: false,
            detail: {
                findingId: this._finding ? this._finding.Id : null,
                newStatus: this._selectedStatus,
                note:      this._note.trim()
            }
        }));
    }

    handleCancel() {
        // Reset selection back to current status (i.e. deselect).
        this._selectedStatus = this.currentStatus;
        this._note = '';
        this._noteError = null;
    }
}
