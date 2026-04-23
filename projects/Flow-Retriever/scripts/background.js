const SF_API_VERSION = 'v66.0';
const FETCH_TIMEOUT_MS = 15000;
const FLOW_API_NAME_PATTERN = /^[a-zA-Z][a-zA-Z0-9_]*$/;
const FLOW_ID_PATTERN = /^[a-zA-Z0-9]{15,18}$/;
const TRUSTED_ORIGINS = [
    /^https:\/\/([a-zA-Z0-9-]+\.)+salesforce\.com$/,
    /^https:\/\/([a-zA-Z0-9-]+\.)+lightning\.force\.com$/,
    /^https:\/\/([a-zA-Z0-9-]+\.)+force\.com$/
];

// Validate that the message came from a trusted Salesforce tab
function isTrustedSender(sender) {
    if (!sender?.tab?.url) return false;
    try {
        const origin = new URL(sender.tab.url).origin;
        return TRUSTED_ORIGINS.some(pattern => pattern.test(origin));
    } catch {
        return false;
    }
}

// Listen for messages from the Content Script (the UI)
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {

    if (request.action === 'RETRIEVE_FLOW') {

        // Security: reject any message not originating from a trusted Salesforce tab
        if (!isTrustedSender(sender)) {
            sendResponse({ success: false, error: 'Untrusted message origin.' });
            return;
        }

        const orgDomain = new URL(sender.tab.url).origin;
        const { flowApiName, flowId, versionNumber, method } = request;

        // Validate inputs
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

        // Step 1: Collect all sid cookie candidates across Salesforce domain variants.
        // Try each one against the Tooling API directly - no pre-probe roundtrip needed.
        getSalesforceSid(orgDomain).then(async (candidates) => {
            if (!candidates.length) {
                sendResponse({ success: false, error: 'No active Salesforce session found. Please ensure you are logged in.' });
                return;
            }

            let lastError = 'All session candidates failed.';

            for (const { sessionId, apiDomain } of candidates) {
                try {
                    const result = await fetchFlowFromSalesforce(
                        apiDomain, sessionId, flowApiName, flowId, versionNumber
                    );

                    if (method === 'DOWNLOAD') {
                        downloadJsonFile(result.json, result.flowApiName, result.versionNumber);
                    }

                    sendResponse({ success: true, json: result.json });
                    return;

                } catch (error) {
                    if (error.cause === 401) {
                        lastError = error.message;
                        continue; // try next candidate
                    }
                    sendResponse({ success: false, error: error.message });
                    return;
                }
            }

            sendResponse({ success: false, error: lastError });
        }).catch((error) => {
            sendResponse({ success: false, error: error.message });
        });

        return true; // Keep the message channel open for the async response
    }
});

// Promisified cookie lookups
function getCookiesAll(details) {
    return new Promise(resolve => chrome.cookies.getAll(details, resolve));
}

// Collect every sid cookie across all known Salesforce domains.
// chrome.cookies.get returns only the most domain-specific match,
// which is often not the active API session. getAll finds them all.
async function collectAllSidCookies(orgDomain) {
    const hostname = new URL(orgDomain).hostname;

    // Derive all plausible domain roots from the org hostname
    const domainRoots = new Set();
    for (const suffix of ['.lightning.force.com', '.my.salesforce.com', '.salesforce.com', '.force.com']) {
        if (hostname.endsWith(suffix)) {
            const base = hostname.slice(0, hostname.length - suffix.length);
            domainRoots.add(`${base}.salesforce.com`);
            domainRoots.add(`${base}.my.salesforce.com`);
            domainRoots.add(`${base}.lightning.force.com`);
        }
    }
    domainRoots.add(hostname); // always include the current host

    const seen = new Set();
    const results = [];

    for (const domain of domainRoots) {
        const cookies = await getCookiesAll({ domain, name: 'sid' });
        for (const c of cookies) {
            if (c.value && !seen.has(c.value)) {
                seen.add(c.value);
                // Prefer HTTPS and exact domain matches as the API endpoint
                const apiDomain = `https://${domain}`;
                results.push({ sessionId: c.value, apiDomain });
            }
        }
    }
    return results;
}

// Return all sid cookie candidates ordered by most-likely-correct domain first.
// The caller tries each one and stops on the first successful API response.
async function getSalesforceSid(orgDomain) {
    const candidates = await collectAllSidCookies(orgDomain);
    return candidates; // caller iterates and stops on first 200
}

// Resolve DeveloperName + VersionNumber for a Flow record.
// Uses a single relationship query - Definition.DeveloperName traverses to FlowDefinition
// where the API name reliably lives, avoiding a second roundtrip.
async function fetchFlowIdentity(apiDomain, sessionId, flowId) {
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

// Fetch from Tooling API and return raw JSON metadata
async function fetchFlowFromSalesforce(apiDomain, sessionId, flowApiName, flowId, versionNumber) {
    let query;
    let ver = versionNumber != null ? Number(versionNumber) : null;
    let resolvedApiName = flowApiName || null;

    // When we have a flowId, always fetch metadata by Id - it is the only reliable
    // query form that avoids 400 errors from Salesforce Tooling API edge cases.
    // Identity resolution runs separately and is used only for the filename.
    if (flowId) {
        query = `SELECT Metadata FROM Flow WHERE Id = '${flowId}'`;
        if (!resolvedApiName) {
            try {
                const identity = await fetchFlowIdentity(apiDomain, sessionId, flowId);
                resolvedApiName = identity.developerName;
                ver = identity.versionNumber ?? ver;
            } catch {
                // Best-effort - filename will fall back to metadata label
            }
        }
    } else if (flowApiName && ver !== null) {
        query = `SELECT Metadata FROM Flow WHERE DeveloperName = '${flowApiName}' AND VersionNumber = ${ver}`;
    } else if (flowApiName) {
        query = `SELECT Metadata FROM Flow WHERE DeveloperName = '${flowApiName}' AND Status = 'Active'`;
    } else {
        throw new Error('Flow API Name or ID is required.');
    }

    const url = `${apiDomain}/services/data/${SF_API_VERSION}/tooling/query/?q=${encodeURIComponent(query)}`;

    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);

    let response;
    try {
        response = await fetch(url, {
            headers: {
                'Authorization': `Bearer ${sessionId}`,
                'Content-Type': 'application/json'
            },
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
        err.cause = response.status; // lets caller detect 401 and try next session candidate
        throw err;
    }

    const jsonResponse = await response.json();

    if (!jsonResponse.records || jsonResponse.records.length === 0) {
        const label = resolvedApiName || flowApiName || flowId;
        throw new Error(`Flow "${label}" (Version ${ver ?? 'Active'}) not found in this org.`);
    }

    const metadata = jsonResponse.records[0].Metadata;

    // If API name could not be resolved via identity query, fall back to the
    // label embedded in the metadata JSON (already in hand - no extra API call).
    // Sanitize: replace whitespace with underscores, strip chars invalid in filenames.
    if (!resolvedApiName && metadata?.label) {
        resolvedApiName = metadata.label.replace(/\s+/g, '_').replace(/[\\/:*?"<>|]/g, '');
    }

    return {
        json: JSON.stringify(metadata, null, 2),
        flowApiName: resolvedApiName,
        versionNumber: ver
    };
}

// Trigger a local file download via chrome.downloads.
// Uses a base64 data URL instead of URL.createObjectURL - the latter is not
// available in MV3 service workers.
function downloadJsonFile(jsonContent, flowLabel, versionNumber) {
    const bytes = new TextEncoder().encode(jsonContent);
    let binary = '';
    const chunkSize = 8192;
    for (let i = 0; i < bytes.length; i += chunkSize) {
        binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
    }
    const dataUrl = `data:application/json;base64,${btoa(binary)}`;
    const filename = `${flowLabel}_Ver${versionNumber ?? 'Active'}.json`;

    chrome.downloads.download({ url: dataUrl, filename, saveAs: true });
}
