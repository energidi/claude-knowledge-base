import { formatElapsed, truncateAt, countToBucket, truncateApiName, renderPills, sanitizeFilename, buildDefaultFilename } from 'c/metaMapperFormatters';

describe('c-meta-mapper-formatters', () => {
    describe('formatElapsed', () => {
        it('formats under one hour as MM:SS', () => {
            const created = new Date(Date.now() - 65000).toISOString(); // ~65s ago
            expect(formatElapsed(created)).toMatch(/^01:0[4-6]$/);
        });

        it('formats just under the one-hour boundary as MM:SS', () => {
            const created = new Date(Date.now() - 3599000).toISOString(); // ~59:59
            expect(formatElapsed(created)).toMatch(/^59:5[7-9]$/);
        });

        it('formats exactly at the one-hour boundary as H:MM:SS', () => {
            const created = new Date(Date.now() - 3600000).toISOString(); // ~1:00:00
            expect(formatElapsed(created)).toMatch(/^1:00:0[0-2]$/);
        });

        it('returns 00:00 for an invalid date string', () => {
            expect(formatElapsed('not-a-date')).toBe('00:00');
        });
    });

    describe('truncateAt', () => {
        it('returns the original string when under the max length', () => {
            expect(truncateAt('short', 10)).toBe('short');
        });

        it('truncates at the nearest word boundary and appends an ellipsis', () => {
            expect(truncateAt('this is a long sentence', 10)).toBe('this is a...');
        });

        it('returns an empty string for null/undefined input', () => {
            expect(truncateAt(null, 10)).toBe('');
            expect(truncateAt(undefined, 10)).toBe('');
        });
    });

    describe('countToBucket', () => {
        it('buckets boundary values correctly', () => {
            expect(countToBucket(100)).toBe('Small');
            expect(countToBucket(101)).toBe('Medium');
            expect(countToBucket(500)).toBe('Medium');
            expect(countToBucket(501)).toBe('Large');
            expect(countToBucket(2000)).toBe('Large');
            expect(countToBucket(2001)).toBe('Very Large');
        });

        it('returns null when count is null', () => {
            expect(countToBucket(null)).toBeNull();
        });
    });

    describe('truncateApiName', () => {
        it('leaves names of 50 characters or fewer untouched', () => {
            expect(truncateApiName('Account.Phone__c')).toBe('Account.Phone__c');
        });

        it('truncates names over 50 characters to 47 characters plus an ellipsis', () => {
            const longName = 'A'.repeat(60);
            expect(truncateApiName(longName)).toBe('A'.repeat(47) + '...');
        });
    });

    describe('renderPills', () => {
        it('renders isWrite: true as "Writes to this field"', () => {
            expect(renderPills(JSON.stringify({ v: 1, isWrite: true }))).toBe('Writes to this field');
        });

        it('renders activeVersions as "N active versions"', () => {
            expect(renderPills(JSON.stringify({ v: 1, activeVersions: 3 }))).toBe('3 active versions');
        });

        it('renders cycleClosesAt as "Cycle closes at ..." text', () => {
            expect(renderPills(JSON.stringify({ v: 1, cycleClosesAt: '01p000000000001' }))).toBe(
                'Cycle closes at 01p000000000001'
            );
        });

        it('renders a multi-item filterUsage array as a comma-joined "Used as:" list', () => {
            expect(
                renderPills(JSON.stringify({ v: 1, filterUsage: ['filter', 'grouping', 'column'] }))
            ).toBe('Used as: filter, grouping, column');
        });

        it('renders a single-item filterUsage array in singular form with no trailing comma', () => {
            expect(renderPills(JSON.stringify({ v: 1, filterUsage: ['filter'] }))).toBe('Used as: filter');
        });

        it('does not throw and returns an empty string for malformed JSON', () => {
            expect(() => renderPills('{not valid json')).not.toThrow();
            expect(renderPills('{not valid json')).toBe('');
        });

        it('does not throw and returns an empty string for null/empty input', () => {
            expect(() => renderPills(null)).not.toThrow();
            expect(renderPills(null)).toBe('');
            expect(renderPills('')).toBe('');
        });

        it('falls back to a generic label for an unsupported schema version', () => {
            expect(renderPills(JSON.stringify({ v: 2, isWrite: true }))).toBe(
                'Additional context available (unsupported format) - view raw data for details'
            );
        });

        it('renders an unrecognized key as plain text "key: value" fallback', () => {
            expect(renderPills(JSON.stringify({ v: 1, someNewKey: 'X' }))).toBe('someNewKey: X');
        });
    });

    describe('sanitizeFilename', () => {
        it('replaces "." with "_"', () => {
            expect(sanitizeFilename('Account.Phone__c')).toBe('Account_Phone__c');
        });

        it('replaces "/" and "\\" with "_"', () => {
            expect(sanitizeFilename('Account/Phone\\Field__c')).toBe('Account_Phone_Field__c');
        });

        it('returns an empty string for null/undefined input', () => {
            expect(sanitizeFilename(null)).toBe('');
            expect(sanitizeFilename(undefined)).toBe('');
        });
    });

    describe('buildDefaultFilename', () => {
        it('produces the documented MetaMapper_[sanitizedName]_[YYYYMMDD]_[HHmm] shape with a suffix', () => {
            const result = buildDefaultFilename('Account.Phone__c', 'csv');
            expect(result).toMatch(/^MetaMapper_Account_Phone__c_csv_\d{8}_\d{4}$/);
        });

        it('omits the suffix segment when no suffix is provided', () => {
            const result = buildDefaultFilename('Account.Phone__c');
            expect(result).toMatch(/^MetaMapper_Account_Phone__c_\d{8}_\d{4}$/);
        });
    });
});
