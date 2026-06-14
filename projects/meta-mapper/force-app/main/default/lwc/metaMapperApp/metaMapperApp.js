import { LightningElement, track, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import verifyHealthCheck from '@salesforce/apex/ToolingApiHealthCheck.verify';
import getJobStatus from '@salesforce/apex/DependencyJobController.getJobStatus';

const TOUR_KEY = 'metaMapper_tourSeen_v1';
const PE_CHANNEL = '/event/Dependency_Scan_Status__e';

const PREFLIGHT_ERRORS = {
    PERMISSION_SET_MISSING: {
        title: 'Access Required',
        body: "You don't have access to MetaMapper. Ask your admin to assign you the MetaMapper Admin permission set. If you were recently assigned, try refreshing your browser - Salesforce caches permission checks for a few minutes.",
        showLearnMore: false, showRetry: false
    },
    UNAUTHORIZED: {
        title: 'Setup Required',
        body: 'MetaMapper needs one-time setup. An admin must authorize the Tooling API connection.',
        showLearnMore: true, showRetry: false
    },
    CALLOUT_FORBIDDEN: {
        title: 'Configuration Error',
        body: 'MetaMapper connected but was denied by the Tooling API. Ask your admin to verify the Connected App has the required OAuth scopes.',
        showLearnMore: false, showRetry: false
    },
    UNREACHABLE: {
        title: 'Tooling API Unavailable',
        body: 'MetaMapper cannot reach the Tooling API right now. This may be a temporary org issue.',
        showLearnMore: false, showRetry: true
    },
    TIMEOUT: {
        title: 'Connection Timed Out',
        body: "MetaMapper's connection check timed out. This is usually a temporary org issue - try again in a moment.",
        showLearnMore: false, showRetry: true
    }
};

const TOUR_SLIDES = [
    {
        title: 'Reading the graph',
        body: 'Nodes are color-coded by metadata type. Solid borders show standard dependencies. Dashed borders indicate circular dependencies - these components depend on each other in a loop. Hover over any node to see details.'
    },
    {
        title: 'Warning badges',
        body: 'Orange warning badge = dynamic reference (an Apex string we cannot fully resolve - verify manually). Red error badge = low confidence match (below 70% - verify before making changes). Dashed border = circular dependency.'
    },
    {
        title: 'Supplemental results',
        body: 'Some dependencies are found through secondary analysis, not the standard Salesforce metadata API. These may include false positives. Nodes with a confidence score below 70% should be verified before making any changes.'
    }
];

export default class MetaMapperApp extends LightningElement {
    @wire(CurrentPageReference) pageRef;

    @track view = 'loading';
    @track jobId = null;
    @track job = null;
    @track isCheckingHealth = true;
    @track isDeepLinkLoading = false;
    @track preflightErrorCode = null;
    @track showLearnMoreModal = false;
    @track showTour = false;
    @track tourSlide = 1;
    @track toastMessage = '';
    @track toastVariant = 'info';

    _peSubscription = null;
    _toastTimer = null;
    _tourTriggerElement = null;

    connectedCallback() {
        this.runHealthCheck();
        onError(err => console.error('PE error:', err));
    }

    disconnectedCallback() {
        if (this._peSubscription) {
            unsubscribe(this._peSubscription, () => {});
        }
        clearTimeout(this._toastTimer);
    }

    async runHealthCheck() {
        this.isCheckingHealth = true;
        this.preflightErrorCode = null;
        try {
            const code = await verifyHealthCheck();
            if (code === 'AUTHORIZED') {
                await this._handleHealthCheckPassed();
            } else {
                this.preflightErrorCode = code || 'UNREACHABLE';
                this.view = 'preflight-error';
            }
        } catch {
            this.preflightErrorCode = 'UNREACHABLE';
            this.view = 'preflight-error';
        } finally {
            this.isCheckingHealth = false;
        }
    }

    async _handleHealthCheckPassed() {
        const params = this.pageRef && this.pageRef.state;
        const deepJobId = params && params.jobId;
        if (deepJobId) {
            this.isDeepLinkLoading = true;
            try {
                const jobData = await getJobStatus({ jobId: deepJobId });
                if (jobData) {
                    this.jobId = deepJobId;
                    this.job = jobData;
                    const s = jobData.Status__c;
                    this.view = ['Initializing', 'Processing', 'Paused'].includes(s) ? 'progress' : 'results';
                } else {
                    this.view = 'search';
                    this._showToast('This scan result is no longer available. It may have been automatically deleted.', 'error');
                }
            } catch {
                this.view = 'search';
            } finally {
                this.isDeepLinkLoading = false;
            }
        } else {
            this.view = 'search';
        }

        if (!localStorage.getItem(TOUR_KEY) && this.view === 'search') {
            this._tourTriggerElement = document.activeElement;
            this.showTour = true;
        }

        this._subscribePE();
    }

    _subscribePE() {
        subscribe(PE_CHANNEL, -1, event => {
            const payload = event.data.payload;
            if (payload.Scan_Job_Id__c !== this.jobId) return;
            this._handlePEEvent(payload);
        }).then(sub => { this._peSubscription = sub; });
    }

    _handlePEEvent(payload) {
        const newStatus = payload.Status__c;
        if (['Completed', 'Failed', 'Cancelled'].includes(newStatus)) {
            this._refreshJob();
        }
        if (['Initializing', 'Processing'].includes(newStatus) && this.view !== 'progress') {
            this.view = 'progress';
        }
        const prog = this.template.querySelector('c-meta-mapper-progress');
        if (prog) prog.handleStatusEvent(payload);
        const res = this.template.querySelector('c-meta-mapper-results');
        if (res) res.notifyStatusChange(this.job);
    }

    async _refreshJob() {
        try {
            this.job = await getJobStatus({ jobId: this.jobId });
        } catch {
            // ignore - job state will be corrected by next poll
        }
    }

    // --- Computed getters ---

    get isSearchView()      { return this.view === 'search'; }
    get isProgressView()    { return this.view === 'progress'; }
    get isResultsView()     { return this.view === 'results'; }
    get maxComponentsCap()  { return (this.job && this.job.maxComponentsCap) || 0; }
    get showApp() {
        return !this.isCheckingHealth && !this.isDeepLinkLoading && !this.showPreflightError;
    }

    get showPreflightError() {
        return this.view === 'preflight-error' && !!this.preflightErrorCode;
    }

    get preflightErrorTitle() {
        return (PREFLIGHT_ERRORS[this.preflightErrorCode] || {}).title || 'Error';
    }
    get preflightErrorBody() {
        return (PREFLIGHT_ERRORS[this.preflightErrorCode] || {}).body || '';
    }
    get showLearnMoreLink() {
        return !!(PREFLIGHT_ERRORS[this.preflightErrorCode] || {}).showLearnMore;
    }
    get showRetryButton() {
        return !!(PREFLIGHT_ERRORS[this.preflightErrorCode] || {}).showRetry;
    }

    get tourSlideTitle() { return (TOUR_SLIDES[this.tourSlide - 1] || {}).title || ''; }
    get tourSlideBody()  { return (TOUR_SLIDES[this.tourSlide - 1] || {}).body  || ''; }
    get showTourPrev()   { return this.tourSlide > 1; }
    get tourNextLabel()  { return this.tourSlide === 3 ? 'Got it' : 'Next'; }
    get tourPrevLabel()  { return `Previous (slide ${this.tourSlide - 1} of 3)`; }

    get toastClass() {
        return `slds-notify slds-notify_toast slds-theme_${this.toastVariant} toast-overlay`;
    }

    // --- Event handlers ---

    handleJobCreated(event) {
        this.jobId = event.detail.jobId;
        this._refreshJob().then(() => { this.view = 'progress'; });
    }

    handleJobStatusPolled(event) {
        this.job = event.detail;
        const s = this.job && this.job.Status__c;
        if (s === 'Completed' || s === 'Failed' || s === 'Cancelled') {
            this.view = 'results';
        }
    }

    handleViewPartialResults() { this.view = 'results'; }

    handleStartNew() {
        this.jobId = null;
        this.job = null;
        this.view = 'search';
    }

    handleViewRunningScan() {
        this._showToast('The scan finished while this message was showing. You can start a new scan now.', 'info');
    }

    handleLearnMore() { this.showLearnMoreModal = true; }
    closeLearnMore()  { this.showLearnMoreModal = false; }

    handleTourNext() {
        if (this.tourSlide < 3) {
            this.tourSlide++;
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                const el = this.refs && this.refs.tourSlideBody;
                if (el) el.focus();
            }, 0);
        } else {
            this.closeTour();
        }
    }

    handleTourPrev() {
        if (this.tourSlide > 1) {
            this.tourSlide--;
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                const el = this.refs && this.refs.tourSlideBody;
                if (el) el.focus();
            }, 0);
        }
    }

    closeTour() {
        localStorage.setItem(TOUR_KEY, 'true');
        this.showTour = false;
        if (this._tourTriggerElement) {
            this._tourTriggerElement.focus();
        }
    }

    handleShowError(event) {
        this._showToast(event.detail.message, 'error');
    }

    handleFiltersReset() {
        this._showToast('Some filters from your previous session were reset because this scan has different metadata types.', 'info');
    }

    handleAskCopilot() {
        // Copilot integration is org-specific - no-op placeholder
    }

    _showToast(message, variant) {
        this.toastMessage = message;
        this.toastVariant = variant || 'info';
        clearTimeout(this._toastTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._toastTimer = setTimeout(() => { this.toastMessage = ''; }, 5000);
    }
}
