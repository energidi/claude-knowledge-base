import { LightningElement, api } from 'lwc';

const CATEGORY_OPTIONS = [
    { label: 'All Categories', value: '' },
    { label: 'User & Access', value: 'User & Access' },
    { label: 'Guest User / Experience Cloud', value: 'Guest User / Experience Cloud' },
    { label: 'Sharing & Record Access', value: 'Sharing & Record Access' },
    { label: 'Session & Auth', value: 'Session & Auth' },
    { label: 'Connected Apps & Integrations', value: 'Connected Apps & Integrations' },
    { label: 'Apex & Automation', value: 'Apex & Automation' },
    { label: 'LWC & Aura', value: 'LWC & Aura' },
    { label: 'Agentforce & GenAI', value: 'Agentforce & GenAI' },
    { label: 'Metadata & Secrets', value: 'Metadata & Secrets' },
    { label: 'File Upload & Execution', value: 'File Upload & Execution' },
    { label: 'Certificates & Encryption', value: 'Certificates & Encryption' },
    { label: 'Monitoring', value: 'Monitoring' },
    { label: 'Health Check Baseline', value: 'Health Check Baseline' }
];

const SEVERITY_OPTIONS = [
    { label: 'C', ariaLabel: 'Critical findings', value: 'Critical' },
    { label: 'H', ariaLabel: 'High findings', value: 'High' },
    { label: 'M', ariaLabel: 'Medium findings', value: 'Medium' },
    { label: 'L', ariaLabel: 'Low findings', value: 'Low' },
    { label: 'I', ariaLabel: 'Info findings', value: 'Info' }
];

const STATUS_OPTIONS = ['Open', 'Acknowledged', 'Remediated', 'Risk Accepted', 'False Positive'];

const DEFAULT_FILTERS = {
    category: '',
    severity: '',
    findingType: '',
    statuses: [],
    searchTerm: ''
};

export default class SecurityFilterBar extends LightningElement {
    @api activeFilters = { ...DEFAULT_FILTERS, statuses: [] };

    _searchTimeout = null;

    // -------------------------------------------------------------------------
    // Getters - derived from activeFilters (no local state)
    // -------------------------------------------------------------------------

    get categoryOptions() {
        return CATEGORY_OPTIONS;
    }

    get severityOptions() {
        return SEVERITY_OPTIONS.map(opt => ({
            ...opt,
            variant: this.activeFilters.severity === opt.value ? 'brand' : 'neutral',
            cssClass: 'slds-button slds-button_neutral severity-btn' +
                (this.activeFilters.severity === opt.value ? ' active' : '')
        }));
    }

    get findingTypeAutomatedVariant() {
        return this.activeFilters.findingType === 'Automated' ? 'brand' : 'neutral';
    }

    get findingTypeRecommendationVariant() {
        return this.activeFilters.findingType === 'Recommendation' ? 'brand' : 'neutral';
    }

    get findingTypeAutomatedClass() {
        return 'slds-button slds-button_neutral finding-type-btn' +
            (this.activeFilters.findingType === 'Automated' ? ' active' : '');
    }

    get findingTypeRecommendationClass() {
        return 'slds-button slds-button_neutral finding-type-btn' +
            (this.activeFilters.findingType === 'Recommendation' ? ' active' : '');
    }

    get statusCheckboxes() {
        const statuses = this.activeFilters.statuses || [];
        return STATUS_OPTIONS.map(s => ({
            label: s,
            value: s,
            checked: statuses.includes(s)
        }));
    }

    get hasActiveFilters() {
        const f = this.activeFilters;
        return (
            f.category !== '' ||
            f.severity !== '' ||
            f.findingType !== '' ||
            (f.statuses && f.statuses.length > 0) ||
            (f.searchTerm && f.searchTerm.trim() !== '')
        );
    }

    get activePills() {
        const pills = [];
        const f = this.activeFilters;

        if (f.searchTerm && f.searchTerm.trim() !== '') {
            pills.push({ key: 'searchTerm', label: `"${f.searchTerm.trim()}"`, filterKey: 'searchTerm' });
        }
        if (f.category !== '') {
            pills.push({ key: 'category', label: f.category, filterKey: 'category' });
        }
        if (f.severity !== '') {
            pills.push({ key: 'severity', label: f.severity, filterKey: 'severity' });
        }
        if (f.findingType !== '') {
            pills.push({ key: 'findingType', label: f.findingType, filterKey: 'findingType' });
        }
        if (f.statuses && f.statuses.length > 0) {
            f.statuses.forEach(s => {
                pills.push({ key: `status-${s}`, label: s, filterKey: 'status', filterValue: s });
            });
        }
        return pills;
    }

    // -------------------------------------------------------------------------
    // Event handlers
    // -------------------------------------------------------------------------

    handleSearchChange(event) {
        const value = event.target.value;
        if (this._searchTimeout) {
            clearTimeout(this._searchTimeout);
        }
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._searchTimeout = setTimeout(() => {
            this._emitFilters({ searchTerm: value });
        }, 300);
    }

    handleCategoryChange(event) {
        this._emitFilters({ category: event.detail.value });
    }

    handleSeverityClick(event) {
        const value = event.currentTarget.dataset.value;
        const newSeverity = this.activeFilters.severity === value ? '' : value;
        this._emitFilters({ severity: newSeverity });
    }

    handleFindingTypeClick(event) {
        const value = event.currentTarget.dataset.value;
        const newType = this.activeFilters.findingType === value ? '' : value;
        this._emitFilters({ findingType: newType });
    }

    handleStatusChange(event) {
        const value = event.target.dataset.value;
        const checked = event.target.checked;
        const current = [...(this.activeFilters.statuses || [])];
        let updated;
        if (checked) {
            updated = current.includes(value) ? current : [...current, value];
        } else {
            updated = current.filter(s => s !== value);
        }
        this._emitFilters({ statuses: updated });
    }

    handleClearFilters() {
        if (this._searchTimeout) {
            clearTimeout(this._searchTimeout);
        }
        this.dispatchEvent(new CustomEvent('filterchange', {
            detail: { filters: { ...DEFAULT_FILTERS, statuses: [] } },
            bubbles: true,
            composed: true
        }));
    }

    handlePillRemove(event) {
        const filterKey = event.currentTarget.dataset.filterKey;
        const filterValue = event.currentTarget.dataset.filterValue;

        if (filterKey === 'status') {
            const updated = (this.activeFilters.statuses || []).filter(s => s !== filterValue);
            this._emitFilters({ statuses: updated });
        } else if (filterKey === 'searchTerm') {
            this._emitFilters({ searchTerm: '' });
        } else if (filterKey === 'category') {
            this._emitFilters({ category: '' });
        } else if (filterKey === 'severity') {
            this._emitFilters({ severity: '' });
        } else if (filterKey === 'findingType') {
            this._emitFilters({ findingType: '' });
        }
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    _emitFilters(patch) {
        const merged = {
            ...this.activeFilters,
            statuses: [...(this.activeFilters.statuses || [])],
            ...patch
        };
        this.dispatchEvent(new CustomEvent('filterchange', {
            detail: { filters: merged },
            bubbles: true,
            composed: true
        }));
    }
}
