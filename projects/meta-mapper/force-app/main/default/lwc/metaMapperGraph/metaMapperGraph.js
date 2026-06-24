import { LightningElement, api } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import ECHARTS from '@salesforce/resourceUrl/ECharts';
import { applyFilters } from 'c/metaMapperNodeServices';
import { renderPills } from 'c/metaMapperFormatters';

const TYPE_COLORS = {
    ApexClass: '#0176d3',
    ApexTrigger: '#0176d3',
    Flow: '#1b5297',
    CustomField: '#2e844a',
    ValidationRule: '#ba0517',
    WorkflowRule: '#dd7a01',
    Report: '#444444',
};
const DEFAULT_COLOR = '#3e3e3c';

const LEGEND_TYPES = [
    { type: 'ApexClass', label: 'Apex Class', icon: 'utility:apex' },
    { type: 'ApexTrigger', label: 'Apex Trigger', icon: 'utility:apex' },
    { type: 'Flow', label: 'Flow', icon: 'utility:flow' },
    { type: 'CustomField', label: 'Custom Field', icon: 'utility:custom_apps' },
    { type: 'ValidationRule', label: 'Validation Rule', icon: 'utility:rules' },
    { type: 'WorkflowRule', label: 'Workflow Rule', icon: 'utility:process' },
    { type: 'Report', label: 'Report', icon: 'utility:report' },
    { type: '_default', label: 'Other', icon: 'utility:connected_apps' },
];

export default class MetaMapperGraph extends LightningElement {
    // ---- @api props with setters ----

    _nodes = [];
    _filters = {};

    @api
    get nodes() {
        return this._nodes;
    }
    set nodes(val) {
        this._nodes = val || [];
        if (this._chartReady) {
            this._renderGraph();
        }
    }

    @api
    get filters() {
        return this._filters;
    }
    set filters(val) {
        this._filters = val || {};
        if (this._chartReady) {
            this._renderGraph();
        }
    }

    @api targetApiName = '';

    @api
    set selectedNodeId(val) {
        const prev = this._selectedNodeId;
        this._selectedNodeId = val || null;
        if (this._chartReady && prev !== this._selectedNodeId) {
            this._renderGraph();
        }
    }
    get selectedNodeId() {
        return this._selectedNodeId;
    }

    // ---- internal state ----
    _chart = null;
    _chartReady = false;
    _echartsLoaded = false;
    _firstFinishedFired = false;
    _themeRegistered = false;
    _selectedNodeId = null;
    _focusPath = null;
    _showClearFocus = false;
    _collapsedNodes = new Set();
    _maxVisibleDepth = 9999;
    _contextMenu = null;
    _graphSearchTerm = '';
    _searchHighlights = null;
    _showShortcutLegend = false;
    _expandAllModal = null;
    _loadError = false;
    _nodeMap = new Map();
    _ariaTableRows = [];
    _showLargeGraphDismissed = false;
    _spanningNoticeDismissed = false;
    _isMounted = false;
    _isMobileState = false;
    _tabReadyTimeout = null;

    _handleCtrlK = null;
    _handleResize = null;
    _ctrlKAttached = false;
    _ariaRebuildTimer = null;
    _ariaTableBusy = false;
    _graphAriaLiveText = '';
    _lastFocusBeforeMenu = null;
    // Virtual focus index — tracks keyboard focus position within the canvas (WCAG 2.1 SC 2.1.1).
    _activeNodeIndex = -1;
    _orderedNodeIds = [];

    // ---- lifecycle ----

    connectedCallback() {
        this._isMounted = true;
        try {
            this._spanningNoticeDismissed =
                localStorage.getItem('metaMapper_spanningTreeNotice_v1') === 'true';
        } catch {
            this._spanningNoticeDismissed = false;
        }
        this._isMobileState = window.innerWidth < 1024;
        this._handleResize = () => {
            if (this._chart) {
                this._chart.resize();
            }
            this._isMobileState = window.innerWidth < 1024;
        };
        window.addEventListener('resize', this._handleResize);
    }

    renderedCallback() {
        if (this._echartsLoaded) {
            if (!this._ctrlKAttached) {
                this._attachCtrlK();
            }
            return;
        }
        this._echartsLoaded = true;
        loadScript(this, ECHARTS + '/echarts.min.js')
            .then(() => {
                if (!this._isMounted) return;
                this._initChart();
            })
            .catch(() => {
                this._loadError = true;
                if (!this._firstFinishedFired) {
                    this._firstFinishedFired = true;
                    this.dispatchEvent(new CustomEvent('tabready'));
                }
            });
    }

    disconnectedCallback() {
        this._isMounted = false;
        clearTimeout(this._tabReadyTimeout);
        clearTimeout(this._ariaRebuildTimer);
        window.removeEventListener('resize', this._handleResize);
        if (this._handleCtrlK) {
            const wrapper = this.template.querySelector('.graph-canvas-wrapper');
            if (wrapper) {
                wrapper.removeEventListener('keydown', this._handleCtrlK);
            }
        }
        if (this._chart) {
            this._chart.dispose();
            this._chart = null;
        }
    }

    // ---- chart init ----

    _initChart() {
        if (!window.echarts) return;
        try {
            if (!this._themeRegistered) {
                // eslint-disable-next-line no-undef
                echarts.registerTheme('sfDark', {
                    backgroundColor: '#1B1B1B',
                    textStyle: { color: '#FFFFFF' },
                });
                this._themeRegistered = true;
            }
            const container = this.template.querySelector('.graph-canvas-wrapper');
            if (!container) return;
            const isDark = document.body.classList.contains('slds-theme_inverse');
            // eslint-disable-next-line no-undef
            this._chart = echarts.init(container, isDark ? 'sfDark' : null);
            this._chartReady = true;

            this._chart.on('click', (params) => {
                if (!this._isMounted) return;
                if (params.dataType === 'node') {
                    const nodeId = params.data.id;
                    const node = this._nodeMap.get(nodeId);
                    if (node) {
                        this._selectedNodeId = nodeId;
                        this._renderGraph();
                        this.dispatchEvent(
                            new CustomEvent('nodeselected', { detail: { nodeId, node } })
                        );
                    }
                }
            });

            this._chart.on('contextmenu', (params) => {
                if (!this._isMounted) return;
                if (params.dataType === 'node') {
                    params.event.event.preventDefault();
                    // Track pre-menu focus for restoration on close (finding #6).
                    this._lastFocusBeforeMenu = document.activeElement;
                    // Spec: focus path must clear synchronously before the menu renders (finding #4).
                    if (this._focusPath) {
                        this._clearFocusPath();
                    }
                    this._contextMenu = {
                        x: params.event.event.clientX,
                        y: params.event.event.clientY,
                        nodeId: params.data.id,
                        node: this._nodeMap.get(params.data.id),
                    };
                    // eslint-disable-next-line @lwc/lwc/no-async-operation
                    setTimeout(() => {
                        if (!this._isMounted) return;
                        const first = this.template.querySelector('.ctx-menu [role="menuitem"]');
                        if (first) first.focus();
                    }, 0);
                }
            });

            this._chart.on('finished', () => {
                if (!this._isMounted) return;
                if (!this._firstFinishedFired) {
                    this._firstFinishedFired = true;
                    this.dispatchEvent(new CustomEvent('tabready'));
                }
            });

            // Hard 3s timeout in case 'finished' never fires
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            this._tabReadyTimeout = setTimeout(() => {
                if (!this._firstFinishedFired) {
                    this._firstFinishedFired = true;
                    this.dispatchEvent(new CustomEvent('tabready'));
                }
            }, 3000);

            this._attachCtrlK();
            this._renderGraph();
        } catch {
            this._loadError = true;
            if (!this._firstFinishedFired) {
                this._firstFinishedFired = true;
                this.dispatchEvent(new CustomEvent('tabready'));
            }
        }
    }

    _attachCtrlK() {
        const wrapper = this.template.querySelector('.graph-canvas-wrapper');
        if (!wrapper || this._ctrlKAttached) return;
        this._handleCtrlK = (e) => {
            if (e.ctrlKey && e.key === 'k') {
                e.preventDefault();
                const searchInput = this.template.querySelector('.graph-search-input');
                if (searchInput) {
                    searchInput.focus();
                }
            } else if (e.shiftKey && e.key === '?') {
                e.preventDefault();
                this._showShortcutLegend = true;
            } else if (
                (e.key === 'ArrowDown' || e.key === 'ArrowRight' ||
                 e.key === 'ArrowUp'   || e.key === 'ArrowLeft') &&
                !this._contextMenu && !this._showShortcutLegend
            ) {
                // Virtual focus navigation. preventDefault() also stops ECharts from panning
                // on the same keypress so the two interactions don't fight each other.
                e.preventDefault();
                const delta = (e.key === 'ArrowDown' || e.key === 'ArrowRight') ? 1 : -1;
                this._moveVirtualFocus(delta);
            } else if (e.key === 'Enter' && !this._contextMenu && !this._showShortcutLegend) {
                this._activateVirtualFocusNode();
            } else if (e.key === 'Escape') {
                if (this._focusPath) {
                    this._clearFocusPath();
                } else if (this._graphSearchTerm) {
                    this._graphSearchTerm = '';
                    this._searchHighlights = null;
                    this._renderGraph();
                }
            } else if (
                ((e.shiftKey && e.key === 'F10') || e.key === 'ContextMenu') &&
                !this._contextMenu && !this._showShortcutLegend
            ) {
                // Keyboard context menu trigger required by WCAG 2.1.1 (finding #1).
                e.preventDefault();
                const activeNodeId =
                    this._activeNodeIndex >= 0 && this._activeNodeIndex < this._orderedNodeIds.length
                        ? this._orderedNodeIds[this._activeNodeIndex]
                        : null;
                if (activeNodeId) {
                    const wrapper = this.template.querySelector('.graph-canvas-wrapper');
                    const rect = wrapper ? wrapper.getBoundingClientRect() : { left: 0, top: 0, width: 200, height: 200 };
                    this._lastFocusBeforeMenu = document.activeElement;
                    if (this._focusPath) { this._clearFocusPath(); }
                    this._contextMenu = {
                        x: rect.left + rect.width / 2,
                        y: rect.top + rect.height / 2,
                        nodeId: activeNodeId,
                        node: this._nodeMap.get(activeNodeId),
                    };
                    // eslint-disable-next-line @lwc/lwc/no-async-operation
                    setTimeout(() => {
                        if (!this._isMounted) return;
                        const first = this.template.querySelector('.ctx-menu [role="menuitem"]');
                        if (first) first.focus();
                    }, 0);
                }
            }
        };
        wrapper.addEventListener('keydown', this._handleCtrlK);
        this._ctrlKAttached = true;
    }

    // ---- visible nodes ----

    _getVisibleNodes() {
        const filtered = applyFilters(this._nodes, this._filters);
        if (this._collapsedNodes.size === 0 && this._maxVisibleDepth >= 9999) {
            return filtered;
        }
        const nm = new Map(filtered.map((n) => [n.Metadata_Id__c, n]));
        return filtered.filter((n) => {
            if ((n.Dependency_Depth__c || 0) > this._maxVisibleDepth) return false;
            if (this._collapsedNodes.size === 0) return true;
            let cur = n;
            while (cur && cur.Parent_Dependency__c) {
                if (this._collapsedNodes.has(cur.Parent_Dependency__c)) return false;
                cur = nm.get(cur.Parent_Dependency__c);
            }
            return true;
        });
    }

    // ---- render ----

    _renderGraph() {
        if (!this._chart) return;
        const visible = this._getVisibleNodes();
        this._nodeMap = new Map(visible.map((n) => [n.Metadata_Id__c, n]));
        // Rebuild ordered node list for virtual focus traversal (depth ASC, then name ASC for
        // deterministic arrow-key order regardless of force-layout position).
        this._orderedNodeIds = visible
            .slice()
            .sort(
                (a, b) =>
                    (a.Dependency_Depth__c || 0) - (b.Dependency_Depth__c || 0) ||
                    (a.Metadata_Name__c || '').localeCompare(b.Metadata_Name__c || '')
            )
            .map((n) => n.Metadata_Id__c);
        // Clamp active index when filters reduce the visible set so it never goes out of bounds.
        if (this._activeNodeIndex >= this._orderedNodeIds.length) {
            this._activeNodeIndex = Math.max(0, this._orderedNodeIds.length - 1);
        }
        const option = this._buildOption(visible);
        this._chart.setOption(option, true);
        this._scheduleAriaTableRebuild(visible);
    }

    _scheduleAriaTableRebuild(visible) {
        clearTimeout(this._ariaRebuildTimer);
        this._ariaTableBusy = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._ariaRebuildTimer = setTimeout(() => {
            if (!this._isMounted) return;
            this._ariaTableRows = visible.map((n) => ({
                id: n.Metadata_Id__c,
                name: n.Metadata_Name__c || '',
                type: n.Metadata_Type__c || '',
                flags: [n.Is_Circular__c && 'Circular', n.Is_Dynamic_Reference__c && 'Dynamic']
                    .filter(Boolean)
                    .join(', '),
            }));
            this._ariaTableBusy = false;
        }, 400);
    }

    _buildOption(visibleNodes) {
        const idSet = new Set(visibleNodes.map((n) => n.Metadata_Id__c));
        const edges = visibleNodes
            .filter((n) => n.Parent_Dependency__c && idSet.has(n.Parent_Dependency__c))
            .map((n) => ({ source: n.Parent_Dependency__c, target: n.Metadata_Id__c }));

        const focusSet = this._focusPath;
        const highlights = this._searchHighlights;
        const activeNodeId =
            this._activeNodeIndex >= 0 && this._activeNodeIndex < this._orderedNodeIds.length
                ? this._orderedNodeIds[this._activeNodeIndex]
                : null;

        const echartsNodes = visibleNodes.map((n) => {
            const baseColor = TYPE_COLORS[n.Metadata_Type__c] || DEFAULT_COLOR;
            const isSelected = n.Metadata_Id__c === this._selectedNodeId;
            const isActive = n.Metadata_Id__c === activeNodeId;
            const isFocused = !focusSet || focusSet.has(n.Metadata_Id__c);
            const isHighlighted = highlights && highlights.has(n.Metadata_Id__c);

            let opacity = 1;
            if (!isFocused) opacity = 0.2;
            else if (highlights && !isHighlighted) opacity = 0.3;

            // Priority: virtual focus > selected/highlighted > circular > normal.
            // Active (virtual keyboard focus) uses white 4px border so it is visually
            // distinct from the yellow 3px selection ring even when both flags are set.
            let borderColor;
            let borderWidth;
            if (isActive) {
                borderColor = '#FFFFFF';
                borderWidth = 4;
            } else if (isSelected || isHighlighted) {
                borderColor = '#FFB81C';
                borderWidth = isSelected ? 3 : 2;
            } else {
                borderColor = baseColor;
                borderWidth = n.Is_Circular__c ? 2 : 1;
            }
            const borderType = n.Is_Circular__c ? 'dashed' : 'solid';

            const flags = [];
            if (n.Is_Circular__c) flags.push('Circular dependency');
            if (n.Is_Dynamic_Reference__c) flags.push('Dynamic reference');
            if (n.Discovery_Source__c === 'Supplemental') flags.push('Supplemental');
            if (n.Supplemental_Confidence__c != null && n.Supplemental_Confidence__c < 70) {
                flags.push(`${n.Supplemental_Confidence__c}% confidence - verify manually`);
            }

            return {
                id: n.Metadata_Id__c,
                name: n.Metadata_Name__c || '',
                label: { show: true },
                itemStyle: {
                    color: baseColor,
                    opacity,
                    borderWidth,
                    borderColor,
                    borderType,
                },
                emphasis: {
                    itemStyle: { borderWidth: 3, borderColor: '#FFB81C' },
                },
                _node: n,
                _flags: flags,
            };
        });

        return {
            tooltip: {
                trigger: 'item',
                formatter: (params) => {
                    if (params.dataType !== 'node') return '';
                    const n = params.data._node;
                    if (!n) return params.data.name;
                    const pills = renderPills(n.Dependency_Context__c);
                    const conf =
                        n.Supplemental_Confidence__c != null && n.Supplemental_Confidence__c < 70
                            ? ` | Confidence: ${n.Supplemental_Confidence__c}% - verify manually`
                            : '';
                    return `${n.Metadata_Name__c || ''} (${n.Metadata_Type__c || ''})${pills ? ' | ' + pills : ''}${conf}`;
                },
            },
            series: [
                {
                    type: 'graph',
                    layout: 'force',
                    data: echartsNodes,
                    edges,
                    force: {
                        repulsion: 300,
                        edgeLength: 120,
                        gravity: 0.2,
                        layoutAnimation: false,
                    },
                    roam: true,
                    label: {
                        show: true,
                        position: 'right',
                        fontSize: 11,
                        overflow: 'truncate',
                        width: 120,
                    },
                    emphasis: {
                        itemStyle: { borderWidth: 3, borderColor: '#FFB81C' },
                    },
                    lineStyle: { color: '#BBBBBB', width: 1, opacity: 0.6 },
                },
            ],
        };
    }

    // ---- focus path ----

    @api
    activateFocusPath(nodeId) {
        if (nodeId && this._chartReady) {
            this._activateFocusPath(nodeId);
        }
    }

    _activateFocusPath(nodeId) {
        const pathSet = new Set([nodeId]);
        const nm = this._nodeMap;
        let cur = nm.get(nodeId);
        while (cur && cur.Parent_Dependency__c) {
            pathSet.add(cur.Parent_Dependency__c);
            cur = nm.get(cur.Parent_Dependency__c);
        }
        this._focusPath = pathSet;
        this._showClearFocus = true;
        this._renderGraph();
        this._announceAriaLive(`Focus path activated: ${pathSet.size} nodes highlighted`);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            if (!this._isMounted) return;
            const btn = this.template.querySelector('.clear-focus-btn');
            if (btn) btn.focus();
        }, 0);
    }

    _clearFocusPath() {
        this._focusPath = null;
        this._showClearFocus = false;
        this._renderGraph();
    }

    // ---- collapse / expand ----

    _collapseSubtree(nodeId) {
        this._collapsedNodes = new Set([...this._collapsedNodes, nodeId]);
        this._renderGraph();
    }

    // ---- search ----

    _handleSearchChange(term) {
        this._graphSearchTerm = term;
        if (!term) {
            this._searchHighlights = null;
        } else {
            const lower = term.toLowerCase();
            const visible = this._getVisibleNodes();
            this._searchHighlights = new Set(
                visible
                    .filter((n) => (n.Metadata_Name__c || '').toLowerCase().includes(lower))
                    .map((n) => n.Metadata_Id__c)
            );
            this._announceAriaLive(`${this._searchHighlights.size} nodes match your search`);
        }
        this._renderGraph();
    }

    // ---- computed getters ----

    get canvasAriaLabel() {
        return (
            'Dependency graph for ' +
            (this.targetApiName || 'component') +
            '. Use Tree View tab for full keyboard access and screen reader support.'
        );
    }

    get showLargeGraphWarningBanner() {
        if (this._showLargeGraphDismissed) return false;
        if (this.isMobile) return false;
        return (this._nodes || []).length > 8000;
    }

    get showFilterEmpty() {
        return this._chartReady
            && this._nodes.length > 0
            && this._getVisibleNodes().length === 0;
    }

    get isMobile() {
        return this._isMobileState;
    }

    get legendItems() {
        return LEGEND_TYPES.map((item) => ({
            ...item,
            color: item.type === '_default' ? DEFAULT_COLOR : TYPE_COLORS[item.type] || DEFAULT_COLOR,
            swatchStyle: `background-color: ${item.type === '_default' ? DEFAULT_COLOR : TYPE_COLORS[item.type] || DEFAULT_COLOR};`,
        }));
    }

    get ariaTableRows() {
        return this._ariaTableRows || [];
    }

    get ariaTableBusy() {
        return this._ariaTableBusy ? 'true' : 'false';
    }

    get graphAriaLiveText() {
        return this._graphAriaLiveText || '';
    }

    _announceAriaLive(text) {
        this._graphAriaLiveText = text;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this._graphAriaLiveText = ''; }, 3000);
    }

    get contextMenuStyle() {
        if (!this._contextMenu) return '';
        return `top: ${this._contextMenu.y}px; left: ${this._contextMenu.x}px;`;
    }

    get ctxCollapseLabel() {
        if (!this._contextMenu) return 'Collapse subtree';
        const node = this._contextMenu.node;
        if (node && (node.Dependency_Depth__c || 0) === 0) return 'Collapse all children';
        return 'Collapse subtree';
    }

    get showSpanningNotice() {
        return !this._spanningNoticeDismissed;
    }

    // ---- event handlers ----

    handleGraphSearch(e) {
        this._handleSearchChange(e.target.value);
    }

    handleClearFocus() {
        this._clearFocusPath();
    }

    handleCollapseAll() {
        this._maxVisibleDepth = 0;
        this._collapsedNodes = new Set();
        this._renderGraph();
    }

    handleExpandAll() {
        this._expandAllTriggerEl = this.template.activeElement
            || this.template.querySelector('[data-id="expand-all-btn"]');
        const visible = this._getVisibleNodes();
        if (visible.length > 1000) {
            this._expandAllModal = {
                count: visible.length,
                expandAriaLabel: `Confirm. Expand all ${visible.length} nodes now. This may slow your browser.`
            };
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                if (!this._isMounted) return;
                const btn = this.template.querySelector('.modal-footer .slds-button_neutral');
                if (btn) btn.focus();
            }, 0);
        } else {
            this._maxVisibleDepth = 9999;
            this._collapsedNodes = new Set();
            this._renderGraph();
        }
    }

    handleExpandAllConfirm() {
        this._expandAllModal = null;
        this._maxVisibleDepth = 9999;
        this._collapsedNodes = new Set();
        this._renderGraph();
        if (this._expandAllTriggerEl) {
            this._expandAllTriggerEl.focus();
            this._expandAllTriggerEl = null;
        }
    }

    handleExpandAllCancel() {
        this._expandAllModal = null;
        if (this._expandAllTriggerEl) {
            this._expandAllTriggerEl.focus();
            this._expandAllTriggerEl = null;
        }
    }

    handleShowShortcuts() {
        this._showShortcutLegend = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        Promise.resolve().then(() => {
            if (!this._isMounted) return;
            const modal = this.template.querySelector('[aria-label="Keyboard shortcuts"]');
            if (modal) modal.focus();
        });
    }

    handleCloseShortcuts() {
        this._showShortcutLegend = false;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            if (!this._isMounted) return;
            const btn = this.template.querySelector('.shortcut-legend-btn');
            if (btn) btn.focus();
        }, 0);
    }

    handleShortcutModalKeyDown(e) {
        if (e.key === 'Escape') {
            this.handleCloseShortcuts();
        }
    }

    handleExpandModalKeyDown(e) {
        if (e.key === 'Escape') {
            this.handleExpandAllCancel();
        }
    }

    handleSwitchToTree() {
        this.dispatchEvent(new CustomEvent('switchtotree', { bubbles: true, composed: true }));
    }

    dismissLargeGraphWarning() {
        this._showLargeGraphDismissed = true;
    }

    dismissSpanningNotice() {
        this._spanningNoticeDismissed = true;
        try {
            localStorage.setItem('metaMapper_spanningTreeNotice_v1', 'true');
        } catch {
            // storage unavailable
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            if (!this._isMounted) return;
            const wrapper = this.template.querySelector('.graph-canvas-wrapper');
            if (wrapper) wrapper.focus();
        }, 0);
    }

    handleCanvasKeyDown(e) {
        if (e.key === 'Escape') {
            if (this._contextMenu) {
                this.closeContextMenu();
            } else if (this._focusPath) {
                this._clearFocusPath();
            } else if (this._graphSearchTerm) {
                this._graphSearchTerm = '';
                this._searchHighlights = null;
                this._renderGraph();
            }
        }
    }

    handleCanvasContextMenu(e) {
        // ECharts handles its own contextmenu via chart.on('contextmenu')
        // This handler suppresses the native context menu on the wrapper div itself
        // when no ECharts node was right-clicked
        if (!this._contextMenu) {
            e.preventDefault();
        }
    }

    closeContextMenu() {
        const lastMenu = this._contextMenu;
        const savedFocus = this._lastFocusBeforeMenu;
        this._contextMenu = null;
        this._lastFocusBeforeMenu = null;
        if (lastMenu) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                if (!this._isMounted) return;
                // Restore pre-menu focus; fall back to canvas wrapper (finding #6).
                const target = (savedFocus && document.contains(savedFocus))
                    ? savedFocus
                    : this.template.querySelector('.graph-canvas-wrapper');
                if (target) target.focus();
            }, 0);
        }
    }

    handleCtxMenuKeyDown(e) {
        if (e.key === 'Escape') {
            this.closeContextMenu();
        } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
            e.preventDefault();
            const items = Array.from(this.template.querySelectorAll('.ctx-menu [role="menuitem"]'));
            if (!items.length) return;
            const idx = items.indexOf(document.activeElement);
            const next =
                e.key === 'ArrowDown'
                    ? (idx + 1) % items.length
                    : (idx - 1 + items.length) % items.length;
            items[next].focus();
        }
    }

    handleCtxCopyName() {
        const node = this._contextMenu?.node;
        this.closeContextMenu();
        if (!node) return;
        const name = node.Metadata_Name__c || '';
        navigator.clipboard
            .writeText(name)
            .then(() => {
                this._fireToast('success', '', `Copied API Name: ${name}`);
            })
            .catch(() => {
                this._fireToast(
                    'error',
                    '',
                    'Could not copy to clipboard. Select and copy the name manually instead.'
                );
            });
    }

    handleCtxFocusPath() {
        const nodeId = this._contextMenu?.nodeId;
        this.closeContextMenu();
        if (!nodeId) return;
        if (this._focusPath) {
            this._clearFocusPath();
        }
        this._activateFocusPath(nodeId);
    }

    handleCtxCollapseSubtree() {
        const nodeId = this._contextMenu?.nodeId;
        this.closeContextMenu();
        if (!nodeId) return;
        this._collapseSubtree(nodeId);
    }

    handleRetryLoad() {
        this._loadError = false;
        this._chartReady = false;
        this._firstFinishedFired = false;
        // _echartsLoaded stays true — call loadScript directly rather than
        // relying on renderedCallback which won't re-fire after a flag reset
        loadScript(this, ECHARTS + '/echarts.min.js')
            .then(() => {
                if (!this._isMounted) return;
                this._initChart();
            })
            .catch(() => {
                if (!this._isMounted) return;
                this._loadError = true;
                if (!this._firstFinishedFired) {
                    this._firstFinishedFired = true;
                    this.dispatchEvent(new CustomEvent('tabready'));
                }
            });
    }

    handleCtxMenuItemKeyDown(e) {
        if (e.key !== 'Enter' && e.key !== ' ') return;
        e.preventDefault();
        const action = e.currentTarget.dataset.action;
        if (action === 'copy') this.handleCtxCopyName();
        else if (action === 'focus') this.handleCtxFocusPath();
        else if (action === 'collapse') this.handleCtxCollapseSubtree();
    }

    // ---- virtual focus ----

    _moveVirtualFocus(delta) {
        if (!this._orderedNodeIds.length) return;
        if (this._activeNodeIndex < 0) {
            // First arrow key press: always start at the root (index 0) regardless of direction.
            this._activeNodeIndex = 0;
        } else {
            this._activeNodeIndex = Math.max(
                0,
                Math.min(this._orderedNodeIds.length - 1, this._activeNodeIndex + delta)
            );
        }
        this._renderGraph();
        const nodeId = this._orderedNodeIds[this._activeNodeIndex];
        const node = this._nodeMap.get(nodeId);
        if (node) {
            const flags = [];
            if (node.Is_Circular__c) flags.push('circular dependency');
            if (node.Is_Dynamic_Reference__c) flags.push('dynamic reference');
            const flagText = flags.length ? ', ' + flags.join(', ') : '';
            this._announceAriaLive(
                `${node.Metadata_Name__c || nodeId} (${node.Metadata_Type__c || 'Component'})` +
                `${flagText}, depth ${node.Dependency_Depth__c || 0}. ` +
                `${this._activeNodeIndex + 1} of ${this._orderedNodeIds.length}. ` +
                `Press Enter to open details.`
            );
        }
    }

    _activateVirtualFocusNode() {
        if (this._activeNodeIndex < 0 || !this._orderedNodeIds.length) return;
        const nodeId = this._orderedNodeIds[this._activeNodeIndex];
        const node = this._nodeMap.get(nodeId);
        if (!node) return;
        this._selectedNodeId = nodeId;
        this._renderGraph();
        this.dispatchEvent(new CustomEvent('nodeselected', { detail: { nodeId, node } }));
    }

    _fireToast(variant, title, message) {
        this.dispatchEvent(
            new CustomEvent('showtoast', {
                bubbles: true,
                composed: true,
                detail: { title, message, variant },
            })
        );
    }
}
