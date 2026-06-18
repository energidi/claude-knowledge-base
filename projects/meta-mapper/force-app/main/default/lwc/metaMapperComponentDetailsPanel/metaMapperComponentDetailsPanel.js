import { LightningElement, api, track } from 'lwc';
import { resolveSetupUrl } from 'c/metaMapperNodeServices';
import { renderPills } from 'c/metaMapperFormatters';

export default class MetaMapperComponentDetailsPanel extends LightningElement {
    @api selectedNodeId = null;
    @api nodeMap = null;
    @api orgId = '';
    @api jobId = '';

    @track _copyLinkSuccess = false;
    @track _showAllAncestors = false;

    // ── Panel visibility ──────────────────────────────────────────────────────

    get isOpen() {
        return this.selectedNodeId !== null;
    }

    // ── Selected node ─────────────────────────────────────────────────────────

    get selectedNode() {
        if (!this.selectedNodeId || !this.nodeMap) return null;
        return this.nodeMap.get(this.selectedNodeId) || null;
    }

    // ── Breadcrumbs ───────────────────────────────────────────────────────────

    get breadcrumbs() {
        const node = this.selectedNode;
        if (!node || !node.Ancestor_Path__c) return [];
        const ids = node.Ancestor_Path__c.split('|').filter(Boolean);
        return ids.map(id => {
            const ancestor = this.nodeMap && this.nodeMap.get(id);
            return {
                id,
                sepId: 'sep-' + id,
                name: ancestor ? ancestor.Metadata_Name__c : id,
                type: ancestor ? ancestor.Metadata_Type__c : ''
            };
        });
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
        const node = this.selectedNode;
        if (!node || !this.orgId) return null;
        return resolveSetupUrl(node, this.orgId);
    }

    get setupButtonDisabled() {
        return !this.setupUrl;
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
        this.dispatchEvent(new CustomEvent('panelclosed'));
    }

    handleOpenInSetup() {
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
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                this._copyLinkSuccess = false;
                const el = this.template.querySelector('.copy-link-live');
                if (el) el.textContent = '';
            }, 2000);
        }).catch(() => {
            this.dispatchEvent(new CustomEvent('showtoast', {
                bubbles: true,
                composed: true,
                detail: {
                    title: 'Error',
                    message: 'Could not copy to clipboard. Select and copy the URL manually instead.',
                    variant: 'error'
                }
            }));
        });
    }
}
