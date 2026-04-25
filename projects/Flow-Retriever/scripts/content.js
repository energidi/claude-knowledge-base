// ==========================================
// TOAST NOTIFICATION SYSTEM
// ==========================================
function showToast(message, type = 'info') {
    const COLORS = {
        success: { bg: '#2e844a', icon: '✓' },
        error:   { bg: '#ba0517', icon: '✕' },
        info:    { bg: '#0070d2', icon: 'ℹ' }
    };
    const { bg, icon } = COLORS[type] || COLORS.info;

    const toast = document.createElement('div');
    toast.style.cssText = `
        position: fixed;
        top: 20px;
        right: 20px;
        z-index: 99999;
        display: flex;
        align-items: center;
        gap: 10px;
        padding: 12px 16px;
        background: ${bg};
        color: #fff;
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
        font-size: 13px;
        font-weight: 500;
        border-radius: 4px;
        box-shadow: 0 4px 12px rgba(0,0,0,0.25);
        max-width: 360px;
        line-height: 1.4;
        animation: fxr-slide-in 0.2s ease-out;
        pointer-events: none;
    `;

    // Animations are defined in styles/custom.css (injected by the extension),
    // avoiding dynamic <style> injection into the host page DOM.

    const iconEl = document.createElement('span');
    iconEl.style.cssText = 'font-size:15px;flex-shrink:0;';
    iconEl.textContent = icon;

    const textEl = document.createElement('span');
    textEl.textContent = message;

    toast.appendChild(iconEl);
    toast.appendChild(textEl);
    document.body.appendChild(toast);

    setTimeout(() => {
        toast.style.animation = 'fxr-fade-out 0.3s ease-in forwards';
        setTimeout(() => toast.remove(), 300);
    }, type === 'error' ? 6000 : 3000);
}

// ==========================================
// CLIPBOARD HELPER
// Uses the async Clipboard API only. execCommand('copy') was removed because
// it writes the full Flow JSON into the page DOM where other page scripts
// (e.g. ISV managed package JS) can read it during the operation.
// If the Clipboard API is unavailable, the caller surfaces an error toast.
// ==========================================
function copyToClipboard(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
        return navigator.clipboard.writeText(text);
    }
    return Promise.reject(new Error('Clipboard API unavailable'));
}

// ==========================================
// DOWNLOAD HELPER
// Blob URL + anchor click is the correct approach for content scripts in MV3 (Chrome 120+).
// ==========================================
function downloadJson(jsonContent, flowApiName, versionNumber) {
    const filename = `${flowApiName}_Ver${versionNumber ?? 'Active'}.json`;
    const blob = new Blob([jsonContent], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.style.cssText = 'display:none;position:fixed;';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    // 60s delay: if the user has "Ask where to save" enabled in Chrome, the OS file
    // dialog stays open and the download reads the Blob URL after the click. Revoking
    // at 5s destroys the URL before they finish navigating the dialog.
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    showToast(`Downloaded: ${filename}`, 'success');
}

// ==========================================
// ENTRY POINT
// ==========================================
(function init() {
    if (window.location.href.includes('/builder_platform_interaction/flowBuilder')) {
        injectIntoFlowBuilder();
        watchForNavigation();
    }
})();

// Module-level references for cleanup across SPA navigations
let _modalObserver = null;
let _modalDebounceTimer = null;
let _dropdownListenerController = null;

// Cache defaultAction so the click handler can act synchronously - the async
// storage.sync.get callback expires the user-gesture window needed for clipboard access.
const _ALLOWED_ACTIONS = new Set(['COPY', 'DOWNLOAD']);
let _defaultAction = 'COPY';
chrome.storage.sync.get({ defaultAction: 'COPY' }, (result) => {
    if (!chrome.runtime.lastError && result?.defaultAction) {
        _defaultAction = _ALLOWED_ACTIONS.has(result.defaultAction) ? result.defaultAction : 'COPY';
    }
});
chrome.storage.onChanged.addListener((changes, area) => {
    if (area === 'sync' && changes.defaultAction) {
        _defaultAction = changes.defaultAction.newValue;
    }
});

// ==========================================
// SPA navigation watcher
// Polls window.location.href every 500ms. pushState/replaceState patching does not
// work in MV3 isolated worlds (each world has its own history object).
// Guard against interval accumulation on extension hot-reload via _fxrNavPatched flag.
// ==========================================
function watchForNavigation() {
    // Prevent stacking wrappers if content script context is reused
    if (window._fxrNavPatched) return;
    window._fxrNavPatched = true;

    let lastUrl = window.location.href;

    const handleNavigation = () => {
        if (document.hidden) return; // No work needed while tab is not visible
        const currentUrl = window.location.href;
        // Skip if URL has not meaningfully changed
        if (currentUrl === lastUrl) return;
        lastUrl = currentUrl;

        const existing = document.querySelector('#xml-retrieve-builder-btn');
        if (existing) {
            // Disconnect observer and cancel any pending debounce before removing the element
            if (_modalObserver) { _modalObserver.disconnect(); _modalObserver = null; }
            if (_modalDebounceTimer) { clearTimeout(_modalDebounceTimer); _modalDebounceTimer = null; }
            existing.remove();
        }

        if (currentUrl.includes('/builder_platform_interaction/flowBuilder')) {
            setTimeout(injectIntoFlowBuilder, 300);
        }
    };

    // Poll for URL changes every 500ms - the only reliable SPA detection approach
    // in MV3 isolated-world content scripts (pushState/replaceState patching only
    // intercepts calls from the content script's own world, not the page's JS).
    setInterval(handleNavigation, 500);
    window.addEventListener('popstate', handleNavigation);
}

// ==========================================
// SHARED: Send message to background and handle response
// ==========================================
function triggerRetrieve(method, flowId) {
    if (!flowId) {
        showToast('Flow ID not found in URL. Please ensure a Flow is open.', 'error');
        return;
    }

    const MAX_JSON_CHARS = 5 * 1024 * 1024; // 5 MB guard

    chrome.runtime.sendMessage(
        { action: 'RETRIEVE_FLOW', method, flowApiName: null, versionNumber: null, flowId },
        (response) => {
            if (chrome.runtime.lastError) {
                showToast(chrome.runtime.lastError.message, 'error');
                return;
            }
            if (!response || !response.success) {
                showToast(response?.error || 'Unknown error', 'error');
                return;
            }
            if (response.json && response.json.length > MAX_JSON_CHARS) {
                showToast('Flow JSON exceeds 5 MB. Use Download instead.', 'error');
                return;
            }
            if (method === 'COPY') {
                copyToClipboard(response.json).then(() => {
                    showToast('Flow JSON copied to clipboard.', 'success');
                }).catch(() => {
                    showToast('Clipboard access denied. Use Download instead.', 'error');
                });
            } else if (method === 'DOWNLOAD') {
                downloadJson(response.json, response.flowApiName, response.versionNumber);
            }
        }
    );
}

// ==========================================
// ENVIRONMENT: Flow Builder Canvas
// ==========================================
function injectIntoFlowBuilder() {
    // Remove any stale button from a previous extension context (hot-reload / auto-update).
    // Returning early would leave the old button whose event listeners point to the dead context.
    const existing = document.querySelector('#xml-retrieve-builder-btn');
    if (existing) existing.remove();

    const wrapper = document.createElement('div');
    wrapper.id = 'xml-retrieve-builder-btn';

    const primaryBtn = document.createElement('button');
    primaryBtn.id = 'xml-retrieve-btn-primary';
    primaryBtn.textContent = 'JSON';
    primaryBtn.title = 'Execute default action (configurable in extension options)';
    primaryBtn.addEventListener('click', () => {
        const { flowId } = resolveFlowIdentityFromBuilder();
        triggerRetrieve(_defaultAction, flowId);
    });

    const arrowBtn = document.createElement('button');
    arrowBtn.id = 'xml-retrieve-btn-arrow';
    arrowBtn.textContent = '▼';
    arrowBtn.title = 'JSON options';
    arrowBtn.setAttribute('aria-haspopup', 'true');
    arrowBtn.setAttribute('aria-expanded', 'false');

    const dropdownMenu = document.createElement('div');
    dropdownMenu.id = 'xml-retrieve-builder-menu';
    dropdownMenu.setAttribute('role', 'menu');
    dropdownMenu.setAttribute('aria-label', 'JSON export options');

    const menuList = document.createElement('ul');
    menuList.className = 'slds-dropdown__list';

    const makeMenuItem = (label, method) => {
        const li = document.createElement('li');
        li.setAttribute('role', 'presentation');
        const a = document.createElement('a');
        a.href = '#';
        a.setAttribute('role', 'menuitem');
        a.textContent = label;
        a.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            closeDropdown();
            const { flowId } = resolveFlowIdentityFromBuilder();
            triggerRetrieve(method, flowId);
        });
        li.appendChild(a);
        return li;
    };

    menuList.appendChild(makeMenuItem('📋  Copy JSON', 'COPY'));
    menuList.appendChild(makeMenuItem('⬇  Download JSON', 'DOWNLOAD'));
    dropdownMenu.appendChild(menuList);

    const closeDropdown = () => {
        dropdownMenu.style.display = 'none';
        arrowBtn.setAttribute('aria-expanded', 'false');
    };

    arrowBtn.addEventListener('click', (e) => {
        e.stopPropagation();
        const isOpen = dropdownMenu.style.display === 'block';
        dropdownMenu.style.display = isOpen ? 'none' : 'block';
        arrowBtn.setAttribute('aria-expanded', String(!isOpen));
    });

    // AbortController ensures the previous document listener is removed before re-injecting,
    // preventing accumulation of stale capture listeners across SPA navigations
    if (_dropdownListenerController) _dropdownListenerController.abort();
    _dropdownListenerController = new AbortController();
    document.addEventListener('click', (e) => {
        if (!wrapper.contains(e.target)) closeDropdown();
    }, { capture: true, signal: _dropdownListenerController.signal });

    wrapper.appendChild(primaryBtn);
    wrapper.appendChild(arrowBtn);
    wrapper.appendChild(dropdownMenu);
    document.body.appendChild(wrapper);

    // Debounced MutationObserver: Salesforce Flow Builder mutates the DOM hundreds of
    // times per second (drag, type, hover). Running querySelector on every mutation
    // causes layout thrashing. The 150ms debounce coalesces bursts into one check.
    let lastModalState = false;
    const syncModalState = () => {
        const modalOpen = !!document.querySelector('.modal-backdrop, .slds-backdrop_open');
        if (modalOpen !== lastModalState) {
            lastModalState = modalOpen;
            wrapper.style.display = modalOpen ? 'none' : 'flex';
        }
    };

    syncModalState(); // Sync immediately - modal may already be open at injection time

    _modalObserver = new MutationObserver(() => {
        if (_modalDebounceTimer) return;
        _modalDebounceTimer = setTimeout(() => {
            _modalDebounceTimer = null;
            syncModalState();
        }, 150);
    });
    _modalObserver.observe(document.body, { childList: true, subtree: true });
}

// Returns flowId from URL query params - resolved at call time to handle SPA navigation
function resolveFlowIdentityFromBuilder() {
    const params = new URLSearchParams(window.location.search);
    const flowId = params.get('flowId') || params.get('id') || null;
    return { flowId };
}
