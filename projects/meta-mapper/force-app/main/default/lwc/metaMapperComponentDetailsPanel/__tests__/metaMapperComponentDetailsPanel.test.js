import { createElement } from 'lwc';
import MetaMapperComponentDetailsPanel from 'c/metaMapperComponentDetailsPanel';

// jsdom does not implement matchMedia; the component uses it in connectedCallback for its
// mobile-breakpoint modal behavior, so it must be polyfilled before mount.
beforeAll(() => {
    window.matchMedia = window.matchMedia || function matchMedia(query) {
        return {
            matches: false,
            media: query,
            addEventListener: () => {},
            removeEventListener: () => {},
            addListener: () => {},
            removeListener: () => {},
            dispatchEvent: () => false
        };
    };
});

function buildNodeMap(nodes) {
    const map = new Map();
    nodes.forEach((n) => map.set(n.Metadata_Id__c, n));
    return map;
}

function breadcrumbNames(element) {
    return [...element.shadowRoot.querySelectorAll('.breadcrumb-item:not(.breadcrumb-current)')].map(
        (el) => el.textContent
    );
}

describe('c-meta-mapper-component-details-panel', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    describe('breadcrumb ID-to-name resolution', () => {
        it('resolves each ancestor id in Ancestor_Path__c to its Metadata_Name__c via nodeMap', async () => {
            const nodes = [
                { Metadata_Id__c: 'id1', Metadata_Name__c: 'RootClass', Metadata_Type__c: 'ApexClass' },
                { Metadata_Id__c: 'id2', Metadata_Name__c: 'MiddleClass', Metadata_Type__c: 'ApexClass' },
                {
                    Metadata_Id__c: 'id3',
                    Metadata_Name__c: 'LeafField',
                    Metadata_Type__c: 'CustomField',
                    Ancestor_Path__c: 'id1|id2'
                }
            ];
            const element = createElement('c-meta-mapper-component-details-panel', { is: MetaMapperComponentDetailsPanel });
            element.nodeMap = buildNodeMap(nodes);
            document.body.appendChild(element);
            element.selectedNodeId = 'id3';
            await Promise.resolve();

            expect(breadcrumbNames(element)).toEqual(['RootClass', 'MiddleClass']);
        });

        it('falls back to the raw id when an ancestor id is not found in nodeMap', async () => {
            const nodes = [
                {
                    Metadata_Id__c: 'id3',
                    Metadata_Name__c: 'LeafField',
                    Metadata_Type__c: 'CustomField',
                    Ancestor_Path__c: 'missingId'
                }
            ];
            const element = createElement('c-meta-mapper-component-details-panel', { is: MetaMapperComponentDetailsPanel });
            element.nodeMap = buildNodeMap(nodes);
            document.body.appendChild(element);
            element.selectedNodeId = 'id3';
            await Promise.resolve();

            expect(breadcrumbNames(element)).toEqual(['missingId']);
        });

        it('renders no breadcrumb section when the selected node has no Ancestor_Path__c', async () => {
            const nodes = [{ Metadata_Id__c: 'root', Metadata_Name__c: 'Root', Metadata_Type__c: 'ApexClass' }];
            const element = createElement('c-meta-mapper-component-details-panel', { is: MetaMapperComponentDetailsPanel });
            element.nodeMap = buildNodeMap(nodes);
            document.body.appendChild(element);
            element.selectedNodeId = 'root';
            await Promise.resolve();

            expect(element.shadowRoot.querySelector('.breadcrumb-chain')).toBeNull();
        });

        it('shows only the 10 nearest ancestors and expands to all on "Show all" click', async () => {
            const ids = [];
            for (let i = 0; i < 12; i++) ids.push('a' + i);
            const nodes = ids.map((id) => ({ Metadata_Id__c: id, Metadata_Name__c: id, Metadata_Type__c: 'ApexClass' }));
            nodes.push({
                Metadata_Id__c: 'leaf',
                Metadata_Name__c: 'Leaf',
                Metadata_Type__c: 'ApexClass',
                Ancestor_Path__c: ids.join('|')
            });
            const element = createElement('c-meta-mapper-component-details-panel', { is: MetaMapperComponentDetailsPanel });
            element.nodeMap = buildNodeMap(nodes);
            document.body.appendChild(element);
            element.selectedNodeId = 'leaf';
            await Promise.resolve();

            expect(breadcrumbNames(element)).toHaveLength(10);
            // Nearest-to-selected 10 ancestors: the last 10 entries of the 12-length path (a2..a11).
            expect(breadcrumbNames(element)[0]).toBe('a2');

            const showAllBtn = element.shadowRoot.querySelector('.show-all-ancestors');
            expect(showAllBtn).not.toBeNull();
            showAllBtn.dispatchEvent(new CustomEvent('click'));
            await Promise.resolve();

            expect(breadcrumbNames(element)).toHaveLength(12);
        });
    });

    describe('Setup URL routing per type', () => {
        const orgId = '00Dxx0000001gEZ';

        it('routes ApexClass to the Apex Classes setup home and enables the Setup button', async () => {
            const node = { Metadata_Id__c: 'id1', Metadata_Type__c: 'ApexClass', Metadata_Name__c: 'MyClass' };
            const element = createElement('c-meta-mapper-component-details-panel', { is: MetaMapperComponentDetailsPanel });
            element.nodeMap = buildNodeMap([node]);
            element.orgId = orgId;
            document.body.appendChild(element);
            element.selectedNodeId = 'id1';
            await Promise.resolve();

            const btn = element.shadowRoot.querySelector('.setup-btn');
            expect(btn.classList.contains('is-disabled')).toBe(false);
            expect(btn.getAttribute('aria-disabled')).toBe('false');

            const openSpy = jest.spyOn(window, 'open').mockImplementation(() => {});
            btn.dispatchEvent(new CustomEvent('click'));
            expect(openSpy).toHaveBeenCalledWith(`/${orgId}/lightning/setup/ApexClasses/home`, '_blank', 'noopener,noreferrer');
            openSpy.mockRestore();
        });

        it('routes CustomField using the parentObject from Dependency_Context__c', async () => {
            const node = {
                Metadata_Id__c: 'id2',
                Metadata_Type__c: 'CustomField',
                Metadata_Name__c: 'Account.My_Field__c',
                Dependency_Context__c: JSON.stringify({ v: 1, parentObject: 'Account' })
            };
            const element = createElement('c-meta-mapper-component-details-panel', { is: MetaMapperComponentDetailsPanel });
            element.nodeMap = buildNodeMap([node]);
            element.orgId = orgId;
            document.body.appendChild(element);
            element.selectedNodeId = 'id2';
            await Promise.resolve();

            const openSpy = jest.spyOn(window, 'open').mockImplementation(() => {});
            element.shadowRoot.querySelector('.setup-btn').dispatchEvent(new CustomEvent('click'));
            expect(openSpy).toHaveBeenCalledWith(
                `/${orgId}/lightning/setup/ObjectManager/Account/FieldsAndRelationships/view`,
                '_blank',
                'noopener,noreferrer'
            );
            openSpy.mockRestore();
        });

        it('disables the Setup button and sets the fallback tooltip for an unsupported type, without opening a window', async () => {
            const node = { Metadata_Id__c: 'id3', Metadata_Type__c: 'SomeUnknownType', Metadata_Name__c: 'X' };
            const element = createElement('c-meta-mapper-component-details-panel', { is: MetaMapperComponentDetailsPanel });
            element.nodeMap = buildNodeMap([node]);
            element.orgId = orgId;
            document.body.appendChild(element);
            element.selectedNodeId = 'id3';
            await Promise.resolve();

            const btn = element.shadowRoot.querySelector('.setup-btn');
            expect(btn.classList.contains('is-disabled')).toBe(true);
            expect(btn.getAttribute('aria-disabled')).toBe('true');
            expect(btn.getAttribute('title')).toContain('Setup link not available');

            const openSpy = jest.spyOn(window, 'open').mockImplementation(() => {});
            btn.dispatchEvent(new CustomEvent('click'));
            expect(openSpy).not.toHaveBeenCalled();
            openSpy.mockRestore();
        });
    });
});
