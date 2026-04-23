// I1: Allowlist guards both reads from storage and writes back to storage
const ALLOWED_ACTIONS = new Set(['COPY', 'DOWNLOAD']);
const radios = document.querySelectorAll('input[name="defaultAction"]');
const status = document.getElementById('status');

chrome.storage.sync.get({ defaultAction: 'COPY' }, ({ defaultAction }) => {
    const safeDefault = ALLOWED_ACTIONS.has(defaultAction) ? defaultAction : 'COPY';
    if (safeDefault !== defaultAction) {
        chrome.storage.sync.set({ defaultAction: safeDefault });
    }
    radios.forEach(r => { r.checked = r.value === safeDefault; });
});

radios.forEach(radio => {
    radio.addEventListener('change', () => {
        // I1: Validate before writing - consistent with the read-time guard above
        if (!ALLOWED_ACTIONS.has(radio.value)) return;
        chrome.storage.sync.set({ defaultAction: radio.value }, () => {
            status.textContent = 'Saved.';
            setTimeout(() => { status.textContent = ''; }, 1500);
        });
    });
});
