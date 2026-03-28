import { LightningElement, api } from 'lwc';

const EVT_CATEGORY_SELECT = 'categoryselect';

export default class SecurityCategoryCell extends LightningElement {
    @api categoryCode;
    @api categoryName;
    @api findingCount = 0;
    @api hasCritical = false;

    // ----- computed getters -----

    get _count() {
        return this.findingCount ?? 0;
    }

    get statusLabel() {
        if (this._count === 0) return 'PASS';
        if (this._count < 10) return 'WARN';
        return 'FAIL';
    }

    get cellClass() {
        let base = 'cell';
        if (this._count === 0) base += ' cell--pass';
        else if (this._count < 10) base += ' cell--warn';
        else base += ' cell--fail';
        if (this.hasCritical) base += ' cell--critical';
        return base;
    }

    get ariaLabel() {
        const count = this._count;
        const suffix = count === 1 ? 'finding' : 'findings';
        return `${this.categoryName}: ${count} ${suffix}`;
    }

    // ----- event handlers -----

    handleClick() {
        this._fire();
    }

    handleKeyDown(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this._fire();
        }
    }

    _fire() {
        this.dispatchEvent(
            new CustomEvent(EVT_CATEGORY_SELECT, {
                bubbles: true,
                composed: true,
                detail: {
                    categoryCode: this.categoryCode,
                    categoryName: this.categoryName
                }
            })
        );
    }
}
