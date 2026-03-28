import { LightningElement, api } from 'lwc';

const TABS = [
    { id: 'dashboard', baseLabel: 'Dashboard' },
    { id: 'findings',  baseLabel: 'Findings'  },
    { id: 'history',   baseLabel: 'History'   }
];

export default class SecurityScannerTabs extends LightningElement {
    /** @type {'dashboard'|'findings'|'history'} */
    @api activeTab = 'dashboard';

    /** @type {number} */
    @api findingCount = 0;

    /** @type {boolean} Disables all tabs when a scan is in progress */
    @api isScanRunning = false;

    /** @type {boolean} When false, only Dashboard tab is enabled */
    @api hasScan = false;

    // -------------------------------------------------------------------------
    // Getters
    // -------------------------------------------------------------------------

    get tabs() {
        return TABS.map(tab => {
            const isActive   = this.activeTab === tab.id;
            const isDisabled = this._isTabDisabled(tab.id);

            const liClasses = [
                'slds-tabs_default__item',
                isActive ? 'slds-is-active' : ''
            ].filter(Boolean).join(' ');

            const btnClasses = [
                'slds-tabs_default__link',
                'tab-btn',
                isDisabled ? 'tab-btn_disabled' : '',
                isActive   ? 'tab-btn_active'   : ''
            ].filter(Boolean).join(' ');

            let label = tab.baseLabel;
            if (tab.id === 'findings') {
                label = `Findings (${this.findingCount ?? 0})`;
            }

            return {
                id:           tab.id,
                label,
                isActive,
                isDisabled,
                liClasses,
                btnClasses,
                ariaSelected: isActive ? 'true' : 'false',
                tabIndex:     isActive ? '0' : '-1'
            };
        });
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    _isTabDisabled(tabId) {
        if (this.isScanRunning) return true;
        if (!this.hasScan && tabId !== 'dashboard') return true;
        return false;
    }

    // -------------------------------------------------------------------------
    // Handlers
    // -------------------------------------------------------------------------

    handleTabClick(event) {
        const tabId = event.currentTarget.dataset.tab;
        if (!tabId) return;
        if (this._isTabDisabled(tabId)) return;
        if (tabId === this.activeTab) return;

        this.dispatchEvent(
            new CustomEvent('tabswitch', {
                detail:   { tab: tabId },
                bubbles:  true,
                composed: true
            })
        );
    }

    handleTabKeydown(event) {
        // Allow keyboard activation via Enter or Space
        if (event.key !== 'Enter' && event.key !== ' ') return;
        event.preventDefault();
        this.handleTabClick(event);
    }
}
