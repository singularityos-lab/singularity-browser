namespace Singularity.Apps.Browser {

    public class HeldCodeInfo : Object {
        public uint id;
        public string code;
        public string service;
        public string domain;
        public string app;
    }

    public class OneTimeCodeClient : Object {
        public const string WORLD = "singularity-one-time-code";
        public const string HANDLER = "singularityOneTimeCode";
        private const string NAME = "dev.sinty.OneTimeCodes";
        private const string PATH = "/dev/sinty/OneTimeCodes";
        private const string IFACE = "dev.sinty.OneTimeCodes1";

        private static OneTimeCodeClient? instance;
        private DBusConnection? bus;

        public static OneTimeCodeClient get_default () {
            if (instance == null) instance = new OneTimeCodeClient ();
            return instance;
        }

        private OneTimeCodeClient () {
            try {
                bus = Bus.get_sync (BusType.SESSION);
            } catch (Error e) {
                bus = null;
            }
        }

        public async HeldCodeInfo? latest () {
            if (bus == null) return null;
            try {
                var reply = yield bus.call (NAME, PATH, IFACE, "Latest", null, new VariantType ("(bussssx)"),
                    DBusCallFlags.NO_AUTO_START, 1000, null);
                bool found;
                uint id;
                string code, service, domain, app;
                int64 expires;
                reply.get ("(bussssx)", out found, out id, out code, out service, out domain, out app, out expires);
                if (!found || expires <= get_real_time () / 1000000) return null;
                var info = new HeldCodeInfo ();
                info.id = id;
                info.code = code;
                info.service = service;
                info.domain = domain;
                info.app = app;
                return info;
            } catch (Error e) {
                return null;
            }
        }

        public void notify_call (string method, Variant? args) {
            if (bus == null) return;
            bus.call.begin (NAME, PATH, IFACE, method, args, null, DBusCallFlags.NO_AUTO_START, 1000, null);
        }

        public static bool domain_fits (string host, string domain) {
            return domain == "" || Singularity.OneTimeCodes.domain_matches (host, domain);
        }

        public static string script () {
            return """(() => {
  if (window.__singularityCodes) return;
  window.__singularityCodes = true;
  const handler = window.webkit.messageHandlers.""" + HANDLER + """;
  const named = /(one.?time|otp|totp|2fa|mfa|verif|security.?code|sms.?code|auth.?code|passcode|pin.?code|codice|codigo|código|bestätigung|tan\b)/i;
  const usable = (i) => !i.matches(':disabled') && !i.readOnly &&
    i.getBoundingClientRect().width > 0 && getComputedStyle(i).visibility === 'visible';
  const boxes = (el) => {
    let scope = el.parentElement;
    for (let depth = 0; scope && depth < 4; depth++, scope = scope.parentElement) {
      const list = Array.from(scope.querySelectorAll('input')).filter((i) => i.maxLength === 1 && usable(i));
      if (list.length >= 4 && list.includes(el)) return list;
    }
    return null;
  };
  const isCode = (el) => {
    if (!(el instanceof HTMLInputElement) || !usable(el)) return false;
    const type = (el.type || 'text').toLowerCase();
    if (!['text', 'tel', 'number', 'password', ''].includes(type)) return false;
    if (el.maxLength === 1) {
      const group = boxes(el);
      return !!group && group.every((i) => i.value === '');
    }
    if (el.value !== '') return false;
    if ((el.autocomplete || '').toLowerCase().includes('one-time-code')) return true;
    const label = [el.name, el.id, el.placeholder, el.getAttribute('aria-label') || ''].join(' ');
    return named.test(label);
  };
  const set = (el, v) => {
    const desc = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value');
    if (desc && desc.set) desc.set.call(el, v); else el.value = v;
    el.dispatchEvent(new InputEvent('input', { bubbles: true, data: v, inputType: 'insertText' }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  };
  let filling = false;
  const fill = (el, code) => {
    filling = true;
    try { place(el, code); } finally { filling = false; }
  };
  const place = (el, code) => {
    const group = el.maxLength === 1 ? boxes(el) : null;
    if (group && group.length >= code.length) {
      let start = group.indexOf(el);
      if (group.length - start < code.length) start = 0;
      for (let i = 0; i < code.length; i++) {
        group[start + i].focus();
        set(group[start + i], code[i]);
      }
      return;
    }
    el.focus();
    set(el, code);
  };
  let asking = null;
  const ask = (el) => {
    if (asking === el) return;
    asking = el;
    const r = el.getBoundingClientRect();
    handler.postMessage({ host: location.hostname, top: window.top === window,
      x: r.left, y: r.top, width: r.width, height: r.height }).then((code) => {
      asking = null;
      if (typeof code === 'string' && code !== '' && document.contains(el)) fill(el, code);
    }, () => { asking = null; });
  };
  document.addEventListener('focusin', (e) => { if (!filling && isCode(e.target)) ask(e.target); }, true);
  const focused = document.activeElement;
  if (focused && isCode(focused)) ask(focused);
})();""";
        }
    }
}
