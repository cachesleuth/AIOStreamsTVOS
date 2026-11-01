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
  var errorLog = [];
  function logError(text) {
    errorLog.push(String(text).slice(0, 1500));
    if (errorLog.length > 15) errorLog.shift();
  }
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
  function isField(el) {
    return !!el && !!el.matches && el.matches(TEXT_FIELD) && !el.disabled;
  }
  window.__aiostreamsEditField = function () {
    var el = document.activeElement;
    if (!isField(el)) return '';
    if (el.readOnly) {
      // The web app's Android TV mode keeps a focused field read-only until
      // Select, which it reads as Enter (src/lib/tv.ts). Enter releases it.
      el.dispatchEvent(new KeyboardEvent('keydown', {
        key: 'Enter', code: 'Enter', bubbles: true, cancelable: true
      }));
      el = document.activeElement;
      // Still read-only: a field nothing may be typed into.
      if (!isField(el) || el.readOnly) return '';
    }
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

  // The web app lays a TV's page out at a fixed width (1280) for the web view
  // to scale up to the screen. This one is told the scale outright.
  function fitViewport(meta) {
    if (!meta || (meta.getAttribute('name') || '').toLowerCase() !== 'viewport') return;
    var content = meta.getAttribute('content') || '';
    var width = /(?:^|[,\s])width=(\d+)/.exec(content);
    if (!width || /initial-scale/.test(content)) return;
    var scale = Math.round(((window.screen && screen.width) || 1920) / Number(width[1]) * 1000) / 1000;
    meta.setAttribute('content', content + ', initial-scale=' + scale +
      ', minimum-scale=' + scale + ', maximum-scale=' + scale + ', user-scalable=no');
  }

  // The page rings what has focus with :focus-visible, which WebKit only
  // applies after a real key press, and the remote's keys come from script.
  // With no pointer here, any focus is a remote's, so it reads as :focus.
  // Not an escaped `\:focus-visible`, which is part of a class name such as Tailwind's.
  var FOCUS_VISIBLE = /(^|[^\\]):focus-visible/g;
  function plainFocus(selector) {
    return typeof selector === 'string' && selector.indexOf(':focus-visible') >= 0
      ? selector.replace(FOCUS_VISIBLE, '$1:focus') : selector;
  }
  ['matches', 'webkitMatchesSelector', 'closest', 'querySelector', 'querySelectorAll'].forEach(function (name) {
    [Element.prototype, Document.prototype, DocumentFragment.prototype].forEach(function (proto) {
      var own = Object.prototype.hasOwnProperty.call(proto, name) && proto[name];
      if (typeof own !== 'function') return;
      proto[name] = function (selector) {
        return own.apply(this, [plainFocus(selector)].concat([].slice.call(arguments, 1)));
      };
    });
  });
  function plainFocusRules(rules) {
    if (!rules) return;
    for (var i = 0; i < rules.length; i++) {
      var rule = rules[i];
      if (rule.selectorText && rule.selectorText.indexOf(':focus-visible') >= 0) {
        try { rule.selectorText = plainFocus(rule.selectorText); } catch (e) {}
      }
      if (rule.cssRules) plainFocusRules(rule.cssRules);
    }
  }
  var sheetsTimer = 0;
  function plainFocusSheets() {
    clearTimeout(sheetsTimer);
    sheetsTimer = setTimeout(function () {
      for (var i = 0; i < document.styleSheets.length; i++) {
        try { plainFocusRules(document.styleSheets[i].cssRules); } catch (e) {}
      }
    }, 0);
  }

  new MutationObserver(function (changes) {
    var sheets = false;
    for (var i = 0; i < changes.length; i++) {
      var change = changes[i];
      if (change.type === 'attributes') {
        if (change.target.tagName === 'META') fitViewport(change.target);
        continue;
      }
      for (var j = 0; j < change.addedNodes.length; j++) {
        var node = change.addedNodes[j];
        if (node.tagName === 'META') fitViewport(node);
        else if (node.tagName === 'STYLE' || node.tagName === 'LINK') sheets = true;
      }
    }
    if (sheets) plainFocusSheets();
  }).observe(document.documentElement, {
    subtree: true, childList: true, attributes: true, attributeFilter: ['content']
  });
  // A stylesheet's rules are readable once it loads.
  document.addEventListener('load', function (e) {
    if (e.target && e.target.tagName === 'LINK') plainFocusSheets();
  }, true);
  document.addEventListener('DOMContentLoaded', plainFocusSheets);
  window.addEventListener('load', plainFocusSheets);

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

  // A TV has no console, so what goes wrong is kept for the app's own error screen.
  function reportError(text) {
    logError(text);
    post({ type: 'web-error', message: text });
  }
  window.addEventListener('error', function (e) {
    var el = e.target;
    if (el && (el.tagName === 'SCRIPT' || el.tagName === 'LINK')) {
      reportError('Could not load ' + (el.src || el.href));
    } else if (e.message) {
      reportError(String(e.message) + (e.filename ? '\n  at ' + e.filename + ':' + e.lineno + ':' + e.colno : '') +
        (e.error && e.error.stack ? '\n' + e.error.stack : ''));
    }
  }, true);
  window.addEventListener('unhandledrejection', function (e) {
    var reason = e.reason;
    reportError('Unhandled rejection: ' + String((reason && (reason.stack || reason.message)) || reason));
  });
  var consoleError = console.error;
  console.error = function () {
    try {
      logError([].map.call(arguments, function (a) {
        return a && a.stack ? a.stack : typeof a === 'object' ? JSON.stringify(a) : String(a);
      }).join(' '));
    } catch (e) {}
    return consoleError.apply(console, arguments);
  };
  // Read by the app directly, so it works even when the bridge never connected.
  window.__aiostreamsStatus = function () {
    var root = document.getElementById('root');
    return JSON.stringify({
      href: location.href,
      readyState: document.readyState,
      rendered: !!root && root.childNodes.length > 0,
      bridge: !!window.__aiostreamsPost,
      storageKeys: (function () { try { return localStorage.length; } catch (e) { return -1; } })(),
      errors: errorLog
    });
  };

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
