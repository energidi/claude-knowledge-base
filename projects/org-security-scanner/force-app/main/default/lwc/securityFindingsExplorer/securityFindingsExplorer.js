import { LightningElement, api } from 'lwc';

export default class SecurityFindingsExplorer extends LightningElement {

    // ── @api ──────────────────────────────────────────────────────────────────

    @api scanRunId         = null;
    @api allFindings       = [];
    @api hasMore           = false;
    @api isLoadingMore     = false;
    @api isHistoricalView  = false;
    @api activeFilters     = {
        category    : '',
        severity    : '',
        findingType : '',
        statuses    : [],
        searchTerm  : ''
    };

    // ── Derived: client-side filter pass ─────────────────────────────────────

    /**
     * Secondary client-side filter applied to the already-loaded pages.
     * Server already filters on searchTerm for pages it loads; this pass
     * ensures consistency when filters change before the next server fetch.
     *
     * Filter precedence: skip any criterion that is empty/unset.
     */
    get filteredFindings() {
        const list = Array.isArray(this.allFindings) ? this.allFindings : [];
        if (list.length === 0) return [];

        const f = this.activeFilters || {};
        const category    = f.category    || '';
        const severity    = f.severity    || '';
        const findingType = f.findingType || '';
        const statuses    = Array.isArray(f.statuses) ? f.statuses : [];
        const searchTerm  = (f.searchTerm || '').trim().toLowerCase();

        return list.filter(finding => {
            // 1. Category
            if (category && finding.Category__c !== category) return false;

            // 2. Severity
            if (severity && finding.Severity__c !== severity) return false;

            // 3. Finding type
            if (findingType && finding.FindingType__c !== findingType) return false;

            // 4. Statuses (include only if status is in the selected set)
            if (statuses.length > 0 && !statuses.includes(finding.Status__c)) return false;

            // 5. Search term - case-insensitive contains on CheckName__c or AffectedComponent__c
            if (searchTerm) {
                const name      = (finding.CheckName__c         || '').toLowerCase();
                const component = (finding.AffectedComponent__c || '').toLowerCase();
                if (!name.includes(searchTerm) && !component.includes(searchTerm)) return false;
            }

            return true;
        });
    }

    // ── Derived: display flags ────────────────────────────────────────────────

    /** True only during initial load (no findings yet and isLoadingMore is true). */
    get showInitialSpinner() {
        const list = Array.isArray(this.allFindings) ? this.allFindings : [];
        return this.isLoadingMore && list.length === 0;
    }

    /** Show the explorer body (filter bar + list) once we are not in initial load. */
    get showExplorerBody() {
        return !this.showInitialSpinner;
    }

    // ── Sort label (static, shown when findings are present) ─────────────────

    get showSortLabel() {
        return this.filteredFindings.length > 0;
    }
}
