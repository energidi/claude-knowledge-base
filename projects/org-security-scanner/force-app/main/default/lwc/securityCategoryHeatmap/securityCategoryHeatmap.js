import { LightningElement, api } from 'lwc';

const CATEGORIES = [
    { code: 'UA',  name: 'User & Access' },
    { code: 'GU',  name: 'Guest User / Experience Cloud' },
    { code: 'SRA', name: 'Sharing & Record Access' },
    { code: 'SA',  name: 'Session & Auth' },
    { code: 'CAI', name: 'Connected Apps & Integrations' },
    { code: 'AA',  name: 'Apex & Automation' },
    { code: 'LA',  name: 'LWC & Aura' },
    { code: 'AGA', name: 'Agentforce & GenAI' },
    { code: 'MS',  name: 'Metadata & Secrets' },
    { code: 'FUE', name: 'File Upload & Execution' },
    { code: 'CE',  name: 'Certificates & Encryption' },
    { code: 'MON', name: 'Monitoring' },
    { code: 'HCB', name: 'Health Check Baseline' }
];

export default class SecurityCategoryHeatmap extends LightningElement {
    @api scanRun;
    @api allFindings;

    get categoryRows() {
        const findings = Array.isArray(this.allFindings) ? this.allFindings : [];

        const countMap = {};
        const criticalMap = {};

        for (const f of findings) {
            const code = f.CategoryCode__c;
            if (!code) continue;
            countMap[code] = (countMap[code] ?? 0) + 1;
            if (f.Severity__c === 'Critical') {
                criticalMap[code] = true;
            }
        }

        return CATEGORIES.map(cat => ({
            code:         cat.code,
            name:         cat.name,
            findingCount: countMap[cat.code] ?? 0,
            hasCritical:  criticalMap[cat.code] ?? false
        }));
    }

    handleCategorySelect(event) {
        this.dispatchEvent(new CustomEvent('categoryselect', {
            detail:   event.detail,
            bubbles:  true,
            composed: true
        }));
    }
}
