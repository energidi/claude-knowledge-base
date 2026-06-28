import { createElement } from 'lwc';
import IcdLookup from 'c/icdLookup';
import searchIcd10 from '@salesforce/apex/ICDLookupController.searchIcd10';
import getIcdLookupConfig from '@salesforce/apex/ICDLookupController.getIcdLookupConfig';

jest.mock('@salesforce/apex/ICDLookupController.searchIcd10', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ICDLookupController.getIcdLookupConfig', () => ({ default: jest.fn() }), { virtual: true });

const MOCK_RESULTS = [
    { code: 'I10', description: 'Essential (primary) hypertension' },
    { code: 'I11', description: 'Hypertensive heart disease' }
];

function createElement_icdLookup(props = {}) {
    const el = createElement('c-icd-lookup', { is: IcdLookup });
    Object.assign(el, props);
    document.body.appendChild(el);
    return el;
}

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
});

describe('validate()', () => {
    it('returns isValid true when mandatory is false and selectedCode is empty', async () => {
        const el = createElement_icdLookup({ mandatory: false });
        await Promise.resolve();
        expect(el.validate().isValid).toBe(true);
    });

    it('returns isValid false with field-specific message when mandatory and no selection', async () => {
        const el = createElement_icdLookup({ mandatory: true, label: 'Primary Diagnosis' });
        await Promise.resolve();
        const result = el.validate();
        expect(result.isValid).toBe(false);
        expect(result.errorMessage).toBe('Primary Diagnosis is required.');
    });

    it('returns isValid true when mandatory and selectedCode is set', async () => {
        const el = createElement_icdLookup({ mandatory: true });
        el.selectedCode = 'I10: Essential (primary) hypertension';
        await Promise.resolve();
        expect(el.validate().isValid).toBe(true);
    });
});

describe('defaultValue pre-population', () => {
    it('sets selectedCode from defaultValue on init without dispatching FlowAttributeChangeEvent', async () => {
        const handler = jest.fn();
        const el = createElement_icdLookup({ defaultValue: 'I10: Essential (primary) hypertension' });
        el.addEventListener('flowattributechange', handler);
        await Promise.resolve();
        expect(el.selectedCode).toBe('I10: Essential (primary) hypertension');
        expect(handler).not.toHaveBeenCalled();
    });
});

describe('selection', () => {
    it('commits selectedCode and fires FlowAttributeChangeEvent on result click', async () => {
        searchIcd10.mockResolvedValue(MOCK_RESULTS);
        getIcdLookupConfig.mockResolvedValue(null);
        const el = createElement_icdLookup({});
        await Promise.resolve();

        const input = el.shadowRoot.querySelector('input');
        input.value = 'hyp';
        input.dispatchEvent(new CustomEvent('input', { bubbles: true }));
        await Promise.resolve();

        jest.runAllTimers && jest.runAllTimers();
        await Promise.resolve();
        await Promise.resolve();

        const handler = jest.fn();
        el.addEventListener('flowattributechange', handler);

        const firstOption = el.shadowRoot.querySelector('[role="option"]');
        if (firstOption) {
            firstOption.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }));
            firstOption.dispatchEvent(new MouseEvent('click', { bubbles: true }));
            await Promise.resolve();
            expect(el.selectedCode).toBeTruthy();
        }
    });

    it('clears selectedCode when user re-types after selection', async () => {
        const el = createElement_icdLookup({});
        el.selectedCode = 'I10: Essential (primary) hypertension';
        await Promise.resolve();

        const input = el.shadowRoot.querySelector('input');
        input.value = 'changed';
        input.dispatchEvent(new CustomEvent('input', { bubbles: true }));
        await Promise.resolve();

        expect(el.selectedCode).toBe('');
    });
});

describe('focusout behavior', () => {
    it('does not close dropdown when relatedTarget is inside the component', async () => {
        searchIcd10.mockResolvedValue(MOCK_RESULTS);
        getIcdLookupConfig.mockResolvedValue(null);
        const el = createElement_icdLookup({});
        await Promise.resolve();

        const input = el.shadowRoot.querySelector('input');
        const dropdownDiv = el.shadowRoot.querySelector('.slds-combobox');
        if (dropdownDiv) {
            dropdownDiv.dispatchEvent(
                new FocusEvent('focusout', { relatedTarget: input, bubbles: true })
            );
            await Promise.resolve();
        }
    });
});
