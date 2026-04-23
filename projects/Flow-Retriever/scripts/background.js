const SF_API_VERSION = 'v66.0';
const FETCH_TIMEOUT_MS = 15000;
// m1: Salesforce IDs are exactly 15 or exactly 18 chars - never 16 or 17
const FLOW_ID_PATTERN = /^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$/;
const FLOW_API_NAME_PATTERN = /^[a-zA-Z][a-zA-Z0-9_]*$/;
const ALLOWED_METHODS = new Set(['COPY', 'DOWNLOAD']);
const TRUSTED_ORIGINS = [
    /^https:\/\/([a-zA-Z0-9-]+\.)+salesforce\.com$/,
    /^https:\/\/([a-zA-Z0-9-]+\.)+lightning\.force\.com$/,
    /^https:\/\/([a-zA-Z0-9-]+\.)+force\.com$/
];

// C2: No-op alarm listener - the act of handling the alarm event keeps the
// service worker alive during async fetch operations in MV3.
chrome.alarms.onAlarm.addListener((alarm) => {
    if (alarm.name === 'sw-keepalive') {} // intentional no-op
});

// C2: Wrap any async operation in an alarm-based keepalive so the MV3
// service worker is not suspended mid-fetch by the browser.
function withKeepAlive(asyncFn) {
    chrome.alarms.create('sw-keepalive', { periodInMinutes: 0.1 });
    return asyncFn().finally(() => chrome.alarms.clear('sw-keepalive'));
}

function isTrustedSender(sender) {
    if (!sender?.tab?.url) return false;
    try {
        const origin = new URL(sender.tab.url).origin;
        return TRUSTED_ORIGINS.some(pattern => pattern.test(origin));
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

        withKeepAlive(() => collectAllSidCookies(orgDomain)).then(async (candidates) => {
            if (!candidates.length) {
                sendResponse({ success: false, error: 'No active Salesforce session found. Please ensure you are logged in.' });
                return;
            }

            let lastError = 'All session candidates failed.';

            for (const { sessionId, apiDomain } of candidates) {
                try {
                    const result = await withKeepAlive(() =>
                        fetchFlowFromSalesforce(apiDomain, sessionId, flowId, versionNumber)
                    );
                    // Download is now handled in content.js via blob URL (I6: data: URL deprecated in MV3)
                    sendResponse({
                        success: true,
                        json: result.json,
                        flowApiName: result.flowApiName,
                        versionNumber: result.versionNumber
                    });
                    return;
                } catch (error) {
                    // C1: Also retry on network errors (TypeError) in addition to 401,
                    // since cookie-derived apiDomains may not always be valid API endpoints.
                    if (error.cause === 401 || error instanceof TypeError) {
                        lastError = error.message;
                        continue;
                    }
                    sendResponse({ success: false, error: error.message });
                    return;
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
    return new Promise(resolve => chrome.cookies.getAll(details, resolve));
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
            // I4: Also add the force.com variant - missing from previous version
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
                // C1: Derive apiDomain from the cookie's actual domain attribute, not the
                // query domain. This ensures the API call goes to the correct host.
                // If c.domain is a bare parent (e.g. salesforce.com), the retry loop
                // handles the resulting network error and moves to the next candidate.
                const cookieHost = c.domain.startsWith('.') ? c.domain.slice(1) : c.domain;
                results.push({ sessionId: c.value, apiDomain: `https://${cookieHost}` });
            }
        }
    }
    return results;
}

// C1: Internal guard - validate flowId before building any SOQL query
async function fetchFlowIdentity(apiDomain, sessionId, flowId) {
    if (!FLOW_ID_PATTERN.test(flowId)) throw new Error('Invalid Flow ID passed to fetchFlowIdentity.');

    const query = `SELECT Id, VersionNumber, Definition.DeveloperName FROM Flow WHERE Id = '${flowId}'`;
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

// C1: Internal guard - validate flowId before building any SOQL query
async function fetchFlowFromSalesforce(apiDomain, sessionId, flowId, versionNumber) {
    if (!flowId || !FLOW_ID_PATTERN.test(flowId)) throw new Error('A valid Flow ID is required.');

    let ver = versionNumber != null ? Number(versionNumber) : null;
    let resolvedApiName = null;

    const query = `SELECT Metadata FROM Flow WHERE Id = '${flowId}'`;

    try {
        const identity = await fetchFlowIdentity(apiDomain, sessionId, flowId);
        resolvedApiName = identity.developerName;
        ver = identity.versionNumber ?? ver;
    } catch (err) {
        // I5: Re-throw 401 so caller's retry loop skips to the next session candidate
        // immediately, avoiding a redundant second failing API call with the same token.
        if (err.cause === 401) throw err;
        // C2: Log only err.message - never log sessionId or full error objects
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

    // m2: Explicit null check - missing metadata means a permissions problem, not a missing flow
    if (metadata == null) {
        throw new Error(`Flow "${flowId}" returned no metadata. Check org permissions.`);
    }

    if (!resolvedApiName && metadata.label) {
        // Strip dots in addition to other invalid filename chars to prevent .. sequences
        resolvedApiName = metadata.label.replace(/\s+/g, '_').replace(/[\\/:*?"<>|.]/g, '');
    }

    return {
        json: JSON.stringify(metadata, null, 2),
        flowApiName: resolvedApiName || flowId,
        versionNumber: ver
    };
}
