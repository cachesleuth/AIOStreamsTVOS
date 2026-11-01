import Foundation

/**
 * The script `index.html` runs first. It gives the page `window.aiostreamsApp`
 * as the Android app does (protocol 2), so the unmodified web app drives this
 * app's mpv, and adds the hooks the native side calls: keys, text entry and
 * localStorage mirroring.
 *
 * Page to app: `window.__aiostreamsPost(text)`, which the app puts into the
 * page's JavaScript context (see JSContextHook). Messages wait in a queue until
 * it exists. App to page: `window.__aiostreamsReceive(message)`.
 */
enum BridgeScript {
    struct Identity: Encodable {
        let version: String
        let device: String
        let deviceId: String
    }

    static func make(identity: Identity, storage: [String: String]) -> String {
        let encoder = JSONEncoder()
        let identityJSON = (try? encoder.encode(identity)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let storageJSON = (try? encoder.encode(storage)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return template
            .replacingOccurrences(of: "__IDENTITY__", with: identityJSON)
            .replacingOccurrences(of: "__STORAGE__", with: storageJSON)
    }

    private static let template = #"""
(function () {
  if (window.top !== window || window.aiostreamsApp) return;
  var identity = __IDENTITY__;
  var saved = __STORAGE__;
  var listeners = [];
  var queue = [];

  function post(message) {
    var text = JSON.stringify(message);
    if (window.__aiostreamsPost) window.__aiostreamsPost(text);
    else queue.push(text);
  }
  window.__aiostreamsFlush = function () {
    while (queue.length && window.__aiostreamsPost) window.__aiostreamsPost(queue.shift());
  };
  window.__aiostreamsReceive = function (message) {
    var all = listeners.slice();
    for (var i = 0; i < all.length; i++) {
      try { all[i](message); } catch (error) { console.error(error); }
    }
  };

  // The remote's presses, as keys on whatever has focus. The page's own
  // spatial navigation moves focus; it reads `key`, since `keyCode` can't be set.
  window.__aiostreamsKey = function (type, key, repeat) {
    var target = document.activeElement || document.body;
    target.dispatchEvent(new KeyboardEvent(type, {
      key: key, code: key, repeat: !!repeat, bubbles: true, cancelable: true
    }));
  };

  // Text entry through the system keyboard, which has dictation.
  var TEXT_FIELD = 'input:not([type=button]):not([type=checkbox]):not([type=color]):not([type=file])' +
    ':not([type=image]):not([type=radio]):not([type=range]):not([type=reset]):not([type=submit]),' +
    ' textarea, [contenteditable=""], [contenteditable=true]';
  function editing() { return document.querySelector('[data-tvos-editing]'); }
  window.__aiostreamsEditField = function () {
    var el = document.activeElement;
    if (!el || !el.matches || !el.matches(TEXT_FIELD) || el.disabled || el.readOnly) return '';
    var old = editing();
    if (old) old.removeAttribute('data-tvos-editing');
    el.setAttribute('data-tvos-editing', '');
    return JSON.stringify({
      value: el.isContentEditable ? el.textContent : el.value,
      type: (el.getAttribute('type') || 'text').toLowerCase(),
      placeholder: el.getAttribute('placeholder') || el.getAttribute('aria-label') || '',
      enterKeyHint: el.getAttribute('enterkeyhint') || '',
      inputMode: el.getAttribute('inputmode') || ''
    });
  };
  window.__aiostreamsSetText = function (value) {
    var el = editing();
    if (!el) return;
    if (el.isContentEditable) {
      el.textContent = value;
    } else {
      // React tracks a field's value through the prototype's setter.
      var proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
    }
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  };
  window.__aiostreamsSubmitText = function () {
    var el = editing();
    if (!el) return;
    var enter = new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', bubbles: true, cancelable: true });
    el.dispatchEvent(enter);
    if (!enter.defaultPrevented && el.form) {
      if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit();
    }
  };
  window.__aiostreamsEndEdit = function () {
    var el = editing();
    if (el) el.removeAttribute('data-tvos-editing');
  };

  // tvOS may clear a web view's storage with the caches, so the app keeps a
  // copy of localStorage and puts back what is missing before the page starts.
  try {
    for (var key in saved) {
      if (Object.prototype.hasOwnProperty.call(saved, key) && localStorage.getItem(key) === null)
        localStorage.setItem(key, saved[key]);
    }
  } catch (e) {}
  var storageTimer = 0;
  function sendStorage() {
    clearTimeout(storageTimer);
    storageTimer = 0;
    try {
      var items = {};
      for (var i = 0; i < localStorage.length; i++) {
        var k = localStorage.key(i);
        items[k] = localStorage.getItem(k);
      }
      post({ type: 'tvos-storage', items: items });
    } catch (e) {}
  }
  window.__aiostreamsFlushStorage = function () { if (storageTimer) sendStorage(); };
  try {
    var proto = Storage.prototype;
    var setItem = proto.setItem, removeItem = proto.removeItem, clear = proto.clear;
    var changed = function (storage) {
      if (storage !== window.localStorage) return;
      clearTimeout(storageTimer);
      storageTimer = setTimeout(sendStorage, 500);
    };
    proto.setItem = function () { var r = setItem.apply(this, arguments); changed(this); return r; };
    proto.removeItem = function () { var r = removeItem.apply(this, arguments); changed(this); return r; };
    proto.clear = function () { var r = clear.apply(this, arguments); changed(this); return r; };
  } catch (e) {}

  window.addEventListener('error', function (e) {
    post({ type: 'web-error', message: String(e.message) + ' ' + (e.filename || '') + ':' + (e.lineno || 0) });
  });
  window.addEventListener('unhandledrejection', function (e) {
    var reason = e.reason;
    post({ type: 'web-error', message: String((reason && (reason.stack || reason.message)) || reason) });
  });

  // The Android app's bridge, as the web app reads it: `tv` gets the TV layout.
  window.aiostreamsApp = Object.freeze({
    protocol: 2,
    version: identity.version,
    platform: 'android',
    tv: true,
    voice: false,
    gamepads: false,
    pip: false,
    device: identity.device,
    deviceId: identity.deviceId,
    send: post,
    subscribe: function (listener) {
      listeners.push(listener);
      return function () {
        var at = listeners.indexOf(listener);
        if (at >= 0) listeners.splice(at, 1);
      };
    }
  });
})();
"""#
}
