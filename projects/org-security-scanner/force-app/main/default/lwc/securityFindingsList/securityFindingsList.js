import { LightningElement, api } from 'lwc';
import { FINDING_TYPE } from 'c/secScanConstants';

// SeverityRank__c numeric values (Critical=1 ... Info=5)
const SEVERITY_LABELS = {
    1: 'Critical',
    2: 'High',
    3: 'Medium',
    4: 'Low',
    5: 'Informational'
};

export default class SecurityFindingsList extends LightningElement {

    // ─── @api ─────────────────────────────────────────────────────────────

    @api findings      = [];
    @api hasMore       = false;
    @api isLoadingMore = false;

    // ─── Derived: findings augmented with group header flags ───────────────

    /**
     * Returns the findings array with two extra fields injected per item:
     *   showGroupHeader {boolean} - true when this item starts a new severity group
     *   groupLabel      {string}  - e.g. "Critical - 8 findings"
     *
     * Group counts are computed in a single pass before the second pass that
     * attaches the flags, so the label can show the total for that group.
     */
    get findingsWithHeaders() {
        const list = Array.isArray(this.findings) ? this.findings : [];
        if (list.length === 0) return [];

        // Pass 1: count per rank
        const counts = {};
        for (const f of list) {
            const rank = f.SeverityRank__c;
            counts[rank] = (counts[rank] || 0) + 1;
        }

        // Pass 2: annotate
        let prevRank = null;
        return list.map(f => {
            const rank         = f.SeverityRank__c;
            const isNewGroup   = rank !== prevRank;
            prevRank           = rank;
            const label        = SEVERITY_LABELS[rank] || 'Unknown';
            const count        = counts[rank] || 0;
            const plural       = count === 1 ? 'finding' : 'findings';
            return {
                ...f,
                showGroupHeader: isNewGroup,
                groupLabel:      `${label} - ${count} ${plural}`
            };
        });
    }

    // ─── Derived: empty state ─────────────────────────────────────────────

    get hasNoFindings() { return !this.hasFindings; }
    get isNotLoadingMore() { return !this.isLoadingMore; }
    get hasNoMore() { return !this.hasMore; }

    get hasFindings() {
        return Array.isArray(this.findings) && this.findings.length > 0;
    }

    get totalLoaded() {
        return Array.isArray(this.findings) ? this.findings.length : 0;
    }

    // ─── Derived: load-more button label ──────────────────────────────────

    get loadMoreLabel() {
        return `Load More (${this.totalLoaded} loaded)`;
    }

    get allLoadedLabel() {
        return `All ${this.totalLoaded} findings loaded`;
    }

    // ─── Derived: per-row CSS / badge helpers ─────────────────────────────

    /**
     * Returns a plain object of computed display properties for each row.
     * Called via a getter on the augmented item inside the template using
     * a helper method exposed as a bound function on each item object
     * (see findingsWithHeaders - we attach helpers directly to each item).
     *
     * LWC templates cannot call methods with arguments directly, so we
     * precompute all display properties inside findingsWithHeaders instead.
     */
    get findingsWithHeadersAndStyles() {
        return this.findingsWithHeaders.map(f => ({
            ...f,
            rowClass:         this._rowClass(f),
            typeIcon:         this._typeIcon(f),
            typeIconVariant:  this._typeIconVariant(f),
            typeTitle:        f.FindingType__c || '',
            severityBadgeClass: this._severityBadgeClass(f),
            severityLabel:    SEVERITY_LABELS[f.SeverityRank__c] || f.Severity__c || '',
            statusBadgeClass: this._statusBadgeClass(f),
            actionAriaLabel:  `Actions for ${f.CheckName__c || 'finding'}`,
            checkNameTitle:   f.CheckName__c || '',
            affectedTitle:    f.AffectedComponent__c || ''
        }));
    }

    // ─── Private style helpers ────────────────────────────────────────────

    _rowClass(f) {
        const type = f.FindingType__c;
        if (type === FINDING_TYPE.AUTOMATED)     return 'finding-row finding-row--automated';
        if (type === FINDING_TYPE.RECOMMENDATION) return 'finding-row finding-row--recommendation';
        return 'finding-row';
    }

    _typeIcon(f) {
        return f.FindingType__c === FINDING_TYPE.RECOMMENDATION
            ? 'utility:knowledge_base'
            : 'utility:shield';
    }

    _typeIconVariant(f) {
        return f.FindingType__c === FINDING_TYPE.RECOMMENDATION ? 'brand' : 'default';
    }

    _severityBadgeClass(f) {
        const rank = f.SeverityRank__c;
        const base = 'severity-badge';
        if (rank === 1) return `${base} severity-badge--critical`;
        if (rank === 2) return `${base} severity-badge--high`;
        if (rank === 3) return `${base} severity-badge--medium`;
        if (rank === 4) return `${base} severity-badge--low`;
        return `${base} severity-badge--info`;
    }

    _statusBadgeClass(f) {
        const s    = f.Status__c;
        const base = 'status-badge';
        if (s === 'Open')          return `${base} status-badge--open`;
        if (s === 'Acknowledged')  return `${base} status-badge--acknowledged`;
        if (s === 'Remediated')    return `${base} status-badge--remediated`;
        if (s === 'Risk Accepted') return `${base} status-badge--risk-accepted`;
        if (s === 'False Positive') return `${base} status-badge--false-positive`;
        return base;
    }

    // ─── Event handlers ───────────────────────────────────────────────────

    handleMenuSelect(event) {
        const value      = event.detail.value;
        const findingId  = event.currentTarget.dataset.findingId;

        let detail;
        switch (value) {
            case 'view':
                detail = { findingId, openTab: 'details' };
                break;
            case 'acknowledge':
                detail = { findingId, openTab: 'status', targetStatus: 'Acknowledged' };
                break;
            case 'remediate':
                detail = { findingId, openTab: 'status', targetStatus: 'Remediated' };
                break;
            case 'false-positive':
                detail = { findingId, openTab: 'status', targetStatus: 'False Positive' };
                break;
            case 'accept-risk':
                detail = { findingId, openTab: 'status', targetStatus: 'Risk Accepted' };
                break;
            default:
                return;
        }

        this.dispatchEvent(new CustomEvent('findingselect', {
            bubbles:  true,
            composed: true,
            detail
        }));
    }

    handleLoadMore() {
        this.dispatchEvent(new CustomEvent('loadmore', {
            bubbles:  true,
            composed: true
        }));
    }

    handleClearFilters() {
        this.dispatchEvent(new CustomEvent('clearfilters', {
            bubbles:  true,
            composed: true
        }));
    }
}
