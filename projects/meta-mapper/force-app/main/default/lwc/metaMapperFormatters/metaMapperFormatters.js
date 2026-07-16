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

// Keys with a known plain-English rendering. 'v' is the schema version marker, not a pill.
const KNOWN_CONTEXT_KEYS = new Set([
    'v', 'isWrite', 'activeVersions', 'isActive', 'triggerType', 'parentObject',
    'filterUsage', 'cycleClosesAt', 'maxDepthExceeded',
]);

// CLAUDE.md: "'v' is the only compatibility contract" - handlers increment it on schema change.
// This function only understands v1. A future v:2 payload with restructured fields would render
// silently wrong under per-key matching, so gate on it and fall back to a generic label instead.
const KNOWN_SCHEMA_VERSION = 1;

function renderUnknownKey(key, value) {
    if (value == null) return null;
    const rendered = Array.isArray(value) ? value.join(', ') : String(value);
    return `${key}: ${rendered}`;
}

export function renderPills(contextJson) {
    if (!contextJson) return '';
    let ctx;
    try { ctx = JSON.parse(contextJson); } catch { return ''; }
    if (ctx.v != null && ctx.v !== KNOWN_SCHEMA_VERSION) {
        return 'Additional context available in a newer format - export to JSON for full details';
    }
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
    // Fallback: render any key this function doesn't recognize as plain text rather than
    // silently dropping it (CLAUDE.md: "unknown keys render as plain text with a fallback label").
    Object.keys(ctx)
        .filter((key) => !KNOWN_CONTEXT_KEYS.has(key))
        .forEach((key) => {
            const fallback = renderUnknownKey(key, ctx[key]);
            if (fallback) parts.push(fallback);
        });
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
