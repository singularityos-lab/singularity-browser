chrome.runtime.onMessage.addListener((m, s, r) => r({ echo: m }));
