namespace Singularity.Apps.Browser {

    public enum ExtensionContext {
        CONTENT,
        PAGE,
        BACKGROUND
    }

    namespace ExtensionScript {

        public string handler_for (string id) {
            return "sinty_" + id;
        }

        public string world_for (string id) {
            return "sinty-extension-" + id;
        }

        public string source (Extension extension, ExtensionContext context, string messages_json) {
            var generator = new Json.Generator ();
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (extension.manifest);
            generator.set_root (node);
            string manifest_json = generator.to_data (null);
            string kind = context == ExtensionContext.CONTENT ? "content" : (context == ExtensionContext.BACKGROUND ? "background" : "page");
            return SHIM.replace ("@HANDLER@", handler_for (extension.id))
                .replace ("@ID@", extension.id)
                .replace ("@KIND@", kind)
                .replace ("@MANIFEST@", manifest_json)
                .replace ("@MESSAGES@", messages_json);
        }

        private const string SHIM = """(() => {
if (globalThis.__sintyExtension) return;
const handler = window.webkit.messageHandlers["@HANDLER@"];
const id = "@ID@";
const kind = "@KIND@";
const manifest = @MANIFEST@;
const messages = @MESSAGES@;
let lastError;
const runtime = {};
const raw = (op, args) => handler.postMessage(JSON.stringify({ op, args: args === undefined ? null : args }))
    .then(reply => reply === null || reply === undefined || reply === "" ? undefined : JSON.parse(reply));
const call = (op, args, callback) => {
    const promise = raw(op, args);
    if (typeof callback !== "function") return promise;
    promise.then(value => { callback(value); }, error => {
        lastError = { message: String(error && error.message || error) };
        try { callback(); } finally { lastError = undefined; }
    });
};
const event = () => {
    const set = new Set();
    return {
        set,
        addListener: f => set.add(f),
        removeListener: f => set.delete(f),
        hasListener: f => set.has(f),
        hasListeners: () => set.size > 0
    };
};
const tail = args => typeof args[args.length - 1] === "function" ? args.pop() : undefined;
const onMessage = event(), onMessageExternal = event(), onInstalled = event(), onStartup = event();
const onChanged = event(), onAlarm = event(), onClicked = event(), onConnect = event();
const onUpdated = event(), onActivated = event(), onRemoved = event(), onCreated = event();
const onCommand = event(), onMenuClicked = event();
const area = name => ({
    get: (keys, callback) => {
        if (typeof keys === "function") { callback = keys; keys = null; }
        return call("storage.get", { area: name, keys: keys === undefined ? null : keys }, callback);
    },
    set: (items, callback) => call("storage.set", { area: name, items }, callback),
    remove: (keys, callback) => call("storage.remove", { area: name, keys }, callback),
    clear: callback => call("storage.clear", { area: name }, callback),
    getBytesInUse: (keys, callback) => call("storage.bytes", { area: name, keys: keys === undefined ? null : keys }, typeof keys === "function" ? keys : callback),
    setAccessLevel: () => Promise.resolve(),
    QUOTA_BYTES: 10485760,
    onChanged: event()
});
const substitute = (text, subs) => {
    if (subs === undefined || subs === null) subs = [];
    if (!Array.isArray(subs)) subs = [subs];
    return text.replace(/\$(\d)/g, (m, n) => subs[Number(n) - 1] === undefined ? "" : String(subs[Number(n) - 1]));
};
Object.assign(runtime, {
    id,
    getManifest: () => JSON.parse(JSON.stringify(manifest)),
    getURL: path => "chrome-extension://" + id + "/" + String(path).replace(/^\/+/, ""),
    sendMessage: (...args) => {
        const callback = tail(args);
        if (args.length > 1 && typeof args[0] === "string" && args[0] !== id) args.shift();
        return call("runtime.sendMessage", { message: args[0] === undefined ? null : args[0] }, callback);
    },
    connect: () => { throw new Error("runtime.connect is not supported yet"); },
    openOptionsPage: callback => call("runtime.openOptionsPage", null, callback),
    getPlatformInfo: callback => { const info = { os: "linux", arch: "x86-64", nacl_arch: "x86-64" }; if (callback) callback(info); return Promise.resolve(info); },
    setUninstallURL: (url, callback) => { if (callback) callback(); return Promise.resolve(); },
    reload: () => call("runtime.reload"),
    getContexts: () => Promise.resolve([]),
    onMessage, onMessageExternal, onInstalled, onStartup, onConnect,
    onSuspend: event(), onUpdateAvailable: event(), onConnectExternal: event()
});
Object.defineProperty(runtime, "lastError", { get: () => lastError });
const chrome = {
    runtime,
    storage: { local: area("local"), sync: area("sync"), session: area("session"), managed: area("managed"), onChanged },
    i18n: {
        getMessage: (name, subs) => {
            const entry = messages[String(name).toLowerCase()];
            if (name === "@@extension_id") return id;
            if (name === "@@ui_locale") return navigator.language.replace("-", "_");
            if (name === "@@bidi_dir") return "ltr";
            return entry ? substitute(entry, subs) : "";
        },
        getUILanguage: () => navigator.language,
        getAcceptLanguages: callback => { const l = [...navigator.languages]; if (callback) callback(l); return Promise.resolve(l); },
        detectLanguage: (text, callback) => { const r = { isReliable: false, languages: [] }; if (callback) callback(r); return Promise.resolve(r); }
    },
    extension: {
        getURL: path => runtime.getURL(path),
        inIncognitoContext: false,
        isAllowedIncognitoAccess: callback => { if (callback) callback(false); return Promise.resolve(false); }
    }
};
if (kind !== "content") {
    Object.assign(chrome, {
        tabs: {
            query: (info, callback) => call("tabs.query", info || {}, callback),
            get: (tabId, callback) => call("tabs.get", { tabId }, callback),
            getCurrent: callback => call("tabs.current", null, callback),
            create: (props, callback) => call("tabs.create", props || {}, callback),
            update: (...args) => { const callback = tail(args); const tabId = typeof args[0] === "number" ? args.shift() : null; return call("tabs.update", { tabId, props: args[0] || {} }, callback); },
            remove: (tabIds, callback) => call("tabs.remove", { tabIds: Array.isArray(tabIds) ? tabIds : [tabIds] }, callback),
            reload: (...args) => { const callback = tail(args); return call("tabs.reload", { tabId: typeof args[0] === "number" ? args[0] : null }, callback); },
            sendMessage: (tabId, message, ...rest) => call("tabs.sendMessage", { tabId, message }, tail(rest)),
            onUpdated, onActivated, onRemoved, onCreated, onReplaced: event(), onHighlighted: event(), onMoved: event(),
            TAB_ID_NONE: -1
        },
        windows: {
            getCurrent: (...args) => { const r = { id: 1, focused: true, type: "normal", state: "normal", incognito: false }; const callback = tail(args); if (callback) callback(r); return Promise.resolve(r); },
            getLastFocused: (...args) => chrome.windows.getCurrent(...args),
            getAll: (...args) => { const callback = tail(args); const r = [{ id: 1, focused: true, type: "normal", state: "normal", incognito: false }]; if (callback) callback(r); return Promise.resolve(r); },
            create: (data, callback) => call("tabs.create", { url: data && (Array.isArray(data.url) ? data.url[0] : data.url) }, callback),
            WINDOW_ID_CURRENT: -2, WINDOW_ID_NONE: -1,
            onFocusChanged: event(), onCreated: event(), onRemoved: event()
        },
        scripting: {
            executeScript: (details, callback) => call("scripting.executeScript", {
                tabId: details.target && details.target.tabId, files: details.files || null,
                func: details.func ? details.func.toString() : null, args: details.args || []
            }, callback),
            insertCSS: (details, callback) => call("scripting.insertCSS", { tabId: details.target && details.target.tabId, files: details.files || null, css: details.css || null }, callback),
            removeCSS: (details, callback) => { if (callback) callback(); return Promise.resolve(); },
            registerContentScripts: (scripts, callback) => { if (callback) callback(); return Promise.resolve(); },
            getRegisteredContentScripts: (filter, callback) => { if (typeof filter === "function") callback = filter; if (callback) callback([]); return Promise.resolve([]); },
            unregisterContentScripts: (filter, callback) => { if (typeof filter === "function") callback = filter; if (callback) callback(); return Promise.resolve(); }
        },
        alarms: {
            create: (...args) => { const info = args.pop() || {}; const name = typeof args[0] === "string" ? args[0] : ""; return call("alarms.create", { name, info }); },
            get: (...args) => { const callback = tail(args); return call("alarms.get", { name: typeof args[0] === "string" ? args[0] : "" }, callback); },
            getAll: callback => call("alarms.getAll", null, callback),
            clear: (...args) => { const callback = tail(args); return call("alarms.clear", { name: typeof args[0] === "string" ? args[0] : "" }, callback); },
            clearAll: callback => call("alarms.clearAll", null, callback),
            onAlarm
        },
        action: {
            setBadgeText: (details, callback) => call("action.setBadgeText", details || {}, callback),
            getBadgeText: (details, callback) => call("action.getBadgeText", details || {}, callback),
            setBadgeBackgroundColor: (details, callback) => { if (callback) callback(); return Promise.resolve(); },
            setBadgeTextColor: (details, callback) => { if (callback) callback(); return Promise.resolve(); },
            setTitle: (details, callback) => call("action.setTitle", details || {}, callback),
            getTitle: (details, callback) => call("action.getTitle", details || {}, callback),
            setIcon: (details, callback) => { if (callback) callback(); return Promise.resolve(); },
            setPopup: (details, callback) => call("action.setPopup", details || {}, callback),
            getPopup: (details, callback) => call("action.getPopup", details || {}, callback),
            enable: (...args) => Promise.resolve(), disable: (...args) => Promise.resolve(),
            openPopup: () => call("action.openPopup"),
            onClicked
        },
        contextMenus: {
            create: (props, callback) => { call("contextMenus.create", props || {}).then(() => callback && callback()); return props && props.id; },
            update: (menuId, props, callback) => call("contextMenus.update", { menuId, props }, callback),
            remove: (menuId, callback) => call("contextMenus.remove", { menuId }, callback),
            removeAll: callback => call("contextMenus.removeAll", null, callback),
            onClicked: onMenuClicked
        },
        notifications: {
            create: (...args) => { const callback = tail(args); const options = args.pop() || {}; const nid = typeof args[0] === "string" ? args[0] : ""; return call("notifications.create", { id: nid, options }, callback); },
            clear: (nid, callback) => call("notifications.clear", { id: nid }, callback),
            onClicked: event(), onClosed: event(), onButtonClicked: event()
        },
        commands: { getAll: callback => { if (callback) callback([]); return Promise.resolve([]); }, onCommand },
        permissions: {
            contains: (p, callback) => call("permissions.contains", p || {}, callback),
            getAll: callback => call("permissions.getAll", null, callback),
            request: (p, callback) => call("permissions.contains", p || {}, callback),
            remove: (p, callback) => { if (callback) callback(false); return Promise.resolve(false); },
            onAdded: event(), onRemoved: event()
        },
        declarativeNetRequest: {
            getEnabledRulesets: callback => call("dnr.enabled", null, callback),
            updateEnabledRulesets: (options, callback) => call("dnr.updateRulesets", options || {}, callback),
            getDynamicRules: (...args) => { const callback = tail(args); return call("dnr.dynamic", null, callback); },
            updateDynamicRules: (options, callback) => call("dnr.updateDynamic", options || {}, callback),
            getSessionRules: (...args) => { const callback = tail(args); if (callback) callback([]); return Promise.resolve([]); },
            updateSessionRules: (options, callback) => { if (callback) callback(); return Promise.resolve(); },
            isRegexSupported: (r, callback) => { const v = { isSupported: true }; if (callback) callback(v); return Promise.resolve(v); },
            getAvailableStaticRuleCount: callback => { if (callback) callback(300000); return Promise.resolve(300000); },
            setExtensionActionOptions: () => Promise.resolve(),
            MAX_NUMBER_OF_REGEX_RULES: 1000, MAX_NUMBER_OF_DYNAMIC_RULES: 30000, MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
            onRuleMatchedDebug: event()
        },
        offscreen: {
            createDocument: (params, callback) => call("offscreen.create", params || {}, callback),
            closeDocument: callback => call("offscreen.close", null, callback),
            hasDocument: callback => call("offscreen.has", null, callback),
            Reason: { DOM_PARSER: "DOM_PARSER", CLIPBOARD: "CLIPBOARD", BLOBS: "BLOBS" }
        },
        sidePanel: { setOptions: () => Promise.resolve(), setPanelBehavior: () => Promise.resolve(), open: () => Promise.resolve() },
        webNavigation: { onCommitted: event(), onCompleted: event(), onBeforeNavigate: event(), onDOMContentLoaded: event(), onHistoryStateUpdated: event(), getFrame: () => Promise.resolve(null), getAllFrames: () => Promise.resolve([]) },
        idle: { queryState: (s, callback) => { if (callback) callback("active"); return Promise.resolve("active"); }, setDetectionInterval: () => {}, onStateChanged: event() }
    });
}
globalThis.__sintyExtension = {
    dispatch(type, payload, sender) {
        const data = payload ? JSON.parse(payload) : null;
        const from = sender ? JSON.parse(sender) : {};
        if (type === "message") {
            return new Promise(resolve => {
                let pending = false, done = false;
                const respond = value => { if (!done) { done = true; resolve(value === undefined ? null : JSON.stringify(value)); } };
                for (const listener of [...onMessage.set]) {
                    let result;
                    try { result = listener(data, from, respond); } catch (e) { console.error(e); }
                    if (result === true) pending = true;
                    else if (result && typeof result.then === "function") { pending = true; result.then(respond, () => respond(undefined)); }
                }
                if (!pending) respond(undefined);
            });
        }
        const fire = (target, ...values) => { for (const listener of [...target.set]) { try { listener(...values); } catch (e) { console.error(e); } } return null; };
        if (type === "storage") { fire(onChanged, data.changes, data.area); return fire(chrome.storage[data.area].onChanged, data.changes); }
        if (type === "installed") return fire(onInstalled, data);
        if (type === "startup") return fire(onStartup);
        if (type === "alarm") return fire(onAlarm, data);
        if (type === "action") return fire(onClicked, data);
        if (type === "menu") return fire(onMenuClicked, data.info, data.tab);
        if (type === "tabUpdated") return fire(onUpdated, data.tabId, data.changes, data.tab);
        if (type === "tabActivated") return fire(onActivated, data);
        if (type === "tabRemoved") return fire(onRemoved, data.tabId, { windowId: 1, isWindowClosing: false });
        if (type === "tabCreated") return fire(onCreated, data);
        return null;
    }
};
globalThis.chrome = chrome;
if (manifest.manifest_version === 2 && kind !== "content") globalThis.browser = chrome;
})();
""";
    }
}
