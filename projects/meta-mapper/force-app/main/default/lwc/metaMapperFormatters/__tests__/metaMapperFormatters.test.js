import { formatElapsed, truncateAt, countToBucket, truncateApiName } from 'c/metaMapperFormatters';

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
});
