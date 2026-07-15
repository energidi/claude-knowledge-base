import { createElement } from 'lwc';
import MetaMapperSearch from 'c/metaMapperSearch';
import createJob from '@salesforce/apex/DependencyJobController.createJob';
import getActiveJobId from '@salesforce/apex/DependencyJobController.getActiveJobId';

jest.mock('@salesforce/apex/DependencyJobController.createJob', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/DependencyJobController.getObjectList', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/DependencyJobController.getComponentCount', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/DependencyJobController.getActiveJobId', () => ({ default: jest.fn() }), { virtual: true });

function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

// Lightning base component props (name, label, type) are JS properties on the jest stub,
// not reflected HTML attributes - attribute selectors never match, so find by property.
function findByProp(root, tag, propName, propValue) {
    return Array.from(root.querySelectorAll(tag)).find((el) => el[propName] === propValue);
}

function selectType(element, value) {
    const combobox = findByProp(element.shadowRoot, 'lightning-combobox', 'name', 'metadataType');
    combobox.dispatchEvent(new CustomEvent('change', { detail: { value } }));
}

function setApiName(element, value) {
    const input = findByProp(element.shadowRoot, 'lightning-input', 'name', 'apiName');
    input.dispatchEvent(new CustomEvent('change', { detail: { value } }));
}

function setTargetObject(element, value) {
    const input = element.shadowRoot.querySelector('.typeahead-container input');
    input.value = value;
    input.dispatchEvent(new CustomEvent('input'));
}

function submitButton(element) {
    return element.shadowRoot.querySelector('.submit-btn');
}

function clickSubmit(element) {
    submitButton(element).dispatchEvent(new CustomEvent('click'));
}

describe('c-meta-mapper-search', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    describe('form validation', () => {
        it('disables submit when no type or API name is entered', () => {
            const element = createElement('c-meta-mapper-search', { is: MetaMapperSearch });
            document.body.appendChild(element);
            expect(submitButton(element).disabled).toBe(true);
        });

        it('remains disabled for CustomField type until Target Object is populated', async () => {
            const element = createElement('c-meta-mapper-search', { is: MetaMapperSearch });
            document.body.appendChild(element);

            selectType(element, 'CustomField');
            await flushPromises();
            setApiName(element, 'Account.My_Field__c');
            await flushPromises();

            expect(submitButton(element).disabled).toBe(true);
            expect(element.shadowRoot.querySelector('.typeahead-container input')).not.toBeNull();
        });

        it('enables submit once type, API name, and (for CustomField) target object are all populated', async () => {
            const element = createElement('c-meta-mapper-search', { is: MetaMapperSearch });
            document.body.appendChild(element);

            selectType(element, 'CustomField');
            await flushPromises();
            setApiName(element, 'Account.My_Field__c');
            await flushPromises();
            setTargetObject(element, 'Account');
            await flushPromises();

            expect(submitButton(element).disabled).toBe(false);
        });

        it('enables submit for a non-CustomField type without requiring a target object', async () => {
            const element = createElement('c-meta-mapper-search', { is: MetaMapperSearch });
            document.body.appendChild(element);

            selectType(element, 'ApexClass');
            await flushPromises();
            setApiName(element, 'MyClass');
            await flushPromises();

            expect(submitButton(element).disabled).toBe(false);
        });

        it('shows the ValidationRule-specific help text only when ValidationRule is selected', async () => {
            const element = createElement('c-meta-mapper-search', { is: MetaMapperSearch });
            document.body.appendChild(element);

            expect(element.shadowRoot.textContent).not.toContain('do not include the parent object');
            selectType(element, 'ValidationRule');
            await flushPromises();
            expect(element.shadowRoot.textContent).toContain('do not include the parent object');
        });
    });

    describe('createJob() invocation', () => {
        it('calls createJob with trimmed values and dispatches jobcreated on success', async () => {
            createJob.mockResolvedValue('a0Xxx0000000001');
            const element = createElement('c-meta-mapper-search', { is: MetaMapperSearch });
            document.body.appendChild(element);

            const handler = jest.fn();
            element.addEventListener('jobcreated', handler);

            selectType(element, 'ApexClass');
            await flushPromises();
            setApiName(element, '  MyClass  ');
            await flushPromises();
            clickSubmit(element);
            await flushPromises();

            expect(createJob).toHaveBeenCalledWith({
                metadataType: 'ApexClass',
                apiName: 'MyClass',
                targetObject: null,
                activeFlowsOnly: true
            });
            expect(handler).toHaveBeenCalledTimes(1);
            expect(handler.mock.calls[0][0].detail.jobId).toBe('a0Xxx0000000001');
        });

        it('does not call createJob when the form is invalid', async () => {
            const element = createElement('c-meta-mapper-search', { is: MetaMapperSearch });
            document.body.appendChild(element);

            clickSubmit(element);
            await flushPromises();

            expect(createJob).not.toHaveBeenCalled();
        });

        it('surfaces a concurrency rejection message and sets isRunningScanError', async () => {
            createJob.mockRejectedValue({ body: { message: 'Another MetaMapper scan is already running.' } });
            const element = createElement('c-meta-mapper-search', { is: MetaMapperSearch });
            document.body.appendChild(element);

            selectType(element, 'ApexClass');
            await flushPromises();
            setApiName(element, 'MyClass');
            await flushPromises();
            clickSubmit(element);
            await flushPromises();

            expect(submitButton(element).disabled).toBe(false);
            expect(element.shadowRoot.textContent).toContain('Another MetaMapper scan is already running.');
            expect(element.shadowRoot.querySelector('a.slds-m-left_x-small')).not.toBeNull();
        });

        it('re-enables the submit button after a non-concurrency createJob failure', async () => {
            createJob.mockRejectedValue({ body: { message: 'Some other error.' } });
            const element = createElement('c-meta-mapper-search', { is: MetaMapperSearch });
            document.body.appendChild(element);

            selectType(element, 'ApexClass');
            await flushPromises();
            setApiName(element, 'MyClass');
            await flushPromises();
            clickSubmit(element);
            await flushPromises();

            expect(submitButton(element).disabled).toBe(false);
            expect(element.shadowRoot.textContent).toContain('Some other error.');
            expect(element.shadowRoot.querySelector('a.slds-m-left_x-small')).toBeNull();
        });
    });

    describe('view running scan link', () => {
        async function triggerConcurrencyRejection(element) {
            createJob.mockRejectedValue({ body: { message: 'Another MetaMapper scan is already running.' } });
            selectType(element, 'ApexClass');
            await flushPromises();
            setApiName(element, 'MyClass');
            await flushPromises();
            clickSubmit(element);
            await flushPromises();
        }

        it('dispatches viewrunningscan with the active job id when the link is clicked', async () => {
            getActiveJobId.mockResolvedValue('a0Xxx0000000002');
            const element = createElement('c-meta-mapper-search', { is: MetaMapperSearch });
            document.body.appendChild(element);
            const handler = jest.fn();
            element.addEventListener('viewrunningscan', handler);

            await triggerConcurrencyRejection(element);

            const link = element.shadowRoot.querySelector('a.slds-m-left_x-small');
            link.dispatchEvent(new CustomEvent('click'));
            await flushPromises();

            expect(handler).toHaveBeenCalledTimes(1);
            expect(handler.mock.calls[0][0].detail.jobId).toBe('a0Xxx0000000002');
        });

        it('shows an info toast instead of dispatching when no active job is found', async () => {
            getActiveJobId.mockResolvedValue(null);
            const element = createElement('c-meta-mapper-search', { is: MetaMapperSearch });
            document.body.appendChild(element);
            const navHandler = jest.fn();
            const toastHandler = jest.fn();
            element.addEventListener('viewrunningscan', navHandler);
            element.addEventListener('showtoast', toastHandler);

            await triggerConcurrencyRejection(element);

            const link = element.shadowRoot.querySelector('a.slds-m-left_x-small');
            link.dispatchEvent(new CustomEvent('click'));
            await flushPromises();

            expect(navHandler).not.toHaveBeenCalled();
            expect(toastHandler).toHaveBeenCalledTimes(1);
        });
    });
});
