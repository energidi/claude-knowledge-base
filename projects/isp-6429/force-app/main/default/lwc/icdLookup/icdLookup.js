import { LightningElement, api } from 'lwc';
import searchIcd10 from '@salesforce/apex/ICDLookupController.searchIcd10';
import getIcdLookupConfig from '@salesforce/apex/ICDLookupController.getIcdLookupConfig';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';

export default class IcdLookup extends LightningElement {
    @api label = 'ICD-10 Diagnosis';
    @api automationApiName;
    @api mandatory = false;
    @api defaultValue;
    @api tooltip;
    @api noResultsMessage = 'No matching codes found.';
    @api fieldPlaceholder = "Search by code or description (e.g. 'Hypertension')";
    @api selectedCode;

    searchTerm = '';
    icdResults = [];
    isLoading = false;
    errorMessage = '';
    isSelected = false;
    validationError = '';
    searchDebounceTimer;
    _handleOutsideClick;
    _focusedIndex = -1;
    _searchCompleted = false;

    connectedCallback() {
        this._handleOutsideClick = (event) => {
            if (!this.template.contains(event.target)) {
                this.icdResults = [];
                this._searchCompleted = false;
                this._focusedIndex = -1;
            }
        };
        document.addEventListener('click', this._handleOutsideClick);

        if (this.defaultValue) {
            this.selectedCode = this.defaultValue;
            this.searchTerm = this.defaultValue;
            this.isSelected = true;
            this.dispatchEvent(new FlowAttributeChangeEvent('selectedCode', this.selectedCode));
        }

        if (this.automationApiName) {
            getIcdLookupConfig({ automationApiName: this.automationApiName })
                .then(config => {
                    if (config) {
                        if (config.Field_Label__c) this.label = config.Field_Label__c;
                        if (config.Field_Placeholder__c) this.fieldPlaceholder = config.Field_Placeholder__c;
                        if (config.No_Matching_Codes_Found_Message__c) this.noResultsMessage = config.No_Matching_Codes_Found_Message__c;
                        if (config.Tooltip__c) this.tooltip = config.Tooltip__c;
                        this.mandatory = config.Mandatory__c;
                    }
                })
                .catch(error => {
                    console.error('Config load error:', error);
                });
        }
    }

    disconnectedCallback() {
        clearTimeout(this.searchDebounceTimer);
        document.removeEventListener('click', this._handleOutsideClick);
    }

    @api validate() {
        if (this.mandatory && !this.selectedCode) {
            this.validationError = 'This field is required.';
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
            isActive: index === this._focusedIndex
        }));
    }

    get activeDescendant() {
        return this._focusedIndex >= 0 ? `icd-option-${this._focusedIndex}` : '';
    }

    get dropdownClass() {
        return (this.icdResults.length > 0 || this.showNoResults)
            ? 'slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click slds-is-open'
            : 'slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click';
    }

    get comboboxContainerClass() {
        return this.isSelected ? 'slds-combobox_container selection-confirmed' : 'slds-combobox_container';
    }

    get formElementClass() {
        return (this.validationError || this.errorMessage)
            ? 'slds-form-element slds-has-error'
            : 'slds-form-element';
    }

    get showNoResults() {
        return this._searchCompleted && this.searchTerm.length >= 3 && !this.isLoading && this.icdResults.length === 0 && !this.errorMessage && !this.isSelected;
    }

    get isOpen() {
        return this.icdResults.length > 0 || this.showNoResults;
    }

    get displayError() {
        return this.validationError || this.errorMessage;
    }

    get screenReaderStatus() {
        if (this.isLoading) return 'Loading results...';
        if (this.errorMessage) return this.errorMessage;
        if (this.showNoResults) return this.noResultsMessage;
        if (this.icdResults.length > 0) {
            return `${this.icdResults.length} result${this.icdResults.length === 1 ? '' : 's'} found`;
        }
        return '';
    }

    handleSearchChange(event) {
        this.searchTerm = event.target.value;
        if (this.searchTerm !== this.selectedCode) {
            this.selectedCode = '';
            this.dispatchEvent(new FlowAttributeChangeEvent('selectedCode', ''));
        }
        this.errorMessage = '';
        this.isSelected = false;
        this.validationError = '';
        this._focusedIndex = -1;
        this._searchCompleted = false;
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
        searchIcd10({ searchTerm: this.searchTerm })
            .then(result => {
                this.icdResults = result;
            })
            .catch(error => {
                this.errorMessage = error.body?.message || 'Lookup failed. Please try again.';
                this.icdResults = [];
            })
            .finally(() => {
                this.isLoading = false;
                this._searchCompleted = true;
            });
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
                this._focusedIndex = Math.max(this._focusedIndex - 1, 0);
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
                this._searchCompleted = false;
                break;
        }
    }

    handleSelect(event) {
        const code = event.currentTarget.dataset.code;
        const desc = event.currentTarget.dataset.desc;
        this._commitSelection(code, desc);
    }

    _commitSelection(code, desc) {
        this.selectedCode = `${code}: ${desc}`;
        this.searchTerm = this.selectedCode;
        this.icdResults = [];
        this._focusedIndex = -1;
        this._searchCompleted = false;
        this.isSelected = true;
        this.validationError = '';
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedCode', this.selectedCode));
    }
}
