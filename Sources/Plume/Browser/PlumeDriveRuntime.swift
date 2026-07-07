import Foundation

extension PlumeBrowserRuntime {
    /// The Hotwire-equivalent "drive" layer appended to the static runtime:
    /// stream-envelope `apply`, programmatic `visit`, lazy frames that scope
    /// navigation to themselves, progressive form interception (with a no-JS full
    /// submit fallback), and an idiomorph-style in-place DOM morph that preserves
    /// focus, selection, and scroll.
    ///
    /// Written as plain ES5-style JavaScript (no arrow functions, to match the
    /// compiled runtime and keep broad browser support). Plume defines and drives
    /// the DOM; it knows nothing of the transport — `visit`/forms/frames just
    /// `fetch` a URL and apply whatever envelope or HTML comes back, and `apply`
    /// accepts an envelope from ANY source via the public `Plume.apply` API.
    static let driveRuntime: String = #"""
    (function () {
      "use strict";
      if (typeof window === "undefined") return;
      var Plume = window.Plume || {};
      window.Plume = Plume;

      function isEnvelope(text) {
        return typeof text === "string" && text.indexOf("<plume-stream") !== -1;
      }

      function sameOrigin(url) {
        try {
          var a = document.createElement("a");
          a.href = url;
          return a.origin === window.location.origin || a.host === window.location.host;
        } catch (e) { return true; }
      }

      // --- focus / selection / scroll preservation ---------------------------
      function captureFocus() {
        var el = document.activeElement;
        if (!el || el === document.body || !el.id) return null;
        var record = { id: el.id, start: null, end: null, scrollTop: el.scrollTop, scrollLeft: el.scrollLeft };
        try { record.start = el.selectionStart; record.end = el.selectionEnd; } catch (e) {}
        return record;
      }
      function restoreFocus(record) {
        if (!record) return;
        var el = document.getElementById(record.id);
        if (!el) return;
        if (document.activeElement !== el && typeof el.focus === "function") el.focus();
        if (record.start !== null && typeof el.setSelectionRange === "function") {
          try { el.setSelectionRange(record.start, record.end); } catch (e) {}
        }
        if (typeof record.scrollTop === "number") { el.scrollTop = record.scrollTop; el.scrollLeft = record.scrollLeft; }
      }

      // --- morph (idiomorph-lite) --------------------------------------------
      function morph(target, incoming) {
        var focus = captureFocus();
        morphNode(target, incoming);
        restoreFocus(focus);
        return target;
      }

      function morphNode(a, b) {
        if (a.nodeType !== b.nodeType || a.nodeName !== b.nodeName) {
          a.replaceWith(b);
          return b;
        }
        if (a.nodeType === 3 || a.nodeType === 8) {
          if (a.nodeValue !== b.nodeValue) a.nodeValue = b.nodeValue;
          return a;
        }
        if (a.nodeType === 1) {
          syncAttributes(a, b);
          morphChildren(a, b);
        }
        return a;
      }

      function syncAttributes(a, b) {
        var keepLiveValue = a === document.activeElement && ("value" in a);
        var i, attrs = a.attributes;
        for (i = attrs.length - 1; i >= 0; i--) {
          var name = attrs[i].name;
          if (!b.hasAttribute(name)) a.removeAttribute(name);
        }
        var battrs = b.attributes;
        for (i = 0; i < battrs.length; i++) {
          var n = battrs[i].name, v = battrs[i].value;
          if (keepLiveValue && n === "value") continue;
          if (a.getAttribute(n) !== v) a.setAttribute(n, v);
        }
      }

      function findChildById(parent, id) {
        var child = parent.firstChild;
        while (child) {
          if (child.nodeType === 1 && child.id === id) return child;
          child = child.nextSibling;
        }
        return null;
      }

      function morphChildren(parent, incoming) {
        var oldChild = parent.firstChild;
        var newChild = incoming.firstChild;
        while (newChild) {
          var nextNew = newChild.nextSibling;
          if (!oldChild) {
            parent.appendChild(newChild);
            newChild = nextNew;
            continue;
          }
          if (newChild.nodeType === 1 && newChild.id) {
            var keyed = findChildById(parent, newChild.id);
            if (keyed) {
              if (keyed !== oldChild) parent.insertBefore(keyed, oldChild);
              morphNode(keyed, newChild);
              oldChild = keyed.nextSibling;
              newChild = nextNew;
              continue;
            }
          }
          if (oldChild.nodeType === newChild.nodeType && oldChild.nodeName === newChild.nodeName
              && !(newChild.nodeType === 1 && newChild.id)) {
            var nextOld = oldChild.nextSibling;
            morphNode(oldChild, newChild);
            oldChild = nextOld;
          } else {
            parent.insertBefore(newChild, oldChild);
          }
          newChild = nextNew;
        }
        while (oldChild) {
          var remove = oldChild;
          oldChild = oldChild.nextSibling;
          parent.removeChild(remove);
        }
      }

      // --- stream envelope apply ---------------------------------------------
      function parseEnvelope(envelope) {
        var container;
        if (typeof envelope === "string") {
          container = document.createElement("div");
          container.innerHTML = envelope;
        } else if (envelope && envelope.querySelectorAll) {
          container = envelope;
        } else {
          return [];
        }
        var streams = container.querySelectorAll("plume-stream");
        var ops = [];
        for (var i = 0; i < streams.length; i++) {
          var node = streams[i];
          var template = node.querySelector("template");
          ops.push({
            action: node.getAttribute("action"),
            target: node.getAttribute("target"),
            template: template
          });
        }
        return ops;
      }

      function fragmentFor(op) {
        if (!op.template) return null;
        return op.template.content.cloneNode(true);
      }

      function applyOperation(op) {
        var target = op.target ? document.getElementById(op.target) : null;
        if (!target) return;
        var fragment;
        switch (op.action) {
          case "append": fragment = fragmentFor(op); if (fragment) target.appendChild(fragment); break;
          case "prepend": fragment = fragmentFor(op); if (fragment) target.insertBefore(fragment, target.firstChild); break;
          case "update": fragment = fragmentFor(op); target.textContent = ""; if (fragment) target.appendChild(fragment); break;
          case "replace": fragment = fragmentFor(op); if (fragment) target.replaceWith(fragment); break;
          case "remove": target.remove(); break;
          case "before": fragment = fragmentFor(op); if (fragment && target.parentNode) target.parentNode.insertBefore(fragment, target); break;
          case "after": fragment = fragmentFor(op); if (fragment && target.parentNode) target.parentNode.insertBefore(fragment, target.nextSibling); break;
          case "morph":
            fragment = fragmentFor(op);
            var incoming = fragment ? fragment.firstElementChild : null;
            if (incoming) morph(target, incoming);
            break;
        }
      }

      Plume.apply = function (envelope) {
        var ops = parseEnvelope(envelope);
        for (var i = 0; i < ops.length; i++) applyOperation(ops[i]);
        return ops.length;
      };

      Plume.morph = function (target, incoming) {
        if (typeof incoming === "string") {
          var holder = document.createElement("div");
          holder.innerHTML = incoming;
          incoming = holder.firstElementChild;
        }
        if (incoming) morph(target, incoming);
        return target;
      };

      // --- regions: a frame swaps its own content ----------------------------
      function swapRegion(region, body) {
        if (isEnvelope(body)) { Plume.apply(body); return; }
        region.innerHTML = body;
        loadFrames(region);
      }

      function fetchInto(region, url, init) {
        if (typeof window.fetch !== "function") { window.location.href = url; return; }
        return window.fetch(url, init).then(function (response) {
          return response.text().then(function (body) { swapRegion(region, body); });
        });
      }

      function loadFrames(root) {
        var frames = (root || document).querySelectorAll("plume-frame[src]");
        for (var i = 0; i < frames.length; i++) {
          var frame = frames[i];
          if (frame.getAttribute("data-plume-loaded") === "true") continue;
          if (frame.getAttribute("loading") === "lazy" && typeof IntersectionObserver === "function") {
            observeLazyFrame(frame);
          } else {
            loadFrame(frame);
          }
        }
      }

      function loadFrame(frame) {
        var src = frame.getAttribute("src");
        if (!src) return;
        frame.setAttribute("data-plume-loaded", "true");
        fetchInto(frame, src, { headers: { "X-Plume-Frame": frame.id || "" } });
      }

      function observeLazyFrame(frame) {
        var observer = new IntersectionObserver(function (entries) {
          for (var i = 0; i < entries.length; i++) {
            if (entries[i].isIntersecting) { observer.disconnect(); loadFrame(frame); }
          }
        });
        observer.observe(frame);
      }

      // --- full-page swap ------------------------------------------------------
      // A top-level visit or form submission that returned a full HTML document.
      // Never dump the raw response into the body (that hoists <head> content —
      // meta/title/config scripts — into the body and breaks layout). Delegate to
      // the binding core's navigation swap (title/head/state sync, config
      // re-read, hooks, history) when present; otherwise parse the document and
      // swap only its body. `url` is the response's final URL (fetch follows
      // redirects), so the address bar ends up on the redirect target.
      function swapFullPage(body, url) {
        var resolved = null;
        try { resolved = new URL(url, window.location.href); } catch (e) { resolved = null; }
        var href = resolved ? resolved.href : window.location.href;
        if (typeof DOMParser !== "function") { window.location.href = href; return; }
        var nextDocument = new DOMParser().parseFromString(body, "text/html");
        var core = window.Plume ? window.Plume.swapDocument : null;
        if (typeof core === "function" && resolved) {
          core(resolved, nextDocument, { history: href !== window.location.href });
          return;
        }
        if (!nextDocument.body || !document.body) { window.location.href = href; return; }
        var changed = href !== window.location.href;
        document.title = nextDocument.title;
        document.body.replaceWith(document.importNode(nextDocument.body, true));
        if (changed && window.history && typeof window.history.pushState === "function") {
          window.history.pushState({}, "", href);
        }
        loadFrames(document);
      }

      // The binding core swaps pages without knowing about <plume-frame>; load
      // any frames the incoming page brought along after every completed swap
      // (link visits, popstate, and the delegated full-page swaps above).
      document.addEventListener("plume:navigate:after-swap", function () { loadFrames(document); });

      // --- navigation scoped to a frame --------------------------------------
      function enclosingFrame(node) {
        return node && node.closest ? node.closest("plume-frame[id]") : null;
      }

      document.addEventListener("click", function (event) {
        if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
        var link = event.target && event.target.closest ? event.target.closest("a[href]") : null;
        if (!link) return;
        var frame = enclosingFrame(link);
        if (!frame) return; // outside a frame: leave to declarative navigation
        if (link.getAttribute("data-plume-navigation") === "false") return;
        if (!sameOrigin(link.href)) return;
        event.preventDefault();
        event.stopPropagation();
        fetchInto(frame, link.href, { headers: { "X-Plume-Frame": frame.id || "" } });
      }, true);

      // --- navigation progress bar -------------------------------------------
      // A Turbo-style top-of-viewport bar shown when a visit or intercepted form
      // submission outlasts a delay threshold. Enabled by default; configured by
      // the @navigation directive (progressBar / progressBarDelay) through the
      // same data-plume-navigation JSON the binding core reads. Styling is
      // injected here (namespaced), and the color is overridable from app CSS
      // via the --plume-progress-color custom property.
      var progressState = { active: 0, element: null, delayTimer: null, trickleTimer: null, value: 0 };

      function progressConfig() {
        var config = { enabled: true, delay: 500 };
        var scripts = document.querySelectorAll("script[data-plume-navigation]");
        for (var i = 0; i < scripts.length; i++) {
          var parsed = null;
          try { parsed = JSON.parse(scripts[i].textContent || "[]"); } catch (e) { parsed = null; }
          if (!parsed) continue;
          var list = Array.isArray(parsed) ? parsed : [parsed];
          for (var j = 0; j < list.length; j++) {
            var entry = list[j];
            if (!entry || typeof entry !== "object") continue;
            if (typeof entry.progressBar === "boolean") config.enabled = entry.progressBar;
            var delay = Number(entry.progressBarDelay);
            if (entry.progressBarDelay !== undefined && !isNaN(delay) && delay >= 0) config.delay = delay;
          }
        }
        return config;
      }

      function ensureProgressStyle() {
        if (document.getElementById("plume-progress-bar-style")) return;
        var style = document.createElement("style");
        style.id = "plume-progress-bar-style";
        style.textContent = ".plume-progress-bar{position:fixed;top:0;left:0;height:3px;width:0;" +
          "background:var(--plume-progress-color,#0076ff);z-index:2147483647;" +
          "transition:width 300ms ease-out,opacity 200ms ease-in;pointer-events:none;}";
        (document.head || document.documentElement).appendChild(style);
      }

      function trickleProgress() {
        var bar = progressState.element;
        if (!bar) return;
        progressState.value = Math.min(progressState.value + (90 - progressState.value) / 10 + 1, 90);
        bar.style.width = progressState.value + "%";
      }

      function showProgressBar() {
        if (progressState.element) return;
        ensureProgressStyle();
        var bar = document.createElement("div");
        bar.className = "plume-progress-bar";
        bar.style.width = "0%";
        bar.style.opacity = "1";
        // Attached to <html>, not <body>, so a top-level body swap mid-visit
        // cannot remove the bar out from under the runtime.
        document.documentElement.appendChild(bar);
        progressState.element = bar;
        progressState.value = 0;
        trickleProgress();
        progressState.trickleTimer = setInterval(trickleProgress, 300);
      }

      function startProgress() {
        var config = progressConfig();
        if (!config.enabled) return;
        progressState.active += 1;
        if (progressState.active > 1) return;
        progressState.delayTimer = setTimeout(function () {
          progressState.delayTimer = null;
          if (progressState.active > 0) showProgressBar();
        }, config.delay);
      }

      function finishProgress() {
        if (progressState.active === 0) return;
        progressState.active -= 1;
        if (progressState.active > 0) return;
        if (progressState.delayTimer) { clearTimeout(progressState.delayTimer); progressState.delayTimer = null; }
        if (progressState.trickleTimer) { clearInterval(progressState.trickleTimer); progressState.trickleTimer = null; }
        var bar = progressState.element;
        progressState.element = null;
        if (!bar) return;
        // Complete, then fade, then remove — success and failure look the same.
        bar.style.width = "100%";
        setTimeout(function () {
          bar.style.opacity = "0";
          setTimeout(function () { if (bar.parentNode) bar.parentNode.removeChild(bar); }, 250);
        }, 250);
      }

      Plume.progress = { start: startProgress, finish: finishProgress };

      // --- progressive form interception -------------------------------------
      document.addEventListener("submit", function (event) {
        var form = event.target;
        if (!form || form.tagName !== "FORM") return;
        if (form.getAttribute("data-plume-navigation") === "false") return;
        var action = form.getAttribute("action") || window.location.href;
        if (!sameOrigin(action)) return;
        if (typeof window.fetch !== "function") return; // no-JS / no-fetch: normal submit
        event.preventDefault();
        submitForm(form, action);
      }, false);

      function submitForm(form, action) {
        var method = (form.getAttribute("method") || "get").toUpperCase();
        var data = new FormData(form);
        var frame = enclosingFrame(form);
        var region = frame || document.documentElement;
        var init = { method: method, headers: { "X-Plume-Navigation": "true" } };
        if (method === "GET") {
          var params = new URLSearchParams(data);
          var query = params.toString();
          action = action + (action.indexOf("?") === -1 ? "?" : "&") + query;
        } else if ((form.getAttribute("enctype") || "").toLowerCase() === "multipart/form-data") {
          init.body = data; // file uploads: let the browser pick the boundary
        } else {
          // Native submission semantics: the default enctype is urlencoded.
          init.body = new URLSearchParams(data);
        }
        if (typeof window.fetch !== "function") { form.submit(); return; }
        startProgress();
        window.fetch(action, init).then(function (response) {
          return response.text().then(function (body) {
            finishProgress();
            if (isEnvelope(body)) { Plume.apply(body); }
            else if (frame) { swapRegion(frame, body); }
            // Top-level submit that returned a full HTML page: swap the document
            // like a navigation. fetch followed any redirect, so response.url is
            // the final URL (e.g. the 303 target after a create).
            else { swapFullPage(body, response.url || action); }
          });
        }).then(null, function (error) {
          finishProgress();
          throw error;
        });
      }

      // --- programmatic visit ------------------------------------------------
      Plume.visit = function (url, options) {
        options = options || {};
        if (typeof window.fetch !== "function") { window.location.href = url; return; }
        var init = { headers: { "X-Plume-Navigation": "true", "Accept": "text/html" } };
        if (options.method) init.method = options.method;
        if (options.body !== undefined) init.body = options.body;
        startProgress();
        return window.fetch(url, init).then(function (response) {
          return response.text().then(function (body) {
            finishProgress();
            if (isEnvelope(body)) { Plume.apply(body); }
            else { swapFullPage(body, response.url || url); }
            return body;
          });
        }).then(null, function (error) {
          finishProgress();
          throw error;
        });
      };

      // --- boot ---------------------------------------------------------------
      function boot() { loadFrames(document); }
      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", boot);
      } else {
        boot();
      }
    })();
    """#
}
