import { LightningElement, api, track } from 'lwc';
import cancelJob from '@salesforce/apex/DependencyJobController.cancelJob';
import resumeJob from '@salesforce/apex/DependencyJobController.resumeJob';
import getJobStatus from '@salesforce/apex/DependencyJobController.getJobStatus';
import { formatElapsed, truncateApiName } from 'c/metaMapperFormatters';

const POLL_INTERVAL_PROCESSING = 5000;
const POLL_INTERVAL_PAUSED     = 10000;
const LONG_RUN_THRESHOLD_SEC   = 900;
const TIMEOUT_THRESHOLD_SEC    = 3600;
const CANCEL_CONFIRM_TIMEOUT   = 30000;
const RESUME_TIMEOUT           = 30000;

export default class MetaMapperProgress extends LightningElement {
    @api jobId;
    @api maxComponentsCap;
    @api batchSizeInUse;

    @track cancelDisabled = false;
    @track cancelLabel = 'Cancel';
    @track showCancelModal = false;
    @track showCancellingSubtext = false;
    @track showCancelTimeoutBanner = false;
    @track showLongRunningBanner = false;
    @track showTimeoutBanner = false;
    @track longRunningBannerDismissed = false;
    @track resumeLoading = false;
    @track resumeSlowerActive = false;
    @track showPollingNotice = false;
    @track pollingNoticeText = '';
    @track showPollWarningBanner = false;
    @track showPollErrorBanner = false;
    @track showStreamingQuotaBanner = false;

    _jobInternal = null;
    _elapsedFrozenSeconds = null;

    @api
    get job() {
        return this._jobInternal;
    }
    set job(val) {
        const prevStatus = this._jobInternal && this._jobInternal.Status__c;
        const nextStatus = val && val.Status__c;
        if (prevStatus !== 'Paused' && nextStatus === 'Paused' && this._elapsedFrozenSeconds === null && val.CreatedDate) {
            this._elapsedFrozenSeconds = Math.floor((Date.now() - new Date(val.CreatedDate).getTime()) / 1000);
        } else if (prevStatus === 'Paused' && nextStatus !== 'Paused') {
            this._elapsedFrozenSeconds = null;
        }
        this._jobInternal = val;
    }

    _isMounted = false;
    _peSuppressionActiveProp = false;
    _streamingQuotaBannerDismissed = false;

    @api
    get peSuppressionActive() {
        return this._peSuppressionActiveProp;
    }
    set peSuppressionActive(val) {
        this._peSuppressionActiveProp = val === true;
        if (this._peSuppressionActiveProp && this._isMounted) {
            this._startPolling();
        }
    }
    _pollTimer = null;
    _elapsedTimer = null;
    _cancelTimeoutTimer = null;
    _peWatchdogTimer = null;
    _cancelPhase = 'idle';
    _elapsedTick = 0;
    _resumeTimeoutTimer = null;
    _pollFailCount = 0;
    _isResuming = false;

    connectedCallback() {
        this._isMounted = true;
        this._startElapsedTimer();
        // Props are set before connectedCallback fires; if peSuppressionActive arrived
        // before mount the setter could not start polling — check here.
        if (this._peSuppressionActiveProp) {
            this._startPolling();
        } else {
            this._resetPeWatchdog();
        }
    }

    disconnectedCallback() {
        this._isMounted = false;
        this._isResuming = false;
        clearTimeout(this._pollTimer);
        clearInterval(this._elapsedTimer);
        clearTimeout(this._cancelTimeoutTimer);
        clearTimeout(this._resumeTimeoutTimer);
        clearTimeout(this._peWatchdogTimer);
    }

    @api
    handleStatusEvent(eventData) {
        if (!this._isMounted) return;
        this._resetPeWatchdog();
        if (eventData && eventData.peSuppressionActive) {
            this._startPolling();
        }
        if (eventData && eventData.streamingQuotaLimitExceeded && !this._streamingQuotaBannerDismissed) {
            this.showStreamingQuotaBanner = true;
        }
        if (eventData && eventData.Status__c === 'Cancelled' && this._cancelPhase === 'cancelling') {
            this._cancelPhase = 'cancelled';
            this.showCancellingSubtext = false;
            clearTimeout(this._cancelTimeoutTimer);
        }
        if (eventData && ['Completed', 'Failed', 'Cancelled'].includes(eventData.Status__c)) {
            this.showPollingNotice = false;
        }
        // When PE fires a Processing transition (e.g. after resume from Paused), refresh the
        // polling notice text so it no longer says "every 10 seconds" if polling is active.
        if (eventData && eventData.Status__c === 'Processing' && this.showPollingNotice) {
            this._startPolling();
        }
    }

    dismissStreamingQuotaBanner() {
        this.showStreamingQuotaBanner = false;
        this._streamingQuotaBannerDismissed = true;
    }

    // --- Computed getters ---

    get status() { return (this.job && this.job.Status__c) || ''; }
    get isPaused() { return this.status === 'Paused'; }
    get isProcessing() { return this.status === 'Processing' || this.status === 'Initializing'; }
    get isTerminal() { return ['Completed', 'Failed', 'Cancelled'].includes(this.status); }
    get isCancelled() { return this.status === 'Cancelled'; }

    get showStatusLabel() { return !this.isPaused && !this.showTimeoutBanner; }
    get showCancelButton() {
        return !this.isTerminal && !this.isPaused && this._cancelPhase !== 'cancelled';
    }
    get cancelButtonDisabled() { return this.cancelDisabled || this.showTimeoutBanner; }

    get showProgressBar() {
        if (!this.job) return false;
        const cap = this.maxComponentsCap || 0;
        return cap > 0 && (this.isProcessing || this.isPaused);
    }

    get showProgressSpinner() { return !this.showProgressBar && this.isProcessing; }
    get showElapsed() { return !this.isTerminal; }

    get progressValue() {
        if (!this.job) return 0;
        const cap = this.maxComponentsCap || 0;
        if (cap <= 0) return 0;
        if (this.status === 'Completed') return 100;
        return Math.min(Math.round((this.job.Components_Analyzed__c || 0) / cap * 100), 95);
    }

    get elapsedFormatted() {
        if (!this.job || !this.job.CreatedDate) return '00:00';
        if (this._elapsedTick < 0) return '00:00';
        if (this._elapsedFrozenSeconds !== null) {
            const s = this._elapsedFrozenSeconds;
            const h = Math.floor(s / 3600);
            const m = Math.floor((s % 3600) / 60);
            const sec = s % 60;
            if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`;
            return `${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}`;
        }
        return formatElapsed(this.job.CreatedDate);
    }

    get resumeCurrentLabel() {
        const size = this._effectiveBatchSize();
        return `Resume with current settings (batch size: ${size})`;
    }

    get resumeCurrentActive() { return this.resumeLoading && !this.resumeSlowerActive; }

    get pauseBannerText() {
        const reason = this.job && this.job.Pause_Reason__c;
        if (reason === 'ComponentLimitReached') {
            return 'Analysis paused - the component limit was reached. Raise Max_Components__c in MetaMapper Settings to continue.';
        }
        const apiName = (this.job && this.job.Target_API_Name__c) ? this.job.Target_API_Name__c : 'the component';
        return `Analysis of ${apiName} paused - encountered a complex component. You can resume at a slower speed or with current settings.`;
    }

    _effectiveBatchSize() {
        if (this.batchSizeInUse != null) return this.batchSizeInUse;
        if (this.job && this.job.Batch_Size_Override__c) return this.job.Batch_Size_Override__c;
        return 50;
    }

    // Static API-name display area (distinct from the full-sentence statusLabel below, which
    // is never truncated per spec). Truncated at 47 chars + "..." when over 50 chars; full name
    // always available via the title attribute tooltip.
    get displayApiName() {
        const name = (this.job && this.job.Target_API_Name__c) || '';
        return truncateApiName(name);
    }

    get fullApiNameTitle() {
        return (this.job && this.job.Target_API_Name__c) || '';
    }

    get showApiNameDisplay() {
        return !!(this.job && this.job.Target_API_Name__c);
    }

    get statusLabel() {
        if (!this.job) return '';
        const name = this.job.Target_API_Name__c || '';
        const count = this.job.Components_Analyzed__c || 0;
        switch (this.status) {
            case 'Initializing': return 'Setting up your analysis...';
            case 'Processing':   return `Analyzing ${name}... ${count} components found so far`;
            case 'Completed':    return `Analysis of ${name} complete. ${count} components found.`;
            case 'Failed': {
                const log = this.job.Scan_Diagnostic_Log__c || '';
                const msg = log ? log.substring(0, 200) : 'An unexpected error stopped the analysis.';
                return `Analysis of ${name} failed. ${msg} See details for diagnostics.`;
            }
            case 'Cancelled':    return `Analysis of ${name} cancelled. Partial results are available.`;
            default: return '';
        }
    }

    // --- Elapsed timer ---

    _startElapsedTimer() {
        this._elapsedTimer = setInterval(() => {
            if (!this._isMounted) return;
            this._elapsedTick++;
            if (this.job && this.job.CreatedDate) {
                const elapsed = Math.floor((Date.now() - new Date(this.job.CreatedDate).getTime()) / 1000);
                if (elapsed > TIMEOUT_THRESHOLD_SEC && this.isProcessing) {
                    this.showTimeoutBanner = true;
                    this.showLongRunningBanner = false;
                    this.showPollingNotice = false;
                    this._stopPolling();
                } else if (elapsed > LONG_RUN_THRESHOLD_SEC && this.isProcessing && !this.longRunningBannerDismissed) {
                    this.showLongRunningBanner = true;
                }
            }
        }, 1000);
    }

    // --- Polling ---

    _startPolling() {
        clearTimeout(this._peWatchdogTimer);
        this._stopPolling();
        // Use 5s after a successful resumeJob() call regardless of current Paused status,
        // so the Processing transition is caught quickly before the Queueable runs.
        const interval = (this.isPaused && !this._isResuming) ? POLL_INTERVAL_PAUSED : POLL_INTERVAL_PROCESSING;
        this._pollTimer = setTimeout(() => this._poll(), interval);
        this.showPollingNotice = true;
        this.pollingNoticeText = (this.isPaused && !this._isResuming)
            ? 'Live updates paused - refreshing every 10 seconds.'
            : 'Live updates paused - refreshing every 5 seconds.';
    }

    _stopPolling() {
        clearTimeout(this._pollTimer);
        this._pollTimer = null;
    }

    // Resets the 45-second PE inactivity watchdog. Called after every PE event arrives
    // and on connectedCallback (when not already polling). If 45 seconds pass without a
    // PE event the watchdog fires a one-shot getJobStatus() to detect suppression.
    // No-op when polling is already active, PE is already suppressed, or job is terminal.
    _resetPeWatchdog() {
        clearTimeout(this._peWatchdogTimer);
        if (this.isTerminal || this._peSuppressionActiveProp || this._pollTimer || !this._isMounted) return;
        this._peWatchdogTimer = setTimeout(() => this._peWatchdogFired(), 45000);
    }

    async _peWatchdogFired() {
        if (!this._isMounted || this.isTerminal || this._peSuppressionActiveProp || this._pollTimer) return;
        try {
            const result = await getJobStatus({ jobId: this.jobId });
            if (!this._isMounted) return;
            this.dispatchEvent(new CustomEvent('jobstatuspolled', {
                detail: result, bubbles: true, composed: true
            }));
            if (result && result.peSuppressionActive) {
                this._startPolling();
            } else if (this.isProcessing) {
                this._resetPeWatchdog();
            }
        } catch {
            if (this._isMounted && this.isProcessing) this._resetPeWatchdog();
        }
    }

    async _poll() {
        if (!this._isMounted || this.isTerminal) return;
        try {
            const result = await getJobStatus({ jobId: this.jobId });
            this._pollFailCount = 0;
            this.showPollWarningBanner = false;
            this.showPollErrorBanner = false;
            if (!this._isMounted) return;
            // Dispatch the full wrapper so metaMapperApp._storeJobResult() can extract
            // the raw job record, peSuppressionActive, batchSizeInUse, and maxComponentsCap.
            this.dispatchEvent(new CustomEvent('jobstatuspolled', {
                detail: result, bubbles: true, composed: true
            }));
            const status = result && result.job && result.job.Status__c;
            if (status === 'Cancelled' && this._cancelPhase === 'cancelling') {
                this._cancelPhase = 'cancelled';
                this.showCancellingSubtext = false;
                clearTimeout(this._cancelTimeoutTimer);
            }
            // Clear resume loading state once status leaves Paused.
            if (this.resumeLoading && status !== 'Paused') {
                this.resumeLoading = false;
                this.resumeSlowerActive = false;
                this._isResuming = false;
                clearTimeout(this._resumeTimeoutTimer);
            }
            // Reset resume timeout on each poll that confirms job is still Paused
            // (resume in-flight but Queueable hasn't woken yet).
            if (this.resumeLoading && status === 'Paused') {
                clearTimeout(this._resumeTimeoutTimer);
                this._resumeTimeoutTimer = setTimeout(() => {
                    if (!this._isMounted || this.status !== 'Paused') return;
                    this.resumeLoading = false;
                    this.resumeSlowerActive = false;
                    this.dispatchEvent(new CustomEvent('showerror', {
                        detail: { message: 'Resume is taking longer than expected. The scan will continue when the current step finishes. Try resuming again if this persists.' },
                        bubbles: true, composed: true
                    }));
                }, RESUME_TIMEOUT);
            }
            if (status && !['Completed', 'Failed', 'Cancelled'].includes(status)) {
                this._startPolling();
            } else {
                this.showPollingNotice = false;
            }
        } catch {
            if (!this._isMounted) return;
            this._pollFailCount++;
            if (this._pollFailCount >= 5) {
                this._stopPolling();
                this.showPollErrorBanner = true;
            } else if (this._pollFailCount >= 3) {
                this.showPollWarningBanner = true;
                this._startPolling();
            } else {
                this._startPolling();
            }
        }
    }

    // --- Cancel flow ---

    handleCancelClick() {
        this.showCancelModal = true;
        setTimeout(() => {
            const btn = this.template.querySelector('[data-id="keepRunningBtn"]');
            if (btn) btn.focus();
        }, 0);
    }

    handleKeepRunning() {
        this.showCancelModal = false;
        setTimeout(() => {
            const btn = this.template.querySelector('.cancel-btn');
            if (btn) btn.focus();
        }, 0);
    }

    async handleConfirmCancel() {
        this.showCancelModal = false;
        this.cancelDisabled = true;
        this.cancelLabel = 'Cancelling...';
        this.showCancellingSubtext = true;
        try {
            await cancelJob({ jobId: this.jobId });
            this._cancelPhase = 'cancelling';
            this._cancelTimeoutTimer = setTimeout(() => {
                if (!this._isMounted || this._cancelPhase !== 'cancelling') return;
                this.cancelDisabled = false;
                this.cancelLabel = 'Cancel';
                this.showCancellingSubtext = false;
                this.showCancelTimeoutBanner = true;
                this._cancelPhase = 'timeout';
            }, CANCEL_CONFIRM_TIMEOUT);
            this._startPolling();
        } catch (e) {
            this.cancelDisabled = false;
            this.cancelLabel = 'Cancel';
            this.showCancellingSubtext = false;
            this._cancelPhase = 'idle';
            const msg = (e.body && e.body.message) ? e.body.message : 'Could not cancel the scan.';
            this.dispatchEvent(new CustomEvent('showerror', { detail: { message: msg }, bubbles: true, composed: true }));
        }
    }

    // --- Resume flow ---

    async handleResumeSlower() {
        await this._resume(true);
    }

    async handleResumeCurrent() {
        await this._resume(false);
    }

    async _resume(slower) {
        this._isResuming = true;
        this.resumeLoading = true;
        this.resumeSlowerActive = slower;
        const currentBatchSize = this._effectiveBatchSize();
        const overrideBatchSize = slower ? Math.max(1, Math.floor(currentBatchSize / 2)) : currentBatchSize;
        try {
            await resumeJob({ jobId: this.jobId, overrideBatchSize });
            this._startPolling();
            // Initial timeout; _poll() resets this on each Paused-confirming poll.
            this._resumeTimeoutTimer = setTimeout(() => {
                if (!this._isMounted || this.status !== 'Paused') return;
                this.resumeLoading = false;
                this.resumeSlowerActive = false;
                this.dispatchEvent(new CustomEvent('showerror', {
                    detail: { message: 'Resume is taking longer than expected. The scan will continue when the current step finishes. Try resuming again if this persists.' },
                    bubbles: true, composed: true
                }));
            }, RESUME_TIMEOUT);
        } catch (e) {
            this._isResuming = false;
            this.resumeLoading = false;
            this.resumeSlowerActive = false;
            const msg = (e.body && e.body.message) ? e.body.message : 'Could not resume the scan.';
            this.dispatchEvent(new CustomEvent('showerror', {
                detail: { message: `Could not resume the scan. ${msg}` },
                bubbles: true, composed: true
            }));
        }
    }

    // --- Actions ---

    handleViewPartialResults() {
        this.dispatchEvent(new CustomEvent('viewpartialresults', { bubbles: true, composed: true }));
    }

    handleStartNew() {
        this.dispatchEvent(new CustomEvent('startnew', { bubbles: true, composed: true }));
    }

    dismissLongRunningBanner() {
        this.showLongRunningBanner = false;
        this.longRunningBannerDismissed = true;
    }

    handleRetryPolling() {
        this._pollFailCount = 0;
        this.showPollErrorBanner = false;
        this._startPolling();
    }
}
