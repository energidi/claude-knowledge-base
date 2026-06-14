import { LightningElement, api, track } from 'lwc';
import getNodeHierarchy from '@salesforce/apex/DependencyJobController.getNodeHierarchy';
import getJobStatus from '@salesforce/apex/DependencyJobController.getJobStatus';
import isCopilotEnabled from '@salesforce/apex/DependencyJobController.isCopilotEnabled';
import { loadFilters, saveFilters, validateFilters, DEFAULT_FILTERS } from 'c/metaMapperFilters';
import { buildTypeCounts, applyFilters, buildNodeMap, extractTypes } from 'c/metaMapperNodeFilters';
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

    _summaryPollTimer = null;
    _summaryPollCount = 0;
    _tabReadyTimer = null;
    _isMounted = false;
    _filteredNodesCache = null;
    _nodeMapCache = null;

    connectedCallback() {
        this._isMounted = true;
        this.filters = loadFilters();
        this._checkCopilot();
        this.loadResults();
    }

    disconnectedCallback() {
        this._isMounted = false;
        clearTimeout(this._summaryPollTimer);
        clearTimeout(this._tabReadyTimer);
    }

    async _checkCopilot() {
        try {
            this.copilotEnabled = await isCopilotEnabled();
        } catch {
            // suppress — button is hidden on exception
        }
    }

    async loadResults() {
        this.isLoading = true;
        this.loadError = '';
        try {
            const nodes = await getNodeHierarchy({ jobId: this.jobId });
            if (!this._isMounted) return;
            this.allNodes = nodes || [];
            this._invalidateCaches();
            this._syncFiltersToNodes();
            this._startSummaryPollIfNeeded();
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
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._summaryPollTimer = setTimeout(async () => {
            try {
                const result = await getJobStatus({ jobId: this.jobId });
                if (!this._isMounted) return;
                if (result && result.Scan_Summary_Text__c) {
                    this.summaryText = result.Scan_Summary_Text__c;
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

    get isCompleted() { return this.job && this.job.Status__c === 'Completed'; }
    get hasResults()  { return !this.isLoading && !this.loadError; }
    get isZeroResults() { return this.hasResults && this.allNodes.length === 0; }
    get showTabs() { return this.hasResults && this.allNodes.length > 0; }
    get targetApiName() { return (this.job && this.job.Target_API_Name__c) || ''; }
    get retentionHours() { return (this.job && this.job.Retention_Hours__c) || 72; }

    get isSerializerFailure() {
        return this.job
            && this.job.Status__c === 'Failed'
            && this.job.Components_Analyzed__c > 0
            && !this.job.Result_File_Id__c
            && this.job.Result_Save_Attempted__c === true;
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
        if (!this.isCompleted) return this.allNodes.length > 0;
        return this.typeCounts.length > 0;
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

    // --- Event handlers ---

    handleTabActivate() {
        this.isTransitioning = true;
        clearTimeout(this._tabReadyTimer);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._tabReadyTimer = setTimeout(() => {
            if (!this._isMounted) return;
            this.isTransitioning = false;
        }, TAB_TRANSITION_TIMEOUT);
    }

    handleTabReady() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            if (!this._isMounted) return;
            this.isTransitioning = false;
            clearTimeout(this._tabReadyTimer);
        }, TAB_TRANSITION_MIN_MS);
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
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                this.copyLabel = 'Copy';
                if (region) { region.textContent = ''; }
            }, 2000);
        }).catch(() => {
            this.dispatchEvent(new CustomEvent('showtoast', {
                detail: { title: 'Error', message: 'Could not copy to clipboard. Select the text manually instead.', variant: 'error' },
                bubbles: true, composed: true
            }));
        });
    }

    handleAskCopilot() {
        this.dispatchEvent(new CustomEvent('askcopilot', {
            detail: { text: this.summaryText }, bubbles: true, composed: true
        }));
    }

    reloadResults() { this.loadResults(); }
    handleStartNew() { this.dispatchEvent(new CustomEvent('startnew', { bubbles: true, composed: true })); }
    handleExportPartial() { /* handled by metaMapperExport */ }
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
        if (!this._isMounted) return;
        const wasCompleted = this.isCompleted;
        if (!wasCompleted && newJob && newJob.Status__c === 'Completed') {
            this.showReloadBanner = true;
        }
        if (newJob && ['Failed', 'Cancelled'].includes(newJob.Status__c)) {
            this.showPartialBanner = true;
        }
    }
}
