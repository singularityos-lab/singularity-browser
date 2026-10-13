(() => {
  const query = new URLSearchParams(location.search);
  const ORIGINS = { author: 'regular', 'user-agent': 'user-agent', inspector: 'inspector', user: 'injected' };
  const RESOURCE_TYPES = {
    Document: 'Document', StyleSheet: 'Stylesheet', Image: 'Image', Font: 'Font', Script: 'Script',
    XHR: 'XHR', Fetch: 'Fetch', Ping: 'Ping', Beacon: 'Ping', WebSocket: 'WebSocket', EventSource: 'EventSource',
    Media: 'Media', Manifest: 'Manifest', Other: 'Other',
  };
  const SCOPES = {
    global: 'global', with: 'with', closure: 'closure', catch: 'catch', functionName: 'closure',
    globalLexicalEnvironment: 'script', nestedLexical: 'block',
  };
  const CONSOLE_TYPES = {
    log: 'log', dir: 'dir', dirxml: 'dirxml', table: 'table', trace: 'trace', clear: 'clear',
    startGroup: 'startGroup', startGroupCollapsed: 'startGroupCollapsed', endGroup: 'endGroup',
    assert: 'assert', timing: 'timeEnd', profile: 'profile', profileEnd: 'profileEnd', image: 'log',
  };
  const CONSOLE_LEVELS = { log: 'log', info: 'info', warning: 'warning', error: 'error', debug: 'debug' };

  class Link {
    constructor(path, onEvent, onClose) {
      this.pending = new Map();
      this.nextId = 1;
      this.pageTarget = null;
      this.queue = [];
      this.onEvent = onEvent;
      this.ready = new Promise((resolve, reject) => {
        this.resolveReady = resolve;
        this.rejectReady = reject;
      });
      this.socket = new WebSocket(`ws://${query.get('server')}${path}`);
      this.socket.onmessage = (event) => this.receive(JSON.parse(event.data));
      this.socket.onerror = () => this.rejectReady(new Error('inspector connection failed'));
      this.socket.onclose = () => onClose && onClose(this);
    }

    receive(message) {
      if (message.method === 'Target.targetCreated') {
        const info = message.params.targetInfo;
        if (info.type === 'page' && !this.pageTarget) {
          this.pageTarget = info.targetId;
          this.resolveReady(this);
        }
        return;
      }
      if (message.method === 'Target.didCommitProvisionalTarget') {
        if (message.params.oldTargetId === this.pageTarget) {
          this.pageTarget = message.params.newTargetId;
          this.onEvent({ method: 'Singularity.targetSwapped', params: {} });
        }
        return;
      }
      if (message.method === 'Target.dispatchMessageFromTarget') {
        if (message.params.targetId !== this.pageTarget) return;
        const inner = JSON.parse(message.params.message);
        if (inner.id !== undefined) {
          const waiter = this.pending.get(inner.id);
          if (!waiter) return;
          this.pending.delete(inner.id);
          if (inner.error) waiter.reject(inner.error);
          else waiter.resolve(inner.result || {});
          return;
        }
        this.onEvent(inner);
      }
    }

    send(method, params) {
      const id = this.nextId++;
      const inner = JSON.stringify({ id, method, params: params || {} });
      return new Promise((resolve, reject) => {
        this.pending.set(id, { resolve, reject });
        this.socket.send(JSON.stringify({
          id: id + 1000000000,
          method: 'Target.sendMessageToTarget',
          params: { targetId: this.pageTarget, message: inner },
        }));
      });
    }

    close() {
      this.socket.close();
    }
  }

  const missing = (error) => error && /was not found|not supported|Unknown/i.test(error.message || '');

  class Translator {
    constructor() {
      this.link = null;
      this.enabled = new Set();
      this.nodes = new Map();
      this.styles = new Map();
      this.contexts = new Map();
      this.frames = new Map();
      this.mainFrame = null;
      this.scripts = new Map();
      this.scopeObjects = new Set();
      this.backlog = [];
      this.handlers = this.buildHandlers();
      this.events = this.buildEvents();
      this.connect();
    }

    async connect(attempt = 0) {
      const targets = JSON.parse(query.get('targets') || '[]');
      const marker = query.get('marker');
      for (const path of targets) {
        const link = new Link(path, (event) => this.fromBackend(event), (closed) => this.closed(closed));
        try {
          await link.ready;
          if (marker && targets.length > 1) {
            const check = await link.send('Runtime.evaluate', { expression: 'window.__singularityDevtools', returnByValue: true });
            if (!check.result || check.result.value !== marker) {
              link.close();
              continue;
            }
          }
          this.link = link;
          break;
        } catch (e) {
          link.close();
        }
      }
      if (!this.link) {
        if (attempt < 10) setTimeout(() => this.connect(attempt + 1), 300);
        return;
      }
      const backlog = this.backlog;
      this.backlog = [];
      for (const message of backlog) this.fromFrontend(message);
    }

    closed(link) {
      if (link === this.link) this.emit('Inspector.detached', { reason: 'target_closed' });
    }

    reattach() {
      this.enabled.clear();
      if (this.link) this.link.close();
      this.link = null;
      this.connect();
    }

    emit(method, params, sessionId) {
      const message = { method, params };
      if (sessionId) message.sessionId = sessionId;
      window.DevToolsAPI.dispatchMessage(JSON.stringify(message));
    }

    reply(id, sessionId, result, error) {
      const message = { id };
      if (sessionId) message.sessionId = sessionId;
      if (error) message.error = { code: error.code || -32000, message: error.message || String(error) };
      else message.result = result || {};
      window.DevToolsAPI.dispatchMessage(JSON.stringify(message));
    }

    async fromFrontend(json) {
      const message = typeof json === 'string' ? JSON.parse(json) : json;
      if (!this.link) {
        this.backlog.push(message);
        return;
      }
      const { id, method, sessionId } = message;
      const params = message.params || {};
      const debug = window.SingularityDebug;
      try {
        const handler = this.handlers[method];
        if (debug && !handler) debug(`forward ${method}`);
        const result = handler ? await handler(params) : await this.forward(method, params);
        this.reply(id, sessionId, result);
      } catch (error) {
        if (debug) debug(`fail ${method}: ${error && (error.message || JSON.stringify(error))} params=${JSON.stringify(params).slice(0, 300)}`);
        if (missing(error)) this.reply(id, sessionId, {});
        else this.reply(id, sessionId, null, error);
      }
    }

    async forward(method, params) {
      try {
        return await this.link.send(method, params);
      } catch (error) {
        if (missing(error)) return {};
        throw error;
      }
    }

    async enable(domain) {
      this.enabled.add(domain);
      return this.forward(`${domain}.enable`, {});
    }

    fromBackend(event) {
      if (event.method === 'Singularity.targetSwapped') {
        this.targetSwapped();
        return;
      }
      const translate = this.events[event.method];
      if (translate === null) return;
      if (!translate) {
        this.emit(event.method, event.params);
        return;
      }
      const out = translate(event.params || {});
      if (!out) return;
      for (const [method, params] of Array.isArray(out[0]) ? out : [out]) this.emit(method, params);
    }

    async targetSwapped() {
      this.nodes.clear();
      this.styles.clear();
      this.contexts.clear();
      this.emit('Runtime.executionContextsCleared', {});
      const domains = [...this.enabled];
      for (const domain of domains) {
        try {
          await this.link.send(`${domain}.enable`, {});
        } catch (e) {
        }
      }
      this.emit('DOM.documentUpdated', {});
    }

    node(payload) {
      if (!payload) return payload;
      payload.backendNodeId = payload.nodeId;
      if (payload.nodeType === 1 && !payload.attributes) payload.attributes = [];
      if (payload.frameId === undefined && this.mainFrame && payload.nodeType === 9) payload.frameId = this.mainFrame;
      this.nodes.set(payload.nodeId, payload);
      for (const key of ['children', 'pseudoElements', 'shadowRoots']) {
        if (payload[key]) payload[key].forEach((child) => this.node(child));
      }
      if (payload.contentDocument) this.node(payload.contentDocument);
      if (payload.templateContent) this.node(payload.templateContent);
      if (payload.pseudoType === 'before' || payload.pseudoType === 'after') payload.pseudoIdentifier = undefined;
      return payload;
    }

    frame(frame) {
      if (!frame) return frame;
      let host = '';
      try {
        host = new URL(frame.url).hostname;
      } catch (e) {
      }
      frame.domainAndRegistry = host.split('.').slice(-2).join('.');
      frame.secureContextType = frame.securityOrigin && frame.securityOrigin.startsWith('https') ? 'Secure' : 'InsecureScheme';
      frame.crossOriginIsolatedContextType = 'NotIsolated';
      frame.gatedAPIFeatures = [];
      frame.adFrameStatus = { adFrameType: 'none' };
      if (!frame.parentId) this.mainFrame = frame.id;
      this.frames.set(frame.id, frame);
      return frame;
    }

    frameTree(tree) {
      this.frame(tree.frame);
      if (tree.childFrames) tree.childFrames.forEach((child) => this.frameTree(child));
      if (tree.resources) {
        tree.resources.forEach((resource) => {
          resource.type = RESOURCE_TYPES[resource.type] || 'Other';
        });
      }
      return tree;
    }

    property(prop) {
      return {
        name: prop.name,
        value: prop.value,
        important: prop.priority === 'important',
        implicit: !!prop.implicit,
        text: prop.text,
        parsedOk: prop.parsedOk !== false,
        disabled: prop.status === 'disabled',
        range: prop.range,
      };
    }

    style(style) {
      if (!style) return style;
      const sheet = style.styleId ? style.styleId.styleSheetId : undefined;
      if (style.styleId && style.range) {
        this.styles.set(`${sheet}:${style.range.startLine}:${style.range.startColumn}`, style.styleId);
      }
      return {
        styleSheetId: sheet,
        cssProperties: (style.cssProperties || []).map((p) => this.property(p)),
        shorthandEntries: (style.shorthandEntries || []).map((e) => ({ name: e.name, value: e.value, important: e.priority === 'important' })),
        cssText: style.cssText,
        range: style.range,
      };
    }

    selectors(list) {
      return {
        selectors: (list.selectors || []).map((s) => ({
          text: s.text,
          specificity: s.specificity ? { a: s.specificity[0], b: s.specificity[1], c: s.specificity[2] } : undefined,
        })),
        text: list.text,
      };
    }

    rule(rule) {
      const sheet = rule.ruleId ? rule.ruleId.styleSheetId : (rule.style && rule.style.styleId ? rule.style.styleId.styleSheetId : undefined);
      const media = (rule.groupings || []).filter((g) => g.type && g.type.startsWith('media')).map((g) => ({
        text: g.text,
        source: g.type === 'media-import-rule' ? 'importRule' : 'mediaRule',
        sourceURL: g.sourceURL,
        range: g.range,
        styleSheetId: sheet,
      }));
      return {
        styleSheetId: sheet,
        selectorList: this.selectors(rule.selectorList || { selectors: [], text: '' }),
        origin: ORIGINS[rule.origin] || 'regular',
        style: this.style(rule.style),
        media: media.length ? media : undefined,
      };
    }

    ruleMatch(match) {
      return { rule: this.rule(match.rule), matchingSelectors: match.matchingSelectors || [] };
    }

    sheetHeader(header) {
      return {
        styleSheetId: header.styleSheetId,
        frameId: header.frameId,
        sourceURL: header.sourceURL,
        origin: ORIGINS[header.origin] || 'regular',
        title: header.title || '',
        disabled: !!header.disabled,
        isInline: !!header.isInline,
        isMutable: header.origin !== 'user-agent',
        isConstructed: false,
        startLine: header.startLine || 0,
        startColumn: header.startColumn || 0,
        length: 0,
        endLine: header.startLine || 0,
        endColumn: header.startColumn || 0,
      };
    }

    context(context) {
      let origin = '';
      const frame = this.frames.get(context.frameId);
      if (frame) origin = frame.securityOrigin || '';
      const out = {
        id: context.id,
        origin,
        name: context.name || '',
        uniqueId: `${context.frameId}-${context.id}`,
        auxData: {
          isDefault: context.type === 'normal' || context.isPageContext === true,
          type: context.type === 'normal' || context.isPageContext ? 'default' : 'isolated',
          frameId: context.frameId,
        },
      };
      this.contexts.set(context.id, out);
      return out;
    }

    defaultContext() {
      for (const context of this.contexts.values()) {
        if (context.auxData.isDefault && context.auxData.frameId === this.mainFrame) return context.id;
      }
      return undefined;
    }

    remote(object) {
      if (!object) return object;
      if (object.subtype === 'class') object.subtype = undefined;
      if (object.type === 'class') object.type = 'function';
      return object;
    }

    stack(trace) {
      if (!trace) return undefined;
      const frames = trace.callFrames || trace;
      return {
        callFrames: (Array.isArray(frames) ? frames : []).map((f) => ({
          functionName: f.functionName || '',
          scriptId: f.scriptId || '',
          url: f.url || '',
          lineNumber: Math.max(0, (f.lineNumber || 1) - 1),
          columnNumber: Math.max(0, (f.columnNumber || 1) - 1),
        })),
      };
    }

    callFrame(frame) {
      const script = this.scripts.get(frame.location.scriptId);
      return {
        callFrameId: frame.callFrameId,
        functionName: frame.functionName || '',
        location: frame.location,
        url: script ? script.url : '',
        scopeChain: (frame.scopeChain || []).map((scope, index) => {
          if (scope.object && scope.object.objectId) this.scopeObjects.add(scope.object.objectId);
          return {
            type: index === 0 && scope.type === 'closure' ? 'local' : (SCOPES[scope.type] || 'closure'),
            object: this.remote(scope.object),
            name: scope.name,
            startLocation: scope.location,
          };
        }),
        this: this.remote(frame.this),
        canBeRestarted: false,
      };
    }

    request(request) {
      return {
        url: request.url,
        method: request.method,
        headers: request.headers || {},
        postData: request.postData,
        hasPostData: !!request.postData,
        initialPriority: 'High',
        referrerPolicy: 'strict-origin-when-cross-origin',
      };
    }

    response(response, timestamp) {
      const timing = response.timing || {};
      const ms = (value) => (value === undefined || value < 0 ? -1 : value);
      return {
        url: response.url,
        status: response.status,
        statusText: response.statusText || '',
        headers: response.headers || {},
        mimeType: response.mimeType || '',
        requestHeaders: response.requestHeaders,
        connectionReused: false,
        connectionId: 0,
        fromDiskCache: response.source === 'disk-cache',
        fromServiceWorker: response.source === 'service-worker',
        fromPrefetchCache: false,
        encodedDataLength: 0,
        securityState: response.url && response.url.startsWith('https') ? 'secure' : 'neutral',
        protocol: (response.security && response.security.connection && response.security.connection.protocol) || '',
        remoteIPAddress: timing.remoteAddress,
        timing: response.timing ? {
          requestTime: (timing.startTime || timestamp || 0),
          proxyStart: -1,
          proxyEnd: -1,
          dnsStart: ms(timing.domainLookupStart),
          dnsEnd: ms(timing.domainLookupEnd),
          connectStart: ms(timing.connectStart),
          connectEnd: ms(timing.connectEnd),
          sslStart: ms(timing.secureConnectionStart),
          sslEnd: timing.secureConnectionStart > 0 ? ms(timing.connectEnd) : -1,
          workerStart: -1,
          workerReady: -1,
          workerFetchStart: -1,
          workerRespondWithSettled: -1,
          sendStart: ms(timing.requestStart),
          sendEnd: ms(timing.requestStart),
          pushStart: 0,
          pushEnd: 0,
          receiveHeadersStart: ms(timing.responseStart),
          receiveHeadersEnd: ms(timing.responseStart),
        } : undefined,
      };
    }

    async nodeFor(params) {
      if (params.nodeId) return params.nodeId;
      if (params.backendNodeId) return params.backendNodeId;
      if (params.objectId) {
        const found = await this.link.send('DOM.requestNode', { objectId: params.objectId });
        return found.nodeId;
      }
      return undefined;
    }

    async objectFor(nodeId) {
      const resolved = await this.link.send('DOM.resolveNode', { nodeId, objectGroup: 'singularity' });
      return resolved.object.objectId;
    }

    async boxModel(params) {
      const nodeId = await this.nodeFor(params);
      const objectId = await this.objectFor(nodeId);
      const result = await this.link.send('Runtime.callFunctionOn', {
        objectId,
        functionDeclaration: `function () {
          const el = this.nodeType === 1 ? this : this.parentElement;
          if (!el) return null;
          const r = el.getBoundingClientRect();
          const s = getComputedStyle(el);
          const n = (v) => parseFloat(v) || 0;
          const sx = window.scrollX, sy = window.scrollY;
          const quad = (x, y, w, h) => [x + sx, y + sy, x + w + sx, y + sy, x + w + sx, y + h + sy, x + sx, y + h + sy];
          const m = [n(s.marginTop), n(s.marginRight), n(s.marginBottom), n(s.marginLeft)];
          const b = [n(s.borderTopWidth), n(s.borderRightWidth), n(s.borderBottomWidth), n(s.borderLeftWidth)];
          const p = [n(s.paddingTop), n(s.paddingRight), n(s.paddingBottom), n(s.paddingLeft)];
          return {
            border: quad(r.left, r.top, r.width, r.height),
            margin: quad(r.left - m[3], r.top - m[0], r.width + m[1] + m[3], r.height + m[0] + m[2]),
            padding: quad(r.left + b[3], r.top + b[0], r.width - b[1] - b[3], r.height - b[0] - b[2]),
            content: quad(r.left + b[3] + p[3], r.top + b[0] + p[0], r.width - b[1] - b[3] - p[1] - p[3], r.height - b[0] - b[2] - p[0] - p[2]),
            width: Math.round(r.width),
            height: Math.round(r.height),
          };
        }`,
        returnByValue: true,
      });
      if (!result.result || !result.result.value) throw { message: 'Could not compute box model.' };
      return { model: result.result.value };
    }

    buildHandlers() {
      const ok = () => ({});
      const h = {};
      const quiet = [
        'Target.setAutoAttach', 'Target.setDiscoverTargets', 'Target.setRemoteLocations', 'Runtime.runIfWaitingForDebugger',
        'Page.setLifecycleEventsEnabled', 'Page.setAdBlockingEnabled', 'Page.addScriptToEvaluateOnNewDocument',
        'Emulation.setFocusEmulationEnabled', 'Emulation.setEmulatedVisionDeficiency', 'Emulation.setAutoDarkModeOverride',
        'Emulation.setTouchEmulationEnabled', 'Emulation.setEmitTouchEventsForMouse', 'Emulation.setIdleOverride',
        'Network.setAttachDebugStack', 'Network.clearAcceptedEncodingsOverride', 'Network.setBlockedURLs',
        'Debugger.setAsyncCallStackDepth', 'Debugger.setBlackboxPatterns', 'Debugger.setBlackboxExecutionContexts',
        'Debugger.setInstrumentationBreakpoint', 'Debugger.setSkipAllPauses', 'Runtime.addBinding',
        'Log.startViolationsReport', 'Log.stopViolationsReport', 'Audits.enable', 'ServiceWorker.enable',
        'Overlay.setShowViewportSizeOnResize', 'Overlay.setShowGridOverlays', 'Overlay.setShowFlexOverlays',
        'Overlay.setShowScrollSnapOverlays', 'Overlay.setShowContainerQueryOverlays', 'Overlay.setShowIsolatedElements',
        'Overlay.setPausedInDebuggerMessage', 'Overlay.enable', 'Autofill.enable', 'Autofill.setAddresses',
        'Preload.enable', 'FedCm.enable', 'Storage.trackCacheStorageForOrigin', 'Storage.trackIndexedDBForOrigin',
        'Storage.trackIndexedDBForStorageKey', 'Storage.trackCacheStorageForStorageKey', 'Storage.setInterestGroupTracking',
        'Storage.setSharedStorageTracking', 'Storage.setStorageBucketTracking', 'Profiler.enable', 'HeapProfiler.enable',
        'Accessibility.enable', 'Media.enable', 'WebAuthn.enable', 'EventBreakpoints.setInstrumentationBreakpoint',
        'DOMDebugger.setBreakOnCSPViolation', 'Network.setCacheDisabled', 'CSS.trackComputedStyleUpdates',
        'CSS.trackComputedStyleUpdatesForNode', 'Page.setBypassCSP', 'Page.startScreencast', 'Page.stopScreencast',
      ];
      quiet.forEach((name) => { h[name] = ok; });

      h['Runtime.enable'] = () => this.enable('Runtime');
      h['Page.enable'] = () => this.enable('Page');
      h['DOM.enable'] = () => this.enable('DOM');
      h['CSS.enable'] = async () => {
        await this.enable('DOM');
        return this.enable('CSS');
      };
      h['Network.enable'] = () => this.enable('Network');
      h['Debugger.enable'] = async () => {
        await this.enable('Debugger');
        return { debuggerId: 'singularity' };
      };
      h['Log.enable'] = () => this.enable('Console');
      h['Inspector.enable'] = () => this.enable('Inspector');
      h['Animation.enable'] = () => this.enable('Animation');
      h['DOMStorage.enable'] = () => this.enable('DOMStorage');
      h['IndexedDB.enable'] = () => this.enable('IndexedDB');
      h['LayerTree.enable'] = () => this.enable('LayerTree');

      h['Runtime.evaluate'] = async (p) => {
        const result = await this.link.send('Runtime.evaluate', {
          expression: p.expression,
          objectGroup: p.objectGroup,
          includeCommandLineAPI: p.includeCommandLineAPI,
          doNotPauseOnExceptionsAndMuteConsole: p.silent,
          contextId: p.contextId,
          returnByValue: p.returnByValue,
          generatePreview: p.generatePreview,
          emulateUserGesture: p.userGesture,
          awaitPromise: p.awaitPromise,
        });
        return this.evaluation(result);
      };
      h['Runtime.callFunctionOn'] = async (p) => {
        let objectId = p.objectId;
        if (!objectId) {
          const global = await this.link.send('Runtime.evaluate', { expression: 'globalThis', contextId: p.executionContextId });
          objectId = global.result.objectId;
        }
        const result = await this.link.send('Runtime.callFunctionOn', {
          objectId,
          functionDeclaration: p.functionDeclaration,
          arguments: p.arguments,
          doNotPauseOnExceptionsAndMuteConsole: p.silent,
          returnByValue: p.returnByValue,
          generatePreview: p.generatePreview,
          emulateUserGesture: p.userGesture,
          awaitPromise: p.awaitPromise,
        });
        return this.evaluation(result);
      };
      h['Runtime.getProperties'] = async (p) => {
        const scope = this.scopeObjects.has(p.objectId);
        const result = await this.link.send(scope ? 'Runtime.getDisplayableProperties' : 'Runtime.getProperties', scope ? {
          objectId: p.objectId,
          generatePreview: p.generatePreview,
        } : {
          objectId: p.objectId,
          ownProperties: p.ownProperties,
          generatePreview: p.generatePreview,
        });
        const properties = (result.properties || []).map((prop) => {
          prop.value = this.remote(prop.value);
          if (prop.writable === undefined) prop.writable = scope;
          if (prop.configurable === undefined) prop.configurable = scope;
          if (prop.enumerable === undefined) prop.enumerable = scope;
          if (prop.isOwn === undefined) prop.isOwn = true;
          return prop;
        });
        return { result: properties, internalProperties: result.internalProperties || [] };
      };
      h['Runtime.compileScript'] = async (p) => {
        try {
          await this.link.send('Runtime.parse', { source: p.expression });
        } catch (e) {
        }
        return {};
      };
      h['Runtime.globalLexicalScopeNames'] = () => ({ names: [] });
      h['Runtime.getIsolateId'] = () => ({ id: 'singularity' });
      h['Runtime.getHeapUsage'] = () => ({ usedSize: 0, totalSize: 0 });

      h['Page.getResourceTree'] = async () => {
        const result = await this.link.send('Page.getResourceTree', {});
        return { frameTree: this.frameTree(result.frameTree) };
      };
      h['Page.getFrameTree'] = async () => {
        const result = await this.link.send('Page.getResourceTree', {});
        const strip = (tree) => ({ frame: tree.frame, childFrames: (tree.childFrames || []).map(strip) });
        return { frameTree: strip(this.frameTree(result.frameTree)) };
      };
      h['Page.getNavigationHistory'] = async () => {
        const result = await this.link.send('Runtime.evaluate', { expression: 'JSON.stringify([location.href, document.title])', returnByValue: true });
        const [url, title] = JSON.parse(result.result.value);
        return { currentIndex: 0, entries: [{ id: 0, url, userTypedURL: url, title, transitionType: 'typed' }] };
      };
      h['Page.reload'] = (p) => this.link.send('Page.reload', { ignoreCache: !!p.ignoreCache });
      h['Page.navigate'] = async (p) => {
        await this.link.send('Page.navigate', { url: p.url });
        return { frameId: this.mainFrame };
      };
      h['Page.getLayoutMetrics'] = async () => {
        const result = await this.link.send('Runtime.evaluate', {
          expression: 'JSON.stringify([innerWidth, innerHeight, scrollX, scrollY, document.documentElement.scrollWidth, document.documentElement.scrollHeight])',
          returnByValue: true,
        });
        const [w, h2, x, y, sw, sh] = JSON.parse(result.result.value);
        const viewport = { pageX: x, pageY: y, clientWidth: w, clientHeight: h2, offsetX: 0, offsetY: 0, scale: 1, zoom: 1 };
        return {
          layoutViewport: { pageX: x, pageY: y, clientWidth: w, clientHeight: h2 },
          visualViewport: viewport,
          contentSize: { x: 0, y: 0, width: sw, height: sh },
          cssLayoutViewport: { pageX: x, pageY: y, clientWidth: w, clientHeight: h2 },
          cssVisualViewport: viewport,
          cssContentSize: { x: 0, y: 0, width: sw, height: sh },
        };
      };
      h['Page.getAppManifest'] = () => ({ url: '', errors: [] });
      h['Page.getInstallabilityErrors'] = () => ({ installabilityErrors: [] });
      h['Page.getAdScriptAncestry'] = () => ({});
      h['Page.getOriginTrials'] = () => ({ originTrials: [] });
      h['Page.getPermissionsPolicyState'] = () => ({ states: [] });

      h['DOM.getDocument'] = async () => {
        const result = await this.link.send('DOM.getDocument', {});
        this.documentReady = true;
        if (this.pendingInspect) {
          const { x, y } = this.pendingInspect;
          this.pendingInspect = null;
          setTimeout(() => this.inspectAt(x, y), 300);
        }
        return { root: this.node(result.root) };
      };
      h['DOM.requestChildNodes'] = (p) => this.link.send('DOM.requestChildNodes', { nodeId: p.nodeId, depth: p.depth });
      h['DOM.describeNode'] = async (p) => {
        const nodeId = await this.nodeFor(p);
        const node = this.nodes.get(nodeId) || { nodeId, backendNodeId: nodeId, nodeType: 1, nodeName: '', localName: '', nodeValue: '' };
        return { node };
      };
      h['DOM.pushNodesByBackendIdsToFrontend'] = (p) => ({ nodeIds: p.backendNodeIds });
      h['DOM.requestNode'] = (p) => this.link.send('DOM.requestNode', { objectId: p.objectId });
      h['DOM.resolveNode'] = async (p) => {
        const nodeId = await this.nodeFor(p);
        const result = await this.link.send('DOM.resolveNode', { nodeId, objectGroup: p.objectGroup });
        return { object: this.remote(result.object) };
      };
      h['DOM.getBoxModel'] = (p) => this.boxModel(p);
      h['DOM.getContentQuads'] = async (p) => {
        const box = await this.boxModel(p);
        return { quads: [box.model.border] };
      };
      h['DOM.getNodeForLocation'] = async (p) => {
        const found = await this.link.send('Runtime.evaluate', {
          expression: `document.elementFromPoint(${Number(p.x)}, ${Number(p.y)})`,
        });
        if (!found.result || !found.result.objectId) throw { message: 'No node found at given location' };
        const node = await this.link.send('DOM.requestNode', { objectId: found.result.objectId });
        return { backendNodeId: node.nodeId, nodeId: node.nodeId, frameId: this.mainFrame };
      };
      h['DOM.getFrameOwner'] = () => {
        throw { message: 'Frame owner not available' };
      };
      h['DOM.getNodesForSubtreeByStyle'] = () => ({ nodeIds: [] });
      h['DOM.getTopLayerElements'] = () => ({ nodeIds: [] });
      h['DOM.getAnchorElement'] = () => {
        throw { message: 'Not available' };
      };
      h['DOM.scrollIntoViewIfNeeded'] = async (p) => {
        const nodeId = await this.nodeFor(p);
        const objectId = await this.objectFor(nodeId);
        await this.link.send('Runtime.callFunctionOn', {
          objectId,
          functionDeclaration: 'function () { (this.nodeType === 1 ? this : this.parentElement).scrollIntoView({ block: "center", inline: "center" }); }',
        });
        return {};
      };
      h['DOM.setInspectedNode'] = (p) => this.link.send('Console.addInspectedNode', { nodeId: p.nodeId }).catch(() => ({}));
      h['DOM.markUndoableState'] = () => this.forward('DOM.markUndoableState', {});
      h['DOM.focus'] = async (p) => {
        const nodeId = await this.nodeFor(p);
        return this.link.send('DOM.focus', { nodeId });
      };

      h['Overlay.highlightNode'] = async (p) => {
        const nodeId = await this.nodeFor(p);
        if (!nodeId) return {};
        return this.link.send('DOM.highlightNode', { nodeId, highlightConfig: this.highlight(p.highlightConfig) });
      };
      h['Overlay.highlightRect'] = (p) => this.link.send('DOM.highlightRect', {
        x: p.x, y: p.y, width: p.width, height: p.height, color: p.color, outlineColor: p.outlineColor,
      });
      h['Overlay.highlightFrame'] = ok;
      h['Overlay.hideHighlight'] = () => this.link.send('DOM.hideHighlight', {});
      h['Overlay.setInspectMode'] = (p) => this.link.send('DOM.setInspectModeEnabled', {
        enabled: p.mode !== 'none',
        highlightConfig: this.highlight(p.highlightConfig),
      });
      h['Overlay.setShowPaintRects'] = (p) => this.forward('Page.setShowPaintRects', { result: !!p.result });
      h['Overlay.setShowLayoutShiftRegions'] = ok;
      h['Overlay.setShowAdHighlights'] = ok;
      h['Overlay.setShowDebugBorders'] = (p) => this.forward('Page.setCompositingBordersVisible', { visible: !!p.show });
      h['Overlay.setShowFPSCounter'] = ok;
      h['Overlay.setShowHinge'] = ok;
      h['Overlay.setShowWebVitals'] = ok;
      h['Overlay.getHighlightObjectForTest'] = ok;

      h['CSS.getMatchedStylesForNode'] = async (p) => {
        const result = await this.link.send('CSS.getMatchedStylesForNode', { nodeId: p.nodeId, includePseudo: true, includeInherited: true });
        const inline = await this.link.send('CSS.getInlineStylesForNode', { nodeId: p.nodeId }).catch(() => ({}));
        return {
          inlineStyle: inline.inlineStyle ? this.style(inline.inlineStyle) : undefined,
          attributesStyle: inline.attributesStyle ? this.style(inline.attributesStyle) : undefined,
          matchedCSSRules: (result.matchedCSSRules || []).map((m) => this.ruleMatch(m)),
          pseudoElements: (result.pseudoElements || []).map((pe) => ({
            pseudoType: pe.pseudoId,
            matches: (pe.matches || []).map((m) => this.ruleMatch(m)),
          })),
          inherited: (result.inherited || []).map((entry) => ({
            inlineStyle: entry.inlineStyle ? this.style(entry.inlineStyle) : undefined,
            matchedCSSRules: (entry.matchedCSSRules || []).map((m) => this.ruleMatch(m)),
          })),
          inheritedPseudoElements: [],
          cssKeyframesRules: [],
          cssPositionTryRules: [],
          cssPropertyRules: [],
          cssPropertyRegistrations: [],
          cssFontPaletteValuesRule: undefined,
          parentLayoutNodeId: undefined,
          cssFunctionRules: [],
        };
      };
      h['CSS.getInlineStylesForNode'] = async (p) => {
        const result = await this.link.send('CSS.getInlineStylesForNode', { nodeId: p.nodeId });
        return {
          inlineStyle: result.inlineStyle ? this.style(result.inlineStyle) : undefined,
          attributesStyle: result.attributesStyle ? this.style(result.attributesStyle) : undefined,
        };
      };
      h['CSS.getComputedStyleForNode'] = async (p) => {
        const result = await this.link.send('CSS.getComputedStyleForNode', { nodeId: p.nodeId });
        return { computedStyle: (result.computedStyle || []).map((c) => ({ name: c.name, value: c.value })) };
      };
      h['CSS.getPlatformFontsForNode'] = () => ({ fonts: [] });
      h['CSS.getBackgroundColors'] = () => ({ backgroundColors: [] });
      h['CSS.getLayersForNode'] = () => ({ rootLayer: { name: '', subLayers: [], order: 0 } });
      h['CSS.getEnvironmentVariables'] = () => ({ environmentVariables: {} });
      h['CSS.getAnimatedStylesForNode'] = () => ({ animationStyles: [], transitionsStyle: undefined, inherited: [] });
      h['CSS.getStyleSheetText'] = (p) => this.link.send('CSS.getStyleSheetText', { styleSheetId: p.styleSheetId });
      h['CSS.setStyleSheetText'] = async (p) => {
        await this.link.send('CSS.setStyleSheetText', { styleSheetId: p.styleSheetId, text: p.text });
        return {};
      };
      h['CSS.setStyleTexts'] = async (p) => {
        const styles = [];
        for (const edit of p.edits || []) {
          const key = `${edit.styleSheetId}:${edit.range.startLine}:${edit.range.startColumn}`;
          const styleId = this.styles.get(key);
          if (!styleId) throw { message: 'Style not found for the edited range.' };
          const result = await this.link.send('CSS.setStyleText', { styleId, text: edit.text });
          styles.push(this.style(result.style));
        }
        return { styles };
      };
      h['CSS.addRule'] = async (p) => {
        const open = p.ruleText.indexOf('{');
        const selector = (open >= 0 ? p.ruleText.slice(0, open) : p.ruleText).trim();
        const body = open >= 0 ? p.ruleText.slice(open + 1, p.ruleText.lastIndexOf('}')).trim() : '';
        const added = await this.link.send('CSS.addRule', { styleSheetId: p.styleSheetId, selector });
        let rule = added.rule;
        if (body && rule.style && rule.style.styleId) {
          const updated = await this.link.send('CSS.setStyleText', { styleId: rule.style.styleId, text: body });
          rule = Object.assign({}, rule, { style: updated.style });
        }
        return { rule: this.rule(rule) };
      };
      h['CSS.createStyleSheet'] = (p) => this.link.send('CSS.createStyleSheet', { frameId: p.frameId || this.mainFrame });
      h['CSS.forcePseudoState'] = (p) => this.link.send('CSS.forcePseudoState', { nodeId: p.nodeId, forcedPseudoClasses: p.forcedPseudoClasses });
      h['CSS.setEffectivePropertyValueForNode'] = ok;
      h['CSS.takeComputedStyleUpdates'] = () => ({ nodeIds: [] });
      h['CSS.getLonghandProperties'] = () => ({ longhandProperties: [] });
      h['CSS.resolveValues'] = (p) => ({ results: p.values || [] });

      h['Network.getResponseBody'] = (p) => this.link.send('Network.getResponseBody', { requestId: p.requestId });
      h['Network.setExtraHTTPHeaders'] = (p) => this.forward('Network.setExtraHTTPHeaders', { headers: p.headers });
      h['Network.emulateNetworkConditions'] = (p) => this.forward('Network.setEmulatedConditions', {
        bytesPerSecondLimit: p.offline ? 0 : (p.downloadThroughput > 0 ? Math.round(p.downloadThroughput) : undefined),
      });
      h['Network.emulateNetworkConditionsByRule'] = (p) => ({ ruleIds: (p.matchedNetworkConditions || []).map((rule, index) => `singularity-${index}`) });
      h['Network.overrideNetworkState'] = ok;
      h['Network.setUserAgentOverride'] = ok;
      h['Network.getCookies'] = async () => {
        const result = await this.link.send('Page.getCookies', {});
        return {
          cookies: (result.cookies || []).map((c) => ({
            name: c.name, value: c.value, domain: c.domain, path: c.path, expires: c.expires > 0 ? c.expires / 1000 : -1,
            size: c.size, httpOnly: c.httpOnly, secure: c.secure, session: c.session,
            sameSite: c.sameSite === 'None' ? 'None' : c.sameSite, priority: 'Medium', sameParty: false, sourceScheme: 'Secure', sourcePort: 443,
          })),
        };
      };
      h['Network.deleteCookies'] = (p) => this.forward('Page.deleteCookie', { cookieName: p.name, url: p.url || `https://${p.domain}${p.path || '/'}` });
      h['Network.loadNetworkResource'] = () => ({ resource: { success: false, netError: -2, netErrorName: 'net::ERR_FAILED' } });
      h['Network.getRequestPostData'] = () => {
        throw { message: 'No post data available for the request' };
      };
      h['Storage.getCookies'] = () => h['Network.getCookies']();
      h['Storage.getStorageKey'] = async () => {
        const frame = this.frames.get(this.mainFrame);
        return { storageKey: frame ? `${frame.securityOrigin}/` : '' };
      };
      h['Storage.getUsageAndQuota'] = () => ({ usage: 0, quota: 0, overrideActive: false, usageBreakdown: [] });

      h['Debugger.setBreakpointByUrl'] = async (p) => {
        const result = await this.link.send('Debugger.setBreakpointByUrl', {
          lineNumber: p.lineNumber,
          url: p.url,
          urlRegex: p.urlRegex,
          columnNumber: p.columnNumber,
          options: p.condition ? { condition: p.condition } : undefined,
        });
        return { breakpointId: result.breakpointId, locations: result.locations || [] };
      };
      h['Debugger.setBreakpoint'] = async (p) => {
        const result = await this.link.send('Debugger.setBreakpoint', {
          location: p.location,
          options: p.condition ? { condition: p.condition } : undefined,
        });
        return { breakpointId: result.breakpointId, actualLocation: result.actualLocation };
      };
      h['Debugger.getPossibleBreakpoints'] = async (p) => {
        const end = p.end || { scriptId: p.start.scriptId, lineNumber: p.start.lineNumber + 1, columnNumber: 0 };
        const result = await this.forward('Debugger.getBreakpointLocations', { start: p.start, end });
        return { locations: result.locations || [] };
      };
      h['Debugger.setPauseOnExceptions'] = (p) => this.link.send('Debugger.setPauseOnExceptions', {
        state: p.state === 'caught' ? 'all' : p.state,
      });
      h['Debugger.evaluateOnCallFrame'] = async (p) => {
        const result = await this.link.send('Debugger.evaluateOnCallFrame', {
          callFrameId: p.callFrameId,
          expression: p.expression,
          objectGroup: p.objectGroup,
          includeCommandLineAPI: p.includeCommandLineAPI,
          doNotPauseOnExceptionsAndMuteConsole: p.silent,
          returnByValue: p.returnByValue,
          generatePreview: p.generatePreview,
        });
        return this.evaluation(result);
      };
      h['Debugger.getScriptSource'] = (p) => this.link.send('Debugger.getScriptSource', { scriptId: p.scriptId });
      h['Debugger.resume'] = () => this.link.send('Debugger.resume', {});
      h['Debugger.stepOver'] = () => this.link.send('Debugger.stepOver', {});
      h['Debugger.stepInto'] = () => this.link.send('Debugger.stepInto', {});
      h['Debugger.stepOut'] = () => this.link.send('Debugger.stepOut', {});
      h['Debugger.pause'] = () => this.link.send('Debugger.pause', {});
      h['Debugger.continueToLocation'] = (p) => this.link.send('Debugger.continueToLocation', { location: p.location });
      h['Debugger.setBreakpointsActive'] = (p) => this.link.send('Debugger.setBreakpointsActive', { active: p.active });
      h['Debugger.searchInContent'] = (p) => this.link.send('Debugger.searchInContent', {
        scriptId: p.scriptId, query: p.query, caseSensitive: p.caseSensitive, isRegex: p.isRegex,
      });
      h['Debugger.setScriptSource'] = () => {
        throw { message: 'Live edit is not supported.' };
      };
      h['Debugger.restartFrame'] = () => {
        throw { message: 'Restarting frames is not supported.' };
      };
      h['DOMDebugger.getEventListeners'] = async (p) => {
        const nodeId = await this.link.send('DOM.requestNode', { objectId: p.objectId }).then((r) => r.nodeId).catch(() => null);
        if (!nodeId) return { listeners: [] };
        const result = await this.link.send('DOM.getEventListenersForNode', { nodeId });
        return {
          listeners: (result.listeners || []).filter((l) => l.nodeId === nodeId).map((l) => ({
            type: l.type, useCapture: !!l.useCapture, passive: !!l.passive, once: !!l.once,
            scriptId: l.location ? l.location.scriptId : '', lineNumber: l.location ? l.location.lineNumber : 0,
            columnNumber: l.location ? l.location.columnNumber : 0,
          })),
        };
      };

      h['DOMStorage.getDOMStorageItems'] = (p) => this.link.send('DOMStorage.getDOMStorageItems', { storageId: this.storageId(p.storageId) });
      h['DOMStorage.setDOMStorageItem'] = (p) => this.link.send('DOMStorage.setDOMStorageItem', { storageId: this.storageId(p.storageId), key: p.key, value: p.value });
      h['DOMStorage.removeDOMStorageItem'] = (p) => this.link.send('DOMStorage.removeDOMStorageItem', { storageId: this.storageId(p.storageId), key: p.key });
      h['DOMStorage.clear'] = (p) => this.link.send('DOMStorage.clearDOMStorageItems', { storageId: this.storageId(p.storageId) });

      h['Accessibility.getRootAXNode'] = async () => {
        const root = await this.documentNode();
        return { node: await this.axNode(root) };
      };
      h['Accessibility.getFullAXTree'] = async () => {
        const root = await this.axNode(await this.documentNode());
        const children = await Promise.all(root.childIds.map((id) => this.axNode(Number(id))));
        return { nodes: [root, ...children] };
      };
      h['Accessibility.getPartialAXTree'] = async (p) => {
        const nodeId = await this.nodeFor(p);
        const node = await this.axNode(nodeId);
        const nodes = [node];
        if (p.fetchRelatives !== false) {
          nodes.push(...await this.axAncestors(node));
          for (const id of node.childIds) nodes.push(await this.axNode(Number(id)));
        }
        return { nodes };
      };
      h['Accessibility.getAXNodeAndAncestors'] = async (p) => {
        const nodeId = await this.nodeFor(p);
        const node = await this.axNode(nodeId);
        return { nodes: [node, ...await this.axAncestors(node)] };
      };
      h['Accessibility.getChildAXNodes'] = async (p) => {
        const node = await this.axNode(Number(p.id));
        return { nodes: await Promise.all(node.childIds.map((id) => this.axNode(Number(id)))) };
      };
      h['Accessibility.queryAXTree'] = () => ({ nodes: [] });

      h['Browser.getVersion'] = () => ({
        protocolVersion: '1.3', product: 'Singularity Browser', revision: '', userAgent: navigator.userAgent, jsVersion: '',
      });
      h['Schema.getDomains'] = () => ({ domains: [] });
      return h;
    }

    async inspectAt(x, y) {
      if (!this.link || !this.documentReady) {
        this.pendingInspect = { x, y };
        return;
      }
      if (x < 0 || y < 0) {
        window.DevToolsAPI.enterInspectElementMode();
        return;
      }
      try {
        const found = await this.handlers['DOM.getNodeForLocation']({ x, y });
        this.emit('Overlay.inspectNodeRequested', { backendNodeId: found.backendNodeId });
      } catch (e) {
      }
    }

    async documentNode() {
      for (const node of this.nodes.values()) {
        if (node.nodeType === 9) return node.nodeId;
      }
      const result = await this.link.send('DOM.getDocument', {});
      return this.node(result.root).nodeId;
    }

    async axNode(nodeId) {
      let props = {};
      try {
        props = (await this.link.send('DOM.getAccessibilityPropertiesForNode', { nodeId })).properties || {};
      } catch (e) {
      }
      const dom = this.nodes.get(nodeId);
      const isDocument = dom && dom.nodeType === 9;
      const role = isDocument ? 'RootWebArea' : (props.role || (props.ignored ? 'none' : 'generic'));
      const properties = [];
      const add = (name, value, type = 'boolean') => {
        if (value !== undefined && value !== null && value !== '') properties.push({ name, value: { type, value } });
      };
      add('focused', props.focused);
      add('disabled', props.disabled);
      add('expanded', props.expanded);
      add('required', props.required);
      add('readonly', props.readonly);
      add('selected', props.selected);
      add('busy', props.busy);
      add('level', props.headingLevel || props.hierarchyLevel || undefined, 'integer');
      add('checked', props.checked, 'tristate');
      add('pressed', props.pressed, 'tristate');
      add('invalid', props.invalid, 'token');
      add('live', props.liveRegionStatus, 'token');
      return {
        nodeId: String(nodeId),
        ignored: !!props.ignored && !isDocument,
        role: { type: 'role', value: role },
        name: { type: 'computedString', value: props.label || '' },
        properties,
        childIds: (props.childNodeIds || []).map(String),
        parentId: props.parentNodeId ? String(props.parentNodeId) : undefined,
        backendDOMNodeId: nodeId,
        frameId: this.mainFrame,
      };
    }

    async axAncestors(node) {
      const out = [];
      let current = node;
      for (let depth = 0; current.parentId && depth < 64; depth++) {
        current = await this.axNode(Number(current.parentId));
        out.push(current);
      }
      return out;
    }

    storageId(id) {
      if (!id) return id;
      const origin = id.securityOrigin || (id.storageKey ? id.storageKey.replace(/\/$/, '') : '');
      return { securityOrigin: origin, isLocalStorage: id.isLocalStorage };
    }

    highlight(config) {
      if (!config) return { showInfo: true };
      const color = (c) => (c ? { r: c.r, g: c.g, b: c.b, a: c.a === undefined ? 1 : c.a } : undefined);
      return {
        showInfo: config.showInfo !== false,
        contentColor: color(config.contentColor),
        paddingColor: color(config.paddingColor),
        borderColor: color(config.borderColor),
        marginColor: color(config.marginColor),
      };
    }

    evaluation(result) {
      const out = { result: this.remote(result.result) };
      if (result.wasThrown) {
        out.exceptionDetails = {
          exceptionId: 1,
          text: 'Uncaught',
          lineNumber: 0,
          columnNumber: 0,
          exception: out.result,
        };
      }
      return out;
    }

    buildEvents() {
      const e = {};
      e['DOM.setChildNodes'] = (p) => {
        (p.nodes || []).forEach((n) => this.node(n));
        return ['DOM.setChildNodes', p];
      };
      e['DOM.childNodeInserted'] = (p) => {
        this.node(p.node);
        return ['DOM.childNodeInserted', p];
      };
      e['DOM.shadowRootPushed'] = (p) => {
        this.node(p.root);
        return ['DOM.shadowRootPushed', p];
      };
      e['DOM.pseudoElementAdded'] = (p) => {
        this.node(p.pseudoElement);
        return ['DOM.pseudoElementAdded', p];
      };
      e['DOM.didAddEventListener'] = null;
      e['DOM.willRemoveEventListener'] = null;
      e['DOM.willDestroyDOMNode'] = null;
      e['DOM.powerEfficientPlaybackStateChanged'] = null;

      e['Runtime.executionContextCreated'] = (p) => ['Runtime.executionContextCreated', { context: this.context(p.context) }];

      e['Console.messageAdded'] = (p) => {
        const m = p.message;
        const timestamp = (m.timestamp ? m.timestamp * 1000 : Date.now());
        if (m.source === 'console-api') {
          let type = CONSOLE_TYPES[m.type] || 'log';
          if (type === 'log' && (m.level === 'warning' || m.level === 'error' || m.level === 'debug' || m.level === 'info')) {
            type = m.level === 'warning' ? 'warning' : m.level;
          }
          const args = m.parameters ? m.parameters.map((a) => this.remote(a)) : [{ type: 'string', value: m.text }];
          return ['Runtime.consoleAPICalled', {
            type,
            args,
            executionContextId: this.defaultContext() || 1,
            timestamp,
            stackTrace: this.stack(m.stackTrace),
          }];
        }
        if (m.source === 'javascript' && m.level === 'error') {
          return ['Runtime.exceptionThrown', {
            timestamp,
            exceptionDetails: {
              exceptionId: Math.floor(Math.random() * 1e9),
              text: m.text,
              lineNumber: Math.max(0, (m.line || 1) - 1),
              columnNumber: Math.max(0, (m.column || 1) - 1),
              url: m.url,
              stackTrace: this.stack(m.stackTrace),
              exception: m.parameters && m.parameters[0] ? this.remote(m.parameters[0]) : undefined,
              executionContextId: this.defaultContext(),
            },
          }];
        }
        const sources = { xml: 'xml', javascript: 'javascript', network: 'network', 'console-api': 'console-api', storage: 'storage', rendering: 'rendering', security: 'security', 'content-blocker': 'other', media: 'other', mediasource: 'other', webrtc: 'other', itp: 'other', 'private-click-measurement': 'other', 'payment-request': 'other', other: 'other' };
        return ['Log.entryAdded', {
          entry: {
            source: sources[m.source] || 'other',
            level: CONSOLE_LEVELS[m.level] === 'warning' ? 'warning' : (m.level === 'error' ? 'error' : (m.level === 'debug' ? 'verbose' : 'info')),
            text: m.text,
            url: m.url,
            lineNumber: m.line ? m.line - 1 : undefined,
            timestamp,
            networkRequestId: m.networkRequestId,
            stackTrace: this.stack(m.stackTrace),
          },
        }];
      };
      e['Console.messageRepeatCountUpdated'] = null;
      e['Console.messagesCleared'] = () => ['Runtime.executionContextsCleared', {}];
      e['Console.heapSnapshot'] = null;

      e['Page.frameNavigated'] = (p) => ['Page.frameNavigated', { frame: this.frame(p.frame), type: 'Navigation' }];
      e['Page.frameDetached'] = (p) => ['Page.frameDetached', { frameId: p.frameId, reason: 'remove' }];
      e['Page.loadEventFired'] = (p) => ['Page.loadEventFired', { timestamp: p.timestamp }];
      e['Page.domContentEventFired'] = (p) => ['Page.domContentEventFired', { timestamp: p.timestamp }];
      e['Page.defaultUserPreferencesDidChange'] = null;

      e['Network.requestWillBeSent'] = (p) => ['Network.requestWillBeSent', {
        requestId: p.requestId,
        loaderId: p.loaderId,
        documentURL: p.documentURL,
        request: this.request(p.request),
        timestamp: p.timestamp,
        wallTime: p.walltime,
        initiator: p.initiator ? {
          type: p.initiator.type === 'parser' ? 'parser' : (p.initiator.type === 'script' ? 'script' : 'other'),
          url: p.initiator.url,
          lineNumber: p.initiator.lineNumber,
          stack: p.initiator.stackTrace ? this.stack(p.initiator.stackTrace) : undefined,
        } : { type: 'other' },
        redirectHasExtraInfo: false,
        redirectResponse: p.redirectResponse ? this.response(p.redirectResponse, p.timestamp) : undefined,
        type: RESOURCE_TYPES[p.type] || 'Other',
        frameId: p.frameId,
        hasUserGesture: false,
      }];
      e['Network.responseReceived'] = (p) => ['Network.responseReceived', {
        requestId: p.requestId,
        loaderId: p.loaderId,
        timestamp: p.timestamp,
        type: RESOURCE_TYPES[p.type] || 'Other',
        response: this.response(p.response, p.timestamp),
        hasExtraInfo: false,
        frameId: p.frameId,
      }];
      e['Network.dataReceived'] = (p) => ['Network.dataReceived', {
        requestId: p.requestId, timestamp: p.timestamp, dataLength: p.dataLength, encodedDataLength: p.encodedDataLength || 0,
      }];
      e['Network.loadingFinished'] = (p) => ['Network.loadingFinished', {
        requestId: p.requestId,
        timestamp: p.timestamp,
        encodedDataLength: p.metrics && p.metrics.responseBodyBytesReceived !== undefined
          ? p.metrics.responseBodyBytesReceived + (p.metrics.responseHeaderBytesReceived || 0) : 0,
      }];
      e['Network.loadingFailed'] = (p) => ['Network.loadingFailed', {
        requestId: p.requestId, timestamp: p.timestamp, type: 'Other', errorText: p.errorText, canceled: !!p.canceled,
      }];
      e['Network.requestServedFromMemoryCache'] = (p) => ['Network.requestServedFromCache', { requestId: p.requestId }];
      e['Network.webSocketCreated'] = (p) => ['Network.webSocketCreated', { requestId: p.requestId, url: p.url }];
      e['Network.webSocketFrameReceived'] = (p) => ['Network.webSocketFrameReceived', p];
      e['Network.webSocketFrameSent'] = (p) => ['Network.webSocketFrameSent', p];
      e['Network.webSocketClosed'] = (p) => ['Network.webSocketClosed', p];

      e['Debugger.scriptParsed'] = (p) => {
        const url = p.sourceURL || p.url || '';
        this.scripts.set(p.scriptId, { url });
        return ['Debugger.scriptParsed', {
          scriptId: p.scriptId,
          url,
          startLine: p.startLine,
          startColumn: p.startColumn,
          endLine: p.endLine,
          endColumn: p.endColumn,
          executionContextId: this.defaultContext() || 1,
          hash: '',
          isModule: !!p.module,
          sourceMapURL: p.sourceMapURL,
          hasSourceURL: !!p.sourceURL,
          isLiveEdit: false,
          length: 0,
          scriptLanguage: 'JavaScript',
          embedderName: url,
        }];
      };
      e['Debugger.scriptFailedToParse'] = (p) => ['Debugger.scriptFailedToParse', {
        scriptId: p.scriptId || 'failed', url: p.url, startLine: p.startLine, startColumn: p.startColumn, endLine: p.startLine,
        endColumn: p.startColumn, executionContextId: this.defaultContext() || 1, hash: '',
      }];
      e['Debugger.paused'] = (p) => {
        const reasons = { exception: 'exception', assert: 'assert', CSPViolation: 'CSPViolation', DOM: 'DOM', EventListener: 'EventListener', Breakpoint: 'other', PauseOnNextStatement: 'other', XHR: 'XHR', other: 'other' };
        return ['Debugger.paused', {
          callFrames: (p.callFrames || []).map((f) => this.callFrame(f)),
          reason: reasons[p.reason] || 'other',
          data: p.data,
          hitBreakpoints: p.data && p.data.breakpointId ? [p.data.breakpointId] : [],
        }];
      };
      e['Debugger.resumed'] = () => ['Debugger.resumed', {}];
      e['Debugger.breakpointResolved'] = (p) => ['Debugger.breakpointResolved', p];
      e['Debugger.globalObjectCleared'] = () => ['Runtime.executionContextsCleared', {}];
      e['Debugger.didSampleProbe'] = null;
      e['Debugger.playBreakpointActionSound'] = null;

      e['CSS.styleSheetAdded'] = (p) => ['CSS.styleSheetAdded', { header: this.sheetHeader(p.header) }];
      e['CSS.styleSheetRemoved'] = (p) => ['CSS.styleSheetRemoved', p];
      e['CSS.styleSheetChanged'] = (p) => ['CSS.styleSheetChanged', p];
      e['CSS.mediaQueryResultChanged'] = () => ['CSS.mediaQueryResultChanged', {}];
      e['CSS.nodeLayoutFlagsChanged'] = null;

      e['Inspector.inspect'] = (p) => {
        if (!p.object || !p.object.objectId) return null;
        this.link.send('DOM.requestNode', { objectId: p.object.objectId }).then((node) => {
          this.emit('Overlay.inspectNodeRequested', { backendNodeId: node.nodeId });
        }).catch(() => {});
        return null;
      };
      e['Inspector.evaluateForTestInFrontend'] = null;
      e['Inspector.activateExtraDomains'] = null;

      e['DOMStorage.domStorageItemAdded'] = (p) => ['DOMStorage.domStorageItemAdded', p];
      e['DOMStorage.domStorageItemRemoved'] = (p) => ['DOMStorage.domStorageItemRemoved', p];
      e['DOMStorage.domStorageItemUpdated'] = (p) => ['DOMStorage.domStorageItemUpdated', p];
      e['DOMStorage.domStorageItemsCleared'] = (p) => ['DOMStorage.domStorageItemsCleared', p];

      e['Timeline.eventRecorded'] = null;
      e['Heap.garbageCollected'] = null;
      e['Animation.animationCreated'] = null;
      e['Animation.trackingUpdate'] = null;
      e['Animation.nameChanged'] = null;
      e['Animation.effectChanged'] = null;
      e['Animation.targetChanged'] = null;
      e['Animation.animationDestroyed'] = null;
      e['Canvas.canvasAdded'] = null;
      e['Canvas.canvasRemoved'] = null;
      e['LayerTree.layerTreeDidChange'] = () => ['LayerTree.layerTreeDidChange', {}];
      return e;
    }
  }

  window.SingularityCDP = new Translator();
})();
