const radios = document.querySelectorAll('input[name="defaultAction"]');
const status = document.getElementById('status');

// Load saved setting
chrome.storage.sync.get({ defaultAction: 'COPY' }, ({ defaultAction }) => {
    radios.forEach(r => { r.checked = r.value === defaultAction; });
});

// Save on change
radios.forEach(radio => {
    radio.addEventListener('change', () => {
        chrome.storage.sync.set({ defaultAction: radio.value }, () => {
            status.textContent = 'Saved.';
            setTimeout(() => { status.textContent = ''; }, 1500);
        });
    });
});
