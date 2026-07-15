import { applyFilters, buildNodeMap, resolveSetupUrl, isNamespacePrefixed, buildTypeCounts, extractTypes, maxDepth } from 'c/metaMapperNodeServices';

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

        it('excludes nodes outside the minLevel/maxLevel range and retains nodes inside it', () => {
            const nodes = [
                { Metadata_Id__c: '1', Dependency_Depth__c: 0 },
                { Metadata_Id__c: '2', Dependency_Depth__c: 2 },
                { Metadata_Id__c: '3', Dependency_Depth__c: 5 }
            ];
            const result = applyFilters(nodes, { types: [], minLevel: 1, maxLevel: 3 });
            expect(result).toHaveLength(1);
            expect(result[0].Metadata_Id__c).toBe('2');
        });

        it('excludes nodes below confidenceThreshold and retains nodes at/above it', () => {
            const nodes = [
                { Metadata_Id__c: '1', Supplemental_Confidence__c: 65 },
                { Metadata_Id__c: '2', Supplemental_Confidence__c: 70 },
                { Metadata_Id__c: '3', Supplemental_Confidence__c: 95 }
            ];
            const result = applyFilters(nodes, { types: [], confidenceThreshold: 70 });
            expect(result.map(n => n.Metadata_Id__c)).toEqual(['2', '3']);
        });

        it('excludes circular nodes when showCircular is false', () => {
            const nodes = [
                { Metadata_Id__c: '1', Is_Circular__c: true },
                { Metadata_Id__c: '2', Is_Circular__c: false }
            ];
            const result = applyFilters(nodes, { types: [], showCircular: false });
            expect(result).toHaveLength(1);
            expect(result[0].Metadata_Id__c).toBe('2');
        });

        it('excludes dynamic-reference nodes when showDynamic is false', () => {
            const nodes = [
                { Metadata_Id__c: '1', Is_Dynamic_Reference__c: true },
                { Metadata_Id__c: '2', Is_Dynamic_Reference__c: false }
            ];
            const result = applyFilters(nodes, { types: [], showDynamic: false });
            expect(result).toHaveLength(1);
            expect(result[0].Metadata_Id__c).toBe('2');
        });

        it('excludes supplemental nodes when showSupplemental is false', () => {
            const nodes = [
                { Metadata_Id__c: '1', Discovery_Source__c: 'Supplemental' },
                { Metadata_Id__c: '2', Discovery_Source__c: 'ToolingAPI' }
            ];
            const result = applyFilters(nodes, { types: [], showSupplemental: false });
            expect(result).toHaveLength(1);
            expect(result[0].Metadata_Id__c).toBe('2');
        });
    });

    describe('buildNodeMap', () => {
        it('builds a Map keyed by Metadata_Id__c', () => {
            const nodes = [{ Metadata_Id__c: 'a1' }, { Metadata_Id__c: 'a2' }];
            const result = buildNodeMap(nodes);
            expect(result).toBeInstanceOf(Map);
            expect(result.size).toBe(2);
            expect(result.get('a1')).toBe(nodes[0]);
            expect(result.get('a2')).toBe(nodes[1]);
        });

        it('returns an empty Map without throwing for null/empty input', () => {
            expect(buildNodeMap(null)).toEqual(new Map());
            expect(buildNodeMap([])).toEqual(new Map());
        });
    });

    describe('resolveSetupUrl', () => {
        const orgId = '00Dxx0000001gEZ';

        it('returns the Apex Classes setup URL for ApexClass', () => {
            const node = { Metadata_Type__c: 'ApexClass', Metadata_Id__c: '01p000000000001' };
            expect(resolveSetupUrl(node, orgId)).toBe(`/${orgId}/lightning/setup/ApexClasses/home`);
        });

        it('returns the Apex Classes setup URL for ApexTrigger', () => {
            const node = { Metadata_Type__c: 'ApexTrigger', Metadata_Id__c: '01q000000000001' };
            expect(resolveSetupUrl(node, orgId)).toBe(`/${orgId}/lightning/setup/ApexClasses/home`);
        });

        it('returns the Flow Builder URL with flowId embedded for Flow', () => {
            const node = { Metadata_Type__c: 'Flow', Metadata_Id__c: '301000000000001' };
            const url = resolveSetupUrl(node, orgId);
            expect(url).toBe(`/${orgId}/builder_platform_interaction/flowBuilder.app?flowId=301000000000001`);
            expect(url).toContain('flowId=301000000000001');
        });

        it('returns the Workflow Rules home URL for WorkflowRule', () => {
            const node = { Metadata_Type__c: 'WorkflowRule', Metadata_Id__c: '04b000000000001' };
            expect(resolveSetupUrl(node, orgId)).toBe(`/${orgId}/lightning/setup/WorkflowRules/home`);
        });

        it('returns the Report view URL for Report', () => {
            const node = { Metadata_Type__c: 'Report', Metadata_Id__c: '00O000000000001' };
            expect(resolveSetupUrl(node, orgId)).toBe(`/${orgId}/lightning/r/Report/00O000000000001/view`);
        });

        it('uses parentObject from Dependency_Context__c for CustomField when present', () => {
            const node = {
                Metadata_Type__c: 'CustomField',
                Metadata_Name__c: 'Account.My_Field__c',
                Dependency_Context__c: JSON.stringify({ v: 1, parentObject: 'Account' })
            };
            expect(resolveSetupUrl(node, orgId)).toBe(`/${orgId}/lightning/setup/ObjectManager/Account/FieldsAndRelationships/view`);
        });

        it('falls back to splitting Metadata_Name__c on "." for CustomField when no parentObject in context', () => {
            const node = { Metadata_Type__c: 'CustomField', Metadata_Name__c: 'Contact.My_Field__c' };
            expect(resolveSetupUrl(node, orgId)).toBe(`/${orgId}/lightning/setup/ObjectManager/Contact/FieldsAndRelationships/view`);
        });

        it('returns the Validation Rules view URL for ValidationRule', () => {
            const node = { Metadata_Type__c: 'ValidationRule', Metadata_Name__c: 'Opportunity.Validate_Phone' };
            expect(resolveSetupUrl(node, orgId)).toBe(`/${orgId}/lightning/setup/ObjectManager/Opportunity/ValidationRules/view`);
        });

        it('returns null for an unsupported/unknown metadata type', () => {
            const node = { Metadata_Type__c: 'SomeUnknownType', Metadata_Id__c: 'x' };
            expect(resolveSetupUrl(node, orgId)).toBeNull();
        });

        it('returns null when orgId is null or missing', () => {
            const node = { Metadata_Type__c: 'ApexClass', Metadata_Id__c: '01p000000000001' };
            expect(resolveSetupUrl(node, null)).toBeNull();
            expect(resolveSetupUrl(node, undefined)).toBeNull();
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

        it('excludes a namespaced custom field with a trailing __c suffix', () => {
            expect(isNamespacePrefixed('myns__My_Field__c')).toBe(true);
        });

        it('includes "My__Test__c" - inner double-underscore without a leading namespace prefix', () => {
            expect(isNamespacePrefixed('My__Test__c')).toBe(false);
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
