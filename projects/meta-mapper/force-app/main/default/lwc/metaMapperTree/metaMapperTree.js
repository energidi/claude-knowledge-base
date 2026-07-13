import { LightningElement, api, track } from 'lwc';
import { applyFilters, buildNodeMap } from 'c/metaMapperNodeServices';

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
    _nodesValue = [];
    _filtersValue = {};

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
    _searchDebounceTimer = null;

    // Reactive setters (finding #8): the Tree/Graph sync spec requires the tree to react to
    // parent/node and filter changes after initial mount, not just at connectedCallback time.
    // Mirrors the pattern used by metaMapperGraph.js for its equivalent @api props.
    @api
    get nodes() {
        return this._nodesValue;
    }
    set nodes(val) {
        this._nodesValue = val || [];
        this._rebuild();
    }

    @api
    get filters() {
        return this._filtersValue;
    }
    set filters(val) {
        this._filtersValue = val || {};
        this._rebuild();
    }

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
    }

    disconnectedCallback() {
        this._isMounted = false;
        this._contextMenu = null;
        clearTimeout(this._searchDebounceTimer);
    }

    renderedCallback() {
        // Fire tabready after the first render with settled data (populated or empty).
        // Guarded by _hasRendered so it fires exactly once per mount, after nodes prop
        // has been set by the parent - not on the initial connectedCallback firing when
        // props are not yet available.
        if (!this._hasRendered) {
            this._hasRendered = true;
            this.dispatchEvent(new CustomEvent('tabready'));
        }
    }

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
                .map(n => this._makeRow(n, filteredIds));
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
            rows.push(this._makeRow(n, filteredIds));
            if (this._expandedIds.has(n.Metadata_Id__c)) {
                this._dfsFlatten(n.Metadata_Id__c, filteredIds, rows);
            }
        });
    }

    _makeRow(n, filteredIds) {
        const depth = n.Dependency_Depth__c || 0;
        const childList = (this._childrenMap.get(n.Metadata_Id__c) || []).filter(c =>
            filteredIds.has(c.Metadata_Id__c)
        );
        const hasChildren = childList.length > 0;
        const isExpanded = this._expandedIds.has(n.Metadata_Id__c);

        let ariaExpanded;
        if (hasChildren) {
            ariaExpanded = isExpanded ? 'true' : 'false';
        }

        const indentPx = depth * 20;
        const label = n.Metadata_Name__c || '';

        // Selection (isSelected/ariaSelected/rowClass) is intentionally NOT baked in here -
        // see visibleRows getter (finding #22). Baking selection into every row would require
        // a full _rebuildFlatRows() on every click, an O(n) cost over up to 10,000+ nodes for
        // what is just a flag flip on the currently visible slice.
        return {
            Id: n.Metadata_Id__c,
            Metadata_Id__c: n.Metadata_Id__c,
            Metadata_Name__c: label,
            nameSegments: this._buildNameSegments(label),
            Metadata_Type__c: n.Metadata_Type__c,
            Dependency_Depth__c: depth,
            Is_Circular__c: n.Is_Circular__c,
            Is_Dynamic_Reference__c: n.Is_Dynamic_Reference__c,
            ariaLevel: depth + 1,
            ariaExpanded,
            hasChildren,
            isExpanded,
            icon: getIcon(n.Metadata_Type__c),
            indentStyle: `padding-left: ${indentPx}px`,
            _raw: n
        };
    }

    // Splits a node label into {key, text, isMatch} segments around the current search term
    // (case-insensitive) so the template can wrap the matched segment in <mark>. Finding #4:
    // the search box was spec'd to visually highlight matches but never actually rendered any.
    _buildNameSegments(label) {
        const term = this._searchTerm;
        if (!term) {
            return [{ key: 'seg-0', text: label, isMatch: false }];
        }
        const idx = label.toLowerCase().indexOf(term.toLowerCase());
        if (idx === -1) {
            return [{ key: 'seg-0', text: label, isMatch: false }];
        }
        const segments = [];
        if (idx > 0) {
            segments.push({ key: 'seg-pre', text: label.slice(0, idx), isMatch: false });
        }
        segments.push({ key: 'seg-match', text: label.slice(idx, idx + term.length), isMatch: true });
        if (idx + term.length < label.length) {
            segments.push({ key: 'seg-post', text: label.slice(idx + term.length), isMatch: false });
        }
        return segments;
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
        return this._flatRows.slice(this._startIndex, this._endIndex).map((row, i) => {
            const isSelected = row.Metadata_Id__c === this._selectedNodeId;
            return {
                ...row,
                tabIndex: (this._startIndex + i) === this._activeIndex ? '0' : '-1',
                isSelected,
                ariaSelected: isSelected ? 'true' : 'false',
                rowClass: `tree-row${isSelected ? ' row-selected' : ''}`
            };
        });
    }

    get hasSearchTerm() {
        return !!this._searchTerm;
    }

    get showFilterEmpty() {
        return this._flatRows.length === 0 && this._effectiveNodes.length > 0;
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
        // Debounced 250ms, mirroring metaMapperGraph.js's handleGraphSearch: an undebounced
        // per-keystroke call re-filters and re-flattens the tree on every character typed -
        // expensive on large trees (finding #21).
        const value = event.target.value || '';
        clearTimeout(this._searchDebounceTimer);
        this._searchDebounceTimer = setTimeout(() => {
            if (!this._isMounted) return;
            this._searchTerm = value;
            try {
                sessionStorage.setItem(SEARCH_SESSION_KEY, this._searchTerm);
            } catch {
                // unavailable
            }
            // A search term change never alters parent/child relationships or node identity, so
            // only the flat row list needs rebuilding - not the full node/children maps (which
            // re-buckets and re-sorts every node by parent, an O(n log n) cost with no bearing
            // on the search result).
            this._rebuildFlatRows();
            this._computeWindow();
        }, 250);
    }

    handleClearSearch() {
        clearTimeout(this._searchDebounceTimer);
        this._searchTerm = '';
        try {
            sessionStorage.setItem(SEARCH_SESSION_KEY, '');
        } catch {
            // unavailable
        }
        this._rebuildFlatRows();
        this._computeWindow();
    }

    handleScroll() {
        this._computeWindow();
    }

    handleRowClick(event) {
        const nodeId = event.currentTarget.dataset.nodeId;
        const row = this._flatRows.find(r => r.Metadata_Id__c === nodeId);
        if (!row) return;
        // Selection is a plain reactive field, not baked into _flatRows (finding #22) -
        // visibleRows derives isSelected/ariaSelected/rowClass for the visible slice only,
        // so no full O(n) rebuild is needed here.
        this._selectedNodeId = nodeId;
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
        setTimeout(() => {
            const firstItem = this.template.querySelector('.context-menu [role="menuitem"]');
            if (firstItem) firstItem.focus();
        }, 0);
    }

    handleMenuKeyDown(event) {
        if (event.key === 'Escape') {
            this._closeContextMenu();
            return;
        }
        if (event.key === 'ArrowDown' || event.key === 'ArrowUp'
                || event.key === 'Home' || event.key === 'End') {
            event.preventDefault();
            const items = [
                ...this.template.querySelectorAll('.context-menu [role="menuitem"]')
            ];
            if (!items.length) return;
            const current = this.template.querySelector(
                '.context-menu [role="menuitem"]:focus'
            );
            const idx = items.indexOf(current);
            if (event.key === 'ArrowDown') {
                items[(idx + 1) % items.length].focus();
            } else if (event.key === 'ArrowUp') {
                items[(idx - 1 + items.length) % items.length].focus();
            } else if (event.key === 'Home') {
                items[0].focus();
            } else {
                items[items.length - 1].focus();
            }
        }
    }

    handleTreeMenuItemKeyDown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            event.target.click();
        }
    }

    handleKeyDown(event) {
        if (event.key === 'Escape' && this._contextMenu) {
            this._closeContextMenu();
            return;
        }
        if (this._contextMenu) return;

        // Keyboard context menu trigger required by WCAG 2.1.1 (finding #2).
        if ((event.shiftKey && event.key === 'F10') || event.key === 'ContextMenu') {
            event.preventDefault();
            const row = this._flatRows[this._activeIndex];
            if (row) {
                const rowEl = this.template.querySelector(`[data-node-id="${row.Metadata_Id__c}"]`);
                const rect = rowEl ? rowEl.getBoundingClientRect() : null;
                this._contextMenu = {
                    x: rect ? rect.left : 0,
                    y: rect ? rect.bottom : 0,
                    node: row
                };
                setTimeout(() => {
                    const firstItem = this.template.querySelector('.context-menu [role="menuitem"]');
                    if (firstItem) firstItem.focus();
                }, 0);
            }
            return;
        }

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
                // See handleRowClick: selection is a plain reactive field, not baked into
                // _flatRows - no full rebuild needed (finding #22).
                this._selectedNodeId = row.Metadata_Id__c;
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
        this._focusActiveRow();
    }

    // Deferred one microtask so the re-render with the updated tabIndex completes first (finding #3).
    _focusActiveRow() {
        const row = this._flatRows[this._activeIndex];
        if (!row) return;
        Promise.resolve().then(() => {
            const el = this.template && this.template.querySelector(`[data-node-id="${row.Metadata_Id__c}"]`);
            if (el) el.focus();
        });
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
            detail: { nodeId: node.Metadata_Id__c },
            bubbles: true,
            composed: true
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
        // A setTimeout scheduled then cleared within the same synchronous call stack can never
        // fire - JS does not yield to the timer queue mid-execution. To actually show "Locating
        // node..." while ancestor branches expand, defer the (synchronous) expansion work to the
        // next tick ONLY when there is real expansion work to do, so the browser gets a chance to
        // paint the indicator first. When the node's ancestors are already expanded, skip the
        // indicator and defer entirely - there is nothing slow to show it for.
        if (!this._hasCollapsedAncestor(nodeId)) {
            this._locateAndScrollToNode(nodeId);
            return;
        }
        this._locatingNode = true;
        setTimeout(() => {
            if (!this._isMounted) return;
            this._locateAndScrollToNode(nodeId);
            this._locatingNode = false;
        }, 0);
    }

    _hasCollapsedAncestor(nodeId) {
        const node = this._nodeMap.get(nodeId);
        if (!node) return false;
        let current = node;
        while (current && current.Parent_Dependency__c) {
            if (!this._expandedIds.has(current.Parent_Dependency__c)) {
                return true;
            }
            current = this._nodeMap.get(current.Parent_Dependency__c);
        }
        return false;
    }

    _locateAndScrollToNode(nodeId) {
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

    // Public escape hatch retained for callers that want to force a rebuild without a prop
    // reassignment. Not required for reactivity - the `nodes`/`filters` setters above (finding
    // #8) already rebuild automatically on every prop change.
    @api
    refresh() {
        this._rebuild();
    }
}
