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
    return /^[A-Za-z][A-Za-z0-9]*__/.test(name);
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
