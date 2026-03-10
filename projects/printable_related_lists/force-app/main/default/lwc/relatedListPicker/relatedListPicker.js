import { LightningElement, api, track } from 'lwc';

export default class RelatedListPicker extends LightningElement {
    @api relatedLists = [];
    @track selectedValue = '';

    get comboboxOptions() {
        return this.relatedLists.map((list) => ({
            label: list.label,
            value: list.listReference.relatedListId
        }));
    }

    get isPreviewDisabled() {
        return !this.selectedValue;
    }

    handleChange(event) {
        this.selectedValue = event.detail.value;
    }

    handlePreview() {
        if (!this.selectedValue) return;
        this.dispatchEvent(
            new CustomEvent('relatedlistselect', {
                detail: { relatedListId: this.selectedValue }
            })
        );
    }
}
