import { LightningElement, api } from 'lwc';
import searchIcd10 from '@salesforce/apex/ICDLookupController.searchIcd10';
import getIcdLookupConfig from '@salesforce/apex/ICDLookupController.getIcdLookupConfig';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';
import labelPlaceholderDefault from '@salesforce/label/c.ICD_Lookup_Placeholder_Default';
import labelNoResultsDefault from '@salesforce/label/c.ICD_Lookup_No_Results_Default';
import labelSearchFailed from '@salesforce/label/c.ICD_Lookup_Error_Search_Failed';
import labelConfigLoadFailed from '@salesforce/label/c.ICD_Lookup_Error_Config_Load_Failed';
import labelValidationRequired from '@salesforce/label/c.ICD_Lookup_Validation_Required';

export default class IcdLookup extends LightningElement {
    @api label = '';
    @api flowApiName;
    @api mandatory = false;
    @api defaultValue;
    @api tooltip;
    @api noResultsMessage = labelNoResultsDefault;
    @api fieldPlaceholder = labelPlaceholderDefault;
    @api selectedCode;

    searchTerm = '';
    icdResults = [];
    isLoading = false;
    searchError = '';
    configError = '';
    isSelected = false;
    validationError = '';
    searchDebounceTimer;
    _focusedIndex = -1;
    _resultsReady = false;
    _mandatory = null;
    _requestSeq = 0;
    _dropdownDismissed = false;
    _searchIsSlow = false;
    _slowSearchTimer;
    _uid = `icd-${Date.now()}-${Math.random().toString(36).slice(2)}`;

    // CMT-driven mandatory overrides @api mandatory when loaded; @api mandatory is the fallback on CMT failure.
    get isMandatory() {
        return this._mandatory !== null ? this._mandatory : this.mandatory;
    }

    get _labelId() {
        return `icd-label-${this._uid}`;
    }

    get ariaRequired() {
        return this.isMandatory ? 'true' : 'false';
    }

    connectedCallback() {
        if (this.defaultValue) {
            this.selectedCode = this.defaultValue;
            this.searchTerm = this.defaultValue;
            this.isSelected = true;
        }

        if (this.flowApiName) {
            getIcdLookupConfig({ flowApiName: this.flowApiName })
                .then(config => {
                    if (config) {
                        if (config.Field_Placeholder__c) this.fieldPlaceholder = config.Field_Placeholder__c;
                        if (config.No_Matching_Codes_Found_Message__c) this.noResultsMessage = config.No_Matching_Codes_Found_Message__c;
                        if (config.Tooltip__c) this.tooltip = config.Tooltip__c;
                        if (config.Required__c !== null && config.Required__c !== undefined) {
                            this._mandatory = config.Required__c;
                        }
                    }
                })
                .catch(() => {
                    this.configError = labelConfigLoadFailed;
                });
        }
    }

    disconnectedCallback() {
        clearTimeout(this.searchDebounceTimer);
        clearTimeout(this._slowSearchTimer);
    }

    @api validate() {
        if (this.isMandatory && !this.selectedCode) {
            this.validationError = `${this.label} ${labelValidationRequired}`;
            return { isValid: false, errorMessage: this.validationError };
        }
        this.validationError = '';
        return { isValid: true };
    }

    get processedResults() {
        return this.icdResults.map((res, index) => ({
            code: res.code,
            description: res.description,
            optionId: `icd-option-${index}`,
            isActive: index === this._focusedIndex,
            isSelected: `${res.code}: ${res.description}` === this.selectedCode,
            itemClass: `slds-listbox__item${index === this._focusedIndex ? ' slds-has-focus' : ''}`
        }));
    }

    get activeDescendant() {
        return this._focusedIndex >= 0 ? `icd-option-${this._focusedIndex}` : '';
    }

    get dropdownClass() {
        return (this.isLoading || this.icdResults.length > 0 || this.showNoResults)
            ? 'slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click slds-is-open'
            : 'slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click';
    }

    get formElementClass() {
        return (this.validationError || this.searchError)
            ? 'slds-form-element slds-has-error'
            : 'slds-form-element';
    }

    get showNoResults() {
        return this._resultsReady && this.searchTerm.length >= 3 && !this.isLoading && this.icdResults.length === 0 && !this.searchError && !this.isSelected;
    }

    get isOpen() {
        return this.isLoading || this.icdResults.length > 0 || this.showNoResults;
    }

    get displayError() {
        return this.validationError || this.searchError;
    }

    get showMinCharHint() {
        return this.searchTerm.length > 0 && this.searchTerm.length < 3;
    }

    get searchSlowWarning() {
        return this._searchIsSlow && this.isLoading;
    }

    get screenReaderStatus() {
        if (this._dropdownDismissed) return 'Search results dismissed.';
        if (this.isLoading) return 'Loading results...';
        if (this.searchError) return this.searchError;
        if (this.showNoResults) return this.noResultsMessage;
        if (this.icdResults.length > 0) {
            return `${this.icdResults.length} result${this.icdResults.length === 1 ? '' : 's'} found`;
        }
        return '';
    }

    handleSearchChange(event) {
        this._dropdownDismissed = false;
        this.searchTerm = event.target.value;
        if (this.searchTerm !== this.selectedCode) {
            this.selectedCode = '';
            this.dispatchEvent(new FlowAttributeChangeEvent('selectedCode', ''));
        }
        this.searchError = '';
        this.isSelected = false;
        this.validationError = '';
        this._focusedIndex = -1;
        this._resultsReady = false;
        clearTimeout(this.searchDebounceTimer);

        if (this.searchTerm.length >= 3) {
            this.icdResults = [];
            this.searchDebounceTimer = setTimeout(() => {
                this.isLoading = true;
                this.fetchIcdResults();
            }, 400);
        } else {
            this.icdResults = [];
            this.isLoading = false;
        }
    }

    fetchIcdResults() {
        this._requestSeq = (this._requestSeq ?? 0) + 1;
        const seq = this._requestSeq;
        this._slowSearchTimer = setTimeout(() => {
            if (seq === this._requestSeq && this.isLoading) {
                this._searchIsSlow = true;
            }
        }, 5000);
        searchIcd10({ searchTerm: this.searchTerm })
            .then(result => {
                if (seq !== this._requestSeq) return;
                this.icdResults = result;
            })
            .catch(() => {
                if (seq !== this._requestSeq) return;
                this.searchError = labelSearchFailed;
                this.icdResults = [];
            })
            .finally(() => {
                if (seq !== this._requestSeq) return;
                clearTimeout(this._slowSearchTimer);
                this._searchIsSlow = false;
                this.isLoading = false;
                this._resultsReady = true;
            });
    }

    handleRetry() {
        if (this.searchTerm.length >= 3) {
            this.searchError = '';
            this.isLoading = true;
            this.fetchIcdResults();
        }
    }

    handleFocusOut(event) {
        if (!this.template.contains(event.relatedTarget)) {
            this.icdResults = [];
            this._resultsReady = false;
            this._focusedIndex = -1;
        }
    }

    handleDropdownKeydown(event) {
        if (!this.isOpen) return;
        const count = this.icdResults.length;
        switch (event.key) {
            case 'ArrowDown':
                event.preventDefault();
                this._focusedIndex = count > 0 ? Math.min(this._focusedIndex + 1, count - 1) : -1;
                break;
            case 'ArrowUp':
                event.preventDefault();
                if (this._focusedIndex <= 0) {
                    this._focusedIndex = -1;
                    this.template.querySelector('input').focus();
                } else {
                    this._focusedIndex = this._focusedIndex - 1;
                }
                break;
            case 'Enter':
                event.preventDefault();
                if (this._focusedIndex >= 0 && this._focusedIndex < count) {
                    const res = this.icdResults[this._focusedIndex];
                    this._commitSelection(res.code, res.description);
                }
                break;
            case 'Escape':
                event.preventDefault();
                this.icdResults = [];
                this._focusedIndex = -1;
                this._resultsReady = false;
                this._dropdownDismissed = true;
                break;
        }
    }

    handleClear() {
        this.searchTerm = '';
        this.selectedCode = '';
        this.icdResults = [];
        this._resultsReady = false;
        this.isSelected = false;
        this.searchError = '';
        this._dropdownDismissed = false;
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedCode', ''));
        this.template.querySelector('input').focus();
    }

    handleOptionMousedown(event) {
        event.preventDefault();
    }

    handleSelect(event) {
        const code = event.currentTarget.dataset.code;
        const description = event.currentTarget.dataset.description;
        this._commitSelection(code, description);
    }

    _commitSelection(code, description) {
        this.searchError = '';
        this.selectedCode = `${code}: ${description}`;
        this.searchTerm = this.selectedCode;
        this.icdResults = [];
        this._focusedIndex = -1;
        this._resultsReady = false;
        this.isSelected = true;
        this.validationError = '';
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedCode', this.selectedCode));
    }
}
