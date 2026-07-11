import { applyFilters, isNamespacePrefixed, buildTypeCounts, extractTypes, maxDepth } from 'c/metaMapperNodeServices';

describe('c-meta-mapper-node-services', () => {
    describe('applyFilters', () => {
        it('returns an empty array for an empty node array', () => {
            expect(applyFilters([], { types: [] })).toEqual([]);
        });

        it('returns an empty array when nodes is null/undefined', () => {
            expect(applyFilters(null, { types: [] })).toEqual([]);
            expect(applyFilters(undefined, { types: [] })).toEqual([]);
        });

        it('returns nodes unchanged when filters is missing', () => {
            const nodes = [{ Metadata_Id__c: '1' }];
            expect(applyFilters(nodes, null)).toEqual(nodes);
        });

        it('filters by type when types is non-empty', () => {
            const nodes = [
                { Metadata_Id__c: '1', Metadata_Type__c: 'ApexClass' },
                { Metadata_Id__c: '2', Metadata_Type__c: 'Flow' }
            ];
            const result = applyFilters(nodes, { types: ['ApexClass'] });
            expect(result).toHaveLength(1);
            expect(result[0].Metadata_Id__c).toBe('1');
        });
    });

    describe('isNamespacePrefixed', () => {
        // CLAUDE.md documented test cases (Export Formats / package.xml namespace detection).
        it('excludes a namespace-prefixed class', () => {
            expect(isNamespacePrefixed('myns__MyClass')).toBe(true);
        });

        it('includes a plain custom field with only the standard __c suffix', () => {
            expect(isNamespacePrefixed('My_Custom_Field__c', 'CustomField')).toBe(false);
        });

        it('includes a name with a leading underscore (not a valid namespace character)', () => {
            expect(isNamespacePrefixed('_myns__Test')).toBe(false);
        });

        it('excludes a single-character namespace', () => {
            expect(isNamespacePrefixed('a__MyClass')).toBe(true);
        });

        // [?] CLAUDE.md documents 'My__Test__c' as "included" (no namespace), but this has the
        // identical two-double-underscore shape as a genuinely namespaced field like
        // 'myns__My_Field__c' (documented as excluded) - the two cases cannot be reliably told
        // apart by regex alone without a real installed-namespace list. Documenting current
        // behavior rather than asserting the spec's claimed outcome, which would require
        // fabricating a heuristic that risks misclassifying real namespaced components.
        it('[?] "My__Test__c": current behavior treats the leading segment as a namespace (spec ambiguity, see comment)', () => {
            expect(isNamespacePrefixed('My__Test__c')).toBe(true);
        });
    });

    describe('buildTypeCounts', () => {
        it('counts nodes by Metadata_Type__c', () => {
            const nodes = [
                { Metadata_Type__c: 'ApexClass' },
                { Metadata_Type__c: 'ApexClass' },
                { Metadata_Type__c: 'Flow' }
            ];
            expect(buildTypeCounts(nodes)).toEqual({ ApexClass: 2, Flow: 1 });
        });
    });

    describe('extractTypes', () => {
        it('returns a sorted, deduplicated list of types', () => {
            const nodes = [
                { Metadata_Type__c: 'Flow' },
                { Metadata_Type__c: 'ApexClass' },
                { Metadata_Type__c: 'Flow' }
            ];
            expect(extractTypes(nodes)).toEqual(['ApexClass', 'Flow']);
        });
    });

    describe('maxDepth', () => {
        it('returns 0 for an empty node array', () => {
            expect(maxDepth([])).toBe(0);
        });

        it('returns the deepest Dependency_Depth__c value', () => {
            const nodes = [{ Dependency_Depth__c: 1 }, { Dependency_Depth__c: 4 }, { Dependency_Depth__c: 2 }];
            expect(maxDepth(nodes)).toBe(4);
        });
    });
});
