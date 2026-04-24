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

    if (!document.getElementById('fxr-toast-styles')) {
        const style = document.createElement('style');
        style.id = 'fxr-toast-styles';
        style.textContent = `
            @keyframes fxr-slide-in { from { opacity:0; transform:translateX(20px); } to { opacity:1; transform:translateX(0); } }
            @keyframes fxr-fade-out { from { opacity:1; } to { opacity:0; transform:translateY(-6px); } }
        `;
        document.head.appendChild(style);
    }

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
    // Delay revoke to give browser time to initiate the download
    setTimeout(() => URL.revokeObjectURL(url), 5000);
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
let _dropdownListenerController = null;

// ==========================================
// SPA navigation watcher
// Patches pushState AND replaceState (Salesforce uses both) to detect navigation.
// Guard against patch accumulation on extension hot-reload via _fxrNavPatched flag.
// ==========================================
function watchForNavigation() {
    // Prevent stacking wrappers if content script context is reused
    if (window._fxrNavPatched) return;
    window._fxrNavPatched = true;

    let lastUrl = window.location.href;

    const handleNavigation = () => {
        const currentUrl = window.location.href;
        // Skip if URL has not meaningfully changed
        if (currentUrl === lastUrl) return;
        lastUrl = currentUrl;

        const existing = document.querySelector('#xml-retrieve-builder-btn');
        if (existing) {
            // Disconnect observer before removing the element to prevent memory/CPU leak
            if (_modalObserver) { _modalObserver.disconnect(); _modalObserver = null; }
            existing.remove();
        }

        if (currentUrl.includes('/builder_platform_interaction/flowBuilder')) {
            setTimeout(injectIntoFlowBuilder, 300);
        }
    };

    const originalPushState = history.pushState.bind(history);
    history.pushState = function (...args) {
        originalPushState(...args);
        handleNavigation();
    };

    // Salesforce also uses replaceState for in-place URL updates (e.g. version changes)
    const originalReplaceState = history.replaceState.bind(history);
    history.replaceState = function (...args) {
        originalReplaceState(...args);
        handleNavigation();
    };

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
    if (document.querySelector('#xml-retrieve-builder-btn')) return;

    const wrapper = document.createElement('div');
    wrapper.id = 'xml-retrieve-builder-btn';

    const primaryBtn = document.createElement('button');
    primaryBtn.id = 'xml-retrieve-btn-primary';
    primaryBtn.textContent = 'JSON';
    primaryBtn.title = 'Execute default action (configurable in extension options)';
    primaryBtn.addEventListener('click', () => {
        // Resolve flowId inside the storage callback to avoid a race where the user
        // navigates between the click and the async callback firing
        chrome.storage.sync.get({ defaultAction: 'COPY' }, ({ defaultAction }) => {
            const { flowId } = resolveFlowIdentityFromBuilder();
            triggerRetrieve(defaultAction, flowId);
        });
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

    // Memoize last modal state to avoid redundant DOM writes on every mutation.
    // Stored in module-level var so watchForNavigation can disconnect it on re-inject.
    let lastModalState = false;
    _modalObserver = new MutationObserver(() => {
        const modalOpen = !!document.querySelector('.modal-backdrop, .slds-backdrop_open');
        if (modalOpen !== lastModalState) {
            lastModalState = modalOpen;
            wrapper.style.display = modalOpen ? 'none' : 'flex';
        }
    });
    _modalObserver.observe(document.body, { childList: true, subtree: true });
}

// Returns flowId from URL query params - resolved at call time to handle SPA navigation
function resolveFlowIdentityFromBuilder() {
    const params = new URLSearchParams(window.location.search);
    const flowId = params.get('flowId') || params.get('id') || null;
    return { flowId };
}
