import { LightningElement, api } from 'lwc';
import { FlowAttributeChangeEvent } from 'lightning/flowSupport';

export default class CheckboxRadioButtonV2 extends LightningElement {
    @api label;
    @api helpText;
    @api styleOption = 'Checkbox';
    @api displayField = 'Name';
    @api field1API;
    @api field2API;
    @api isRequired = false;

    @api selectedRecordId;
    @api outputValue1;
    @api outputValue2;

    _inputRecords = [];
    _defaultValue;
    _userHasSelected = false;

    @api
    get inputRecords() {
        return this._inputRecords;
    }
    set inputRecords(val) {
        this._inputRecords = val ?? [];
        this._applyDefault();
    }

    @api
    get defaultValue() {
        return this._defaultValue;
    }
    set defaultValue(val) {
        this._defaultValue = val;
        this._applyDefault();
    }

    _applyDefault() {
        if (!this._defaultValue || !this._inputRecords?.length) return;
        if (this._userHasSelected) return;
        if (this.selectedRecordId === this._defaultValue) return;
        const match = this._inputRecords.find(r => r.Id === this._defaultValue);
        if (!match) return;
        this.selectedRecordId = this._defaultValue;
        this.updateOutputValues(this._defaultValue);
        this.notifyFlow();
    }

    get isRadio() {
        return this.styleOption && this.styleOption.toLowerCase() === 'radio';
    }

    get wrapperClass() {
        return this.isRadio ? 'slds-radio' : 'slds-checkbox';
    }

    get showEmptyMessage() {
        return !this._inputRecords || !Array.isArray(this._inputRecords) || this._inputRecords.length === 0;
    }

    get options() {
        if (this.showEmptyMessage) return [];

        return this._inputRecords.map(record => {
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
        this._userHasSelected = true;
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
        const selectedRecord = this._inputRecords.find(rec => rec.Id === recordId);
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
