import { LightningElement, api, track } from 'lwc';
import cancelJob from '@salesforce/apex/DependencyJobController.cancelJob';
import resumeJob from '@salesforce/apex/DependencyJobController.resumeJob';
import getJobStatus from '@salesforce/apex/DependencyJobController.getJobStatus';
import { formatElapsed } from 'c/metaMapperFormatters';

const POLL_INTERVAL_PROCESSING = 5000;
const POLL_INTERVAL_PAUSED     = 10000;
const LONG_RUN_THRESHOLD_SEC   = 900;
const TIMEOUT_THRESHOLD_SEC    = 3600;
const CANCEL_CONFIRM_TIMEOUT   = 30000;
const RESUME_TIMEOUT           = 30000;

export default class MetaMapperProgress extends LightningElement {
    @api jobId;
    @api job;
    @api maxComponentsCap;

    @track cancelDisabled = false;
    @track cancelLabel = 'Cancel';
    @track showCancelModal = false;
    @track showCancellingSubtext = false;
    @track showCancelTimeoutBanner = false;
    @track showLongRunningBanner = false;
    @track showTimeoutBanner = false;
    @track longRunningBannerDismissed = false;
    @track resumeLoading = false;
    @track resumeError = '';
    @track showPollingNotice = false;
    @track pollingNoticeText = '';

    _isMounted = false;
    _pollTimer = null;
    _elapsedTimer = null;
    _cancelTimeoutTimer = null;
    _cancelPhase = 'idle';
    _elapsedTick = 0;
    _resumeTimeoutTimer = null;

    connectedCallback() {
        this._isMounted = true;
        this._startElapsedTimer();
    }

    disconnectedCallback() {
        this._isMounted = false;
        clearTimeout(this._pollTimer);
        clearInterval(this._elapsedTimer);
        clearTimeout(this._cancelTimeoutTimer);
        clearTimeout(this._resumeTimeoutTimer);
    }

    @api
    handleStatusEvent(eventData) {
        if (!this._isMounted) return;
        if (eventData && eventData.peSuppressionActive) {
            this._startPolling();
        }
    }

    // --- Computed getters ---

    get status() { return (this.job && this.job.Status__c) || ''; }
    get isPaused() { return this.status === 'Paused'; }
    get isProcessing() { return this.status === 'Processing' || this.status === 'Initializing'; }
    get isTerminal() { return ['Completed', 'Failed', 'Cancelled'].includes(this.status); }

    get showStatusLabel() { return !this.isPaused && !this.showTimeoutBanner; }
    get showCancelButton() {
        return !this.isTerminal && this._cancelPhase !== 'cancelled' && !this.showTimeoutBanner;
    }

    get showProgressBar() {
        if (!this.job) return false;
        const cap = this.maxComponentsCap || 0;
        return cap > 0 && this.isProcessing;
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
        // Reference _elapsedTick so LWC re-evaluates this getter each second
        return this._elapsedTick >= 0 ? formatElapsed(this.job.CreatedDate) : '00:00';
    }

    get resumeCurrentLabel() {
        const size = (this.job && this.job.Batch_Size_Override__c) || 50;
        return `Resume with current settings (batch size: ${size})`;
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
            case 'Cancelled':    return `Analysis of ${name} cancelled. Partial results are available below.`;
            default: return '';
        }
    }

    // --- Elapsed timer ---

    _startElapsedTimer() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._elapsedTimer = setInterval(() => {
            if (!this._isMounted) return;
            this._elapsedTick++;
            if (this.job && this.job.CreatedDate) {
                const elapsed = Math.floor((Date.now() - new Date(this.job.CreatedDate).getTime()) / 1000);
                if (elapsed > TIMEOUT_THRESHOLD_SEC && this.isProcessing) {
                    this.showTimeoutBanner = true;
                    this.showLongRunningBanner = false;
                    this._stopPolling();
                } else if (elapsed > LONG_RUN_THRESHOLD_SEC && this.isProcessing && !this.longRunningBannerDismissed) {
                    this.showLongRunningBanner = true;
                }
            }
        }, 1000);
    }

    // --- Polling ---

    _startPolling() {
        this._stopPolling();
        const interval = this.isPaused ? POLL_INTERVAL_PAUSED : POLL_INTERVAL_PROCESSING;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._pollTimer = setTimeout(() => this._poll(), interval);
        this.showPollingNotice = true;
        this.pollingNoticeText = this.isPaused
            ? 'Live updates paused - refreshing every 10 seconds.'
            : 'Live updates paused - refreshing every 5 seconds.';
    }

    _stopPolling() {
        clearTimeout(this._pollTimer);
        this._pollTimer = null;
    }

    async _poll() {
        if (!this._isMounted || this.isTerminal) return;
        try {
            const result = await getJobStatus({ jobId: this.jobId });
            if (!this._isMounted) return;
            this.dispatchEvent(new CustomEvent('jobstatuspolled', {
                detail: result, bubbles: true, composed: true
            }));
            if (result && result.Status__c === 'Cancelled' && this._cancelPhase === 'cancelling') {
                this._cancelPhase = 'cancelled';
                clearTimeout(this._cancelTimeoutTimer);
            }
            if (result && !['Completed', 'Failed', 'Cancelled'].includes(result.Status__c)) {
                this._startPolling();
            } else {
                this.showPollingNotice = false;
            }
        } catch {
            if (this._isMounted) this._startPolling();
        }
    }

    // --- Cancel flow ---

    handleCancelClick() {
        this.showCancelModal = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const btn = this.template.querySelector('[aria-label="Keep the scan running - do not cancel"]');
            if (btn) btn.focus();
        }, 0);
    }

    handleKeepRunning() {
        this.showCancelModal = false;
    }

    async handleConfirmCancel() {
        this.showCancelModal = false;
        this.cancelDisabled = true;
        this.cancelLabel = 'Cancelling...';
        this.showCancellingSubtext = true;
        try {
            await cancelJob({ jobId: this.jobId });
            this._cancelPhase = 'cancelling';
            // eslint-disable-next-line @lwc/lwc/no-async-operation
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
        this.resumeLoading = true;
        this.resumeError = '';
        const currentBatchSize = (this.job && this.job.Batch_Size_Override__c) || 50;
        const overrideBatchSize = slower ? Math.max(1, Math.floor(currentBatchSize / 2)) : currentBatchSize;
        try {
            await resumeJob({ jobId: this.jobId, overrideBatchSize });
            this._startPolling();
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this._resumeTimeoutTimer = setTimeout(() => {
                if (!this._isMounted || this.status !== 'Paused') return;
                this.resumeLoading = false;
                this.resumeError = 'Resume is taking longer than expected. The scan will continue when the current step finishes. Try resuming again if this persists.';
            }, RESUME_TIMEOUT);
        } catch (e) {
            const msg = (e.body && e.body.message) ? e.body.message : 'Could not resume the scan.';
            this.resumeError = `Could not resume the scan. ${msg}`;
        } finally {
            this.resumeLoading = false;
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
}
