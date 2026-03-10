import { createElement } from 'lwc';
import { registerLdsTestWireAdapter } from '@salesforce/wire-service-jest-util';
import PrintableRelatedList from 'c/printableRelatedList';
import { getRelatedListsInfo } from 'lightning/uiRelatedListApi';

const getRelatedListsInfoAdapter = registerLdsTestWireAdapter(getRelatedListsInfo);

const MOCK_RELATED_LISTS_DATA = {
    relatedLists: [
        { label: 'Contacts', listReference: { relatedListId: 'Contacts' } },
        { label: 'Opportunities', listReference: { relatedListId: 'Opportunities' } }
    ]
};

function createComponent(props = {}) {
    const el = createElement('c-printable-related-list', { is: PrintableRelatedList });
    Object.assign(el, { recordId: '001000000000001AAA', objectApiName: 'Account', ...props });
    document.body.appendChild(el);
    return el;
}

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
});

describe('printableRelatedList', () => {
    describe('loading state', () => {
        it('shows a spinner while wire is loading', () => {
            const el = createComponent();
            // Wire has not emitted yet — still loading
            const spinner = el.shadowRoot.querySelector('lightning-spinner');
            expect(spinner).not.toBeNull();
        });

        it('hides spinner once data arrives', async () => {
            const el = createComponent();
            getRelatedListsInfoAdapter.emit(MOCK_RELATED_LISTS_DATA);
            await Promise.resolve();
            expect(el.shadowRoot.querySelector('lightning-spinner')).toBeNull();
        });
    });

    describe('error state', () => {
        it('shows an error message when wire returns an error', async () => {
            const el = createComponent();
            getRelatedListsInfoAdapter.error({ body: { message: 'Not authorized' } });
            await Promise.resolve();
            const richText = el.shadowRoot.querySelector('lightning-formatted-rich-text');
            expect(richText).not.toBeNull();
            expect(richText.value).toContain('Not authorized');
        });

        it('does not show the picker when wire errors', async () => {
            const el = createComponent();
            getRelatedListsInfoAdapter.error({ body: { message: 'error' } });
            await Promise.resolve();
            expect(el.shadowRoot.querySelector('c-related-list-picker')).toBeNull();
        });
    });

    describe('empty state', () => {
        it('shows a no-related-lists message when the list is empty', async () => {
            const el = createComponent();
            getRelatedListsInfoAdapter.emit({ relatedLists: [] });
            await Promise.resolve();
            expect(el.shadowRoot.querySelector('p').textContent).toContain('no related lists available');
        });
    });

    describe('picker step', () => {
        it('renders the picker after data loads', async () => {
            const el = createComponent();
            getRelatedListsInfoAdapter.emit(MOCK_RELATED_LISTS_DATA);
            await Promise.resolve();
            expect(el.shadowRoot.querySelector('c-related-list-picker')).not.toBeNull();
        });

        it('passes relatedLists to the picker', async () => {
            const el = createComponent();
            getRelatedListsInfoAdapter.emit(MOCK_RELATED_LISTS_DATA);
            await Promise.resolve();
            const picker = el.shadowRoot.querySelector('c-related-list-picker');
            expect(picker.relatedLists).toHaveLength(2);
        });

        it('does not show the table before a list is selected', async () => {
            const el = createComponent();
            getRelatedListsInfoAdapter.emit(MOCK_RELATED_LISTS_DATA);
            await Promise.resolve();
            expect(el.shadowRoot.querySelector('c-related-list-table')).toBeNull();
        });
    });

    describe('table step', () => {
        async function setupWithSelection(relatedListId = 'Contacts') {
            const el = createComponent();
            getRelatedListsInfoAdapter.emit(MOCK_RELATED_LISTS_DATA);
            await Promise.resolve();
            const picker = el.shadowRoot.querySelector('c-related-list-picker');
            picker.dispatchEvent(
                new CustomEvent('relatedlistselect', { detail: { relatedListId } })
            );
            await Promise.resolve();
            return el;
        }

        it('shows the table after a list is selected', async () => {
            const el = await setupWithSelection();
            expect(el.shadowRoot.querySelector('c-related-list-table')).not.toBeNull();
        });

        it('hides the picker once a list is selected', async () => {
            const el = await setupWithSelection();
            expect(el.shadowRoot.querySelector('c-related-list-picker')).toBeNull();
        });

        it('passes the correct relatedListId to the table', async () => {
            const el = await setupWithSelection('Opportunities');
            const table = el.shadowRoot.querySelector('c-related-list-table');
            expect(table.relatedListId).toBe('Opportunities');
        });

        it('passes recordId and objectApiName to the table', async () => {
            const el = await setupWithSelection();
            const table = el.shadowRoot.querySelector('c-related-list-table');
            expect(table.recordId).toBe('001000000000001AAA');
            expect(table.objectApiName).toBe('Account');
        });

        it('returns to picker when goback event fires from table', async () => {
            const el = await setupWithSelection();
            const table = el.shadowRoot.querySelector('c-related-list-table');
            table.dispatchEvent(new CustomEvent('goback'));
            await Promise.resolve();
            expect(el.shadowRoot.querySelector('c-related-list-picker')).not.toBeNull();
            expect(el.shadowRoot.querySelector('c-related-list-table')).toBeNull();
        });
    });

    describe('cancel button', () => {
        it('renders a Cancel button', async () => {
            const el = createComponent();
            getRelatedListsInfoAdapter.emit(MOCK_RELATED_LISTS_DATA);
            await Promise.resolve();
            const btns = el.shadowRoot.querySelectorAll('lightning-button');
            const cancelBtn = Array.from(btns).find((b) => b.label === 'Cancel');
            expect(cancelBtn).not.toBeNull();
        });

        it('dispatches CloseActionScreenEvent when Cancel is clicked', async () => {
            const el = createComponent();
            getRelatedListsInfoAdapter.emit(MOCK_RELATED_LISTS_DATA);
            await Promise.resolve();

            const handler = jest.fn();
            el.addEventListener('closeactionscreen', handler);

            const btns = el.shadowRoot.querySelectorAll('lightning-button');
            const cancelBtn = Array.from(btns).find((b) => b.label === 'Cancel');
            cancelBtn.click();
            await Promise.resolve();

            expect(handler).toHaveBeenCalledTimes(1);
        });
    });
});
