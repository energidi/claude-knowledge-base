import { LightningElement, api } from 'lwc';
import { DEFAULT_FILTERS } from 'c/metaMapperFilters';

export default class MetaMapperFilterPanel extends LightningElement {
    @api availableTypes = [];
    @api maxDepthValue = 9999;

    _filters = { ...DEFAULT_FILTERS };

    @api
    get filters() {
        return this._filters;
    }
    set filters(val) {
        this._filters = val ? { ...DEFAULT_FILTERS, ...val } : { ...DEFAULT_FILTERS };
    }

    // --- Computed getters ---

    get typeOptions() {
        const selected = this._filters.types || [];
        return (this.availableTypes || []).map((t) => ({
            value: t,
            label: t,
            checked: selected.includes(t)
        }));
    }

    get hasTypes() {
        return this.availableTypes && this.availableTypes.length > 0;
    }

    get minLevel() { return this._filters.minLevel; }
    get maxLevel() {
        // 9999 is the DEFAULT_FILTERS sentinel for "no upper bound" - display the
        // actual max depth of the current result set instead of the raw sentinel.
        return this._filters.maxLevel >= 9999 ? this.maxDepthValue : this._filters.maxLevel;
    }
    get confidenceThreshold() { return this._filters.confidenceThreshold; }
    get showCircular() { return this._filters.showCircular; }
    get showDynamic() { return this._filters.showDynamic; }
    get showSupplemental() { return this._filters.showSupplemental; }

    // --- Handlers ---

    handleTypeToggle(event) {
        const type = event.target.dataset.type;
        const checked = event.target.checked;
        const current = this._filters.types || [];
        const types = checked
            ? (current.includes(type) ? current : [...current, type])
            : current.filter((t) => t !== type);
        this._emitChange({ types });
    }

    handleMinLevelChange(event) {
        const val = Number(event.target.value);
        this._emitChange({ minLevel: Number.isNaN(val) ? 0 : val });
    }

    handleMaxLevelChange(event) {
        const val = Number(event.target.value);
        this._emitChange({ maxLevel: Number.isNaN(val) ? 9999 : val });
    }

    handleConfidenceChange(event) {
        const val = Number(event.target.value);
        this._emitChange({ confidenceThreshold: Number.isNaN(val) ? 0 : val });
    }

    handleShowCircularChange(event) {
        this._emitChange({ showCircular: event.target.checked });
    }

    handleShowDynamicChange(event) {
        this._emitChange({ showDynamic: event.target.checked });
    }

    handleShowSupplementalChange(event) {
        this._emitChange({ showSupplemental: event.target.checked });
    }

    handleReset() {
        this._filters = { ...DEFAULT_FILTERS };
        this.dispatchEvent(new CustomEvent('filterschange', {
            detail: { ...DEFAULT_FILTERS },
            bubbles: true,
            composed: true
        }));
    }

    _emitChange(partial) {
        const updated = { ...this._filters, ...partial };
        this._filters = updated;
        this.dispatchEvent(new CustomEvent('filterschange', {
            detail: updated,
            bubbles: true,
            composed: true
        }));
    }
}
