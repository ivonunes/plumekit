function bootPlumeRuntime() {
  // A page can need the runtime without declaring any @state — @navigation alone
  // is enough — so a missing state hook boots with empty state instead of
  // returning early (which would silently disable declarative navigation).
  let stateScript = document.querySelector("script[data-plume-state]");
  let state = JSON.parse(stateScript?.textContent || "{}");

  let truthy = function(value) {
    if (value === null || value === undefined) return false;
    if (typeof value === "boolean") return value;
    if (typeof value === "number") return value !== 0;
    if (typeof value === "string") return value.length > 0 && value !== "false";
    if (Array.isArray(value)) return value.length > 0;
    return true;
  };

  let valueFor = function(path, event) {
    path = path.trim();
    if (path === "true") return true;
    if (path === "false") return false;
    if (path === "nil" || path === "null") return null;
    if (path === "event.value") return event?.target?.value ?? "";
    if (path.startsWith("event.")) {
      return path.split(".").slice(1).reduce(function(value, key) { return value?.[key]; }, event);
    }
    if (path.startsWith("[") && path.endsWith("]")) {
      return splitArguments(path.slice(1, -1)).map(function(argument) { return evaluate(argument, event); });
    }
    if (/^-?\d+(\.\d+)?$/.test(path)) return Number(path);
    if ((path.startsWith("\"") && path.endsWith("\"")) || (path.startsWith("'") && path.endsWith("'"))) return path.slice(1, -1);
    if (path.startsWith("!")) return !truthy(evaluate(path.slice(1), event));
    if (path.includes(" ? ") && path.includes(" : ")) {
      let question = path.indexOf(" ? ");
      let colon = path.indexOf(" : ", question);
      return truthy(evaluate(path.slice(0, question), event)) ? evaluate(path.slice(question + 3, colon), event) : evaluate(path.slice(colon + 3), event);
    }
    for (let op of ["==", "!=", ">=", "<=", ">", "<"]) {
      let index = path.indexOf(op);
      if (index > -1) {
        let left = evaluate(path.slice(0, index), event);
        let right = evaluate(path.slice(index + op.length), event);
        if (op === "==") return String(left) === String(right);
        if (op === "!=") return String(left) !== String(right);
        if (op === ">=") return Number(left) >= Number(right);
        if (op === "<=") return Number(left) <= Number(right);
        if (op === ">") return Number(left) > Number(right);
        if (op === "<") return Number(left) < Number(right);
      }
    }
    return path.split(".").reduce(function(value, key) { return value?.[key]; }, state);
  };

  let evaluate = function(expression, event) { return valueFor(expression, event); };

  let text = function(value) { return value === null || value === undefined ? "" : String(value); };

  let renderTemplate = function(template, event) {
    return text(template).replace(/\{([^{}]+)\}/g, function(_, expression) { return text(evaluate(expression, event)); });
  };

  let actionArguments = function(expression, name) {
    let prefix = `page.${name}(`;
    if (!expression.startsWith(prefix) || !expression.endsWith(")")) return null;
    return expression.slice(prefix.length, -1);
  };

  let splitArguments = function(argumentsText) {
    let values = [];
    let current = "";
    let quote = null;
    let depth = 0;
    for (let index = 0; index < argumentsText.length; index += 1) {
      let character = argumentsText[index];
      if (quote) {
        current += character;
        if (character === "\\") {
          index += 1;
          if (index < argumentsText.length) current += argumentsText[index];
          continue;
        }
        if (character === quote) quote = null;
        continue;
      }
      if (character === "\"" || character === "'") {
        quote = character;
        current += character;
        continue;
      }
      if (character === "(" || character === "[") {
        depth += 1;
        current += character;
        continue;
      }
      if (character === ")" || character === "]") {
        depth = Math.max(0, depth - 1);
        current += character;
        continue;
      }
      if (character === "," && depth === 0) {
        if (current.trim()) values.push(current.trim());
        current = "";
        continue;
      }
      current += character;
    }
    if (current.trim()) values.push(current.trim());
    return values;
  };

  let parsedArguments = function(argumentsText, event) {
    let output = { positional: [], named: {} };
    splitArguments(argumentsText).forEach(function(argument) {
      let match = argument.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+)$/);
      if (match) {
        output.named[match[1]] = evaluate(match[2], event);
      } else {
        output.positional.push(evaluate(argument, event));
      }
    });
    return output;
  };

  let firstArgument = function(args, ...names) {
    if (args.positional.length) return args.positional[0];
    for (let name of names) {
      if (args.named[name] !== undefined) return args.named[name];
    }
    return null;
  };

  let scrollBehavior = function(argumentsText, event) {
    let args = parsedArguments(argumentsText, event);
    let behavior = args.named.behavior;
    if (behavior) return text(behavior);
    return truthy(args.named.smooth) ? "smooth" : "auto";
  };

  let targetElement = function(selector) {
    if (!selector) return document.documentElement;
    if (selector instanceof Element) return selector;
    try {
      return document.querySelector(text(selector));
    } catch {
      return null;
    }
  };

  let classNames = function(value) { return text(value).split(/\s+/).filter(Boolean); };

  let applyClassAction = function(expression, name, event) {
    let argumentsText = actionArguments(expression, name);
    if (argumentsText === null) return false;
    let args = parsedArguments(argumentsText, event);
    let element = targetElement(args.named.target);
    let names = classNames(firstArgument(args, "name", "class"));
    if (!element || !names.length) return true;
    if (name === "addClass") element.classList.add(...names);
    if (name === "removeClass") element.classList.remove(...names);
    if (name === "toggleClass") {
      let force = args.named.force;
      names.forEach(function(className) {
        if (force === undefined) element.classList.toggle(className);
        else element.classList.toggle(className, truthy(force));
      });
    }
    return true;
  };

  let valuesList = function(value) {
    if (Array.isArray(value)) return value.map(text).filter(Boolean);
    return text(value).split(/[\s,]+/).filter(Boolean);
  };

  let measurementValues = function(element) {
    let rect = element.getBoundingClientRect();
    let x = rect.left + window.scrollX;
    let y = rect.top + window.scrollY;
    return {
      x,
      y,
      left: x,
      top: y,
      width: rect.width,
      height: rect.height,
      right: rect.right + window.scrollX,
      bottom: rect.bottom + window.scrollY,
      viewportX: rect.left,
      viewportY: rect.top,
      viewportLeft: rect.left,
      viewportTop: rect.top,
      centerX: x + rect.width / 2,
      centerY: y + rect.height / 2
    };
  };

  let defaultMeasureProperties = function(count) {
    if (count === 1) return ["x"];
    if (count === 2) return ["x", "width"];
    if (count === 3) return ["x", "y", "width"];
    return ["x", "y", "width", "height"];
  };

  let applyMeasureAction = function(expression, event) {
    let argumentsText = actionArguments(expression, "measure");
    if (argumentsText === null) return false;
    let args = parsedArguments(argumentsText, event);
    let target = args.named.target ?? args.named.selector ?? args.positional[0];
    let element = targetElement(target);
    let names = valuesList(args.named.into);
    if (!element || !names.length) return true;
    let values = measurementValues(element);
    let properties = valuesList(args.named.properties);
    let selected = properties.length ? properties : defaultMeasureProperties(names.length);
    names.forEach(function(stateName, index) {
      if (!(stateName in state)) return;
      let property = selected[index] || selected[selected.length - 1];
      let value = values[property];
      state[stateName] = truthy(args.named.round) ? Math.round(value) : value;
    });
    update(event);
    return true;
  };

  let applyPageAction = function(expression, event) {
    for (let name of ["addClass", "removeClass", "toggleClass"]) {
      if (applyClassAction(expression, name, event)) {
        update(event);
        return true;
      }
    }
    if (applyMeasureAction(expression, event)) return true;

    let argumentsText = actionArguments(expression, "scrollToTop");
    if (argumentsText !== null) {
      event?.preventDefault?.();
      window.scrollTo({ top: 0, behavior: scrollBehavior(argumentsText, event) });
      update(event);
      return true;
    }

    argumentsText = actionArguments(expression, "scrollTo");
    if (argumentsText !== null) {
      event?.preventDefault?.();
      let args = parsedArguments(argumentsText, event);
      let behavior = scrollBehavior(argumentsText, event);
      let selector = args.named.selector;
      if (selector) {
        let target = targetElement(selector);
        if (target) {
          target.scrollIntoView({
            behavior,
            block: text(args.named.block || "start"),
            inline: text(args.named.inline || "nearest")
          });
        }
        update(event);
        return true;
      }
      let top = args.named.top ?? args.named.y ?? 0;
      window.scrollTo({ top: Number(top), behavior });
      update(event);
      return true;
    }

    return false;
  };

  let applyAction = function(expression, event) {
    if (applyPageAction(expression, event)) return;
    let match = expression.match(/^([A-Za-z_][A-Za-z0-9_]*)\.(toggle|set|increment|decrement)\((.*)\)$/);
    if (!match) return;
    let [, name, action, argument] = match;
    if (!(name in state)) return;
    if (action === "toggle") state[name] = !truthy(state[name]);
    if (action === "set") state[name] = evaluate(argument, event);
    if (action === "increment") state[name] = Number(state[name] || 0) + (argument.trim() ? Number(evaluate(argument, event)) : 1);
    if (action === "decrement") state[name] = Number(state[name] || 0) - (argument.trim() ? Number(evaluate(argument, event)) : 1);
    update(event);
  };

  let update = function(event) {
    document.querySelectorAll("[data-plume-text]").forEach(function(node) {
      node.textContent = text(evaluate(node.dataset.plumeText, event));
    });
    document.querySelectorAll("[data-plume-class]").forEach(function(node) {
      let previous = node.dataset.plumeClassValue || "";
      if (previous) node.classList.remove(...previous.split(/\s+/).filter(Boolean));
      let next = text(evaluate(node.dataset.plumeClass, event));
      if (next) node.classList.add(...next.split(/\s+/).filter(Boolean));
      node.dataset.plumeClassValue = next;
    });
    document.querySelectorAll("*").forEach(function(node) {
      for (let { name, value } of Array.from(node.attributes)) {
        if (name.startsWith("data-plume-class-") && name !== "data-plume-class") {
          let className = name.slice("data-plume-class-".length);
          node.classList.toggle(className, truthy(evaluate(value, event)));
        }
        if (name.startsWith("data-plume-bind-")) {
          let attr = name.slice("data-plume-bind-".length);
          node.setAttribute(attr, text(evaluate(value, event)));
        }
        if (name.startsWith("data-plume-style-template-")) {
          let property = name.slice("data-plume-style-template-".length);
          let evaluated = renderTemplate(value, event);
          if (truthy(evaluated)) node.style.setProperty(property, evaluated);
          else node.style.removeProperty(property);
        } else if (name.startsWith("data-plume-style-")) {
          let property = name.slice("data-plume-style-".length);
          let evaluated = evaluate(value, event);
          if (truthy(evaluated)) node.style.setProperty(property, text(evaluated));
          else node.style.removeProperty(property);
        }
        if (name.startsWith("data-plume-attr-") && !name.endsWith("-value")) {
          let attr = name.slice("data-plume-attr-".length);
          let activeValue = node.getAttribute(`data-plume-attr-${attr}-value`);
          let evaluated = evaluate(value, event);
          if (activeValue === null) {
            if (truthy(evaluated)) node.setAttribute(attr, text(evaluated));
            else node.removeAttribute(attr);
          } else if (truthy(evaluated)) {
            node.setAttribute(attr, activeValue);
          } else {
            node.removeAttribute(attr);
          }
        }
      }
    });
  };

  let applyElementAction = function(node, name, event) {
    let action = node.getAttribute(`data-plume-on-${name}`);
    if (!action) return;
    applyAction(action, event);
  };

  let triggerElementActions = function(name, event) {
    document.querySelectorAll(`[data-plume-on-${name}]`).forEach(function(node) {
      applyElementAction(node, name, { target: node, originalEvent: event });
    });
  };

  let scheduleElementActions = function(name) {
    let scheduled = false;
    return function(event) {
      if (scheduled) return;
      scheduled = true;
      requestAnimationFrame(function() {
        scheduled = false;
        triggerElementActions(name, event);
      });
    };
  };

  let visibleObserver = null;
  let setupVisibleActions = function() {
    visibleObserver?.disconnect?.();
    visibleObserver = null;
    let visibleNodes = document.querySelectorAll("[data-plume-on-visible]");
    if (!visibleNodes.length) return;
    if (!("IntersectionObserver" in window)) {
      visibleNodes.forEach(function(node) { applyElementAction(node, "visible", { target: node, visible: true, ratio: 1 }); });
      return;
    }
    visibleObserver = new IntersectionObserver(function(entries) {
      entries.forEach(function(entry) {
        if (!entry.isIntersecting) return;
        applyElementAction(entry.target, "visible", {
          target: entry.target,
          visible: true,
          ratio: entry.intersectionRatio,
          entry
        });
      });
    });
    visibleNodes.forEach(function(node) { visibleObserver.observe(node); });
  };

  let setupViewportActions = function() {
    window.addEventListener("resize", scheduleElementActions("resize"));
    window.addEventListener("scroll", scheduleElementActions("scroll"), { passive: true });
    setupVisibleActions();
  };

  let navigationConfigs = function(root = document) {
    return Array.from(root.querySelectorAll("script[data-plume-navigation]")).flatMap(function(script) {
      try {
        let value = JSON.parse(script.textContent || "[]");
        return Array.isArray(value) ? value : [value];
      } catch {
        return [];
      }
    });
  };

  let mergeNavigationConfigs = function(configs) {
    if (!configs.length) return null;
    return configs.reduce(function(merged, config) {
      let hooks = { ...(merged.hooks || {}) };
      for (let [name, actions] of Object.entries(config.hooks || {})) {
        hooks[name] = [...(hooks[name] || []), ...(Array.isArray(actions) ? actions : [])];
      }
      return {
        root: config.root || merged.root || "body",
        viewTransitions: config.viewTransitions ?? merged.viewTransitions ?? true,
        scroll: config.scroll || merged.scroll || "top",
        minimumDuration: config.minimumDuration ?? merged.minimumDuration ?? 0,
        progressBar: config.progressBar ?? merged.progressBar ?? true,
        progressBarDelay: config.progressBarDelay ?? merged.progressBarDelay ?? 500,
        hooks
      };
    }, { root: "body", viewTransitions: true, scroll: "top", minimumDuration: 0, progressBar: true, progressBarDelay: 500, hooks: {} });
  };

  let navigation = mergeNavigationConfigs(navigationConfigs());

  let navigationEventName = function(name) { return name.replace(/[A-Z]/g, function(character) { return `-${character.toLowerCase()}`; }); };

  let dispatchNavigationEvent = function(name, detail) {
    document.dispatchEvent(new CustomEvent(`plume:navigate:${navigationEventName(name)}`, { detail }));
  };

  let runNavigationHook = function(name, detail) {
    dispatchNavigationEvent(name, detail);
    for (let action of navigation?.hooks?.[name] || []) {
      applyAction(action, { detail, url: detail.url, document: detail.document, error: detail.error });
    }
  };

  let syncNavigationHead = function(nextDocument) {
    document.title = nextDocument.title;
    let headSelectors = [
      "link[rel='stylesheet'][href]",
      "script[type='module'][src]"
    ];
    for (let selector of headSelectors) {
      nextDocument.querySelectorAll(selector).forEach(function(node) {
        let key = node.getAttribute("href") || node.getAttribute("src");
        let exists = Array.from(document.head.querySelectorAll(selector)).some(function(current) {
          return (current.getAttribute("href") || current.getAttribute("src")) === key;
        });
        if (!key || exists) return;
        document.head.appendChild(document.importNode(node, true));
      });
    }
    ["link[rel='canonical']", "meta[name='description']"].forEach(function(selector) {
      let current = document.head.querySelector(selector);
      let next = nextDocument.head.querySelector(selector);
      if (current && next) current.replaceWith(document.importNode(next, true));
    });
  };

  let syncNavigationState = function(nextDocument) {
    let nextStateScript = nextDocument.querySelector("script[data-plume-state]");
    let nextState = JSON.parse(nextStateScript?.textContent || "{}");
    Object.keys(state).forEach(function(key) { delete state[key]; });
    Object.assign(state, nextState);
  };

  let navigationRoot = function(root = document) { return root.querySelector(navigation?.root || "body"); };

  // Tracked bundle assets (the content-hashed app.css / app.js the server injects
  // with data-plume-track). If the incoming page's tracked assets differ from the
  // current page's — a deploy happened between navigations — swapping would leave
  // stale CSS/JS driving new markup, so do a full page load instead.
  let trackedAssetKeys = function(root) {
    return Array.from(root.querySelectorAll("[data-plume-track]"))
      .map(function(node) { return node.getAttribute("href") || node.getAttribute("src") || ""; })
      .sort().join("\n");
  };

  let completeNavigationSwap = function(url, nextDocument, options) {
    let currentRoot = navigationRoot();
    let nextRoot = navigationRoot(nextDocument);
    if (!currentRoot || !nextRoot) {
      window.location.href = url.href;
      return;
    }
    if (trackedAssetKeys(document.head) !== trackedAssetKeys(nextDocument.head)) {
      window.location.href = url.href;
      return;
    }
    let detail = { url: url.href, document: nextDocument };
    runNavigationHook("beforeSwap", detail);
    let swap = function() {
      syncNavigationHead(nextDocument);
      syncNavigationState(nextDocument);
      currentRoot.replaceWith(document.importNode(nextRoot, true));
      let nextNavigation = mergeNavigationConfigs(navigationConfigs(nextDocument));
      if (nextNavigation) navigation = nextNavigation;
      if (options.history) window.history.pushState({}, "", url.href);
      if ((navigation?.scroll || "top") === "top") window.scrollTo({ top: 0, left: 0 });
      update();
      setupVisibleActions();
      runNavigationHook("afterSwap", detail);
    };
    if ((navigation?.viewTransitions ?? true) && document.startViewTransition) {
      let transition = document.startViewTransition(swap);
      transition.finished.finally(function() { runNavigationHook("complete", detail); });
    } else {
      swap();
      runNavigationHook("complete", detail);
    }
  };

  let visit = async function(url, options = { history: true }) {
    let detail = { url: url.href };
    try {
      let startedAt = performance.now();
      runNavigationHook("start", detail);
      // The drive layer's progress bar (Plume.progress) covers slow visits; it
      // reads the navigation config itself, so it no-ops when disabled.
      window.Plume?.progress?.start?.();
      let response = await fetch(url.href, { headers: { "X-Plume-Navigation": "true" } });
      if (!response.ok) throw new Error(`Navigation failed with status ${response.status}`);
      let html = await response.text();
      let nextDocument = new DOMParser().parseFromString(html, "text/html");
      let remaining = Number(navigation.minimumDuration || 0) - (performance.now() - startedAt);
      if (remaining > 0) {
        await new Promise(function(resolve) { setTimeout(resolve, remaining); });
      }
      completeNavigationSwap(url, nextDocument, options);
      window.Plume?.progress?.finish?.();
    } catch (error) {
      window.Plume?.progress?.finish?.();
      runNavigationHook("error", { url: url.href, error });
      window.location.href = url.href;
    }
  };

  // Expose the full navigation swap to the drive layer (appended after this
  // script): a top-level form submission or Plume.visit that receives a full
  // HTML document must behave exactly like a link visit — title/head/state
  // sync, navigation config re-read, hooks, history — instead of dumping the
  // response text into the body.
  window.Plume = window.Plume || {};
  window.Plume.swapDocument = function(url, nextDocument, options = { history: true }) {
    completeNavigationSwap(url, nextDocument, options);
  };

  let shouldHandleNavigationLink = function(link, event) {
    if (!navigation || !link) return false;
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return false;
    if (link.target && link.target !== "_self") return false;
    if (link.hasAttribute("download") || link.getAttribute("data-plume-navigation") === "false") return false;
    let url = new URL(link.href, window.location.href);
    if (url.origin !== window.location.origin) return false;
    let fileName = url.pathname.split("/").pop() || "";
    let extensionParts = fileName.split(".");
    let extension = extensionParts.length > 1 ? extensionParts[extensionParts.length - 1].toLowerCase() : "";
    if (extension && extension !== "html" && extension !== "htm") return false;
    if (url.pathname === window.location.pathname && url.search === window.location.search && url.hash) return false;
    return true;
  };

  if (navigation) {
    document.addEventListener("click", function(event) {
      let eventTarget = event.target instanceof Element ? event.target : event.target?.parentElement;
      let link = eventTarget?.closest("a[href]");
      if (!shouldHandleNavigationLink(link, event)) return;
      event.preventDefault();
      visit(new URL(link.href, window.location.href));
    });
    window.addEventListener("popstate", function() {
      visit(new URL(window.location.href), { history: false });
    });
  }

  [
    "click", "input", "change", "submit",
    "focus", "blur",
    "mouseover", "mouseout", "mouseenter", "mouseleave",
    "pointerover", "pointerout", "pointerenter", "pointerleave"
  ].forEach(function(name) {
    document.addEventListener(name, function(event) {
      let eventTarget = event.target instanceof Element ? event.target : event.target?.parentElement;
      let target = eventTarget?.closest(`[data-plume-on-${name}]`);
      if (!target) return;
      applyAction(target.getAttribute(`data-plume-on-${name}`), event);
    }, true);
  });
  setupViewportActions();
  update();
}
bootPlumeRuntime();

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