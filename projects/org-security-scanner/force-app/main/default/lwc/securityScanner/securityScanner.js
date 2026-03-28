import { LightningElement, wire, track } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import startScan               from '@salesforce/apex/SecScanController.startScan';
import getScanRuns             from '@salesforce/apex/SecScanController.getScanRuns';
import getOrgInfo              from '@salesforce/apex/SecScanController.getOrgInfo';
import getOrgSecuritySettings  from '@salesforce/apex/SecScanController.getOrgSecuritySettings';
import getScanRunStatus        from '@salesforce/apex/SecScanController.getScanRunStatus';
import cancelScan              from '@salesforce/apex/SecScanController.cancelScan';
import exportFindingsCsv       from '@salesforce/apex/SecScanController.exportFindingsCsv';
import getCurrentScanFindings  from '@salesforce/apex/SecScanFindingsController.getCurrentScanFindings';
import getScoreCounts          from '@salesforce/apex/SecScanFindingsController.getScoreCounts';
import updateFindingStatus     from '@salesforce/apex/SecScanFindingsController.updateFindingStatus';
import bulkUpdateFindingStatus from '@salesforce/apex/SecScanFindingsController.bulkUpdateFindingStatus';

import {
    SCAN_STATUS,
    PAGE_SIZE,
    POLL_INTERVAL_INITIAL_MS,
    POLL_INTERVAL_MEDIUM_MS,
    POLL_INTERVAL_SLOW_MS,
    POLL_MEDIUM_CUTOFF_MS,
    POLL_SLOW_CUTOFF_MS,
    SCAN_COOLDOWN_MS
} from 'c/secScanConstants';

// Poll phases - maps to which setInterval bucket is active
const POLL_PHASE_FAST   = 1; // 0-20s  -> 2s
const POLL_PHASE_MEDIUM = 2; // 20-60s -> 5s
const POLL_PHASE_SLOW   = 3; // 60s+   -> 10s

export default class SecurityScanner extends LightningElement {

    // =========================================================================
    // @wire adapters
    // =========================================================================

    @wire(getScanRuns)            _scanRunsWire;
    @wire(getOrgInfo)             _orgInfoWire;
    @wire(getOrgSecuritySettings) _orgSettingsWire;

    // =========================================================================
    // Reactive state
    // =========================================================================

    @track _currentScanId       = null;
    @track _latestScanId        = null;
    @track _scanStatus          = null;
    @track _activeTab           = 'dashboard';
    @track _activeView          = 'dashboard';
    @track _isHistoricalView    = false;
    @track _allFindings         = [];
    @track _hasMore             = false;
    @track _lastSeenId          = null;
    @track _lastRank            = null;
    @track _isLoadingMore       = false;
    @track _activeFilters       = {
        category    : '',
        severity    : '',
        findingType : '',
        statuses    : [],
        searchTerm  : ''
    };
    @track _isExportLoading     = false;
    @track _scoreCounts         = null;
    @track _isLeftPanelCollapsed = false;
    @track _selectedFindingId   = null;
    @track _selectedFindingIndex = 0;
    @track _isDetailOpen        = false;
    @track _activeDetailTab     = 'details';
    @track _cooldownSeconds     = 0;
    @track _fatalError          = null;
    @track _isScanRunning       = false;

    // Polling internals - not tracked (no render dependency)
    _pollInterval    = null;
    _pollStartTime   = null;
    _pollPhase       = POLL_PHASE_FAST;
    _cooldownInterval = null;

    // Flag to prevent double-initialisation from wire re-runs
    _initialised = false;

    // =========================================================================
    // Lifecycle
    // =========================================================================

    connectedCallback() {
        // Wire may have already resolved synchronously in some SSR/test contexts;
        // the wiredCallback setter handles the real init.
    }

    disconnectedCallback() {
        this._clearPollInterval();
        this._clearCooldownInterval();
    }

    errorCallback(error /*, stack */) {
        this._fatalError = (error && error.message) ? error.message : String(error);
    }

    // =========================================================================
    // Wire result setters - used to trigger initialisation on first data arrival
    // =========================================================================

    // Watched via getter; when _scanRunsWire.data arrives we initialise once.
    get _scanRunsResolved() {
        return !!(this._scanRunsWire && this._scanRunsWire.data);
    }

    // =========================================================================
    // Wire result getters (null-safe)
    // =========================================================================

    get scanRuns() {
        const raw = this._scanRunsWire?.data;
        if (!raw) return [];
        // Apex returns SecScanApiResponse; unwrap .data
        if (raw && raw.success !== undefined) {
            return Array.isArray(raw.data) ? raw.data : [];
        }
        return Array.isArray(raw) ? raw : [];
    }

    get orgInfo() {
        const raw = this._orgInfoWire?.data;
        if (!raw) return { isSandbox: true, orgId: '', orgName: '' };
        if (raw && raw.success !== undefined) {
            return raw.data || { isSandbox: true, orgId: '', orgName: '' };
        }
        return raw;
    }

    get orgSettings() {
        const raw = this._orgSettingsWire?.data;
        if (!raw) return null;
        if (raw && raw.success !== undefined) {
            return raw.data || null;
        }
        return raw;
    }

    get currentScanRun() {
        if (!this._currentScanId) return null;
        return this.scanRuns.find(r => r.Id === this._currentScanId) || null;
    }

    get maxScanRuns() {
        return this.orgSettings?.maxScanRuns ?? null;
    }

    // =========================================================================
    // Derived view getters
    // =========================================================================

    get showProgressView() {
        return this._isScanRunning;
    }

    get showDashboard() {
        return !this._isScanRunning && this._activeTab === 'dashboard';
    }

    get showFindings() {
        return !this._isScanRunning && this._activeTab === 'findings';
    }

    get showHistory() {
        return !this._isScanRunning && this._activeTab === 'history';
    }

    get detailPanelClass() {
        return this._isDetailOpen ? 'detail-panel detail-panel--open' : 'detail-panel';
    }

    get isProductionOrg() {
        return this.orgInfo.isSandbox === false;
    }

    get selectedFinding() {
        return this._allFindings[this._selectedFindingIndex] || null;
    }

    /**
     * True when the currently selected index is the last loaded finding AND
     * there are still more pages on the server.
     */
    get isLastLoadedFinding() {
        return this._selectedFindingIndex === this._allFindings.length - 1 && this._hasMore;
    }

    get hasScan() {
        return this.scanRuns.length > 0;
    }

    get findingCount() {
        return this.currentScanRun?.TotalFindings__c ?? 0;
    }

    // Progress view props
    get _completedCategories() {
        return this.currentScanRun?.CompletedCategories__c || '';
    }

    get _failedCategories() {
        return this.currentScanRun?.FailedCategories__c || '';
    }

    // =========================================================================
    // Wire result watcher - initialise once scanRuns are available
    // =========================================================================

    /**
     * LWC does not have a "wiredPropertyChanged" hook.
     * We use a rendered-callback guard to detect first data arrival.
     */
    renderedCallback() {
        if (!this._initialised && this._scanRunsResolved) {
            this._initialised = true;
            this._initialiseScanState();
        }
    }

    _initialiseScanState() {
        const runs = this.scanRuns;
        if (!runs || runs.length === 0) return;

        // Most recent run is first (ORDER BY CreatedDate DESC in Apex)
        const latest = runs[0];
        this._currentScanId = latest.Id;
        this._latestScanId  = latest.Id;
        this._scanStatus    = latest.Status__c;

        // If the run is still in progress, reconnect polling
        if (
            latest.Status__c === SCAN_STATUS.PENDING ||
            latest.Status__c === SCAN_STATUS.RUNNING
        ) {
            this._isScanRunning = true;
            this._startPolling();
        } else {
            // Load findings for the current run
            this._loadFindings(true);
            this._refreshScoreCounts();
        }
    }

    // =========================================================================
    // Scan execution
    // =========================================================================

    handleRunScan() {
        const isProd = this.isProductionOrg;
        const confirmMsg = isProd
            ? 'WARNING: You are about to scan a PRODUCTION org. This is read-only but will consume API and query limits. Proceed?'
            : 'Start a new security scan?';

        // eslint-disable-next-line no-alert
        if (!window.confirm(confirmMsg)) return;

        startScan()
            .then(response => {
                if (!response || !response.success) {
                    this._toast(
                        'Scan Failed to Start',
                        response?.errorMessage || 'Unknown error.',
                        'error'
                    );
                    return;
                }
                const scanRunId = response.data;
                this._isScanRunning  = true;
                this._currentScanId  = scanRunId;
                this._latestScanId   = scanRunId;
                this._scanStatus     = SCAN_STATUS.PENDING;
                this._allFindings    = [];
                this._hasMore        = false;
                this._lastSeenId     = null;
                this._lastRank       = null;
                this._startPolling();
            })
            .catch(err => {
                this._toast(
                    'Scan Failed to Start',
                    this._extractError(err),
                    'error'
                );
            });
    }

    // =========================================================================
    // Polling
    // =========================================================================

    _startPolling() {
        this._clearPollInterval();
        this._pollStartTime = Date.now();
        this._pollPhase     = POLL_PHASE_FAST;
        this._pollInterval  = setInterval(
            () => this._pollTick(),
            POLL_INTERVAL_INITIAL_MS
        );
    }

    _clearPollInterval() {
        if (this._pollInterval !== null) {
            clearInterval(this._pollInterval);
            this._pollInterval = null;
        }
    }

    _stopPolling() {
        this._clearPollInterval();
        this._pollStartTime = null;
    }

    _pollTick() {
        if (!this._currentScanId) return;

        // Phase upgrade: restart interval at lower frequency
        const elapsed = Date.now() - (this._pollStartTime || Date.now());

        if (this._pollPhase === POLL_PHASE_FAST && elapsed >= POLL_MEDIUM_CUTOFF_MS) {
            this._clearPollInterval();
            this._pollPhase    = POLL_PHASE_MEDIUM;
            this._pollInterval = setInterval(
                () => this._pollTick(),
                POLL_INTERVAL_MEDIUM_MS
            );
        } else if (this._pollPhase === POLL_PHASE_MEDIUM && elapsed >= POLL_SLOW_CUTOFF_MS) {
            this._clearPollInterval();
            this._pollPhase    = POLL_PHASE_SLOW;
            this._pollInterval = setInterval(
                () => this._pollTick(),
                POLL_INTERVAL_SLOW_MS
            );
        }

        getScanRunStatus({ scanRunId: this._currentScanId })
            .then(response => {
                if (!response || !response.success) return;

                const dto = response.data;
                if (!dto) return;

                this._scanStatus = dto.status;

                // Update completedCategories on the live run so the progress
                // component reflects real-time category completion.
                // We do this by refreshing the wire (which re-renders the run).
                if (
                    dto.status === SCAN_STATUS.COMPLETED ||
                    dto.status === SCAN_STATUS.FAILED    ||
                    dto.status === SCAN_STATUS.CANCELLED
                ) {
                    this._stopPolling();
                    this._onScanComplete(dto.status);
                }
            })
            .catch(() => {
                // Transient poll failure - do not stop polling
            });
    }

    // =========================================================================
    // Post-scan completion
    // =========================================================================

    _onScanComplete(status) {
        this._isScanRunning = false;

        // Refresh the wire to pick up the completed run record
        refreshApex(this._scanRunsWire)
            .catch(() => {/* non-fatal */});

        // Load findings and score counts
        this._refreshScoreCounts();
        this._loadFindings(true);

        // Switch back to dashboard view
        this._activeTab  = 'dashboard';
        this._activeView = 'dashboard';

        // Toast per terminal status
        if (status === SCAN_STATUS.COMPLETED) {
            this._toast('Scan Complete', 'Security scan finished successfully.', 'success');
            this._startCooldown();
        } else if (status === SCAN_STATUS.FAILED) {
            this._toast('Scan Failed', 'The scan encountered errors. Review partial findings.', 'error');
            this._startCooldown();
        } else if (status === SCAN_STATUS.CANCELLED) {
            this._toast('Scan Cancelled', 'The scan was cancelled.', 'warning');
            // No cooldown after cancel
        }
    }

    // =========================================================================
    // Cooldown
    // =========================================================================

    _startCooldown() {
        this._clearCooldownInterval();
        this._cooldownSeconds  = Math.round(SCAN_COOLDOWN_MS / 1000);
        this._cooldownInterval = setInterval(() => {
            if (this._cooldownSeconds > 0) {
                this._cooldownSeconds -= 1;
            } else {
                this._clearCooldownInterval();
            }
        }, 1000);
    }

    _clearCooldownInterval() {
        if (this._cooldownInterval !== null) {
            clearInterval(this._cooldownInterval);
            this._cooldownInterval = null;
        }
    }

    // =========================================================================
    // Findings loading (KEYSET paginated)
    // =========================================================================

    _loadFindings(reset = false) {
        if (!this._currentScanId) return;

        if (reset) {
            this._allFindings = [];
            this._lastSeenId  = null;
            this._lastRank    = null;
            this._hasMore     = false;
        }

        if (this._isLoadingMore) return; // guard against concurrent calls
        this._isLoadingMore = true;

        const params = {
            scanRunId  : this._currentScanId,
            lastSeenId : this._lastSeenId,
            lastRank   : this._lastRank,
            pageSize   : PAGE_SIZE,
            searchTerm : this._activeFilters.searchTerm || null
        };

        getCurrentScanFindings(params)
            .then(response => {
                this._isLoadingMore = false;
                if (!response || !response.success) return;

                const dto = response.data;
                if (!dto) return;

                const page = Array.isArray(dto.findings) ? dto.findings : [];
                this._allFindings = [...this._allFindings, ...page];
                this._hasMore     = !!dto.hasMore;
                this._lastSeenId  = dto.lastSeenId || null;
                this._lastRank    = dto.lastRank    != null ? dto.lastRank : null;
            })
            .catch(() => {
                this._isLoadingMore = false;
                this._toast('Load Error', 'Failed to load findings. Please try again.', 'error');
            });
    }

    _refreshScoreCounts() {
        if (!this._currentScanId) return;
        getScoreCounts({ scanRunId: this._currentScanId })
            .then(response => {
                if (!response || !response.success) return;
                this._scoreCounts = response.data || null;
            })
            .catch(() => {/* non-fatal */});
    }

    // =========================================================================
    // Event handlers - scan controls
    // =========================================================================

    handleCancelScan() {
        // eslint-disable-next-line no-alert
        if (!window.confirm('Cancel the running scan?')) return;

        cancelScan({ scanRunId: this._currentScanId })
            .then(response => {
                if (!response || !response.success) {
                    this._toast('Cancel Failed', response?.errorMessage || 'Unknown error.', 'error');
                    return;
                }
                this._isScanRunning = false;
                this._stopPolling();
                this._toast('Scan Cancelled', 'The scan has been cancelled.', 'warning');
                refreshApex(this._scanRunsWire).catch(() => {/* non-fatal */});
            })
            .catch(err => {
                this._toast('Cancel Failed', this._extractError(err), 'error');
            });
    }

    handleExportCsv() {
        if (!this._currentScanId) return;
        this._isExportLoading = true;

        exportFindingsCsv({ scanRunId: this._currentScanId })
            .then(response => {
                this._isExportLoading = false;
                if (!response || !response.success) {
                    this._toast('Export Failed', response?.errorMessage || 'Unknown error.', 'error');
                    return;
                }
                const contentDocId = response.data;
                const downloadUrl  = `/sfc/servlet.shepherd/document/download/${contentDocId}?operationContext=S1`;
                this._toast(
                    'Export Ready',
                    `CSV generated. Click to download.`,
                    'success',
                    'sticky'
                );
                // Open download in new tab
                window.open(downloadUrl, '_blank', 'noopener,noreferrer');
            })
            .catch(err => {
                this._isExportLoading = false;
                this._toast('Export Failed', this._extractError(err), 'error');
            });
    }

    // =========================================================================
    // Event handlers - navigation / tabs
    // =========================================================================

    handleTabSwitch(event) {
        const tab = event.detail?.tab;
        if (tab) {
            this._activeTab  = tab;
            this._activeView = tab;
        }
    }

    handleCategorySelect(event) {
        const category = event.detail?.categoryName || '';
        this._activeFilters = { ...this._activeFilters, category };
        this._activeTab     = 'findings';
        this._loadFindings(true);
    }

    handleSeverityFilterSelect(event) {
        const severity = event.detail?.severity || '';
        this._activeFilters = { ...this._activeFilters, severity };
        this._activeTab     = 'findings';
        this._loadFindings(true);
    }

    handleClearFilters() {
        this._activeFilters = {
            category    : '',
            severity    : '',
            findingType : '',
            statuses    : [],
            searchTerm  : ''
        };
        this._loadFindings(true);
    }

    handleFilterChange(event) {
        const filters = event.detail?.filters;
        if (!filters) return;
        this._activeFilters = filters;
        this._loadFindings(true);
    }

    handleLoadMore() {
        this._loadFindings(false);
    }

    handlePanelToggle(event) {
        this._isLeftPanelCollapsed = !!(event.detail?.collapsed);
    }

    // =========================================================================
    // Event handlers - history navigation
    // =========================================================================

    handleViewHistoricalScan(event) {
        const scanRunId = event.detail?.scanRunId;
        if (!scanRunId) return;

        // Preserve the live scan pointer
        if (!this._isHistoricalView) {
            this._latestScanId = this._currentScanId;
        }

        this._currentScanId     = scanRunId;
        this._isHistoricalView  = true;
        this._allFindings       = [];
        this._lastSeenId        = null;
        this._lastRank          = null;
        this._hasMore           = false;
        this._isDetailOpen      = false;
        this._activeTab         = 'dashboard';
        this._activeView        = 'dashboard';

        this._loadFindings(true);
        this._refreshScoreCounts();
    }

    handleReturnToCurrentScan() {
        if (!this._latestScanId) return;

        this._currentScanId    = this._latestScanId;
        this._isHistoricalView = false;
        this._allFindings      = [];
        this._lastSeenId       = null;
        this._lastRank         = null;
        this._hasMore          = false;
        this._isDetailOpen     = false;

        this._loadFindings(true);
        this._refreshScoreCounts();
    }

    // =========================================================================
    // Event handlers - finding detail panel
    // =========================================================================

    handleFindingSelect(event) {
        const findingId = event.detail?.findingId;
        if (!findingId) return;

        const idx = this._allFindings.findIndex(f => f.Id === findingId);
        this._selectedFindingId    = findingId;
        this._selectedFindingIndex = idx >= 0 ? idx : 0;
        this._activeDetailTab      = event.detail?.openTab || 'details';
        this._isDetailOpen         = true;
    }

    handleCloseDetail() {
        this._isDetailOpen = false;
    }

    /**
     * The finding-detail panel emits 'tabswitch' when the user toggles
     * between its Details / Status tabs. This is scoped to the detail panel
     * and must NOT propagate to the main tab handler.
     */
    handleDetailTabSwitch(event) {
        event.stopPropagation();
        const tab = event.detail?.tab;
        if (tab === 'details' || tab === 'status') {
            this._activeDetailTab = tab;
        }
    }

    handlePreviousFinding() {
        if (this._selectedFindingIndex <= 0) return;
        this._selectedFindingIndex -= 1;
        this._selectedFindingId     = this._allFindings[this._selectedFindingIndex]?.Id || null;
    }

    handleNextFinding() {
        const nextIdx = this._selectedFindingIndex + 1;
        if (nextIdx >= this._allFindings.length) return;
        this._selectedFindingIndex = nextIdx;
        this._selectedFindingId    = this._allFindings[nextIdx]?.Id || null;
    }

    // =========================================================================
    // Event handlers - status mutations
    // =========================================================================

    handleStatusChange(event) {
        const { findingId, status, note } = event.detail || {};
        if (!findingId || !status) return;

        updateFindingStatus({ findingId, status, note: note || null })
            .then(response => {
                if (!response || !response.success) {
                    this._toast('Update Failed', response?.errorMessage || 'Unknown error.', 'error');
                    return;
                }
                // Patch in-memory to avoid a full reload for single-record mutations
                this._patchFindingStatus(findingId, status);
                this._refreshScoreCounts();
                refreshApex(this._scanRunsWire).catch(() => {/* non-fatal */});
                this._toast('Status Updated', `Finding status changed to ${status}.`, 'success');
            })
            .catch(err => {
                this._toast('Update Failed', this._extractError(err), 'error');
            });
    }

    handleBulkStatusChange(event) {
        const { findingIds, status, note } = event.detail || {};
        if (!Array.isArray(findingIds) || findingIds.length === 0 || !status) return;

        bulkUpdateFindingStatus({ findingIds, status, note: note || null })
            .then(response => {
                if (!response) return;

                if (response.success && !response.errorMessage) {
                    this._toast(
                        'Bulk Update Complete',
                        `${findingIds.length} finding(s) updated to ${status}.`,
                        'success'
                    );
                } else if (response.success && response.errorMessage) {
                    // Partial success - some findings were skipped (invalid transition)
                    this._toast('Partial Update', response.errorMessage, 'warning');
                } else {
                    this._toast('Bulk Update Failed', response.errorMessage || 'Unknown error.', 'error');
                    return;
                }

                this._refreshScoreCounts();
                this._loadFindings(true);
            })
            .catch(err => {
                this._toast('Bulk Update Failed', this._extractError(err), 'error');
            });
    }

    // =========================================================================
    // Private helpers
    // =========================================================================

    /**
     * Patch a single finding's Status__c in the local array after a successful
     * status update, avoiding a full reload for single-record mutations.
     */
    _patchFindingStatus(findingId, newStatus) {
        const idx = this._allFindings.findIndex(f => f.Id === findingId);
        if (idx === -1) return;
        // Create a shallow copy to trigger reactivity
        const updated = { ...this._allFindings[idx], Status__c: newStatus };
        const copy    = [...this._allFindings];
        copy[idx]     = updated;
        this._allFindings = copy;
    }

    /**
     * Dispatch a ShowToastEvent.
     * @param {string} title
     * @param {string} message
     * @param {'success'|'error'|'warning'|'info'} variant
     * @param {'dismissible'|'sticky'|'pester'} mode
     */
    _toast(title, message, variant, mode = 'dismissible') {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode }));
    }

    /**
     * Extract a human-readable error message from various error shapes.
     */
    _extractError(err) {
        if (!err) return 'Unknown error.';
        if (typeof err === 'string') return err;
        if (err.body && err.body.message) return err.body.message;
        if (err.message) return err.message;
        return JSON.stringify(err);
    }
}
