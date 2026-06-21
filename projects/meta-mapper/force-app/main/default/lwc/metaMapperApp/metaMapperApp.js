import { LightningElement, track, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';
import verifyHealthCheck from '@salesforce/apex/ToolingApiHealthCheck.verify';
import getJobStatus from '@salesforce/apex/DependencyJobController.getJobStatus';
import getOrgId from '@salesforce/apex/DependencyJobController.getOrgId';

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
    @track _peSuppressionActive = false;
    @track _batchSizeInUse = null;
    @track _maxComponentsCap = 0;
    @track _retentionHours = 72;
    @track isCheckingHealth = true;
    _isMounted = false;
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
    _orgId = '';

    connectedCallback() {
        this._isMounted = true;
        this.runHealthCheck();
        onError(err => console.error('PE error:', err));
        getOrgId().then(id => { this._orgId = id || ''; }).catch(() => {});
    }

    get orgId() { return this._orgId; }

    disconnectedCallback() {
        this._isMounted = false;
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
        if (!this._isMounted) return;
        const params = this.pageRef && this.pageRef.state;
        const deepJobId = params && params.jobId;
        const deepNodeId = params && params.nodeId;
        if (deepJobId) {
            this.isDeepLinkLoading = true;
            try {
                const wrapper = await getJobStatus({ jobId: deepJobId });
                if (wrapper) {
                    this.jobId = deepJobId;
                    this._storeJobResult(wrapper);
                    const s = this.job && this.job.Status__c;
                    this.view = ['Initializing', 'Processing', 'Paused'].includes(s) ? 'progress' : 'results';
                    if (deepNodeId && this.view === 'results') {
                        // eslint-disable-next-line @lwc/lwc/no-async-operation
                        setTimeout(() => {
                            const res = this.template.querySelector('c-meta-mapper-results');
                            if (res) res.setPendingNodeId(deepNodeId);
                        }, 0);
                    }
                } else {
                    this.view = 'search';
                    this._showToast('This scan result is no longer available. It may have been automatically deleted.', 'error');
                }
            } catch {
                this.view = 'search';
                this._showToast('Could not load this scan result. Check your connection and try again.', 'error');
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
        try {
            subscribe(PE_CHANNEL, -1, event => {
                if (!this._isMounted) return;
                const payload = event.data.payload;
                if (payload.Scan_Job_Id__c !== this.jobId) return;
                this._handlePEEvent(payload);
            }).then(sub => {
                this._peSubscription = sub;
            }).catch(err => {
                this._handleSubscribeFailure(err);
            });
        } catch (err) {
            this._handleSubscribeFailure(err);
        }
    }

    _handleSubscribeFailure(err) {
        const msg = err && (err.message || (err.body && err.body.message) || String(err));
        console.error('MetaMapper: empApi subscribe failed -', msg);
        const isQuotaLimit = msg && /concurrent clients limit exceeded|streaming api.*limit/i.test(msg);
        const prog = this.template.querySelector('c-meta-mapper-progress');
        if (prog) {
            prog.handleStatusEvent({ peSuppressionActive: true, streamingQuotaLimitExceeded: isQuotaLimit });
        }
    }

    _handlePEEvent(payload) {
        if (!this._isMounted) return;
        const newStatus = payload.Status__c;
        if (newStatus === 'Completed') {
            this._refreshJob().then(() => { this.view = 'results'; });
        } else if (['Failed', 'Cancelled'].includes(newStatus)) {
            // Refresh job so the progress view renders the correct terminal state
            // (Failed diagnostic log, Cancelled "View partial results" link).
            // The user navigates to results themselves via the link in the progress view.
            this._refreshJob();
        }
        if (['Initializing', 'Processing'].includes(newStatus) && this.view !== 'progress') {
            this.view = 'progress';
        }
        const prog = this.template.querySelector('c-meta-mapper-progress');
        // H1: include peSuppressionActive so the progress component can activate polling fallback
        if (prog) prog.handleStatusEvent({ ...payload, peSuppressionActive: this._peSuppressionActive });
        const res = this.template.querySelector('c-meta-mapper-results');
        if (res) res.notifyStatusChange(this.job);
    }

    async _refreshJob() {
        try {
            const wrapper = await getJobStatus({ jobId: this.jobId });
            this._storeJobResult(wrapper);
        } catch {
            // ignore - job state will be corrected by next poll
        }
    }

    // C2: extract the raw job record and wrapper scalars from the JobStatusResult wrapper
    _storeJobResult(wrapper) {
        if (!wrapper) return;
        this.job = wrapper.job || null;
        this._peSuppressionActive = wrapper.peSuppressionActive === true;
        this._batchSizeInUse = wrapper.batchSizeInUse != null ? wrapper.batchSizeInUse : null;
        this._maxComponentsCap = wrapper.maxComponentsCap != null ? wrapper.maxComponentsCap : 0;
        this._retentionHours = wrapper.retentionHours != null ? wrapper.retentionHours : 72;
    }

    // --- Computed getters ---

    get isSearchView()      { return this.view === 'search'; }
    get isProgressView()    { return this.view === 'progress'; }
    get isResultsView()     { return this.view === 'results'; }
    get maxComponentsCap()  { return this._maxComponentsCap || 0; }
    get retentionHours()    { return this._retentionHours || 72; }
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
    get tourNextLabel()      { return this.tourSlide === 3 ? 'Got it' : 'Next'; }
    get tourNextAriaLabel()  {
        return this.tourSlide === 3
            ? 'Got it - close tour'
            : `Next (slide ${this.tourSlide + 1} of 3)`;
    }
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
        this._storeJobResult(event.detail);
        const s = this.job && this.job.Status__c;
        if (s === 'Completed') {
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
        if (window.innerWidth < 1024) {
            // On mobile there is no reliable keyboard focus to restore. Move focus to the
            // first focusable element in metaMapperSearch so screen readers have a landing
            // point without triggering a scroll jump to document.body.
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                const search = this.template.querySelector('c-meta-mapper-search');
                if (search) {
                    const firstFocusable = search.querySelector('input, select, button, [tabindex="0"]');
                    if (firstFocusable) firstFocusable.focus();
                }
            }, 0);
        } else if (this._tourTriggerElement) {
            this._tourTriggerElement.focus();
        }
    }

    handleShowError(event) {
        this._showToast(event.detail.message, 'error');
    }

    handleShowToast(event) {
        this._showToast(event.detail.message, event.detail.variant || 'info');
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
