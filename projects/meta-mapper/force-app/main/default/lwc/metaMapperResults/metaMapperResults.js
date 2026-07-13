import { LightningElement, api, track } from 'lwc';
import getNodeHierarchy from '@salesforce/apex/DependencyJobController.getNodeHierarchy';
import getJobStatus from '@salesforce/apex/DependencyJobController.getJobStatus';
import isCopilotEnabled from '@salesforce/apex/DependencyJobController.isCopilotEnabled';
import { loadFilters, saveFilters, validateFilters, DEFAULT_FILTERS } from 'c/metaMapperFilters';
import { buildTypeCounts, applyFilters, buildNodeMap, extractTypes } from 'c/metaMapperNodeServices';
import { truncateAt } from 'c/metaMapperFormatters';

const SUMMARY_POLL_INTERVAL = 5000;
const SUMMARY_MAX_POLLS = 6;
const TAB_TRANSITION_TIMEOUT = 3000;
const TAB_TRANSITION_MIN_MS = 300;

const TYPE_ICONS = {
    ApexClass:      'utility:apex',
    ApexTrigger:    'utility:apex',
    Flow:           'utility:flow',
    CustomField:    'utility:custom_apps',
    ValidationRule: 'utility:rules',
    WorkflowRule:   'utility:process',
    Report:         'utility:report'
};

export default class MetaMapperResults extends LightningElement {
    @api jobId;
    @api job;
    @api orgId = '';
    @api retentionHours = 72;
    @api peSuppressionActive = false;

    @track allNodes = [];
    @track filters = { ...DEFAULT_FILTERS };
    @track selectedNodeId = null;
    @track isLoading = true;
    @track loadError = '';
    @track showResultFileDeletedHelp = false;
    @track summaryText = '';
    @track summaryLoading = false;
    @track summaryFailed = false;
    @track summaryDismissed = false;
    @track summaryExpanded = false;
    @track copyLabel = 'Copy';
    @track copilotEnabled = false;
    @track showReloadBanner = false;
    @track showPartialBanner = false;
    @track isTransitioning = false;
    @track activeTab = 'tree';
    @track tabLoadFailed = false;

    _summaryPollTimer = null;
    _summaryPollCount = 0;
    _tabReadyTimer = null;
    _statsAnnounceTimer = null;
    _tabReadyMinTimer = null;
    _copyLabelTimer = null;
    _isMounted = false;
    _filteredNodesCache = null;
    _nodeMapCache = null;
    _pendingNodeId = null;
    _pendingFocusNodeId = null;
    _copilotChecked = false;
    _copilotException = false;
    _isMobile = false;
    _resizeTimer = null;

    connectedCallback() {
        this._isMounted = true;
        this._isMobile = window.innerWidth < 1024;
        this._handleResize = () => {
            clearTimeout(this._resizeTimer);
            this._resizeTimer = setTimeout(() => {
                if (!this._isMounted) return;
                this._isMobile = window.innerWidth < 1024;
            }, 200);
        };
        window.addEventListener('resize', this._handleResize);
        this.filters = loadFilters();
        this._checkCopilot();
        this.loadResults();
    }

    disconnectedCallback() {
        this._isMounted = false;
        window.removeEventListener('resize', this._handleResize);
        clearTimeout(this._resizeTimer);
        clearTimeout(this._summaryPollTimer);
        clearTimeout(this._tabReadyTimer);
        clearTimeout(this._statsAnnounceTimer);
        clearTimeout(this._tabReadyMinTimer);
        clearTimeout(this._copyLabelTimer);
    }

    async _checkCopilot() {
        try {
            this.copilotEnabled = await isCopilotEnabled();
        } catch (e) {
            // Suppress silently in the UI (no button, no "not available" helper text) per spec -
            // but still log to the console so the failure isn't entirely invisible.
            console.error('MetaMapper: isCopilotEnabled() failed', e);
            this._copilotException = true;
        } finally {
            this._copilotChecked = true;
        }
    }

    get isMobile() { return this._isMobile; }
    get showCopilotButton() { return this.copilotEnabled && !this.isMobile; }
    get showCopilotNotAvailable() {
        return this._copilotChecked && !this.copilotEnabled && !this._copilotException && !this.isMobile;
    }

    @api
    setPendingNodeId(nodeId) {
        this._pendingNodeId = nodeId || null;
    }

    async loadResults() {
        this.isLoading = true;
        this.loadError = '';
        try {
            this.showReloadBanner = false;
            const nodes = await getNodeHierarchy({ jobId: this.jobId });
            if (!this._isMounted) return;
            this.allNodes = nodes || [];
            this._invalidateCaches();
            this._syncFiltersToNodes();
            this._scheduleStatsAnnouncement();
            this._startSummaryPollIfNeeded();
            if (this._pendingNodeId) {
                this.selectedNodeId = this._pendingNodeId;
                this._pendingNodeId = null;
            }
        } catch (e) {
            if (!this._isMounted) return;
            const msg = (e.body && e.body.message) ? e.body.message : 'The dependency data could not be loaded.';
            this.loadError = msg;
            this.showResultFileDeletedHelp = this.isCompleted;
        } finally {
            if (this._isMounted) this.isLoading = false;
        }
    }

    _syncFiltersToNodes() {
        const available = extractTypes(this.allNodes);
        const result = validateFilters(this.filters, available);
        const hadStale = this.filters.types.length > 0 && result.types.length < this.filters.types.length;
        if (hadStale) {
            this.dispatchEvent(new CustomEvent('filtersreset', { bubbles: true, composed: true }));
        }
        this.filters = result;
        this._invalidateCaches();
        saveFilters(this.filters);
    }

    _scheduleStatsAnnouncement() {
        clearTimeout(this._statsAnnounceTimer);
        this._statsAnnounceTimer = setTimeout(() => {
            if (!this._isMounted) return;
            const region = this.refs && this.refs.statsLiveRegion;
            if (!region || !this.typeCounts.length) return;
            region.textContent = 'Type counts updated: ' + this.typeCounts.map(tc => `${tc.label} (${tc.count})`).join(', ');
        }, 150);
    }

    _startSummaryPollIfNeeded() {
        if (!this.isCompleted) return;
        if (this.job && this.job.Scan_Summary_Text__c) {
            this.summaryText = this.job.Scan_Summary_Text__c;
            return;
        }
        this.summaryLoading = true;
        this._pollSummary();
    }

    _pollSummary() {
        if (!this._isMounted) return;
        this._summaryPollCount++;
        if (this._summaryPollCount > SUMMARY_MAX_POLLS) {
            this.summaryLoading = false;
            this.summaryFailed = true;
            return;
        }
        this._summaryPollTimer = setTimeout(async () => {
            try {
                const result = await getJobStatus({ jobId: this.jobId });
                if (!this._isMounted) return;
                // getJobStatus returns a JobStatusResult wrapper; the raw record is result.job
                if (result && result.job && result.job.Scan_Summary_Text__c) {
                    this.summaryText = result.job.Scan_Summary_Text__c;
                    this.summaryLoading = false;
                } else {
                    this._pollSummary();
                }
            } catch {
                this._pollSummary();
            }
        }, SUMMARY_POLL_INTERVAL);
    }

    _invalidateCaches() {
        this._filteredNodesCache = null;
        this._nodeMapCache = null;
    }

    // --- Computed getters ---

    get isTreeTab()   { return this.activeTab === 'tree'; }
    get showTreeLoadError()  { return this.tabLoadFailed && this.activeTab === 'tree'; }
    get showGraphLoadError() { return this.tabLoadFailed && this.activeTab === 'graph'; }
    get isCompleted() { return this.job && this.job.Status__c === 'Completed'; }
    get hasResults()  { return !this.isLoading && !this.loadError; }
    get isZeroResults() { return this.hasResults && this.allNodes.length === 0; }
    get showTabs() { return this.hasResults && this.allNodes.length > 0; }
    get targetApiName() { return (this.job && this.job.Target_API_Name__c) || ''; }

    get isSerializerFailure() {
        return this.job
            && this.job.Status__c === 'Failed'
            && this.job.Components_Analyzed__c > 0
            && !this.job.Result_File_Id__c
            && this.job.Has_Attempted_Result_Save__c === true;
    }

    get hasPartialNodes() { return this.allNodes && this.allNodes.length > 0; }
    get filteredNodes() {
        if (!this._filteredNodesCache) {
            this._filteredNodesCache = applyFilters(this.allNodes, this.filters);
        }
        return this._filteredNodesCache;
    }

    get nodeMap() {
        if (!this._nodeMapCache) {
            this._nodeMapCache = buildNodeMap(this.allNodes);
        }
        return this._nodeMapCache;
    }

    get selectedNode() {
        if (!this.selectedNodeId) return null;
        return this.nodeMap.get(this.selectedNodeId) || null;
    }

    get typeCounts() {
        const counts = buildTypeCounts(this.filteredNodes);
        return Object.entries(counts)
            .map(([type, count]) => ({
                type,
                count,
                label: type,
                icon: TYPE_ICONS[type] || 'utility:connected_apps'
            }))
            .sort((a, b) => b.count - a.count)
            .filter(tc => tc.count > 0);
    }

    get showStatsTile() {
        return this.isCompleted && this.typeCounts.length > 0;
    }

    get showStatsTileUnavailable() {
        return this.hasResults && !this.isCompleted && this.allNodes.length > 0;
    }

    get showSummaryCard() {
        return this.isCompleted && !this.summaryDismissed;
    }

    get summaryDisplayText() {
        if (!this.summaryText) return '';
        if (this.summaryExpanded) return this.summaryText;
        return truncateAt(this.summaryText, 300);
    }

    get summaryTruncated() { return this.summaryText && this.summaryText.length > 300; }
    get summaryToggleLabel() { return this.summaryExpanded ? 'Show less' : 'Show more'; }
    get tabContentClass() { return this.isTransitioning ? 'tab-content is-transitioning' : 'tab-content'; }
    get isTransitioningStr() { return this.isTransitioning ? 'true' : null; }
    get showStatsTileShimmer() {
        return this.isCompleted && this.job && !this.job.Component_Type_Counts__c && this.typeCounts.length === 0;
    }

    // --- Event handlers ---

    handleTabActivate(event) {
        const tabValue = event.detail && event.detail.value;
        if (tabValue) this._activateTab(tabValue);
    }

    _activateTab(tabValue) {
        this.activeTab = tabValue;
        this.isTransitioning = true;
        this.tabLoadFailed = false;
        this._updateTabInert(true);
        clearTimeout(this._tabReadyTimer);
        this._tabReadyTimer = setTimeout(() => {
            if (!this._isMounted) return;
            this.isTransitioning = false;
            this.tabLoadFailed = true;
            this._updateTabInert(false);
            if (!this.peSuppressionActive) { this._reconcileJobStatus(); }
        }, TAB_TRANSITION_TIMEOUT);
    }

    handleTabReady() {
        clearTimeout(this._tabReadyTimer);
        clearTimeout(this._tabReadyMinTimer);
        this._tabReadyMinTimer = setTimeout(() => {
            if (!this._isMounted) return;
            this.isTransitioning = false;
            this.tabLoadFailed = false;
            this._updateTabInert(false);
            if (!this.peSuppressionActive) { this._reconcileJobStatus(); }
            if (this._pendingFocusNodeId) {
                const nodeId = this._pendingFocusNodeId;
                this._pendingFocusNodeId = null;
                this.selectedNodeId = nodeId;
                const graphEl = this.template.querySelector('c-meta-mapper-graph');
                if (graphEl) graphEl.activateFocusPath(nodeId);
            }
        }, TAB_TRANSITION_MIN_MS);
    }

    _updateTabInert(inert) {
        const containers = this.template.querySelectorAll('[data-tab-content]');
        containers.forEach(el => {
            if (inert) {
                el.setAttribute('inert', '');
            } else {
                el.removeAttribute('inert');
            }
        });
    }

    _reconcileJobStatus() {
        if (this.isCompleted) return;
        getJobStatus({ jobId: this.jobId })
            .then(w => {
                if (this._isMounted && w) {
                    this.dispatchEvent(new CustomEvent('jobstatuspolled', {
                        detail: w, bubbles: true, composed: true
                    }));
                }
            })
            .catch(() => { /* reconciliation is best-effort */ });
    }

    handleNodeSelected(event) {
        if (this.isTransitioning) return;
        this.selectedNodeId = event.detail.nodeId || null;
    }

    handlePanelClosed() { this.selectedNodeId = null; }

    toggleSummaryExpanded() { this.summaryExpanded = !this.summaryExpanded; }
    dismissSummary() { this.summaryDismissed = true; }

    handleCopySummary() {
        navigator.clipboard.writeText(this.summaryText).then(() => {
            this.copyLabel = 'Copied!';
            const region = this.refs.copyLiveRegion;
            if (region) { region.textContent = 'Copied to clipboard.'; }
            clearTimeout(this._copyLabelTimer);
            this._copyLabelTimer = setTimeout(() => {
                this.copyLabel = 'Copy';
                if (region) { region.textContent = ''; }
            }, 2000);
        }).catch(() => {
            this.dispatchEvent(new CustomEvent('showtoast', {
                detail: { title: 'Error', message: 'Could not copy to clipboard. Your browser may require clipboard permission. Select and copy the text manually instead.', variant: 'error' },
                bubbles: true, composed: true
            }));
        });
    }

    handleAskCopilot() {
        this.dispatchEvent(new CustomEvent('askcopilot', {
            detail: { summaryText: this.summaryText }, bubbles: true, composed: true
        }));
    }

    reloadResults() { this.loadResults(); }
    handleStartNew() { this.dispatchEvent(new CustomEvent('startnew', { bubbles: true, composed: true })); }
    handleExportPartial() {
        const exportEl = this.template.querySelector('c-meta-mapper-export');
        if (exportEl) exportEl.exportCsv();
    }

    handleSwitchToTree() { this._activateTab('tree'); }
    handleRetryTab() { this._activateTab(this.activeTab); }

    handleGraphPathRequest(event) {
        const nodeId = event.detail && event.detail.nodeId;
        if (!nodeId) return;
        if (this.activeTab === 'graph' && !this.isTransitioning) {
            // Graph already rendered — activate focus path directly without tab switch.
            this.selectedNodeId = nodeId;
            const graphEl = this.template.querySelector('c-meta-mapper-graph');
            if (graphEl) graphEl.activateFocusPath(nodeId);
        } else {
            this._pendingFocusNodeId = nodeId;
            this._activateTab('graph');
        }
    }
    handleDownloadPartialCsv() {
        const exportEl = this.template.querySelector('c-meta-mapper-export');
        if (exportEl) exportEl.exportCsv();
    }
    handleDownloadPartialJson() {
        const exportEl = this.template.querySelector('c-meta-mapper-export');
        if (exportEl) exportEl.exportJson();
    }

    @api
    notifyStatusChange(newJob) {
        // Platform Events received during a tab transition are discarded, not queued -
        // the polling fallback/reconciliation call captures any missed status change (finding #7).
        if (!this._isMounted || this.isTransitioning) return;
        const wasCompleted = this.isCompleted;
        if (!wasCompleted && newJob && newJob.Status__c === 'Completed') {
            this.showReloadBanner = true;
        }
        if (newJob && ['Failed', 'Cancelled'].includes(newJob.Status__c)) {
            this.showPartialBanner = true;
        }
    }
}
