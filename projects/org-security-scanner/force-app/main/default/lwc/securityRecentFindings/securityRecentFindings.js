import { LightningElement, api } from 'lwc';

const ACTIVATION_KEYS = new Set(['Enter', ' ']);

export default class SecurityRecentFindings extends LightningElement {
    @api findings;

    get hasFindings() {
        return Array.isArray(this.findings) && this.findings.length > 0;
    }

    handleSelect(event) {
        const findingId = event.currentTarget.dataset.id;
        this._dispatchFindingSelect(findingId);
    }

    handleKeyDown(event) {
        if (ACTIVATION_KEYS.has(event.key)) {
            event.preventDefault();
            const findingId = event.currentTarget.dataset.id;
            this._dispatchFindingSelect(findingId);
        }
    }

    _dispatchFindingSelect(findingId) {
        this.dispatchEvent(
            new CustomEvent('findingselect', {
                detail: { findingId },
                bubbles: true,
                composed: true
            })
        );
    }
}
