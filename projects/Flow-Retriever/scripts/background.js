const SF_API_VERSION = 'v66.0';
const FETCH_TIMEOUT_MS = 15000;
// Salesforce Flow IDs are exactly 15 or 18 chars and begin with '301'
const FLOW_ID_PATTERN = /^301[a-zA-Z0-9]{12}([a-zA-Z0-9]{3})?$/;
const FLOW_API_NAME_PATTERN = /^[a-zA-Z][a-zA-Z0-9_]{0,79}$/;
const ALLOWED_METHODS = new Set(['COPY', 'DOWNLOAD']);
const TRUSTED_ORIGINS = [
    /^https:\/\/([a-zA-Z0-9-]+\.)+salesforce\.com$/,
    /^https:\/\/([a-zA-Z0-9-]+\.)+lightning\.force\.com$/,
    /^https:\/\/([a-zA-Z0-9-]+\.)+force\.com$/
];

// No-op alarm listener - the act of handling the alarm event keeps the
// service worker alive during async fetch operations in MV3.
chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === 'sw-keepalive') {} // intentional no-op
});

// Reference-counted keepalive: alarm is created on first acquire and cleared
// only when all concurrent callers have released, preventing alarm collisions.
let _keepAliveCount = 0;
function withKeepAlive(asyncFn) {
    if (++_keepAliveCount === 1) chrome.alarms.create('sw-keepalive', { periodInMinutes: 1 });
    return asyncFn().finally(() => { if (--_keepAliveCount === 0) chrome.alarms.clear('sw-keepalive'); });
}

function isTrustedSender(sender) {
    // Require both tab URL and sender.origin (frame origin in MV3).
    // Falling back to tabOrigin when sender.origin is absent would allow sandboxed
    // iframes (origin "null") to be implicitly trusted via the parent tab URL.
    if (!sender?.tab?.url || !sender.origin) return false;
    try {
        const tabOrigin = new URL(sender.tab.url).origin;
        return TRUSTED_ORIGINS.some(p => p.test(tabOrigin)) &&
               TRUSTED_ORIGINS.some(p => p.test(sender.origin));
    } catch {
        return false;
    }
}

chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.action === 'RETRIEVE_FLOW') {

        if (!isTrustedSender(sender)) {
            sendResponse({ success: false, error: 'Untrusted message origin.' });
            return;
        }

        const orgDomain = new URL(sender.tab.url).origin;
        const { flowApiName, flowId, versionNumber, method } = request;

        if (!ALLOWED_METHODS.has(method)) {
            sendResponse({ success: false, error: 'Invalid method.' });
            return;
        }
        if (!flowApiName && !flowId) {
            sendResponse({ success: false, error: 'Flow API Name or ID is required.' });
            return;
        }
        if (flowApiName && !FLOW_API_NAME_PATTERN.test(flowApiName)) {
            sendResponse({ success: false, error: 'Invalid Flow API Name.' });
            return;
        }
        if (flowId && !FLOW_ID_PATTERN.test(flowId)) {
            sendResponse({ success: false, error: 'Invalid Flow ID.' });
            return;
        }
        if (versionNumber !== null && versionNumber !== undefined) {
            const v = Number(versionNumber);
            if (!Number.isInteger(v) || v < 1) {
                sendResponse({ success: false, error: 'Invalid version number.' });
                return;
            }
        }

        // Single withKeepAlive wraps the entire async chain to avoid nested alarm collisions
        withKeepAlive(async () => {
            const candidates = await collectAllSidCookies(orgDomain);
            if (!candidates.length) {
                sendResponse({ success: false, error: 'No active Salesforce session found. Please ensure you are logged in.' });
                return;
            }

            let lastError = 'All session candidates failed.';

            for (const { sessionId, apiDomain } of candidates) {
                try {
                    const result = await fetchFlowFromSalesforce(apiDomain, sessionId, flowId, versionNumber);
                    sendResponse({
                        success: true,
                        json: result.json,
                        flowApiName: result.flowApiName,
                        versionNumber: result.versionNumber
                    });
                    return;
                } catch (error) {
                    // Only abort the loop for input-validation errors that will not change
                    // across candidates (e.g. structurally invalid Flow ID).
                    // All per-candidate failures (401, 403, 404, 429, timeout, network error)
                    // are retried with the next candidate session.
                    if (error.message.startsWith('A valid Flow ID')) {
                        sendResponse({ success: false, error: error.message });
                        return;
                    }
                    lastError = error.message;
                    continue;
                }
            }

            sendResponse({ success: false, error: lastError });
        }).catch((error) => {
            sendResponse({ success: false, error: error.message });
        });

        return true;
    }
});

function getCookiesAll(details) {
    return new Promise((resolve, reject) => chrome.cookies.getAll(details, (cookies) => {
        if (chrome.runtime.lastError) {
            reject(new Error(`Unable to read Salesforce session cookies: ${chrome.runtime.lastError.message}`));
        } else {
            resolve(cookies);
        }
    }));
}

async function collectAllSidCookies(orgDomain) {
    const hostname = new URL(orgDomain).hostname;

    const domainRoots = new Set();
    for (const suffix of ['.lightning.force.com', '.my.salesforce.com', '.salesforce.com', '.force.com']) {
        if (hostname.endsWith(suffix)) {
            const base = hostname.slice(0, hostname.length - suffix.length);
            domainRoots.add(`${base}.salesforce.com`);
            domainRoots.add(`${base}.my.salesforce.com`);
            domainRoots.add(`${base}.lightning.force.com`);
            domainRoots.add(`${base}.force.com`);
        }
    }
    domainRoots.add(hostname);

    const seen = new Set();
    const results = [];

    for (const domain of domainRoots) {
        const cookies = await getCookiesAll({ domain, name: 'sid' });
        for (const c of cookies) {
            if (c.value && !seen.has(c.value)) {
                seen.add(c.value);
                const cookieHost = c.domain.startsWith('.') ? c.domain.slice(1) : c.domain;
                const apiDomainCandidate = `https://${cookieHost}`;
                // Only use cookie domains that match a known Salesforce origin pattern;
                // bare parent domains (e.g. salesforce.com) are rejected here rather than
                // sending the sid to an unvalidated host and relying on a network error retry.
                if (!TRUSTED_ORIGINS.some(p => p.test(apiDomainCandidate))) continue;
                results.push({ sessionId: c.value, apiDomain: apiDomainCandidate });
            }
        }
    }
    return results;
}

// Internal guard - validate flowId before building any SOQL query
async function fetchFlowIdentity(apiDomain, sessionId, flowId) {
    if (!FLOW_ID_PATTERN.test(flowId)) throw new Error('Invalid Flow ID passed to fetchFlowIdentity.');

    // Secondary sanitization before interpolation - defense in depth
    const safeId = flowId.replace(/[^a-zA-Z0-9]/g, '');
    const query = `SELECT Id, VersionNumber, Definition.DeveloperName FROM Flow WHERE Id = '${safeId}'`;
    const url = `${apiDomain}/services/data/${SF_API_VERSION}/tooling/query/?q=${encodeURIComponent(query)}`;

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

    let response;
    try {
        response = await fetch(url, {
            headers: { 'Authorization': `Bearer ${sessionId}` },
            signal: controller.signal
        });
    } catch (err) {
        if (err.name === 'AbortError') throw new Error('Request timed out resolving Flow identity.');
        throw err;
    } finally {
        clearTimeout(timeoutId);
    }

    if (!response.ok) {
        const err = new Error(`Salesforce API Error: ${response.status} ${response.statusText}`);
        err.cause = response.status;
        throw err;
    }

    const data = await response.json();
    if (!data.records || data.records.length === 0) {
        throw new Error('Flow identity not found.');
    }

    const record = data.records[0];
    return {
        developerName: record.Definition?.DeveloperName || null,
        versionNumber: record.VersionNumber || null
    };
}

// Internal guard - validate flowId before building any SOQL query
async function fetchFlowFromSalesforce(apiDomain, sessionId, flowId, versionNumber) {
    if (!flowId || !FLOW_ID_PATTERN.test(flowId)) throw new Error('A valid Flow ID is required.');

    let ver = versionNumber != null ? Number(versionNumber) : null;
    let resolvedApiName = null;

    // Secondary sanitization before interpolation - defense in depth
    const safeId = flowId.replace(/[^a-zA-Z0-9]/g, '');
    const query = `SELECT Metadata FROM Flow WHERE Id = '${safeId}'`;

    try {
        const identity = await fetchFlowIdentity(apiDomain, sessionId, flowId);
        resolvedApiName = identity.developerName;
        ver = identity.versionNumber ?? ver;
    } catch (err) {
        // Re-throw 401 so caller's retry loop skips to the next session candidate
        if (err.cause === 401) throw err;
        // Log only err.message - never log sessionId or full error objects
        console.warn('[FlowRetriever] Could not resolve flow identity for filename:', err.message);
    }

    const url = `${apiDomain}/services/data/${SF_API_VERSION}/tooling/query/?q=${encodeURIComponent(query)}`;

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

    let response;
    try {
        response = await fetch(url, {
            headers: { 'Authorization': `Bearer ${sessionId}` },
            signal: controller.signal
        });
    } catch (err) {
        if (err.name === 'AbortError') throw new Error('Request timed out after 15 seconds.');
        throw err;
    } finally {
        clearTimeout(timeoutId);
    }

    if (!response.ok) {
        const err = new Error(`Salesforce API Error: ${response.status} ${response.statusText}`);
        err.cause = response.status;
        throw err;
    }

    const jsonResponse = await response.json();

    if (!jsonResponse.records || jsonResponse.records.length === 0) {
        throw new Error(`Flow "${flowId}" (Version ${ver ?? 'Active'}) not found in this org.`);
    }

    const metadata = jsonResponse.records[0].Metadata;

    // Explicit null check - missing metadata means a permissions problem, not a missing flow
    if (metadata == null) {
        throw new Error(`Flow "${flowId}" returned no metadata. Check org permissions.`);
    }

    if (!resolvedApiName && metadata.label) {
        // Strip invalid filename chars, dots (prevents .. sequences), control characters,
        // and Unicode right-to-left override to prevent filename spoofing
        resolvedApiName = metadata.label.replace(/\s+/g, '_').replace(/[\\/:*?"<>|.\x00-\x1f‮​]/g, '');
    }

    return {
        json: JSON.stringify(metadata, null, 2),
        flowApiName: resolvedApiName || flowId,
        versionNumber: ver
    };
}
