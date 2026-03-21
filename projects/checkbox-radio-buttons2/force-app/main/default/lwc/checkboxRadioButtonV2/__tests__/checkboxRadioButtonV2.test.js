import { createElement } from 'lwc';
import CheckboxRadioButtonV2 from 'c/checkboxRadioButtonV2';

jest.mock(
    'lightning/flowSupport',
    () => ({
        FlowAttributeChangeEvent: class FlowAttributeChangeEvent extends CustomEvent {
            constructor(name, value) {
                super('FlowAttributeChange', { bubbles: true });
                this.attributeName = name;
                this.value = value;
            }
        }
    }),
    { virtual: true }
);

const MOCK_RECORDS = [
    { Id: 'rec001', Name: 'Option A', Status__c: 'Active' },
    { Id: 'rec002', Name: 'Option B', Status__c: 'Inactive' },
    { Id: 'rec003', Name: 'Option C', Status__c: 'Active' }
];

describe('c-checkbox-radio-button-v2', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    // --- POSITIVE ---

    it('applies default when inputRecords arrive after defaultValue', async () => {
        const element = createElement('c-checkbox-radio-button-v2', { is: CheckboxRadioButtonV2 });
        element.defaultValue = 'rec002';
        document.body.appendChild(element);

        element.inputRecords = MOCK_RECORDS;
        await Promise.resolve();

        expect(element.selectedRecordId).toBe('rec002');
    });

    it('applies default when defaultValue arrives after inputRecords', async () => {
        const element = createElement('c-checkbox-radio-button-v2', { is: CheckboxRadioButtonV2 });
        element.inputRecords = MOCK_RECORDS;
        document.body.appendChild(element);

        element.defaultValue = 'rec001';
        await Promise.resolve();

        expect(element.selectedRecordId).toBe('rec001');
    });

    it('dispatches FlowAttributeChangeEvent for all three output properties when default is applied', async () => {
        const element = createElement('c-checkbox-radio-button-v2', { is: CheckboxRadioButtonV2 });
        element.defaultValue = 'rec001';
        document.body.appendChild(element);

        const dispatchSpy = jest.spyOn(element, 'dispatchEvent');
        element.inputRecords = MOCK_RECORDS;
        await Promise.resolve();

        const dispatched = dispatchSpy.mock.calls.map(call => call[0].attributeName);
        expect(dispatched).toContain('selectedRecordId');
        expect(dispatched).toContain('outputValue1');
        expect(dispatched).toContain('outputValue2');
    });

    // --- NEGATIVE ---

    it('does not apply default when defaultValue is not found in inputRecords', async () => {
        const element = createElement('c-checkbox-radio-button-v2', { is: CheckboxRadioButtonV2 });
        element.defaultValue = 'rec999';
        document.body.appendChild(element);

        element.inputRecords = MOCK_RECORDS;
        await Promise.resolve();

        expect(element.selectedRecordId).toBeUndefined();
    });

    it('does not apply default when inputRecords is empty', async () => {
        const element = createElement('c-checkbox-radio-button-v2', { is: CheckboxRadioButtonV2 });
        element.defaultValue = 'rec001';
        document.body.appendChild(element);

        element.inputRecords = [];
        await Promise.resolve();

        expect(element.selectedRecordId).toBeUndefined();
    });

    it('does not apply default when defaultValue is not set', async () => {
        const element = createElement('c-checkbox-radio-button-v2', { is: CheckboxRadioButtonV2 });
        document.body.appendChild(element);

        element.inputRecords = MOCK_RECORDS;
        await Promise.resolve();

        expect(element.selectedRecordId).toBeUndefined();
    });

    // --- EDGE ---

    it('does not re-dispatch events when default is already applied and inputRecords is re-set', async () => {
        const element = createElement('c-checkbox-radio-button-v2', { is: CheckboxRadioButtonV2 });
        element.defaultValue = 'rec001';
        element.inputRecords = MOCK_RECORDS;
        document.body.appendChild(element);
        await Promise.resolve();

        const dispatchSpy = jest.spyOn(element, 'dispatchEvent');
        element.inputRecords = [...MOCK_RECORDS];
        await Promise.resolve();

        expect(dispatchSpy).not.toHaveBeenCalled();
    });

    it('does not overwrite user selection when inputRecords reload', async () => {
        const element = createElement('c-checkbox-radio-button-v2', { is: CheckboxRadioButtonV2 });
        element.label = 'Choose one';
        element.defaultValue = 'rec001';
        element.inputRecords = MOCK_RECORDS;
        document.body.appendChild(element);
        await Promise.resolve();

        // Simulate user picking a different option
        const input = element.shadowRoot.querySelector('input');
        input.dataset.id = 'rec003';
        input.checked = true;
        input.dispatchEvent(new CustomEvent('change', { bubbles: true }));
        await Promise.resolve();

        // Records reload - default must not overwrite user pick
        element.inputRecords = [...MOCK_RECORDS];
        await Promise.resolve();

        expect(element.selectedRecordId).toBe('rec003');
    });

    it('handles null inputRecords without throwing', () => {
        const element = createElement('c-checkbox-radio-button-v2', { is: CheckboxRadioButtonV2 });
        element.defaultValue = 'rec001';
        document.body.appendChild(element);

        expect(() => {
            element.inputRecords = null;
        }).not.toThrow();
    });

    // --- VALIDATE ---

    it('validate() returns false when label is missing', () => {
        const element = createElement('c-checkbox-radio-button-v2', { is: CheckboxRadioButtonV2 });
        document.body.appendChild(element);

        const result = element.validate();

        expect(result.isValid).toBe(false);
        expect(result.errorMessage).toBeTruthy();
    });

    it('validate() returns false when required and nothing selected', () => {
        const element = createElement('c-checkbox-radio-button-v2', { is: CheckboxRadioButtonV2 });
        element.label = 'Choose one';
        element.isRequired = true;
        document.body.appendChild(element);

        const result = element.validate();

        expect(result.isValid).toBe(false);
        expect(result.errorMessage).toBeTruthy();
    });

    it('validate() returns true when required and default selection applied', async () => {
        const element = createElement('c-checkbox-radio-button-v2', { is: CheckboxRadioButtonV2 });
        element.label = 'Choose one';
        element.isRequired = true;
        element.defaultValue = 'rec001';
        element.inputRecords = MOCK_RECORDS;
        document.body.appendChild(element);
        await Promise.resolve();

        const result = element.validate();

        expect(result.isValid).toBe(true);
    });

    it('validate() returns true when not required and nothing selected', () => {
        const element = createElement('c-checkbox-radio-button-v2', { is: CheckboxRadioButtonV2 });
        element.label = 'Choose one';
        element.isRequired = false;
        document.body.appendChild(element);

        const result = element.validate();

        expect(result.isValid).toBe(true);
    });
});
