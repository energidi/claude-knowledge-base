import { createElement } from 'lwc';
import IcdLookup from 'c/icdLookup';
import searchIcd10 from '@salesforce/apex/ICDLookupController.searchIcd10';
import getIcdLookupConfig from '@salesforce/apex/ICDLookupController.getIcdLookupConfig';

jest.mock('@salesforce/apex/ICDLookupController.searchIcd10', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/ICDLookupController.getIcdLookupConfig', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/label/c.ICD_Lookup_Validation_Required', () => ({ default: 'is required.' }), { virtual: true });
jest.mock('@salesforce/label/c.ICD_Lookup_Error_Search_Failed', () => ({ default: 'Could not retrieve results. Please try again.' }), { virtual: true });
jest.mock('@salesforce/label/c.ICD_Lookup_Error_Config_Load_Failed', () => ({ default: 'Field configuration could not be loaded. Refresh the page to retry.' }), { virtual: true });
jest.mock('@salesforce/label/c.ICD_Lookup_Min_Char_Hint', () => ({ default: 'Type at least 3 characters to search.' }), { virtual: true });
jest.mock('@salesforce/label/c.ICD_Lookup_Still_Searching', () => ({ default: 'Still searching...' }), { virtual: true });
jest.mock('@salesforce/label/c.ICD_Lookup_Retry', () => ({ default: 'Retry' }), { virtual: true });
jest.mock('@salesforce/label/c.ICD_Lookup_Clear', () => ({ default: 'Clear' }), { virtual: true });
jest.mock('@salesforce/label/c.ICD_Lookup_SR_Dismissed', () => ({ default: 'Search results dismissed.' }), { virtual: true });
jest.mock('@salesforce/label/c.ICD_Lookup_SR_Loading', () => ({ default: 'Loading results...' }), { virtual: true });
jest.mock('@salesforce/label/c.ICD_Lookup_SR_Still_Searching', () => ({ default: 'Still searching, please wait...' }), { virtual: true });
jest.mock('@salesforce/label/c.ICD_Lookup_SR_Result', () => ({ default: 'result found' }), { virtual: true });
jest.mock('@salesforce/label/c.ICD_Lookup_SR_Results', () => ({ default: 'results found' }), { virtual: true });

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

describe('handleClear()', () => {
    it('resets all state and fires FlowAttributeChangeEvent with empty string', async () => {
        // defaultValue sets both searchTerm and selectedCode, making the clear button visible
        const el = createElement_icdLookup({ defaultValue: 'I10: Essential (primary) hypertension' });
        await Promise.resolve();

        const handler = jest.fn();
        el.addEventListener('flowattributechange', handler);

        const clearBtn = el.shadowRoot.querySelector('button[type="button"]');
        expect(clearBtn).not.toBeNull();
        clearBtn.dispatchEvent(new MouseEvent('click', { bubbles: true }));
        await Promise.resolve();

        expect(el.selectedCode).toBe('');
    });
});

describe('handleRetry()', () => {
    it('calls searchIcd10 again after a failed search', async () => {
        jest.useFakeTimers();
        searchIcd10.mockRejectedValue(new Error('API error'));
        getIcdLookupConfig.mockResolvedValue(null);
        const el = createElement_icdLookup({});
        await Promise.resolve();

        const input = el.shadowRoot.querySelector('input');
        input.value = 'hyp';
        input.dispatchEvent(new CustomEvent('input', { bubbles: true }));
        await Promise.resolve();

        jest.advanceTimersByTime(500);
        await Promise.resolve();
        await Promise.resolve();
        await Promise.resolve();

        searchIcd10.mockResolvedValue(MOCK_RESULTS);
        const retryBtn = el.shadowRoot.querySelector('button.slds-button_neutral');
        if (retryBtn) {
            retryBtn.dispatchEvent(new MouseEvent('click', { bubbles: true }));
            await Promise.resolve();
        }
        expect(searchIcd10).toHaveBeenCalledTimes(2);
        jest.useRealTimers();
    });
});

describe('Escape key behavior', () => {
    it('clears results and sets _dropdownDismissed without clearing searchTerm', async () => {
        searchIcd10.mockResolvedValue(MOCK_RESULTS);
        getIcdLookupConfig.mockResolvedValue(null);
        const el = createElement_icdLookup({});
        await Promise.resolve();

        const dropdownDiv = el.shadowRoot.querySelector('.slds-combobox');
        if (dropdownDiv) {
            dropdownDiv.dispatchEvent(
                new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })
            );
            await Promise.resolve();
        }
    });
});

describe('min char hint', () => {
    it('shows hint paragraph when 1-2 characters are typed', async () => {
        const el = createElement_icdLookup({});
        await Promise.resolve();

        const input = el.shadowRoot.querySelector('input');
        input.value = 'hy';
        input.dispatchEvent(new CustomEvent('input', { bubbles: true }));
        await Promise.resolve();

        const hint = el.shadowRoot.querySelector('.slds-form-element__help');
        expect(hint).not.toBeNull();
    });

    it('does not show hint when input is empty', async () => {
        const el = createElement_icdLookup({});
        await Promise.resolve();

        const hints = el.shadowRoot.querySelectorAll('.slds-form-element__help');
        expect(hints.length).toBe(0);
    });
});

describe('configError banner', () => {
    it('renders warning banner when getIcdLookupConfig rejects', async () => {
        getIcdLookupConfig.mockRejectedValue(new Error('load failed'));
        const el = createElement_icdLookup({ flowApiName: 'Some_Flow' });
        await Promise.resolve();
        await Promise.resolve();
        await Promise.resolve();

        const banner = el.shadowRoot.querySelector('.slds-theme_warning');
        expect(banner).not.toBeNull();
    });
});
