import { LightningElement, api } from 'lwc';

export default class SecurityScannerHeader extends LightningElement {
    /** @type {Object} SecurityScanRun__c record */
    @api scanRun;

    /** @type {{ isSandbox: boolean, orgId: string, orgName: string }} */
    @api orgInfo;

    /** @type {boolean} */
    @api isScanRunning = false;

    /** @type {boolean} */
    @api isExportLoading = false;

    /** @type {number} Seconds remaining in post-scan cooldown */
    @api cooldownSecondsRemaining = 0;

    /** @type {Object} Severity counts { critical, high, medium, low, info } */
    @api scoreCounts = {};

    /** @type {Object} Org-level settings passed to score ring popover */
    @api orgSettings = {};

    // -------------------------------------------------------------------------
    // Getters - score ring
    // -------------------------------------------------------------------------

    get currentScore() {
        if (!this.scanRun) return null;
        return this.scanRun.Score__c != null ? Math.round(this.scanRun.Score__c) : null;
    }

    get currentGrade() {
        if (!this.scanRun) return null;
        return this.scanRun.Grade__c || null;
    }

    // -------------------------------------------------------------------------
    // Getters - run button
    // -------------------------------------------------------------------------

    get runButtonLabel() {
        if (this.cooldownSecondsRemaining > 0) {
            return `Run Security Check (${this.cooldownSecondsRemaining}s)`;
        }
        return 'Run Security Check';
    }

    get isRunDisabled() {
        return this.isScanRunning || this.cooldownSecondsRemaining > 0;
    }

    // -------------------------------------------------------------------------
    // Getters - export button
    // -------------------------------------------------------------------------

    get isExportDisabled() {
        return this.isScanRunning || !this.scanRun;
    }

    // -------------------------------------------------------------------------
    // Handlers
    // -------------------------------------------------------------------------

    handleRunClick() {
        this.dispatchEvent(new CustomEvent('runscan', { bubbles: true, composed: true }));
    }

    handleExportClick() {
        this.dispatchEvent(new CustomEvent('exportcsv', { bubbles: true, composed: true }));
    }
}
