import { LightningElement, api, track } from 'lwc';
import { applyFilters, buildNodeMap } from 'c/metaMapperNodeUtils';

const ROW_HEIGHT = 40;
const BUFFER = 15;
const SEARCH_SESSION_KEY = 'metaMapper_treeSearch_v1';

const TYPE_ICONS = {
    ApexClass: 'utility:apex',
    ApexTrigger: 'utility:apex',
    Flow: 'utility:flow',
    CustomField: 'utility:custom_apps',
    ValidationRule: 'utility:rules',
    WorkflowRule: 'utility:process',
    Report: 'utility:report'
};
const DEFAULT_ICON = 'utility:connected_apps';

function getIcon(type) {
    return TYPE_ICONS[type] || DEFAULT_ICON;
}

export default class MetaMapperTree extends LightningElement {
    @api nodes = [];
    @api filters = {};

    @track _flatRows = [];
    @track _startIndex = 0;
    @track _endIndex = 0;
    @track _searchTerm = '';
    @track _locatingNode = false;
    @track _contextMenu = null;
    @track _activeIndex = 0;

    _selectedNodeId = null;
    _expandedIds = new Set();
    _nodeMap = new Map();
    _childrenMap = new Map();
    _hasRendered = false;
    _isMounted = false;

    @api
    get selectedNodeId() {
        return this._selectedNodeId;
    }
    set selectedNodeId(val) {
        this._selectedNodeId = val;
        if (val) {
            this._scrollToNode(val);
        }
    }

    connectedCallback() {
        this._isMounted = true;
        try {
            const saved = sessionStorage.getItem(SEARCH_SESSION_KEY);
            if (saved) this._searchTerm = saved;
        } catch {
            // sessionStorage unavailable
        }
        this._rebuild();
        if (!this._flatRows || this._flatRows.length === 0) {
            this.dispatchEvent(new CustomEvent('tabready'));
            this._hasRendered = true;
        }
    }

    disconnectedCallback() {
        this._isMounted = false;
        this._contextMenu = null;
    }

    renderedCallback() {
        if (!this._hasRendered && this._flatRows && this._flatRows.length > 0) {
            this._hasRendered = true;
            this.dispatchEvent(new CustomEvent('tabready'));
        }
    }

    // --- @api nodes setter path via reactive getters ---

    get _effectiveNodes() {
        return this.nodes || [];
    }

    // Called any time inputs change
    _rebuild() {
        const allNodes = this._effectiveNodes;
        this._nodeMap = buildNodeMap(allNodes);
        this._buildChildrenMap(allNodes);
        this._rebuildFlatRows();
        this._computeWindow();
    }

    _buildChildrenMap(allNodes) {
        const map = new Map();
        map.set(null, []);
        allNodes.forEach(n => {
            const pid = n.Parent_Dependency__c || null;
            if (!map.has(pid)) map.set(pid, []);
            map.get(pid).push(n);
        });
        // Sort each bucket
        map.forEach(children => {
            children.sort((a, b) => {
                const da = a.Dependency_Depth__c || 0;
                const db = b.Dependency_Depth__c || 0;
                if (da !== db) return da - db;
                return (a.Metadata_Name__c || '').localeCompare(b.Metadata_Name__c || '');
            });
        });
        this._childrenMap = map;
    }

    _rebuildFlatRows() {
        const allNodes = this._effectiveNodes;
        const filtered = applyFilters(allNodes, this.filters || {});
        const filteredIds = new Set(filtered.map(n => n.Metadata_Id__c));

        let rows;
        if (this._searchTerm) {
            const term = this._searchTerm.toLowerCase();
            rows = filtered
                .filter(n => (n.Metadata_Name__c || '').toLowerCase().includes(term))
                .map(n => this._makeRow(n, filteredIds, true));
        } else {
            rows = [];
            this._dfsFlatten(null, filteredIds, rows);
        }

        this._flatRows = rows;
    }

    _dfsFlatten(parentId, filteredIds, rows) {
        const children = this._childrenMap.get(parentId) || [];
        const visible = children.filter(n => filteredIds.has(n.Metadata_Id__c));
        visible.forEach(n => {
            rows.push(this._makeRow(n, filteredIds, false));
            if (this._expandedIds.has(n.Metadata_Id__c)) {
                this._dfsFlatten(n.Metadata_Id__c, filteredIds, rows);
            }
        });
    }

    _makeRow(n, filteredIds, forSearch) {
        const depth = n.Dependency_Depth__c || 0;
        const childList = (this._childrenMap.get(n.Metadata_Id__c) || []).filter(c =>
            filteredIds.has(c.Metadata_Id__c)
        );
        const hasChildren = childList.length > 0;
        const isExpanded = this._expandedIds.has(n.Metadata_Id__c);
        const isSelected = n.Metadata_Id__c === this._selectedNodeId;

        let ariaExpanded;
        if (hasChildren) {
            ariaExpanded = isExpanded ? 'true' : 'false';
        }

        const indentPx = depth * 20;

        return {
            Id: n.Metadata_Id__c,
            Metadata_Id__c: n.Metadata_Id__c,
            Metadata_Name__c: n.Metadata_Name__c,
            Metadata_Type__c: n.Metadata_Type__c,
            Dependency_Depth__c: depth,
            Is_Circular__c: n.Is_Circular__c,
            Is_Dynamic_Reference__c: n.Is_Dynamic_Reference__c,
            ariaLevel: depth + 1,
            ariaExpanded,
            ariaSelected: isSelected ? 'true' : 'false',
            isSelected,
            hasChildren,
            isExpanded,
            icon: getIcon(n.Metadata_Type__c),
            indentStyle: `padding-left: ${indentPx}px`,
            rowClass: `tree-row${isSelected ? ' row-selected' : ''}`,
            _raw: n
        };
    }

    _computeWindow() {
        const total = this._flatRows.length;
        const container = this.template && this.template.querySelector('.tree-scroll-container');
        const scrollTop = container ? container.scrollTop : 0;
        const clientHeight = container ? container.clientHeight : 450;
        const start = Math.max(0, Math.floor(scrollTop / ROW_HEIGHT) - BUFFER);
        const end = Math.min(total, Math.ceil((scrollTop + clientHeight) / ROW_HEIGHT) + BUFFER);
        this._startIndex = start;
        this._endIndex = end;
    }

    // --- Computed getters for template ---

    get spacerStyle() {
        return `position: relative; height: ${this._flatRows.length * ROW_HEIGHT}px;`;
    }

    get offsetStyle() {
        return `position: absolute; top: ${this._startIndex * ROW_HEIGHT}px; width: 100%;`;
    }

    get visibleRows() {
        return this._flatRows.slice(this._startIndex, this._endIndex).map((row, i) => ({
            ...row,
            tabIndex: (this._startIndex + i) === this._activeIndex ? '0' : '-1'
        }));
    }

    get hasSearchTerm() {
        return !!this._searchTerm;
    }

    get contextMenuStyle() {
        if (!this._contextMenu) return '';
        return `left: ${this._contextMenu.x}px; top: ${this._contextMenu.y}px;`;
    }

    get collapseSubtreeLabel() {
        if (!this._contextMenu) return 'Collapse subtree';
        const depth = this._contextMenu.node.Dependency_Depth__c || 0;
        return depth === 0 ? 'Collapse all children' : 'Collapse subtree';
    }

    get _locatingText() {
        return this._locatingNode ? 'Locating node...' : '';
    }

    // --- Event handlers ---

    handleSearch(event) {
        this._searchTerm = event.target.value || '';
        try {
            sessionStorage.setItem(SEARCH_SESSION_KEY, this._searchTerm);
        } catch {
            // unavailable
        }
        this._rebuild();
    }

    handleClearSearch() {
        this._searchTerm = '';
        try {
            sessionStorage.setItem(SEARCH_SESSION_KEY, '');
        } catch {
            // unavailable
        }
        this._rebuild();
    }

    handleScroll() {
        this._computeWindow();
    }

    handleRowClick(event) {
        const nodeId = event.currentTarget.dataset.nodeId;
        const row = this._flatRows.find(r => r.Metadata_Id__c === nodeId);
        if (!row) return;
        this._selectedNodeId = nodeId;
        this._rebuildFlatRows();
        this.dispatchEvent(new CustomEvent('nodeselected', {
            detail: { nodeId, node: row._raw }
        }));
    }

    handleChevronClick(event) {
        event.stopPropagation();
        const nodeId = event.currentTarget.dataset.nodeId;
        this._toggleExpand(nodeId);
    }

    _toggleExpand(nodeId) {
        if (this._expandedIds.has(nodeId)) {
            this._expandedIds.delete(nodeId);
        } else {
            this._expandedIds.add(nodeId);
        }
        this._rebuildFlatRows();
        this._computeWindow();
    }

    handleRightClick(event) {
        event.preventDefault();
        const nodeId = event.currentTarget.dataset.nodeId;
        const row = this._flatRows.find(r => r.Metadata_Id__c === nodeId);
        if (!row) return;
        this._contextMenu = { x: event.clientX, y: event.clientY, node: row };
        // Focus first menu item after render
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const firstItem = this.template.querySelector('.context-menu [role="menuitem"]');
            if (firstItem) firstItem.focus();
        }, 0);
    }

    handleMenuKeyDown(event) {
        if (event.key === 'Escape') {
            this._closeContextMenu();
        }
    }

    handleKeyDown(event) {
        if (event.key === 'Escape' && this._contextMenu) {
            this._closeContextMenu();
            return;
        }
        if (this._contextMenu) return;

        const total = this._flatRows.length;
        if (!total) return;

        const key = event.key;
        if (key === 'ArrowDown') {
            event.preventDefault();
            this._activeIndex = Math.min(total - 1, this._activeIndex + 1);
            this._ensureActiveVisible();
        } else if (key === 'ArrowUp') {
            event.preventDefault();
            this._activeIndex = Math.max(0, this._activeIndex - 1);
            this._ensureActiveVisible();
        } else if (key === 'ArrowRight') {
            event.preventDefault();
            const row = this._flatRows[this._activeIndex];
            if (row) {
                if (row.hasChildren && !row.isExpanded) {
                    this._expandedIds.add(row.Metadata_Id__c);
                    this._rebuildFlatRows();
                } else if (row.hasChildren && row.isExpanded) {
                    this._activeIndex = Math.min(total - 1, this._activeIndex + 1);
                    this._ensureActiveVisible();
                }
            }
        } else if (key === 'ArrowLeft') {
            event.preventDefault();
            const row = this._flatRows[this._activeIndex];
            if (row) {
                if (row.hasChildren && row.isExpanded) {
                    this._expandedIds.delete(row.Metadata_Id__c);
                    this._rebuildFlatRows();
                } else {
                    // Move to parent
                    const parentId = row._raw.Parent_Dependency__c || null;
                    if (parentId) {
                        const parentIdx = this._flatRows.findIndex(r => r.Metadata_Id__c === parentId);
                        if (parentIdx >= 0) {
                            this._activeIndex = parentIdx;
                            this._ensureActiveVisible();
                        }
                    }
                }
            }
        } else if (key === 'Enter' || key === ' ') {
            event.preventDefault();
            const row = this._flatRows[this._activeIndex];
            if (row) {
                this._selectedNodeId = row.Metadata_Id__c;
                this._rebuildFlatRows();
                this.dispatchEvent(new CustomEvent('nodeselected', {
                    detail: { nodeId: row.Metadata_Id__c, node: row._raw }
                }));
            }
        }
    }

    handleRowKeyDown(event) {
        // Delegate to container handler; stop prop to avoid double-handling
        event.stopPropagation();
        this.handleKeyDown(event);
    }

    _ensureActiveVisible() {
        const container = this.template && this.template.querySelector('.tree-scroll-container');
        if (!container) return;
        const rowTop = this._activeIndex * ROW_HEIGHT;
        const rowBottom = rowTop + ROW_HEIGHT;
        if (rowTop < container.scrollTop) {
            container.scrollTop = rowTop;
        } else if (rowBottom > container.scrollTop + container.clientHeight) {
            container.scrollTop = rowBottom - container.clientHeight;
        }
        this._computeWindow();
    }

    // --- Context menu actions ---

    handleCopyApiName() {
        const node = this._contextMenu && this._contextMenu.node;
        this._closeContextMenu();
        if (!node) return;
        const name = node.Metadata_Name__c || '';
        navigator.clipboard.writeText(name).then(() => {
            this.dispatchEvent(new CustomEvent('showtoast', {
                bubbles: true,
                composed: true,
                detail: { title: '', message: `Copied API Name: ${name}`, variant: 'success' }
            }));
        }).catch(() => {
            this.dispatchEvent(new CustomEvent('showtoast', {
                bubbles: true,
                composed: true,
                detail: { title: 'Error', message: 'Could not copy to clipboard. Select and copy the name manually instead.', variant: 'error' }
            }));
        });
    }

    handleCollapseSubtree() {
        const node = this._contextMenu && this._contextMenu.node;
        this._closeContextMenu();
        if (!node) return;
        this._collapseDescendants(node.Metadata_Id__c);
        this._expandedIds.delete(node.Metadata_Id__c);
        this._rebuildFlatRows();
        this._computeWindow();
    }

    _collapseDescendants(nodeId) {
        const children = this._childrenMap.get(nodeId) || [];
        children.forEach(c => {
            this._expandedIds.delete(c.Metadata_Id__c);
            this._collapseDescendants(c.Metadata_Id__c);
        });
    }

    handleViewInGraph() {
        const node = this._contextMenu && this._contextMenu.node;
        this._closeContextMenu();
        if (!node) return;
        this.dispatchEvent(new CustomEvent('graphpathrequest', {
            detail: { nodeId: node.Metadata_Id__c }
        }));
    }

    _closeContextMenu() {
        this._contextMenu = null;
        const container = this.template && this.template.querySelector('.tree-scroll-container');
        if (container) container.focus();
    }

    handleBackdropClick() {
        this._closeContextMenu();
    }

    // --- _scrollToNode ---

    _scrollToNode(nodeId) {
        let timer = null;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        timer = setTimeout(() => {
            this._locatingNode = true;
        }, 200);

        this._expandAncestors(nodeId);
        this._rebuildFlatRows();

        const idx = this._flatRows.findIndex(r => r.Metadata_Id__c === nodeId);
        if (idx >= 0) {
            const container = this.template && this.template.querySelector('.tree-scroll-container');
            if (container) {
                container.scrollTop = idx * ROW_HEIGHT;
            }
            this._activeIndex = idx;
            this._computeWindow();
        }

        clearTimeout(timer);
        this._locatingNode = false;
    }

    _expandAncestors(nodeId) {
        const node = this._nodeMap.get(nodeId);
        if (!node) return;
        const ancestors = [];
        let current = node;
        while (current && current.Parent_Dependency__c) {
            ancestors.push(current.Parent_Dependency__c);
            current = this._nodeMap.get(current.Parent_Dependency__c);
        }
        ancestors.forEach(id => this._expandedIds.add(id));
    }

    // Watch for external prop changes - LWC does not have computed setters for @api arrays
    // so we use a getter-based approach: rebuild when visibleRows is accessed if dirty.
    // For simplicity we expose a public method the parent can call.
    @api
    refresh() {
        this._rebuild();
    }
}
