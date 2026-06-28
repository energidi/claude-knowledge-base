import { LightningElement, api } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';

export default class RecordChoiceSelector extends LightningElement {
    @api label;
    @api helpText;
    @api selectionMode = 'Checkbox';
    @api inputRecords = [];
    @api displayField = 'Name';
    @api outputField1ApiName;
    @api outputField2ApiName;
    @api isRequired = false;
    @api defaultValue;

    @api selectedRecordId;
    @api outputFieldValue1;
    @api outputFieldValue2;

    connectedCallback() {
        if (!this.defaultValue) return;
        if (!this.inputRecords || !Array.isArray(this.inputRecords)) return;

        const matchedRecord = this.inputRecords.find(rec => rec.Id === this.defaultValue);
        if (!matchedRecord) return;

        this.selectedRecordId = this.defaultValue;
        this.updateOutputValues(this.defaultValue);
        this.notifyFlow();
    }

    get isRadio() {
        return this.selectionMode && this.selectionMode.toLowerCase() === 'radio';
    }

    get inputType() {
        return this.isRadio ? 'radio' : 'checkbox';
    }

    get wrapperClass() {
        return this.isRadio ? 'slds-radio' : 'slds-checkbox';
    }

    get showEmptyMessage() {
        return !this.inputRecords || !Array.isArray(this.inputRecords) || this.inputRecords.length === 0;
    }

    get options() {
        if (this.showEmptyMessage) return [];

        return this.inputRecords.map(record => {
            const isSelected = record.Id === this.selectedRecordId;
            return {
                id: record.Id,
                label: record[this.displayField],
                checked: isSelected,
                disabled: !this.isRadio && !!this.selectedRecordId && !isSelected
            };
        });
    }

    handleCheckboxChange(event) {
        const selectedId = event.target.dataset.id;
        if (event.target.checked) {
            this.selectedRecordId = selectedId;
            this.updateOutputValues(selectedId);
        } else {
            this.resetSelection();
        }
        this.notifyFlow();
    }

    updateOutputValues(recordId) {
        const selectedRecord = this.inputRecords.find(rec => rec.Id === recordId);
        if (selectedRecord) {
            if (this.outputField1ApiName) this.outputFieldValue1 = selectedRecord[this.outputField1ApiName];
            if (this.outputField2ApiName) this.outputFieldValue2 = selectedRecord[this.outputField2ApiName];
        }
    }

    resetSelection() {
        this.selectedRecordId = null;
        this.outputFieldValue1 = null;
        this.outputFieldValue2 = null;
    }

    notifyFlow() {
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedRecordId', this.selectedRecordId));
        this.dispatchEvent(new FlowAttributeChangeEvent('outputFieldValue1', this.outputFieldValue1));
        this.dispatchEvent(new FlowAttributeChangeEvent('outputFieldValue2', this.outputFieldValue2));
    }

    @api
    validate() {
        if (this.isRequired && !this.selectedRecordId) {
            return { isValid: false, errorMessage: 'Please make a selection to continue.' };
        }
        return { isValid: true };
    }
}
