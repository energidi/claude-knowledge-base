export function applyFilters(nodes, filters) {
    if (!nodes || !filters) return nodes || [];
    return nodes.filter(node => {
        if (filters.types && filters.types.length > 0 && !filters.types.includes(node.Metadata_Type__c)) return false;
        const depth = node.Dependency_Depth__c || 0;
        if (depth < (filters.minLevel || 0) || depth > (filters.maxLevel != null ? filters.maxLevel : 9999)) return false;
        if (filters.confidenceThreshold > 0 && node.Supplemental_Confidence__c != null && node.Supplemental_Confidence__c < filters.confidenceThreshold) return false;
        if (filters.showCircular === false && node.Is_Circular__c) return false;
        if (filters.showDynamic === false && node.Is_Dynamic_Reference__c) return false;
        if (filters.showSupplemental === false && node.Discovery_Source__c === 'Supplemental') return false;
        return true;
    });
}

export function buildNodeMap(nodes) {
    const map = new Map();
    (nodes || []).forEach(n => map.set(n.Metadata_Id__c, n));
    return map;
}

export function resolveSetupUrl(node, orgId) {
    if (!node || !orgId) return null;
    const t = node.Metadata_Type__c;
    let ctx = {};
    try { ctx = JSON.parse(node.Dependency_Context__c || '{}'); } catch { /* ignore */ }

    if (t === 'ApexClass' || t === 'ApexTrigger') return `/${orgId}/lightning/setup/ApexClasses/home`;
    if (t === 'Flow') return `/${orgId}/builder_platform_interaction/flowBuilder.app?flowId=${node.Metadata_Id__c}`;
    if (t === 'WorkflowRule') return `/${orgId}/lightning/setup/WorkflowRules/home`;
    if (t === 'Report') return `/${orgId}/lightning/r/Report/${node.Metadata_Id__c}/view`;
    if (t === 'CustomField') {
        const parent = ctx.parentObject || (node.Metadata_Name__c || '').split('.')[0];
        return `/${orgId}/lightning/setup/ObjectManager/${parent}/FieldsAndRelationships/view`;
    }
    if (t === 'ValidationRule') {
        const parent = ctx.parentObject || (node.Metadata_Name__c || '').split('.')[0];
        return `/${orgId}/lightning/setup/ObjectManager/${parent}/ValidationRules/view`;
    }
    return null;
}

export function isNamespacePrefixed(apiName, metadataType) {
    if (!apiName) return false;
    let name = apiName;
    if (metadataType === 'CustomField') {
        const dot = apiName.lastIndexOf('.');
        name = dot >= 0 ? apiName.substring(dot + 1) : apiName;
    }
    const match = /^[A-Za-z][A-Za-z0-9]*(?=__)/.exec(name);
    if (!match) return false;
    const prefix = match[0];
    // CLAUDE.md's documented test cases require a length-dependent minimum: a name with
    // only one "__" total (no trailing custom-suffix segment, e.g. "a__MyClass") can have a
    // 1-character namespace; a name with a trailing "__c"/"__mdt"-style suffix segment after
    // the candidate namespace (e.g. "My__Test__c" vs "myns__My_Field__c") needs a 3+ character
    // namespace to be treated as managed-package-prefixed - otherwise a short leading word
    // immediately followed by another "__"-delimited segment (not a real registered namespace)
    // would be misclassified as namespaced.
    const doubleUnderscoreCount = (name.match(/__/g) || []).length;
    const minLength = doubleUnderscoreCount >= 2 ? 3 : 1;
    return prefix.length >= minLength;
}

export function extractTypes(nodes) {
    const types = new Set((nodes || []).map(n => n.Metadata_Type__c).filter(Boolean));
    return [...types].sort();
}

export function maxDepth(nodes) {
    return (nodes || []).reduce((acc, n) => Math.max(acc, n.Dependency_Depth__c || 0), 0);
}

export function buildTypeCounts(nodes) {
    const counts = {};
    (nodes || []).forEach(n => {
        const t = n.Metadata_Type__c;
        if (t) counts[t] = (counts[t] || 0) + 1;
    });
    return counts;
}
