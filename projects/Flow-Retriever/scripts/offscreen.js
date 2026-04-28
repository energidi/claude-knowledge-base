chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg.action !== 'COPY_TO_CLIPBOARD') return;
    navigator.clipboard.writeText(msg.text)
        .then(() => sendResponse({ success: true }))
        .catch(err => sendResponse({ success: false, error: err.message }));
    return true;
});
