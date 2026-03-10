import { createElement } from 'lwc';
import RelatedListPicker from 'c/relatedListPicker';

const MOCK_RELATED_LISTS = [
    { label: 'Contacts', listReference: { relatedListId: 'Contacts' } },
    { label: 'Opportunities', listReference: { relatedListId: 'Opportunities' } },
    { label: 'Cases', listReference: { relatedListId: 'Cases' } }
];

function createComponent(props = {}) {
    const el = createElement('c-related-list-picker', { is: RelatedListPicker });
    Object.assign(el, { relatedLists: [], ...props });
    document.body.appendChild(el);
    return el;
}

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
});

describe('relatedListPicker', () => {
    describe('combobox options', () => {
        it('renders an option for each related list', () => {
            const el = createComponent({ relatedLists: MOCK_RELATED_LISTS });
            const combobox = el.shadowRoot.querySelector('lightning-combobox');
            expect(combobox).not.toBeNull();
            expect(combobox.options).toHaveLength(3);
        });

        it('maps label and relatedListId to combobox option label and value', () => {
            const el = createComponent({ relatedLists: MOCK_RELATED_LISTS });
            const { options } = el.shadowRoot.querySelector('lightning-combobox');
            expect(options[0]).toEqual({ label: 'Contacts', value: 'Contacts' });
            expect(options[1]).toEqual({ label: 'Opportunities', value: 'Opportunities' });
        });

        it('renders no options when relatedLists is empty', () => {
            const el = createComponent({ relatedLists: [] });
            const { options } = el.shadowRoot.querySelector('lightning-combobox');
            expect(options).toHaveLength(0);
        });
    });

    describe('Preview button', () => {
        it('is disabled when nothing is selected', () => {
            const el = createComponent({ relatedLists: MOCK_RELATED_LISTS });
            const btn = el.shadowRoot.querySelector('lightning-button');
            expect(btn.disabled).toBe(true);
        });

        it('is enabled after a combobox selection', async () => {
            const el = createComponent({ relatedLists: MOCK_RELATED_LISTS });
            const combobox = el.shadowRoot.querySelector('lightning-combobox');
            combobox.dispatchEvent(new CustomEvent('change', { detail: { value: 'Contacts' } }));
            await Promise.resolve();
            const btn = el.shadowRoot.querySelector('lightning-button');
            expect(btn.disabled).toBe(false);
        });
    });

    describe('relatedlistselect event', () => {
        it('fires with the selected relatedListId when Preview is clicked', async () => {
            const el = createComponent({ relatedLists: MOCK_RELATED_LISTS });
            const handler = jest.fn();
            el.addEventListener('relatedlistselect', handler);

            // Select a value
            const combobox = el.shadowRoot.querySelector('lightning-combobox');
            combobox.dispatchEvent(new CustomEvent('change', { detail: { value: 'Opportunities' } }));
            await Promise.resolve();

            // Click Preview
            el.shadowRoot.querySelector('lightning-button').click();
            await Promise.resolve();

            expect(handler).toHaveBeenCalledTimes(1);
            expect(handler.mock.calls[0][0].detail).toEqual({ relatedListId: 'Opportunities' });
        });

        it('does not fire if no value is selected', () => {
            const el = createComponent({ relatedLists: MOCK_RELATED_LISTS });
            const handler = jest.fn();
            el.addEventListener('relatedlistselect', handler);
            el.shadowRoot.querySelector('lightning-button').click();
            expect(handler).not.toHaveBeenCalled();
        });
    });
});
