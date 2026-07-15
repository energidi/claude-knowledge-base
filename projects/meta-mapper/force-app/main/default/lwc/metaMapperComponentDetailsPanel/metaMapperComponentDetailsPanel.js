import { LightningElement, api, track } from 'lwc';
import { resolveSetupUrl } from 'c/metaMapperNodeServices';
import { renderPills } from 'c/metaMapperFormatters';

export default class MetaMapperComponentDetailsPanel extends LightningElement {
    @api nodeMap = null;
    @api orgId = '';
    @api jobId = '';

    @track _copyLinkSuccess = false;
    @track _showAllAncestors = false;

    _selectedNodeId = null;
    _isMobile = false;
    _mql = null;
    _handleMqlChange = null;
    _triggerElement = null;
    _pendingMobileFocus = false;
    _copyLinkTimeoutId = null;

    // Memoization cache for breadcrumbs/setupUrl - both are re-derived by several dependent
    // getters per render (up to 4x each on deep trees / JSON.parse calls). Cached per
    // selectedNodeId + nodeMap identity, invalidated whenever either changes.
    _breadcrumbsCache = null;
    _breadcrumbsCacheKey = null;
    _setupUrlCache = null;
    _setupUrlCacheKey = null;

    // ── Public API ───────────────────────────────────────────────────────────

    @api
    get selectedNodeId() {
        return this._selectedNodeId;
    }

    set selectedNodeId(value) {
        const wasOpen = this._selectedNodeId !== null;
        const willOpen = value !== null && value !== undefined;
        // Capture the triggering element at the moment the panel is asked to open
        // (mobile full-screen modal only) so focus can be restored on close.
        if (!wasOpen && willOpen && this._isMobile) {
            this._triggerElement = document.activeElement;
            this._pendingMobileFocus = true;
        }
        this._selectedNodeId = value;
    }

    // ── Lifecycle ────────────────────────────────────────────────────────────

    connectedCallback() {
        this._mql = window.matchMedia('(max-width: 1023px)');
        this._isMobile = this._mql.matches;
        this._handleMqlChange = (e) => {
            this._isMobile = e.matches;
        };
        if (this._mql.addEventListener) {
            this._mql.addEventListener('change', this._handleMqlChange);
        } else if (this._mql.addListener) {
            this._mql.addListener(this._handleMqlChange);
        }
    }

    disconnectedCallback() {
        if (this._mql) {
            if (this._mql.removeEventListener) {
                this._mql.removeEventListener('change', this._handleMqlChange);
            } else if (this._mql.removeListener) {
                this._mql.removeListener(this._handleMqlChange);
            }
        }
        if (this._copyLinkTimeoutId) {
            clearTimeout(this._copyLinkTimeoutId);
            this._copyLinkTimeoutId = null;
        }
    }

    renderedCallback() {
        // Mobile full-screen modal: move focus into the panel once it renders open.
        if (this._pendingMobileFocus && this.isOpen) {
            this._pendingMobileFocus = false;
            const closeBtn = this.template.querySelector('.close-btn');
            if (closeBtn) {
                closeBtn.focus();
            }
        }
    }

    // ── Panel visibility ──────────────────────────────────────────────────────

    get isOpen() {
        return this.selectedNodeId !== null;
    }

    // ── Mobile modal ARIA (scoped to <1024px full-screen presentation) ─────────

    get dialogRole() {
        return this._isMobile ? 'dialog' : undefined;
    }

    get panelAriaModal() {
        return this._isMobile ? 'true' : undefined;
    }

    get panelAriaLabel() {
        if (!this._isMobile) return undefined;
        const node = this.selectedNode;
        return node ? `${node.Metadata_Name__c} details` : 'Component details';
    }

    // ── Selected node ─────────────────────────────────────────────────────────

    get selectedNode() {
        if (!this.selectedNodeId || !this.nodeMap) return null;
        return this.nodeMap.get(this.selectedNodeId) || null;
    }

    // ── Breadcrumbs ───────────────────────────────────────────────────────────

    get breadcrumbs() {
        const cacheKey = this.selectedNodeId + ':' + (this.nodeMap ? this.nodeMap.size : 0);
        if (this._breadcrumbsCacheKey === cacheKey) {
            return this._breadcrumbsCache;
        }
        const node = this.selectedNode;
        let result;
        if (!node || !node.Ancestor_Path__c) {
            result = [];
        } else {
            const ids = node.Ancestor_Path__c.split('|').filter(Boolean);
            result = ids.map(id => {
                const ancestor = this.nodeMap && this.nodeMap.get(id);
                return {
                    id,
                    sepId: 'sep-' + id,
                    name: ancestor ? ancestor.Metadata_Name__c : id,
                    type: ancestor ? ancestor.Metadata_Type__c : ''
                };
            });
        }
        this._breadcrumbsCacheKey = cacheKey;
        this._breadcrumbsCache = result;
        return result;
    }

    get hasBreadcrumbs() {
        return this.breadcrumbs.length > 0;
    }

    get hasHiddenBreadcrumbs() {
        return this.breadcrumbs.length > 10;
    }

    get visibleBreadcrumbs() {
        if (this._showAllAncestors || this.breadcrumbs.length <= 10) {
            return this.breadcrumbs;
        }
        return this.breadcrumbs.slice(this.breadcrumbs.length - 10);
    }

    get showAllAncestorsLabel() {
        return this._showAllAncestors
            ? 'Show fewer ancestors'
            : `Show all ${this.breadcrumbs.length} ancestors`;
    }

    // ── Context pills ─────────────────────────────────────────────────────────

    get pillsText() {
        const node = this.selectedNode;
        if (!node) return '';
        return renderPills(node.Dependency_Context__c) || '';
    }

    get pillsList() {
        const text = this.pillsText;
        return text ? text.split(' | ').filter(Boolean) : [];
    }

    get hasPills() {
        return this.pillsList.length > 0;
    }

    // ── Setup URL ─────────────────────────────────────────────────────────────

    get setupUrl() {
        const cacheKey = this.selectedNodeId + ':' + this.orgId;
        if (this._setupUrlCacheKey === cacheKey) {
            return this._setupUrlCache;
        }
        const node = this.selectedNode;
        const result = (!node || !this.orgId) ? null : resolveSetupUrl(node, this.orgId);
        this._setupUrlCacheKey = cacheKey;
        this._setupUrlCache = result;
        return result;
    }

    get setupButtonDisabled() {
        return !this.setupUrl;
    }

    get setupButtonAriaDisabled() {
        return this.setupButtonDisabled ? 'true' : 'false';
    }

    get setupButtonClass() {
        return this.setupButtonDisabled
            ? 'slds-button slds-button_brand setup-btn is-disabled'
            : 'slds-button slds-button_brand setup-btn';
    }

    get setupButtonTitle() {
        return this.setupButtonDisabled
            ? 'Setup link not available for this component type. You can search for it manually in Salesforce Setup.'
            : 'Open in Salesforce Setup';
    }

    // ── Confidence badge ──────────────────────────────────────────────────────

    get showConfidenceBadge() {
        const n = this.selectedNode;
        return !!(n && n.Discovery_Source__c === 'Supplemental' && n.Supplemental_Confidence__c != null);
    }

    get showConfidenceWarning() {
        const n = this.selectedNode;
        return !!(n && n.Discovery_Source__c === 'Supplemental' && n.Supplemental_Confidence__c != null && n.Supplemental_Confidence__c < 70);
    }

    get confidenceScore() {
        const n = this.selectedNode;
        return n ? n.Supplemental_Confidence__c : null;
    }

    get confidenceBadgeClass() {
        return this.showConfidenceWarning ? 'confidence-badge confidence-low' : 'confidence-badge confidence-ok';
    }

    // ── Deep-link URL ─────────────────────────────────────────────────────────

    get deepLinkUrl() {
        const base = window.location.href.split('?')[0];
        return `${base}?jobId=${this.jobId}&nodeId=${this.selectedNodeId}`;
    }

    // ── Event handlers ────────────────────────────────────────────────────────

    handleClose() {
        const restoreEl = this._isMobile ? this._triggerElement : null;
        this._triggerElement = null;
        this.dispatchEvent(new CustomEvent('panelclosed'));
        if (restoreEl && typeof restoreEl.focus === 'function') {
            restoreEl.focus();
        }
    }

    handleKeydown(event) {
        // Escape-to-close is scoped to the mobile full-screen modal presentation.
        if (this._isMobile && event.key === 'Escape') {
            event.stopPropagation();
            this.handleClose();
        }
    }

    handleOpenInSetup() {
        if (this.setupButtonDisabled) {
            return;
        }
        if (this.setupUrl) {
            window.open(this.setupUrl, '_blank');
        }
    }

    handleToggleAncestors() {
        this._showAllAncestors = !this._showAllAncestors;
    }

    handleCopyLink() {
        navigator.clipboard.writeText(this.deepLinkUrl).then(() => {
            this._copyLinkSuccess = true;
            const liveEl = this.template.querySelector('.copy-link-live');
            if (liveEl) liveEl.textContent = 'Link copied to clipboard.';
            this._copyLinkTimeoutId = setTimeout(() => {
                this._copyLinkSuccess = false;
                const el = this.template.querySelector('.copy-link-live');
                if (el) el.textContent = '';
                this._copyLinkTimeoutId = null;
            }, 2000);
        }).catch(() => {
            this.dispatchEvent(new CustomEvent('showtoast', {
                bubbles: true,
                composed: true,
                detail: {
                    title: 'Error',
                    message: 'Could not copy to clipboard. Your browser may require clipboard permission. Select and copy the text manually instead.',
                    variant: 'error'
                }
            }));
        });
    }
}
