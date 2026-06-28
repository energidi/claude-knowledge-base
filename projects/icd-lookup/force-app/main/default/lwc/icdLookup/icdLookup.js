import { LightningElement, track, api } from 'lwc';
import searchICD10 from '@salesforce/apex/ICDLookupController.searchICD10';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';

export default class IcdLookup extends LightningElement {
    @track searchKey = '';
    @track searchResults = [];
    @track isLoading = false; // Controls the spinner
    @api selectedCode = '';
    
    delayTimeout;

    get dropdownClass() {
        // Show dropdown if there are results OR if we are explicitly showing the "No Results" message
        return (this.searchResults.length > 0 || this.showNoResults) 
            ? 'slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click slds-is-open' 
            : 'slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click';
    }

    get showNoResults() {
        return this.searchKey.length >= 3 && !this.isLoading && this.searchResults.length === 0;
    }

    handleSearchChange(event) {
        this.searchKey = event.target.value;
        window.clearTimeout(this.delayTimeout);

        if (this.searchKey.length >= 3) {
            this.isLoading = true; // Start the spinner
            this.delayTimeout = setTimeout(() => {
                this.fetchData();
            }, 400); // Slightly longer debounce for better API efficiency
        } else {
            this.searchResults = [];
            this.isLoading = false;
        }
    }

    fetchData() {
        searchICD10({ searchTerm: this.searchKey })
            .then(result => {
                this.searchResults = result;
            })
            .catch(error => {
                console.error('Lookup Error:', error);
            })
            .finally(() => {
                this.isLoading = false; // Always stop the spinner
            });
    }

    handleSelect(event) {
        const code = event.currentTarget.dataset.code;
        const desc = event.currentTarget.dataset.desc;
        this.selectedCode = `${code}: ${desc}`;
        this.searchKey = this.selectedCode;
        this.searchResults = [];
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedCode', this.selectedCode));
    }
}