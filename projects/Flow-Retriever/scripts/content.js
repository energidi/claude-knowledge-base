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
// Falls back to execCommand when the Clipboard API is unavailable or
// the document has lost focus (common in Salesforce Lightning iframes).
// ==========================================
function copyToClipboard(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
        return navigator.clipboard.writeText(text).catch(() => execCommandCopy(text));
    }
    return execCommandCopy(text);
}

function execCommandCopy(text) {
    return new Promise((resolve, reject) => {
        const textarea = document.createElement('textarea');
        textarea.value = text;
        textarea.style.cssText = 'position:fixed;top:-9999px;left:-9999px;opacity:0;';
        document.body.appendChild(textarea);
        textarea.focus();
        textarea.select();
        try {
            const ok = document.execCommand('copy');
            textarea.remove();
            ok ? resolve() : reject(new Error('execCommand copy returned false'));
        } catch (err) {
            textarea.remove();
            reject(err);
        }
    });
}

// ==========================================
// DOWNLOAD HELPER
// I6: data: URL downloads are deprecated in Chrome MV3 (Chrome 120+).
// Blob URL + anchor click is the correct replacement and works in content scripts.
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

// ==========================================
// M3 + I2 + I3: SPA navigation watcher
// - I2: Guard against patch accumulation on extension hot-reload
// - I3: Track lastUrl so re-injection only fires when flowId/path actually changes
// ==========================================
function watchForNavigation() {
    // I2: Prevent stacking pushState wrappers if content script context is reused
    if (window._fxrNavPatched) return;
    window._fxrNavPatched = true;

    let lastUrl = window.location.href;

    const handleNavigation = () => {
        const currentUrl = window.location.href;
        // I3: Skip if URL has not meaningfully changed (e.g. Salesforce state-only pushState)
        if (currentUrl === lastUrl) return;
        lastUrl = currentUrl;

        const existing = document.querySelector('#xml-retrieve-builder-btn');
        if (existing) existing.remove();

        if (currentUrl.includes('/builder_platform_interaction/flowBuilder')) {
            setTimeout(injectIntoFlowBuilder, 300);
        }
    };

    const originalPushState = history.pushState.bind(history);
    history.pushState = function (...args) {
        originalPushState(...args);
        handleNavigation();
    };
    window.addEventListener('popstate', handleNavigation);
}

// ==========================================
// SHARED: Send message to background and handle response
// ==========================================
function triggerRetrieve(method, flowId) {
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
            if (method === 'COPY') {
                copyToClipboard(response.json).then(() => {
                    showToast('Flow JSON copied to clipboard.', 'success');
                }).catch(() => {
                    showToast('Clipboard write failed. Try the Download option instead.', 'error');
                });
            } else if (method === 'DOWNLOAD') {
                // I6: Download handled here via blob URL - replaces deprecated data: URL in background
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
        // I5: Resolve flowId at click time to handle SPA navigation
        const { flowId } = resolveFlowIdentityFromBuilder();
        chrome.storage.sync.get({ defaultAction: 'COPY' }, ({ defaultAction }) => {
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
            // I5: Resolve flowId at click time
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

    document.addEventListener('click', (e) => {
        if (!wrapper.contains(e.target)) closeDropdown();
    }, { capture: true });

    wrapper.appendChild(primaryBtn);
    wrapper.appendChild(arrowBtn);
    wrapper.appendChild(dropdownMenu);
    document.body.appendChild(wrapper);

    // I4: Memoize last modal state to avoid redundant DOM writes on every mutation
    let lastModalState = false;
    const modalObserver = new MutationObserver(() => {
        const modalOpen = !!document.querySelector('.modal-backdrop, .slds-backdrop_open');
        if (modalOpen !== lastModalState) {
            lastModalState = modalOpen;
            wrapper.style.display = modalOpen ? 'none' : 'flex';
        }
    });
    modalObserver.observe(document.body, { childList: true, subtree: true });
}

// Returns flowId from URL query params - resolved at click time to handle SPA navigation
function resolveFlowIdentityFromBuilder() {
    const params = new URLSearchParams(window.location.search);
    const flowId = params.get('flowId') || params.get('id') || null;
    return { flowId };
}
