import { createElement } from 'lwc';
import MetaMapperFilterPanel from 'c/metaMapperFilterPanel';

function makeElement() {
    const el = createElement('c-meta-mapper-filter-panel', { is: MetaMapperFilterPanel });
    el.availableTypes = ['ApexClass', 'Flow'];
    el.maxDepthValue = 5;
    document.body.appendChild(el);
    return el;
}

// Lightning base component props (type, checked, data-type) are JS properties on the jest
// stub, not reflected HTML attributes for `type` - attribute selectors never match it, so
// find by property instead (data-* attributes are real DOM attributes and do work).
function inputsByType(root, type) {
    return Array.from(root.querySelectorAll('lightning-input')).filter((el) => el.type === type);
}

describe('c-meta-mapper-filter-panel', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('renders one checkbox per available type', async () => {
        const el = makeElement();
        await Promise.resolve();

        const checkboxes = inputsByType(el.shadowRoot, 'checkbox');
        expect(checkboxes.length).toBe(2);
    });

    it('fires filterschange with the type added when a type checkbox is checked', async () => {
        const el = makeElement();
        await Promise.resolve();

        const handler = jest.fn();
        el.addEventListener('filterschange', handler);

        const checkbox = el.shadowRoot.querySelector('[data-type="ApexClass"]');
        checkbox.checked = true;
        checkbox.dispatchEvent(new CustomEvent('change', { detail: {} }));
        await Promise.resolve();

        expect(handler).toHaveBeenCalledTimes(1);
        expect(handler.mock.calls[0][0].detail.types).toEqual(['ApexClass']);
    });

    it('fires filterschange with showCircular=false when the circular toggle is switched off', async () => {
        const el = makeElement();
        await Promise.resolve();

        const handler = jest.fn();
        el.addEventListener('filterschange', handler);

        const toggles = inputsByType(el.shadowRoot, 'toggle');
        const circularToggle = toggles[0];
        circularToggle.checked = false;
        circularToggle.dispatchEvent(new CustomEvent('change', { detail: {} }));
        await Promise.resolve();

        expect(handler).toHaveBeenCalledTimes(1);
        expect(handler.mock.calls[0][0].detail.showCircular).toBe(false);
    });

    it('fires filterschange with DEFAULT_FILTERS when Reset Filters is clicked', async () => {
        const el = makeElement();
        el.filters = { types: ['Flow'], minLevel: 1, maxLevel: 3, confidenceThreshold: 50, showCircular: false, showDynamic: false, showSupplemental: false };
        await Promise.resolve();

        const handler = jest.fn();
        el.addEventListener('filterschange', handler);

        const resetBtn = el.shadowRoot.querySelector('lightning-button');
        resetBtn.click();
        await Promise.resolve();

        expect(handler).toHaveBeenCalledTimes(1);
        expect(handler.mock.calls[0][0].detail).toEqual({
            types: [],
            minLevel: 0,
            maxLevel: 9999,
            confidenceThreshold: 0,
            showCircular: true,
            showDynamic: true,
            showSupplemental: true
        });
    });
});
