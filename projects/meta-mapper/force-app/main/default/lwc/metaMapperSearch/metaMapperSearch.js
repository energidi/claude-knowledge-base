import { LightningElement, track } from 'lwc';
import createJob from '@salesforce/apex/DependencyJobController.createJob';
import getObjectList from '@salesforce/apex/DependencyJobController.getObjectList';
import getComponentCount from '@salesforce/apex/DependencyJobController.getComponentCount';
import { countToBucket } from 'c/metaMapperUtils';

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

    _typeaheadTimer = null;
    _complexityTimer = null;

    get showTargetObject() { return this.selectedType === 'CustomField'; }
    get showValidationRuleHelp() { return this.selectedType === 'ValidationRule'; }
    get apiNamePlaceholder() { return API_NAME_PLACEHOLDERS[this.selectedType] || API_NAME_PLACEHOLDERS.default; }
    get submitLabel() { return this.isSubmitting ? 'Starting analysis...' : 'Analyze Dependencies'; }

    get isSubmitDisabled() {
        if (this.isSubmitting) return true;
        if (!this.selectedType || !this.apiName.trim()) return true;
        if (this.showTargetObject && !this.targetObject.trim()) return true;
        return false;
    }

    handleTypeChange(event) {
        this.selectedType = event.detail.value;
        this.complexityBucket = null;
        this.submissionError = '';
        this._scheduleComplexityPreview();
    }

    handleApiNameChange(event) {
        this.apiName = event.detail.value;
        this._scheduleComplexityPreview();
    }

    handleApiNameBlur() {
        // Inline validation fires on blur — lightning-input required handles the message
    }

    handleActiveFlowsChange(event) { this.activeFlowsOnly = event.detail.checked; }

    handleTargetObjectInput(event) {
        this.targetObject = event.target.value;
        this.targetObjectError = '';
        this.typeaheadCalloutError = false;
        clearTimeout(this._typeaheadTimer);
        if (!this.targetObject.trim()) { this.typeaheadOpen = false; return; }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._typeaheadTimer = setTimeout(() => this._runTypeahead(), 300);
    }

    handleTargetObjectBlur() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.typeaheadOpen = false; }, 150);
        if (this.showTargetObject && !this.targetObject.trim()) {
            this.targetObjectError = 'Enter the API name of the parent object (e.g. Account).';
        }
    }

    handleTypeaheadSelect(event) {
        this.targetObject = event.currentTarget.dataset.value;
        this.typeaheadOpen = false;
        this.targetObjectError = '';
    }

    async _runTypeahead() {
        this.typeaheadLoading = true;
        this.typeaheadCalloutError = false;
        try {
            const results = await getObjectList({ searchTerm: this.targetObject });
            this.typeaheadResults = (results || []).map(r => ({ label: r, value: r }));
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
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._complexityTimer = setTimeout(() => this._fetchComplexity(), 500);
    }

    async _fetchComplexity() {
        try {
            const count = await getComponentCount({ apiName: this.apiName.trim() });
            this.complexityBucket = count != null ? countToBucket(count) : null;
        } catch {
            this.complexityBucket = null;
        }
    }

    async handleSubmit() {
        if (this.isSubmitDisabled) return;
        this.isSubmitting = true;
        this.submissionError = '';
        this.isRunningScanError = false;
        try {
            const jobId = await createJob({
                targetType: this.selectedType,
                targetApiName: this.apiName.trim(),
                targetParentObject: this.targetObject.trim() || null,
                activeFlowsOnly: this.activeFlowsOnly
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
            this.dispatchEvent(new CustomEvent('viewrunningscan', { bubbles: true, composed: true }));
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
}
