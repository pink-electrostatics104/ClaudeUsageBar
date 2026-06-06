// ClaudeUsageBar content script.
//
// Scrapes the Claude.ai usage figure from the page text and relays it to the
// background service worker. It deliberately avoids class names, which change
// often. Instead it scans document.body.innerText against the ordered matchers
// in CONFIG below. When Anthropic changes the UI, update CONFIG.

const CONFIG = {
  // How often to re-scan the page, in milliseconds.
  pollIntervalMs: 15000,

  // Ordered list of matchers. The first one that matches the page text wins.
  // Each build() receives the regex match array and returns { label, detail }.
  matchers: [
    {
      name: "messages-left",
      regex: /(\d+)\s+messages?\s+(?:left|remaining)/i,
      build: (m) => ({ label: `Claude ${m[1]} msgs`, detail: `${m[1]} messages left` })
    },
    {
      name: "percent-used",
      regex: /(\d+)\s*%\s*(?:of your usage|used)/i,
      build: (m) => ({ label: `Claude ${m[1]}%`, detail: `${m[1]}% used` })
    },
    {
      name: "counter",
      regex: /(\d+)\s*\/\s*(\d+)/,
      build: (m) => ({ label: `Claude ${m[1]}/${m[2]}`, detail: `${m[1]} of ${m[2]}` })
    }
  ],

  // Pulls a human readable reset time, for example "3:00 PM" or "15:00".
  resetRegex: /resets?\s*(?:at)?\s*([\d]{1,2}:[\d]{2}\s*(?:AM|PM)?)/i
};

function scrape() {
  const text = document.body ? document.body.innerText : "";
  if (!text) return null;

  let result = null;
  for (const matcher of CONFIG.matchers) {
    const m = text.match(matcher.regex);
    if (m) {
      result = matcher.build(m);
      break;
    }
  }
  if (!result) return null;

  const resetMatch = text.match(CONFIG.resetRegex);
  result.reset = resetMatch ? resetMatch[1].trim() : "";
  return result;
}

// Only send when the value actually changes.
let lastSent = "";

function tick() {
  const payload = scrape();
  if (!payload) return;

  const serialized = JSON.stringify(payload);
  if (serialized === lastSent) return;
  lastSent = serialized;

  try {
    chrome.runtime.sendMessage({ type: "usage", payload });
  } catch (e) {
    // The extension context can be invalidated on reload. Ignore quietly.
  }
}

// Coalesce bursts of DOM mutations into a single scan.
let debounceTimer = null;
function scheduleTick() {
  if (debounceTimer) return;
  debounceTimer = setTimeout(() => {
    debounceTimer = null;
    tick();
  }, 1000);
}

tick();
setInterval(tick, CONFIG.pollIntervalMs);

if (document.body) {
  const observer = new MutationObserver(scheduleTick);
  observer.observe(document.body, { childList: true, subtree: true, characterData: true });
}
