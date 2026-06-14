export function formatElapsed(createdDateIso) {
    const ms = new Date(createdDateIso).getTime();
    const totalSec = Number.isNaN(ms) ? 0 : Math.max(0, Math.floor((Date.now() - ms) / 1000));
    const h = Math.floor(totalSec / 3600);
    const m = Math.floor((totalSec % 3600) / 60);
    const s = totalSec % 60;
    const mm = String(m).padStart(2, '0');
    const ss = String(s).padStart(2, '0');
    return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

export function sanitizeFilename(apiName) {
    return (apiName || '').replace(/[.\\/]/g, '_');
}

export function truncateAt(str, maxLen) {
    if (!str || str.length <= maxLen) return str || '';
    const cut = str.substring(0, maxLen);
    const lastSpace = cut.lastIndexOf(' ');
    return (lastSpace > 0 ? cut.substring(0, lastSpace) : cut) + '...';
}

export function renderPills(contextJson) {
    if (!contextJson) return '';
    let ctx;
    try { ctx = JSON.parse(contextJson); } catch { return ''; }
    const parts = [];
    if (ctx.isWrite === true)  parts.push('Writes to this field');
    if (ctx.isWrite === false) parts.push('Reads this field');
    if (ctx.activeVersions != null) parts.push(`${ctx.activeVersions} active version${ctx.activeVersions !== 1 ? 's' : ''}`);
    if (ctx.isActive === true)  parts.push('Active');
    if (ctx.isActive === false) parts.push('Inactive');
    if (ctx.triggerType) parts.push(`Trigger: ${ctx.triggerType}`);
    if (ctx.parentObject) parts.push(`Object: ${ctx.parentObject}`);
    if (ctx.filterUsage && Array.isArray(ctx.filterUsage)) parts.push(`Used as: ${ctx.filterUsage.join(', ')}`);
    if (ctx.cycleClosesAt) parts.push(`Cycle closes at ${ctx.cycleClosesAt}`);
    if (ctx.maxDepthExceeded) parts.push('Max depth exceeded — traversal stopped');
    return parts.join(' | ');
}

export function buildDefaultFilename(targetApiName, suffix) {
    const now = new Date();
    const date = `${now.getFullYear()}${String(now.getMonth()+1).padStart(2,'0')}${String(now.getDate()).padStart(2,'0')}`;
    const time = `${String(now.getHours()).padStart(2,'0')}${String(now.getMinutes()).padStart(2,'0')}`;
    const safe = sanitizeFilename(targetApiName);
    return `MetaMapper_${safe}${suffix ? '_' + suffix : ''}_${date}_${time}`;
}

export function countToBucket(count) {
    if (count == null) return null;
    if (count <= 100)  return 'Small';
    if (count <= 500)  return 'Medium';
    if (count <= 2000) return 'Large';
    return 'Very Large';
}

export function truncateApiName(name) {
    if (!name || name.length <= 50) return name;
    return name.substring(0, 47) + '...';
}
