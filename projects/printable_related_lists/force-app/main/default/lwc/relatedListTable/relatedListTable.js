import { LightningElement, api, wire, track } from 'lwc';
import { getRelatedListInfo } from 'lightning/uiRelatedListApi';
import { getRelatedListRecords } from 'lightning/uiRelatedListApi';

// Maps UI API data types to lightning-datatable column types
const DATA_TYPE_MAP = {
    String:        'text',
    Text:          'text',
    Email:         'email',
    Phone:         'phone',
    Url:           'url',
    Currency:      'currency',
    Double:        'number',
    Integer:       'number',
    Percent:       'percent',
    Date:          'date',
    DateTime:      'date',
    Boolean:       'boolean',
    Reference:     'text'   // Lookup IDs shown as text (future: resolve to labels)
};

export default class RelatedListTable extends LightningElement {
    @api recordId;
    @api objectApiName;
    @api relatedListId;

    @track tableColumns = [];
    @track tableData = [];
    @track isPopupBlocked = false;

    _listInfoData = null;
    _listInfoError = null;
    _recordsData = null;
    _recordsError = null;
    _fields = null;

    // ─── Wire: Related List Column Metadata ───────────────────────────────────

    @wire(getRelatedListInfo, {
        parentObjectApiName: '$objectApiName',
        relatedListId: '$relatedListId'
    })
    wiredListInfo({ data, error }) {
        if (data) {
            this._listInfoData = data;
            this._listInfoError = null;
            this.tableColumns = this._buildColumns(data.displayColumns);
            this._fields = this._buildFields(data.displayColumns);
        } else if (error) {
            this._listInfoError = error;
            this._listInfoData = null;
        }
    }

    // ─── Wire: Related List Records ───────────────────────────────────────────
    // Only fires once _fields is populated (wire won't fire with null params)

    @wire(getRelatedListRecords, {
        parentRecordId: '$recordId',
        relatedListId: '$relatedListId',
        fields: '$_fields',
        pageSize: 200
    })
    wiredRecords({ data, error }) {
        if (data) {
            this._recordsData = data;
            this._recordsError = null;
            this.tableData = this._flattenRecords(data.records);
        } else if (error) {
            this._recordsError = error;
            this._recordsData = null;
        }
    }

    // ─── State Getters ────────────────────────────────────────────────────────

    get isLoading() {
        // Still loading if either wire hasn't resolved yet
        return !this._listInfoData && !this._listInfoError;
    }

    get hasError() {
        return !!(this._listInfoError || this._recordsError);
    }

    get hasNoRecords() {
        return !this.isLoading && !this.hasError && this.tableData.length === 0;
    }

    get recordCount() {
        return this.tableData.length;
    }

    get isAtMaxRecords() {
        return this.tableData.length === 200;
    }

    get errorMessage() {
        const err = this._listInfoError || this._recordsError;
        if (!err) return '';
        const msg = err.body?.message || err.message || 'Unknown error';
        return `<p><strong>Error loading records:</strong> ${msg}</p>`;
    }

    get relatedListLabel() {
        return this._listInfoData?.label || this.relatedListId;
    }

    // ─── Data Transformation ──────────────────────────────────────────────────

    _buildColumns(displayColumns) {
        if (!displayColumns) return [];
        return displayColumns
            .filter((col) => col.fieldApiName)
            .map((col) => ({
                label: col.label,
                fieldName: col.fieldApiName,
                type: DATA_TYPE_MAP[col.dataType] || 'text',
                cellAttributes: { alignment: 'left' }
            }));
    }

    _buildFields(displayColumns) {
        if (!displayColumns) return null;
        const filtered = displayColumns.filter((col) => col.fieldApiName);
        if (filtered.length === 0) return null;
        return filtered.map((col) => `${this.relatedListId}.${col.fieldApiName}`);
    }

    _flattenRecords(records) {
        if (!records) return [];
        return records.map((record) => {
            const row = { Id: record.id };
            if (record.fields) {
                Object.keys(record.fields).forEach((fieldName) => {
                    row[fieldName] = record.fields[fieldName]?.value ?? '';
                });
            }
            return row;
        });
    }

    // ─── Event Handlers ───────────────────────────────────────────────────────

    handleBack() {
        this.dispatchEvent(new CustomEvent('goback'));
    }

    handlePrint() {
        this.isPopupBlocked = false;

        const htmlContent = this._buildPrintHtml();

        // Must call window.open synchronously inside the click handler
        // so browsers treat it as a trusted user gesture (not a pop-up)
        // eslint-disable-next-line no-restricted-globals
        const printWindow = window.open('', '_blank', 'width=900,height=650');

        if (!printWindow) {
            this.isPopupBlocked = true;
            return;
        }

        printWindow.document.write(htmlContent);
        printWindow.document.close();
    }

    // ─── Print HTML Builder ───────────────────────────────────────────────────

    _buildPrintHtml() {
        const label = this.relatedListLabel;
        const countNote = this.isAtMaxRecords
            ? 'Note: Only the first 200 records are shown.'
            : `${this.recordCount} record(s)`;

        const headerRow = this.tableColumns
            .map((col) => `<th>${this._escapeHtml(col.label)}</th>`)
            .join('');

        const bodyRows = this.tableData
            .map((row) => {
                const cells = this.tableColumns
                    .map((col) => `<td>${this._escapeHtml(String(row[col.fieldName] ?? ''))}</td>`)
                    .join('');
                return `<tr>${cells}</tr>`;
            })
            .join('');

        return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8" />
    <title>${this._escapeHtml(label)}</title>
    <style>
        body {
            font-family: Arial, Helvetica, sans-serif;
            font-size: 10pt;
            color: #181818;
            margin: 0;
            padding: 0;
        }
        .print-header {
            margin-bottom: 12pt;
            border-bottom: 2px solid #dddbda;
            padding-bottom: 8pt;
        }
        .print-header h1 {
            font-size: 14pt;
            margin: 0 0 4pt;
            color: #181818;
        }
        .print-header p {
            font-size: 9pt;
            color: #3e3e3c;
            margin: 0;
        }
        table {
            width: 100%;
            border-collapse: collapse;
        }
        th {
            background-color: #f4f6f9;
            border-bottom: 2px solid #dddbda;
            padding: 6px 8px;
            text-align: left;
            font-size: 9pt;
            font-weight: bold;
        }
        td {
            border-bottom: 1px solid #dddbda;
            padding: 5px 8px;
            font-size: 9pt;
        }
        tr:nth-child(even) td {
            background-color: #fafaf9;
        }
        @media print {
            @page { size: landscape; margin: 0.5in; }
            body { margin: 0; }
        }
    </style>
</head>
<body>
    <div class="print-header">
        <h1>${this._escapeHtml(label)}</h1>
        <p>${this._escapeHtml(countNote)}</p>
    </div>
    <table>
        <thead><tr>${headerRow}</tr></thead>
        <tbody>${bodyRows}</tbody>
    </table>
    <script>
        window.onload = function() {
            window.print();
            window.onafterprint = function() { window.close(); };
        };
    <\/script>
</body>
</html>`;
    }

    _escapeHtml(str) {
        return String(str)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;');
    }
}
