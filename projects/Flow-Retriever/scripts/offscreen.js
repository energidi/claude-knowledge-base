// navigator.clipboard.writeText() fails in offscreen documents because they are
// hidden and cannot receive focus. document.execCommand('copy') works here because
// the clipboardWrite manifest permission grants extension pages clipboard access
// without focus or user gesture. The offscreen context is isolated at the extension's
// own origin, so the DOM textarea is not readable by page scripts (unlike the content
// script context where this approach was deliberately removed for that reason).
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg.action !== 'COPY_TO_CLIPBOARD') return;
    // Reject messages from outside this extension (defense in depth)
    if (sender.id !== chrome.runtime.id) {
        sendResponse({ success: false, error: 'Untrusted sender.' });
        return;
    }
    const textarea = document.createElement('textarea');
    textarea.value = msg.text;
    document.body.appendChild(textarea);
    try {
        textarea.select();
        const ok = document.execCommand('copy');
        sendResponse(ok ? { success: true } : { success: false, error: 'execCommand copy returned false.' });
    } catch (err) {
        sendResponse({ success: false, error: err.message });
    } finally {
        document.body.removeChild(textarea);
    }
    // sendResponse is called synchronously above - no return true needed
});
