// ClaudeUsageBar background service worker.
//
// Receives usage payloads from the content script and forwards them to the
// local menu bar app over loopback only. Failures are expected when the app is
// not running, so they are swallowed and logged at debug level.

const ENDPOINT = "http://127.0.0.1:8787/usage";

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || message.type !== "usage") return;

  fetch(ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(message.payload)
  })
    .then(() => sendResponse({ ok: true }))
    .catch((err) => {
      // The app may not be running. This is not an error worth surfacing.
      console.debug("ClaudeUsageBar: relay failed", err);
      sendResponse({ ok: false });
    });

  // Keep the async message channel open for the fetch above.
  return true;
});
