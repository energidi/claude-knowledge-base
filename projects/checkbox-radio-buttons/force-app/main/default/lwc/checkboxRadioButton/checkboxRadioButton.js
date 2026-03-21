import { LightningElement, api } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';

export default class CheckboxRadioButton extends LightningElement {
    @api label;
    @api helpText;
    @api styleOption = 'Checkbox'; 
    @api inputRecords = [];
    @api displayField = 'Name';
    @api field1API;
    @api field2API;
    @api isRequired = false;
    @api defaultValue;

    @api selectedRecordId;
    @api outputValue1;
    @api outputValue2;

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
        return this.styleOption && this.styleOption.toLowerCase() === 'radio';
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
                disabled: (!!this.selectedRecordId && !isSelected)
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
            if (this.field1API) this.outputValue1 = selectedRecord[this.field1API];
            if (this.field2API) this.outputValue2 = selectedRecord[this.field2API];
        }
    }

    resetSelection() {
        this.selectedRecordId = null;
        this.outputValue1 = null;
        this.outputValue2 = null;
    }

    notifyFlow() {
        this.dispatchEvent(new FlowAttributeChangeEvent('selectedRecordId', this.selectedRecordId));
        this.dispatchEvent(new FlowAttributeChangeEvent('outputValue1', this.outputValue1));
        this.dispatchEvent(new FlowAttributeChangeEvent('outputValue2', this.outputValue2));
    }

    @api
    validate() {
        if (!this.label) {
            return { isValid: false, errorMessage: 'Please provide a label for this component.' };
        }
        if (this.isRequired && !this.selectedRecordId) {
            return { isValid: false, errorMessage: 'Please select an option to continue.' };
        }
        return { isValid: true };
    }
}