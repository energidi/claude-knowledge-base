// M4: Allowlist of valid action values - guards against corrupted or legacy storage values
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
        chrome.storage.sync.set({ defaultAction: radio.value }, () => {
            status.textContent = 'Saved.';
            setTimeout(() => { status.textContent = ''; }, 1500);
        });
    });
});
