import Foundation

/**
 * The script WebKit runs at document start, in the main frame, before the
 * page's own. It gives the page `window.aiostreamsApp`, the bridge AIOStreams'
 * Android app gives it (protocol 2), so the unmodified web app lays itself
 * out for a TV and plays through this app's mpv. Follows bridge.js of the
 * working aiostreams-tvos project.
 *
 * Page to app: `webkit.messageHandlers.aiostreamsNative.postMessage(json)`.
 * App to page: `__aioReceive(message)`. The remote: `__aioTV.down/up/type`.
 */
enum BridgeScript {
    /// `storage` is the app's copy of localStorage by origin, as JSON.
    static func make(version: String, device: String, deviceId: String, storage: String) -> String {
        template
            .replacingOccurrences(of: "__VERSION__", with: literal(version))
            .replacingOccurrences(of: "__DEVICE__", with: literal(device))
            .replacingOccurrences(of: "__DEVICE_ID__", with: literal(deviceId))
            .replacingOccurrences(of: "__STORAGE__", with: storage)
    }

    private static func literal(_ text: String) -> String {
        JSON.string([text]).map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    private static let template = #"""
(() => {
  if (window.top !== window || window.aiostreamsApp) return;
  const handler = window.webkit?.messageHandlers?.aiostreamsNative;
  if (!handler) return;

  /*
   * Artwork otherwise goes through workers that shrink it on OffscreenCanvas
   * and hand back blob URLs, which tvOS's WebKit shows as broken images.
   * Without OffscreenCanvas the page loads each picture as a plain <img>.
   */
  try {
    delete window.OffscreenCanvas;
  } catch {}
  /*
   * The page asks for artwork at devicePixelRatio times its size, and tvOS
   * reports 2 on a 4K TV, so each backdrop comes as a 3840-wide picture,
   * 33 MB once decoded. A page of rows and backdrops then runs WebKit's
   * process out of memory while browsing. At 1 it takes the 1080p sizes, a
   * quarter of the memory; tvOS's own apps draw artwork at that size too.
   */
  try {
    Object.defineProperty(window, 'devicePixelRatio', { get: () => 1, configurable: true });
  } catch {}
  // The page's saved copies of artwork come back as blob URLs too.
  try {
    localStorage.setItem('aiostreams-web-cache-artwork', 'false');
  } catch {}

  const listeners = new Set();
  const send = (message) => handler.postMessage(JSON.stringify(message));

  /*
   * tvOS can drop a web view's stored data between launches, and with it the
   * page's sign-in. The app keeps a copy of localStorage (by origin), puts
   * back what is missing as the page starts, and hears of every change.
   */
  try {
    const saved = __STORAGE__?.[location.origin];
    if (saved && typeof saved === 'object') {
      for (const [key, value] of Object.entries(saved)) {
        if (typeof value === 'string' && localStorage.getItem(key) === null)
          localStorage.setItem(key, value);
      }
    }
  } catch {}
  try {
    const proto = Storage.prototype;
    const { setItem, removeItem, clear } = proto;
    const local = (store) => {
      try {
        return store === window.localStorage;
      } catch {
        return false;
      }
    };
    const origin = location.origin;
    proto.setItem = function (key, value) {
      setItem.call(this, key, value);
      if (local(this))
        send({ type: 'tvos-storage', origin, key: String(key), value: String(value) });
    };
    proto.removeItem = function (key) {
      removeItem.call(this, key);
      if (local(this)) send({ type: 'tvos-storage', origin, key: String(key), value: null });
    };
    proto.clear = function () {
      clear.call(this);
      if (local(this)) send({ type: 'tvos-storage', origin, clear: true });
    };
  } catch {}

  // The app calls this with each message for the page.
  Object.defineProperty(window, '__aioReceive', {
    value(message) {
      for (const listener of listeners) {
        try {
          listener(message);
        } catch (error) {
          console.error(error);
        }
      }
    },
  });

  window.aiostreamsApp = Object.freeze({
    protocol: 2,
    version: __VERSION__,
    // The page treats the Android app on a TV as a TV; tvOS gets the same.
    platform: 'android',
    tv: true,
    voice: false,
    gamepads: false,
    pip: false,
    device: __DEVICE__,
    deviceId: __DEVICE_ID__,
    send,
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  });

  /*
   * The Siri Remote, as the keys the page's own remote handling reads. Back
   * goes through the bridge instead, as on Android.
   */
  const NOT_TEXT = new Set([
    'button', 'checkbox', 'radio', 'range', 'submit', 'reset',
    'color', 'file', 'image', 'hidden',
  ]);
  const isTextField = (el) =>
    !!el &&
    (el.tagName === 'TEXTAREA' ||
      (el.tagName === 'INPUT' && !NOT_TEXT.has((el.type || 'text').toLowerCase())));
  const target = () => document.activeElement || document.body;
  // React tracks the value it last set, so set it as the browser would.
  const setValue = (el, value) => {
    const proto =
      el.tagName === 'TEXTAREA'
        ? HTMLTextAreaElement.prototype
        : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
    el.dispatchEvent(new Event('input', { bubbles: true }));
  };
  let editing = null;
  let swallowed = false;

  const key = (type, name, repeat) =>
    target().dispatchEvent(
      new KeyboardEvent(type, {
        key: name,
        code: name,
        repeat: !!repeat,
        bubbles: true,
        cancelable: true,
      })
    );

  Object.defineProperty(window, '__aioTV', {
    value: Object.freeze({
      down(name, repeat) {
        const el = target();
        // tvOS has no keyboard for a web page, so the app shows its own.
        if (name === 'Enter' && isTextField(el)) {
          if (repeat) return;
          editing = el;
          swallowed = true;
          send({
            type: 'tvos-keyboard',
            value: el.value || '',
            label:
              el.getAttribute('aria-label') ||
              el.placeholder ||
              el.labels?.[0]?.textContent?.trim() ||
              '',
            secure: el.type === 'password',
            email: el.type === 'email',
            numeric:
              el.inputMode === 'numeric' ||
              el.inputMode === 'decimal' ||
              el.type === 'number' ||
              el.type === 'tel',
            url: el.type === 'url' || el.inputMode === 'url',
          });
          return;
        }
        key('keydown', name, repeat);
      },
      up(name) {
        if (name === 'Enter' && swallowed) {
          swallowed = false;
          return;
        }
        key('keyup', name);
      },
      /** Each change on the app's search keyboard, into the field it was opened for. */
      input(value) {
        const el = editing;
        if (el && el.isConnected) setValue(el, value);
      },
      /** The app's keyboard closed; with `submit`, the field's form is sent. */
      done(submit) {
        const el = editing;
        editing = null;
        // The Enter that opened the keyboard was let go over it, out of the page's sight.
        swallowed = false;
        if (!el || !el.isConnected) return;
        el.dispatchEvent(new Event('change', { bubbles: true }));
        el.focus();
        // After React has taken the new value.
        const form = el.form;
        if (submit && form)
          setTimeout(() => {
            if (form.requestSubmit) form.requestSubmit();
            else form.submit();
          }, 250);
      },
      /** The text typed on the app's alert keyboard, all at once. */
      type(value, submit) {
        const el = editing;
        if (el && el.isConnected) setValue(el, value);
        this.done(submit);
      },
    }),
  });

  // A TV has no console; the app keeps these in its start-up log.
  window.addEventListener('error', (e) =>
    send({
      type: 'web-error',
      message: String(e.message || e.error) + (e.filename ? ` (${e.filename}:${e.lineno})` : ''),
    })
  );
  window.addEventListener('unhandledrejection', (e) =>
    send({ type: 'web-error', message: 'Unhandled rejection: ' + String(e.reason?.stack || e.reason) })
  );

  send({ type: 'hello' });
})();
"""#
}
