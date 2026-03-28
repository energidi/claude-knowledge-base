import { LightningElement, api } from 'lwc';

export default class SecurityLeftPanel extends LightningElement {
    @api scanRun;
    @api scoreCounts;
    @api isHistoricalView = false;
    @api isCollapsed = false;

    // ----- Computed: panel state -----

    get panelClass() {
        return this.isCollapsed
            ? 'left-panel left-panel--collapsed'
            : 'left-panel';
    }

    get toggleAriaLabel() {
        return this.isCollapsed ? 'Expand left panel' : 'Collapse left panel';
    }

    get toggleIconClass() {
        return this.isCollapsed
            ? 'toggle-icon toggle-icon--expand'
            : 'toggle-icon';
    }

    get hasScanRun() {
        return !!this.scanRun;
    }

    get showContent() {
        return !this.isCollapsed;
    }

    // ----- Computed: category coverage -----

    get categoriesScannedLabel() {
        if (!this.scanRun) return null;
        return '13 categories scanned';
    }

    get categoryCoverageProgress() {
        // v1: all 13 categories always scanned when a run exists
        return 100;
    }

    // ----- Event handlers -----

    handleToggle() {
        this.dispatchEvent(
            new CustomEvent('paneltoggle', {
                detail:   { collapsed: !this.isCollapsed },
                bubbles:  true,
                composed: true
            })
        );
    }

    handleReturnToCurrent() {
        this.dispatchEvent(
            new CustomEvent('returntocurrentscan', {
                bubbles:  true,
                composed: true
            })
        );
    }

    handleSeverityFilterSelect(event) {
        // Re-fire upward - child already dispatches bubbles+composed but
        // re-dispatch ensures consistent event origin from this component.
        event.stopPropagation();
        this.dispatchEvent(
            new CustomEvent('severityfilterselect', {
                detail:   event.detail,
                bubbles:  true,
                composed: true
            })
        );
    }
}
