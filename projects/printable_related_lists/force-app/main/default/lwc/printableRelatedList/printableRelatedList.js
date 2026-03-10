import { LightningElement, api, wire, track } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { getRelatedListsInfo } from 'lightning/uiRelatedListApi';

export default class PrintableRelatedList extends LightningElement {
    @api recordId;
    @api objectApiName;

    @track selectedRelatedListId = null;
    @track relatedLists = [];
    @track wireError = null;
    @track isWireLoading = true;

    // Required by the LWC Quick Action contract
    @api invoke() {}

    @wire(getRelatedListsInfo, { parentObjectApiName: '$objectApiName' })
    wiredRelatedListsInfo({ data, error }) {
        this.isWireLoading = false;
        if (data) {
            this.relatedLists = data.relatedLists;
            this.wireError = null;
        } else if (error) {
            this.wireError = error;
            this.relatedLists = [];
        }
    }

    get isLoading() {
        return this.isWireLoading;
    }

    get hasError() {
        return !this.isWireLoading && !!this.wireError;
    }

    get hasNoRelatedLists() {
        return !this.isWireLoading && !this.wireError && this.relatedLists.length === 0;
    }

    get showPicker() {
        return !this.isWireLoading && !this.wireError && this.relatedLists.length > 0 && !this.selectedRelatedListId;
    }

    get showTable() {
        return !this.isWireLoading && !this.wireError && !!this.selectedRelatedListId;
    }

    get errorMessage() {
        if (!this.wireError) return '';
        const msg = this.wireError.body?.message || this.wireError.message || 'Unknown error';
        return `<p><strong>Error loading related lists:</strong> ${msg}</p>`;
    }

    handleRelatedListSelect(event) {
        this.selectedRelatedListId = event.detail.relatedListId;
    }

    handleGoBack() {
        this.selectedRelatedListId = null;
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }
}
