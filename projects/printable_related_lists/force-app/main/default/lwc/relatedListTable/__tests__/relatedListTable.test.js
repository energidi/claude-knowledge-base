import { createElement } from 'lwc';
import { registerLdsTestWireAdapter } from '@salesforce/wire-service-jest-util';
import RelatedListTable from 'c/relatedListTable';
import { getRelatedListInfo, getRelatedListRecords } from 'lightning/uiRelatedListApi';

const getRelatedListInfoAdapter = registerLdsTestWireAdapter(getRelatedListInfo);
const getRelatedListRecordsAdapter = registerLdsTestWireAdapter(getRelatedListRecords);

// ─── Mock Data ──────────────────────────────────────────────────────────────

const MOCK_LIST_INFO = {
    label: 'Contacts',
    displayColumns: [
        { fieldApiName: 'Name', label: 'Name', dataType: 'String' },
        { fieldApiName: 'Email', label: 'Email', dataType: 'Email' },
        { fieldApiName: 'Phone', label: 'Phone', dataType: 'Phone' }
    ]
};

const MOCK_RECORDS = {
    records: [
        {
            id: '003000000000001AAA',
            fields: {
                Name: { value: 'John Smith' },
                Email: { value: 'john@example.com' },
                Phone: { value: '555-1234' }
            }
        },
        {
            id: '003000000000002AAA',
            fields: {
                Name: { value: 'Jane Doe' },
                Email: { value: 'jane@example.com' },
                Phone: { value: '555-5678' }
            }
        }
    ]
};

function buildMaxRecords() {
    return {
        records: Array.from({ length: 200 }, (_, i) => ({
            id: `003${String(i).padStart(15, '0')}AAA`,
            fields: { Name: { value: `Contact ${i}` }, Email: { value: '' }, Phone: { value: '' } }
        }))
    };
}

function createComponent(props = {}) {
    const el = createElement('c-related-list-table', { is: RelatedListTable });
    Object.assign(el, {
        recordId: '001000000000001AAA',
        objectApiName: 'Account',
        relatedListId: 'Contacts',
        ...props
    });
    document.body.appendChild(el);
    return el;
}

async function createLoadedComponent(recordsData = MOCK_RECORDS) {
    const el = createComponent();
    getRelatedListInfoAdapter.emit(MOCK_LIST_INFO);
    await Promise.resolve();
    getRelatedListRecordsAdapter.emit(recordsData);
    await Promise.resolve();
    return el;
}

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
    delete window.open;
});

// ─── Tests ───────────────────────────────────────────────────────────────────

describe('relatedListTable', () => {
    describe('loading state', () => {
        it('shows a spinner while list info is loading', () => {
            const el = createComponent();
            expect(el.shadowRoot.querySelector('lightning-spinner')).not.toBeNull();
        });

        it('hides the spinner once list info arrives', async () => {
            const el = createComponent();
            getRelatedListInfoAdapter.emit(MOCK_LIST_INFO);
            await Promise.resolve();
            expect(el.shadowRoot.querySelector('lightning-spinner')).toBeNull();
        });
    });

    describe('error state', () => {
        it('shows error when getRelatedListInfo fails', async () => {
            const el = createComponent();
            getRelatedListInfoAdapter.error({ body: { message: 'List not found' } });
            await Promise.resolve();
            const richText = el.shadowRoot.querySelector('lightning-formatted-rich-text');
            expect(richText).not.toBeNull();
            expect(richText.value).toContain('List not found');
        });

        it('shows error when getRelatedListRecords fails', async () => {
            const el = createComponent();
            getRelatedListInfoAdapter.emit(MOCK_LIST_INFO);
            await Promise.resolve();
            getRelatedListRecordsAdapter.error({ body: { message: 'Access denied' } });
            await Promise.resolve();
            const richText = el.shadowRoot.querySelector('lightning-formatted-rich-text');
            expect(richText).not.toBeNull();
            expect(richText.value).toContain('Access denied');
        });
    });

    describe('columns', () => {
        it('renders a datatable with columns derived from displayColumns', async () => {
            const el = await createLoadedComponent();
            const datatable = el.shadowRoot.querySelector('lightning-datatable');
            expect(datatable).not.toBeNull();
            expect(datatable.columns).toHaveLength(3);
        });

        it('maps fieldApiName to column fieldName', async () => {
            const el = await createLoadedComponent();
            const { columns } = el.shadowRoot.querySelector('lightning-datatable');
            expect(columns[0].fieldName).toBe('Name');
            expect(columns[1].fieldName).toBe('Email');
        });

        it('maps column labels correctly', async () => {
            const el = await createLoadedComponent();
            const { columns } = el.shadowRoot.querySelector('lightning-datatable');
            expect(columns[0].label).toBe('Name');
            expect(columns[1].label).toBe('Email');
        });

        it('maps Email dataType to email column type', async () => {
            const el = await createLoadedComponent();
            const { columns } = el.shadowRoot.querySelector('lightning-datatable');
            expect(columns[1].type).toBe('email');
        });

        it('maps Phone dataType to phone column type', async () => {
            const el = await createLoadedComponent();
            const { columns } = el.shadowRoot.querySelector('lightning-datatable');
            expect(columns[2].type).toBe('phone');
        });
    });

    describe('data rows', () => {
        it('renders flattened row data in the datatable', async () => {
            const el = await createLoadedComponent();
            const { data } = el.shadowRoot.querySelector('lightning-datatable');
            expect(data).toHaveLength(2);
            expect(data[0].Name).toBe('John Smith');
            expect(data[1].Email).toBe('jane@example.com');
        });

        it('includes the record Id in each row', async () => {
            const el = await createLoadedComponent();
            const { data } = el.shadowRoot.querySelector('lightning-datatable');
            expect(data[0].Id).toBe('003000000000001AAA');
        });

        it('shows empty state when records array is empty', async () => {
            const el = await createLoadedComponent({ records: [] });
            expect(el.shadowRoot.querySelector('lightning-datatable')).toBeNull();
            expect(el.shadowRoot.querySelector('p').textContent).toContain('No records found');
        });
    });

    describe('record count notice', () => {
        it('shows the record count when under 200', async () => {
            const el = await createLoadedComponent();
            const note = el.shadowRoot.querySelector('.record-count-note');
            expect(note.textContent).toContain('2 record(s)');
        });

        it('shows the 200-record cap warning when exactly 200 records are returned', async () => {
            const el = await createLoadedComponent(buildMaxRecords());
            const note = el.shadowRoot.querySelector('.record-count-note');
            expect(note.textContent).toContain('200');
            const icon = el.shadowRoot.querySelector('lightning-icon');
            expect(icon).not.toBeNull();
        });
    });

    describe('Back button', () => {
        it('fires a goback event when Back is clicked', async () => {
            const el = await createLoadedComponent();
            const handler = jest.fn();
            el.addEventListener('goback', handler);

            const btns = el.shadowRoot.querySelectorAll('lightning-button');
            const backBtn = Array.from(btns).find((b) => b.label === 'Back');
            backBtn.click();
            await Promise.resolve();

            expect(handler).toHaveBeenCalledTimes(1);
        });
    });

    describe('Print button', () => {
        it('is disabled when there are no records', async () => {
            const el = await createLoadedComponent({ records: [] });
            const btns = el.shadowRoot.querySelectorAll('lightning-button');
            const printBtn = Array.from(btns).find((b) => b.label === 'Print');
            expect(printBtn.disabled).toBe(true);
        });

        it('calls window.open when Print is clicked', async () => {
            const mockWrite = jest.fn();
            const mockClose = jest.fn();
            window.open = jest.fn().mockReturnValue({
                document: { write: mockWrite, close: mockClose }
            });

            const el = await createLoadedComponent();
            const btns = el.shadowRoot.querySelectorAll('lightning-button');
            const printBtn = Array.from(btns).find((b) => b.label === 'Print');
            printBtn.click();
            await Promise.resolve();

            expect(window.open).toHaveBeenCalledWith('', '_blank', expect.any(String));
            expect(mockWrite).toHaveBeenCalledTimes(1);
            expect(mockClose).toHaveBeenCalledTimes(1);
        });

        it('writes correct column headers into the print window', async () => {
            const mockWrite = jest.fn();
            window.open = jest.fn().mockReturnValue({
                document: { write: mockWrite, close: jest.fn() }
            });

            const el = await createLoadedComponent();
            const btns = el.shadowRoot.querySelectorAll('lightning-button');
            Array.from(btns).find((b) => b.label === 'Print').click();
            await Promise.resolve();

            const html = mockWrite.mock.calls[0][0];
            expect(html).toContain('<th>Name</th>');
            expect(html).toContain('<th>Email</th>');
            expect(html).toContain('<th>Phone</th>');
        });

        it('writes correct record data into the print window', async () => {
            const mockWrite = jest.fn();
            window.open = jest.fn().mockReturnValue({
                document: { write: mockWrite, close: jest.fn() }
            });

            const el = await createLoadedComponent();
            const btns = el.shadowRoot.querySelectorAll('lightning-button');
            Array.from(btns).find((b) => b.label === 'Print').click();
            await Promise.resolve();

            const html = mockWrite.mock.calls[0][0];
            expect(html).toContain('John Smith');
            expect(html).toContain('jane@example.com');
        });

        it('escapes HTML special characters in cell values', async () => {
            const maliciousRecords = {
                records: [{
                    id: '003000000000001AAA',
                    fields: {
                        Name: { value: '<script>alert("xss")</script>' },
                        Email: { value: 'safe@example.com' },
                        Phone: { value: '' }
                    }
                }]
            };

            const mockWrite = jest.fn();
            window.open = jest.fn().mockReturnValue({
                document: { write: mockWrite, close: jest.fn() }
            });

            const el = await createLoadedComponent(maliciousRecords);
            Array.from(el.shadowRoot.querySelectorAll('lightning-button'))
                .find((b) => b.label === 'Print').click();
            await Promise.resolve();

            const html = mockWrite.mock.calls[0][0];
            expect(html).not.toContain('<script>');
            expect(html).toContain('&lt;script&gt;');
        });

        it('shows pop-up blocked banner when window.open returns null', async () => {
            window.open = jest.fn().mockReturnValue(null);

            const el = await createLoadedComponent();
            Array.from(el.shadowRoot.querySelectorAll('lightning-button'))
                .find((b) => b.label === 'Print').click();
            await Promise.resolve();

            const warning = el.shadowRoot.querySelector('.slds-alert_warning');
            expect(warning).not.toBeNull();
            expect(warning.textContent).toContain('Pop-ups are blocked');
        });

        it('hides pop-up blocked banner on a successful print after a previous failure', async () => {
            // First attempt: blocked
            window.open = jest.fn().mockReturnValueOnce(null).mockReturnValue({
                document: { write: jest.fn(), close: jest.fn() }
            });

            const el = await createLoadedComponent();
            const printBtn = () =>
                Array.from(el.shadowRoot.querySelectorAll('lightning-button')).find(
                    (b) => b.label === 'Print'
                );

            printBtn().click();
            await Promise.resolve();
            expect(el.shadowRoot.querySelector('.slds-alert_warning')).not.toBeNull();

            // Second attempt: succeeds
            printBtn().click();
            await Promise.resolve();
            expect(el.shadowRoot.querySelector('.slds-alert_warning')).toBeNull();
        });
    });
});
