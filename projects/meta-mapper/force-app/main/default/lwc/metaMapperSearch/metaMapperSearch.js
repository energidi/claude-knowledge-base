import { LightningElement, api, track } from 'lwc';
import createJob from '@salesforce/apex/DependencyJobController.createJob';
import getObjectList from '@salesforce/apex/DependencyJobController.getObjectList';
import getComponentCount from '@salesforce/apex/DependencyJobController.getComponentCount';
import getActiveJobId from '@salesforce/apex/DependencyJobController.getActiveJobId';

const TYPE_OPTIONS = [
    { label: 'Apex Class',       value: 'ApexClass' },
    { label: 'Apex Trigger',     value: 'ApexTrigger' },
    { label: 'Custom Field',     value: 'CustomField' },
    { label: 'Flow',             value: 'Flow' },
    { label: 'Report',           value: 'Report' },
    { label: 'Validation Rule',  value: 'ValidationRule' },
    { label: 'Workflow Rule',    value: 'WorkflowRule' }
];

const API_NAME_PLACEHOLDERS = {
    CustomField:    'e.g. Account.My_Field__c',
    ApexClass:      'e.g. AccountTriggerHandler',
    Flow:           'e.g. Account_Before_Save',
    ValidationRule: 'e.g. Validate_Phone (developer name only, no object prefix)',
    default:        'e.g. Account.My_Field__c'
};

export default class MetaMapperSearch extends LightningElement {
    typeOptions = TYPE_OPTIONS;

    @track selectedType = '';
    @track apiName = '';
    @track targetObject = '';
    @track activeFlowsOnly = true;
    @track isSubmitting = false;
    @track submissionError = '';
    @track isRunningScanError = false;
    @track viewScanLoading = false;
    @track viewScanError = '';
    @track typeaheadResults = [];
    @track typeaheadOpen = false;
    @track typeaheadLoading = false;
    @track typeaheadCalloutError = false;
    @track targetObjectError = '';
    @track complexityBucket = null;
    @track _complexityLoading = false;
    @track _hasWhitespaceHint = false;

    _typeaheadTimer = null;
    _complexityTimer = null;
    _blurCloseTimer = null;
    _focusedTypeaheadIdx = -1;

    disconnectedCallback() {
        clearTimeout(this._typeaheadTimer);
        clearTimeout(this._complexityTimer);
        clearTimeout(this._blurCloseTimer);
    }

    get showTargetObject() { return this.selectedType === 'CustomField'; }

    @api
    focusFirstInput() {
        const el = this.template.querySelector('input, select, button, [tabindex="0"]');
        if (el) el.focus();
    }

    get activeTypeaheadOptionId() {
        if (this._focusedTypeaheadIdx < 0 || !this.typeaheadResults[this._focusedTypeaheadIdx]) return null;
        return this.typeaheadResults[this._focusedTypeaheadIdx].optionId;
    }
    get showValidationRuleHelp() { return this.selectedType === 'ValidationRule'; }
    get apiNamePlaceholder() { return API_NAME_PLACEHOLDERS[this.selectedType] || API_NAME_PLACEHOLDERS.default; }
    get submitLabel() { return this.isSubmitting ? 'Starting analysis...' : 'Analyze Dependencies'; }

    get isSubmitDisabled() {
        if (this.isSubmitting) return true;
        if (!this.selectedType || !this.apiName.trim()) return true;
        if (this.showTargetObject && !this.targetObject.trim()) return true;
        const apiNameInput = this.template.querySelector('lightning-input[name="apiName"]');
        if (apiNameInput && !apiNameInput.checkValidity()) return true;
        return false;
    }

    handleTypeChange(event) {
        this.selectedType = event.detail.value;
        this.complexityBucket = null;
        this.submissionError = '';
        this._scheduleComplexityPreview();
    }

    handleApiNameChange(event) {
        const rawValue = event.detail.value || '';
        this._hasWhitespaceHint = rawValue !== rawValue.trim();
        this.apiName = rawValue;
        this._scheduleComplexityPreview();
    }

    handleApiNameBlur(event) {
        // Explicitly trigger validity reporting on blur so the "value missing" and
        // "pattern mismatch" messages (message-when-value-missing / message-when-pattern-mismatch)
        // actually surface without requiring a submit attempt first.
        if (event.target && event.target.reportValidity) {
            event.target.reportValidity();
        }
    }

    handleActiveFlowsChange(event) { this.activeFlowsOnly = event.detail.checked; }

    handleTargetObjectInput(event) {
        this.targetObject = event.target.value;
        this.targetObjectError = '';
        this.typeaheadCalloutError = false;
        clearTimeout(this._typeaheadTimer);
        if (!this.targetObject.trim()) { this.typeaheadOpen = false; return; }
        this._typeaheadTimer = setTimeout(() => this._runTypeahead(), 300);
    }

    handleTargetObjectBlur() {
        clearTimeout(this._blurCloseTimer);
        this._blurCloseTimer = setTimeout(() => { this.typeaheadOpen = false; this._resetTypeaheadFocus(); }, 150);
        if (this.showTargetObject && !this.targetObject.trim()) {
            this.targetObjectError = 'Enter the API name of the parent object (e.g. Account).';
        }
    }

    handleTypeaheadSelect(event) {
        this.targetObject = event.currentTarget.dataset.value;
        this.typeaheadOpen = false;
        this.targetObjectError = '';
        this._resetTypeaheadFocus();
    }

    handleTypeaheadKeydown(event) {
        if (!this.typeaheadOpen) return;
        const key = event.key;
        if (key === 'ArrowDown') {
            event.preventDefault();
            this._setTypeaheadFocus(Math.min(this._focusedTypeaheadIdx + 1, this.typeaheadResults.length - 1));
        } else if (key === 'ArrowUp') {
            event.preventDefault();
            this._setTypeaheadFocus(Math.max(this._focusedTypeaheadIdx - 1, 0));
        } else if (key === 'Enter') {
            if (this._focusedTypeaheadIdx >= 0 && this.typeaheadResults[this._focusedTypeaheadIdx]) {
                event.preventDefault();
                this.targetObject = this.typeaheadResults[this._focusedTypeaheadIdx].value;
                this.typeaheadOpen = false;
                this.targetObjectError = '';
                this._resetTypeaheadFocus();
            }
        } else if (key === 'Escape') {
            this.typeaheadOpen = false;
            this._resetTypeaheadFocus();
        }
    }

    _setTypeaheadFocus(idx) {
        this._focusedTypeaheadIdx = idx;
        this.typeaheadResults = this.typeaheadResults.map((r, i) => ({ ...r, isFocused: i === idx }));
    }

    _resetTypeaheadFocus() {
        this._focusedTypeaheadIdx = -1;
        if (this.typeaheadResults.some(r => r.isFocused)) {
            this.typeaheadResults = this.typeaheadResults.map(r => ({ ...r, isFocused: false }));
        }
    }

    async _runTypeahead() {
        this.typeaheadLoading = true;
        this.typeaheadCalloutError = false;
        try {
            const results = await getObjectList({ searchTerm: this.targetObject });
            this.typeaheadResults = (results || []).map((r, i) => ({
                label: r.QualifiedApiName, value: r.QualifiedApiName,
                optionId: `typeahead-option-${i}`, isFocused: false
            }));
            this._focusedTypeaheadIdx = -1;
            this.typeaheadOpen = true;
        } catch {
            this.typeaheadCalloutError = true;
            this.typeaheadOpen = false;
        } finally {
            this.typeaheadLoading = false;
        }
    }

    _scheduleComplexityPreview() {
        clearTimeout(this._complexityTimer);
        if (!this.apiName.trim()) { this.complexityBucket = null; return; }
        this._complexityTimer = setTimeout(() => this._fetchComplexity(), 300);
    }

    async _fetchComplexity() {
        this._complexityLoading = true;
        try {
            const bucket = await getComponentCount({ apiName: this.apiName.trim() });
            this.complexityBucket = bucket != null ? bucket : null;
        } catch {
            this.complexityBucket = null;
        } finally {
            this._complexityLoading = false;
        }
    }

    async handleSubmit() {
        if (this.isSubmitDisabled) return;
        this.isSubmitting = true;
        this.submissionError = '';
        this.isRunningScanError = false;
        try {
            const jobId = await createJob({
                metadataType: this.selectedType,
                apiName: this.apiName.trim(),
                targetObject: this.targetObject.trim() || null,
                isActiveFlowsOnly: this.activeFlowsOnly
            });
            this.dispatchEvent(new CustomEvent('jobcreated', { detail: { jobId }, bubbles: true, composed: true }));
        } catch (e) {
            const msg = (e.body && e.body.message) ? e.body.message : 'An error occurred. Please try again.';
            const isConcurrency = msg.includes('scan is already running') || msg.includes('Another MetaMapper');
            this.isRunningScanError = isConcurrency;
            this.submissionError = msg;
        } finally {
            this.isSubmitting = false;
        }
    }

    async handleViewRunningScan() {
        this.viewScanLoading = true;
        this.viewScanError = '';
        try {
            const activeId = await getActiveJobId();
            if (activeId) {
                this.dispatchEvent(new CustomEvent('viewrunningscan', {
                    detail: { jobId: activeId }, bubbles: true, composed: true
                }));
            } else {
                // getActiveJobId() returned null. Two possible causes:
                // (a) the blocking scan completed between rejection and this click (race condition), OR
                // (b) the blocking scan belongs to another user (invisible due to Private OWD).
                // Dismiss the banner so the "View running scan" link disappears, but use copy
                // that covers both cases rather than claiming the scan "finished".
                this.submissionError = '';
                this.isRunningScanError = false;
                this.dispatchEvent(new CustomEvent('showtoast', {
                    detail: {
                        message: "The running scan isn't visible to your account. It may belong to another user or have just completed. Try starting a new scan - if one is still running you will see this message again.",
                        variant: 'info'
                    },
                    bubbles: true, composed: true
                }));
            }
        } catch {
            this.viewScanError = 'Could not load the running scan. Try again.';
        } finally {
            this.viewScanLoading = false;
        }
    }

    dismissError() {
        this.submissionError = '';
        this.isRunningScanError = false;
    }

    handleViewRunningScanKeyDown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleViewRunningScan(event);
        }
    }
}
