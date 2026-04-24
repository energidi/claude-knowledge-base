const ALLOWED_ACTIONS = new Set(['COPY', 'DOWNLOAD']);
const radios = document.querySelectorAll('input[name="defaultAction"]');
const status = document.getElementById('status');

chrome.storage.sync.get({ defaultAction: 'COPY' }, (result) => {
    const defaultAction = chrome.runtime.lastError ? 'COPY' : (result?.defaultAction ?? 'COPY');
    const safeDefault = ALLOWED_ACTIONS.has(defaultAction) ? defaultAction : 'COPY';
    if (!chrome.runtime.lastError && safeDefault !== defaultAction) {
        chrome.storage.sync.set({ defaultAction: safeDefault });
    }
    radios.forEach(r => { r.checked = r.value === safeDefault; });
});

radios.forEach(radio => {
    radio.addEventListener('change', () => {
        if (!ALLOWED_ACTIONS.has(radio.value)) return;
        chrome.storage.sync.set({ defaultAction: radio.value }, () => {
            if (!status) return;
            if (chrome.runtime.lastError) {
                status.textContent = 'Save failed.';
            } else {
                status.textContent = 'Saved.';
            }
            setTimeout(() => { if (status) status.textContent = ''; }, 1500);
        });
    });
});
