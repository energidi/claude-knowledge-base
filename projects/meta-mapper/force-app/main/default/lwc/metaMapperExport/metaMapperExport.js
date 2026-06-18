import { LightningElement, api } from 'lwc';
import { buildDefaultFilename } from 'c/metaMapperFormatters';
import { isNamespacePrefixed } from 'c/metaMapperNodeServices';

export default class MetaMapperExport extends LightningElement {
    @api nodes = [];
    @api jobRecord = null;

    _advancedOpen = false;

    // --------------- computed getters ---------------

    get _targetApiName() {
        return (this.jobRecord && this.jobRecord.Target_API_Name__c) || 'Export';
    }

    get _isPartial() {
        return this.jobRecord && this.jobRecord.Status__c === 'Failed';
    }

    get _baseName() {
        const suffix = this._isPartial ? 'PARTIAL' : '';
        return buildDefaultFilename(this._targetApiName, suffix);
    }

    get hasNodes() {
        return this.nodes && this.nodes.length > 0;
    }

    get nodeCount() {
        return (this.nodes || []).length;
    }

    get exportDisabled() {
        return this.hasNodes ? undefined : true;
    }

    get advancedChevronIcon() {
        return this._advancedOpen ? 'utility:chevrondown' : 'utility:chevronright';
    }

    // --------------- handlers ---------------

    @api
    exportCsv() {
        this.handleDownloadCsv();
    }

    @api
    exportJson() {
        this.handleDownloadJson();
    }

    handleDownloadCsv() {
        try {
            const content = this._buildCsv(this.nodes || []);
            this._downloadFile(content, this._baseName + '.csv', 'text/csv');
        } catch {
            this._fireExportError('CSV');
        }
    }

    handleDownloadJson() {
        try {
            const content = this._buildJson(this.nodes || []);
            this._downloadFile(content, this._baseName + '.json', 'application/json');
        } catch {
            this._fireExportError('JSON');
        }
    }

    handleDownloadPackageXml() {
        try {
            const content = this._buildPackageXml(this.nodes || []);
            this._downloadFile(content, 'package.xml', 'application/xml');
        } catch {
            this._fireExportError('package.xml');
        }
    }

    handleToggleAdvanced() {
        this._advancedOpen = !this._advancedOpen;
    }

    // --------------- build helpers ---------------

    _buildCsv(nodes) {
        const nodeMap = new Map(nodes.map(n => [n.Metadata_Id__c, n]));
        const escape = (val) => {
            const s = String(val == null ? '' : val);
            return s.includes(',') || s.includes('"') || s.includes('\n')
                ? `"${s.replace(/"/g, '""')}"` : s;
        };
        const header = 'Level,Metadata_Type,Metadata_Name,Metadata_ID,Parent_Name,Is_Circular,Is_Dynamic';
        const rows = nodes.map(n => {
            const parent = n.Parent_Dependency__c ? nodeMap.get(n.Parent_Dependency__c) : null;
            return [
                escape(n.Dependency_Depth__c || 0),
                escape(n.Metadata_Type__c || ''),
                escape(n.Metadata_Name__c || ''),
                escape(n.Metadata_Id__c || ''),
                escape(parent ? parent.Metadata_Name__c : ''),
                escape(n.Is_Circular__c ? 'true' : 'false'),
                escape(n.Is_Dynamic_Reference__c ? 'true' : 'false'),
            ].join(',');
        });
        return [header, ...rows].join('\n');
    }

    _buildJson(nodes) {
        const childrenMap = new Map();
        nodes.forEach(n => {
            const pid = n.Parent_Dependency__c || null;
            if (!childrenMap.has(pid)) childrenMap.set(pid, []);
            childrenMap.get(pid).push(n);
        });
        const buildTree = (parentId) => {
            return (childrenMap.get(parentId) || []).map(n => ({
                Metadata_Id__c: n.Metadata_Id__c,
                Metadata_Name__c: n.Metadata_Name__c,
                Metadata_Type__c: n.Metadata_Type__c,
                Dependency_Depth__c: n.Dependency_Depth__c,
                Is_Circular__c: n.Is_Circular__c,
                Is_Dynamic_Reference__c: n.Is_Dynamic_Reference__c,
                Discovery_Source__c: n.Discovery_Source__c,
                Supplemental_Confidence__c: n.Supplemental_Confidence__c,
                Dependency_Context__c: n.Dependency_Context__c,
                children: buildTree(n.Metadata_Id__c),
            }));
        };
        return JSON.stringify({ nodes: buildTree(null) }, null, 2);
    }

    _buildPackageXml(nodes) {
        const typeMap = new Map();
        nodes.forEach(n => {
            if (isNamespacePrefixed(n.Metadata_Name__c, n.Metadata_Type__c)) return;
            const t = n.Metadata_Type__c || 'Unknown';
            if (!typeMap.has(t)) typeMap.set(t, []);
            typeMap.get(t).push(n.Metadata_Name__c || '');
        });

        let xml = `<?xml version="1.0" encoding="UTF-8"?>\n<Package xmlns="http://soap.sforce.com/2006/04/metadata">\n`;
        typeMap.forEach((names, type) => {
            xml += `    <types>\n`;
            names.sort().forEach(name => {
                xml += `        <members>${this._escapeXml(name)}</members>\n`;
            });
            xml += `        <name>${this._escapeXml(type)}</name>\n`;
            xml += `    </types>\n`;
        });
        xml += `    <version>66.0</version>\n</Package>`;
        return xml;
    }

    _escapeXml(str) {
        return String(str || '')
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&apos;');
    }

    _downloadFile(content, filename, mimeType) {
        const blob = new Blob([content], { type: mimeType });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = filename;
        a.click();
        URL.revokeObjectURL(url);
    }

    _fireExportError() {
        this.dispatchEvent(new CustomEvent('showtoast', {
            bubbles: true,
            composed: true,
            detail: {
                title: 'Export failed',
                message: 'Export failed. Try filtering to fewer nodes first, or use JSON instead of CSV for large result sets.',
                variant: 'error'
            }
        }));
    }
}
