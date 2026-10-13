(() => {
  const PREFS_KEY = 'singularity-devtools-preferences';
  const query = new URLSearchParams(location.search);
  const native = (method, args) => {
    const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.singularityDevtools;
    if (handler) handler.postMessage(JSON.stringify({ method, args }));
  };

  if (window.ShadowRoot && !ShadowRoot.prototype.getSelection) {
    ShadowRoot.prototype.getSelection = function () {
      return document.getSelection();
    };
  }

  const insertRule = CSSStyleSheet.prototype.insertRule;
  CSSStyleSheet.prototype.insertRule = function (rule, index) {
    try {
      return insertRule.call(this, rule, index);
    } catch (error) {
      if (window.SingularityDebug) window.SingularityDebug(`unsupported rule: ${String(rule).slice(0, 160)}`);
      return insertRule.call(this, '.singularity-unsupported-rule {}', index);
    }
  };

  if (!window.requestIdleCallback) {
    window.requestIdleCallback = (callback, options) => setTimeout(() => {
      const start = performance.now();
      callback({ didTimeout: false, timeRemaining: () => Math.max(0, 16 - (performance.now() - start)) });
    }, options && options.timeout ? Math.min(options.timeout, 1) : 1);
    window.cancelIdleCallback = (id) => clearTimeout(id);
  }

  let relayout = 0;
  const scheduleRelayout = (delay) => {
    clearTimeout(relayout);
    relayout = setTimeout(() => window.dispatchEvent(new Event('resize')), delay);
  };
  document.addEventListener('DOMContentLoaded', () => {
    let last = '';
    new ResizeObserver(() => {
      const size = `${document.documentElement.clientWidth}x${document.documentElement.clientHeight}`;
      if (size === last) return;
      last = size;
      scheduleRelayout(0);
    }).observe(document.documentElement);
    for (const delay of [300, 1000, 2500]) setTimeout(() => window.dispatchEvent(new Event('resize')), delay);
  });
  for (const type of ['click', 'keydown']) {
    window.addEventListener(type, () => scheduleRelayout(120), true);
  }

  if (query.get('debug')) {
    window.addEventListener('error', (event) => native('log', [`error: ${event.message} at ${event.filename}:${event.lineno}`]));
    window.addEventListener('unhandledrejection', (event) => native('log', [`rejection: ${event.reason && (event.reason.stack || event.reason.message || event.reason)}`]));
    window.SingularityDebug = (text) => native('log', [text]);
    for (const level of ['error', 'warn']) {
      const original = console[level].bind(console);
      console[level] = (...items) => {
        native('log', [`console.${level}: ${items.map((item) => (item && item.stack) || String(item)).join(' ')}`]);
        original(...items);
      };
    }
  }

  let preferences = {};
  try {
    preferences = JSON.parse(localStorage.getItem(PREFS_KEY) || '{}');
  } catch (e) {
    preferences = {};
  }
  const defaults = {
    'elements-panel-split-view-state': JSON.stringify({ vertical: { size: 340 }, horizontal: { size: 300 } }),
    'sources-panel-split-view-state': JSON.stringify({ vertical: { size: 300 }, horizontal: { size: 260 } }),
    'network-panel-split-view-state': JSON.stringify({ vertical: { size: 380 }, horizontal: { size: 300 } }),
  };
  for (const [name, value] of Object.entries(defaults)) {
    if (preferences[name] === undefined) preferences[name] = value;
  }
  const savePreferences = () => {
    try {
      localStorage.setItem(PREFS_KEY, JSON.stringify(preferences));
    } catch (e) {
    }
  };

  const ack = (id, result) => {
    if (id && window.DevToolsAPI) window.DevToolsAPI.embedderMessageAck(id, result);
  };

  const loadNetworkResource = async (id, url, headers, streamId) => {
    try {
      const response = await fetch(url, { credentials: 'include' });
      const text = await response.text();
      window.DevToolsAPI.streamWrite(streamId, text);
      const responseHeaders = {};
      response.headers.forEach((value, name) => { responseHeaders[name] = value; });
      ack(id, { statusCode: response.status, headers: responseHeaders });
    } catch (e) {
      ack(id, { statusCode: 404, netError: -2, netErrorName: 'net::ERR_FAILED', message: String(e) });
    }
  };

  const handle = (message) => {
    const { id, method } = message;
    const args = message.params || [];
    switch (method) {
      case 'dispatchProtocolMessage':
        window.SingularityCDP.fromFrontend(args[0]);
        ack(id);
        return;
      case 'getPreferences':
        ack(id, preferences);
        return;
      case 'getPreference':
        ack(id, preferences[args[0]]);
        return;
      case 'setPreference':
        preferences[args[0]] = args[1];
        savePreferences();
        ack(id);
        return;
      case 'removePreference':
        delete preferences[args[0]];
        savePreferences();
        ack(id);
        return;
      case 'clearPreferences':
        preferences = {};
        savePreferences();
        ack(id);
        return;
      case 'getHostConfig':
        ack(id, {});
        return;
      case 'getSyncInformation':
        ack(id, { isSyncActive: false, arePreferencesSynced: false });
        return;
      case 'canShowSurvey':
        ack(id, { canShowSurvey: false });
        return;
      case 'loadNetworkResource':
        loadNetworkResource(id, args[0], args[1], args[2]);
        return;
      case 'reattach':
        window.SingularityCDP.reattach();
        ack(id);
        return;
      case 'openInNewTab':
      case 'openSearchResultsInNewTab':
      case 'save':
      case 'append':
      case 'bringToFront':
      case 'closeWindow':
      case 'setIsDocked':
      case 'setInspectedPageBounds':
      case 'inspectElementCompleted':
      case 'showItemInFolder':
      case 'zoomIn':
      case 'zoomOut':
      case 'resetZoom':
        native(method, args);
        ack(id);
        return;
      default:
        ack(id);
    }
  };

  window.DevToolsHost = {
    platform: () => 'linux',
    isHostedMode: () => false,
    zoomFactor: () => 1,
    copyText: (text) => native('copyText', [text]),
    isolatedFileSystem: () => null,
    upgradeDraggedFileSystemPermissions: () => {},
    showContextMenuAtPoint: () => {},
    sendMessageToEmbedder: (json) => handle(JSON.parse(json)),
    target: () => query.get('target') || '',
  };
})();
