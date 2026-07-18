import Foundation

/// The browser runtime that implements Plume's client-side contract.
///
/// Pages rendered with `PlumeTemplate` may emit `data-plume-*` attributes
/// (see `PlumeRenderResult.requiresRuntime`). Serving `javaScript` alongside a
/// `<script type="application/json" data-plume-state>` tag containing the
/// render result's `state` wires those attributes up in the browser:
/// text updates, class/style/attribute bindings, event actions, viewport and
/// measurement actions, and declarative navigation configured through
/// `<script type="application/json" data-plume-navigation>` tags.
public enum PlumeBrowserRuntime {
    /// The compiled, dependency-free JavaScript for the browser runtime. This is
    /// the compiled `data-plume-*` binding/navigation core plus the Hotwire-style
    /// "drive" layer (stream-envelope `apply`, `visit`, frames, form interception,
    /// morph) exposed on the public `Plume` global.
    public static var javaScript: String { compiled + "\n" + driveRuntime }

    private static let compiled: String = {
        do {
            return try PlumeClientScriptCompiler.compileBrowserRuntime(source, sourceName: "plume-runtime.plume")
        } catch {
            preconditionFailure("Invalid embedded Plume browser runtime script: \(error)")
        }
    }()

    private static let source = #"""
func bootPlumeRuntime() {
  // A page can need the runtime without declaring any @state — @navigation alone
  // is enough — so a missing state hook boots with empty state instead of
  // returning early (which would silently disable declarative navigation).
  let stateScript = document.querySelector("script[data-plume-state]");
  let state = JSON.parse(stateScript?.textContent || "{}");

  let truthy = func(value) {
    if (value === null || value === undefined) return false;
    if (typeof value === "boolean") return value;
    if (typeof value === "number") return value !== 0;
    if (typeof value === "string") return value.length > 0 && value !== "false";
    if (Array.isArray(value)) return value.length > 0;
    return true;
  };

  let valueFor = func(path, event) {
    path = path.trim();
    if (path === "true") return true;
    if (path === "false") return false;
    if (path === "nil" || path === "null") return null;
    if (path === "event.value") return event?.target?.value ?? "";
    if (path.startsWith("event.")) {
      return path.split(".").slice(1).reduce(func(value, key) { return value?.[key]; }, event);
    }
    if (path.startsWith("[") && path.endsWith("]")) {
      return splitArguments(path.slice(1, -1)).map(func(argument) { return evaluate(argument, event); });
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
    return path.split(".").reduce(func(value, key) { return value?.[key]; }, state);
  };

  let evaluate = func(expression, event) { return valueFor(expression, event); };

  let text = func(value) { return value === null || value === undefined ? "" : String(value); };

  let renderTemplate = func(template, event) {
    return text(template).replace(/\{([^{}]+)\}/g, func(_, expression) { return text(evaluate(expression, event)); });
  };

  let actionArguments = func(expression, name) {
    let prefix = `page.${name}(`;
    if (!expression.startsWith(prefix) || !expression.endsWith(")")) return null;
    return expression.slice(prefix.length, -1);
  };

  let splitArguments = func(argumentsText) {
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

  let parsedArguments = func(argumentsText, event) {
    let output = { positional: [], named: {} };
    splitArguments(argumentsText).forEach(func(argument) {
      let match = argument.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.+)$/);
      if (match) {
        output.named[match[1]] = evaluate(match[2], event);
      } else {
        output.positional.push(evaluate(argument, event));
      }
    });
    return output;
  };

  let firstArgument = func(args, ...names) {
    if (args.positional.length) return args.positional[0];
    for (let name of names) {
      if (args.named[name] !== undefined) return args.named[name];
    }
    return null;
  };

  let scrollBehavior = func(argumentsText, event) {
    let args = parsedArguments(argumentsText, event);
    let behavior = args.named.behavior;
    if (behavior) return text(behavior);
    return truthy(args.named.smooth) ? "smooth" : "auto";
  };

  let targetElement = func(selector) {
    if (!selector) return document.documentElement;
    if (selector instanceof Element) return selector;
    try {
      return document.querySelector(text(selector));
    } catch {
      return null;
    }
  };

  let classNames = func(value) { return text(value).split(/\s+/).filter(Boolean); };

  let applyClassAction = func(expression, name, event) {
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
      names.forEach(func(className) {
        if (force === undefined) element.classList.toggle(className);
        else element.classList.toggle(className, truthy(force));
      });
    }
    return true;
  };

  let valuesList = func(value) {
    if (Array.isArray(value)) return value.map(text).filter(Boolean);
    return text(value).split(/[\s,]+/).filter(Boolean);
  };

  let measurementValues = func(element) {
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

  let defaultMeasureProperties = func(count) {
    if (count === 1) return ["x"];
    if (count === 2) return ["x", "width"];
    if (count === 3) return ["x", "y", "width"];
    return ["x", "y", "width", "height"];
  };

  let applyMeasureAction = func(expression, event) {
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
    names.forEach(func(stateName, index) {
      if (!(stateName in state)) return;
      let property = selected[index] || selected[selected.length - 1];
      let value = values[property];
      state[stateName] = truthy(args.named.round) ? Math.round(value) : value;
    });
    update(event);
    return true;
  };

  let applyPageAction = func(expression, event) {
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

  let applyAction = func(expression, event) {
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

  let update = func(event) {
    document.querySelectorAll("[data-plume-text]").forEach(func(node) {
      node.textContent = text(evaluate(node.dataset.plumeText, event));
    });
    document.querySelectorAll("[data-plume-class]").forEach(func(node) {
      let previous = node.dataset.plumeClassValue || "";
      if (previous) node.classList.remove(...previous.split(/\s+/).filter(Boolean));
      let next = text(evaluate(node.dataset.plumeClass, event));
      if (next) node.classList.add(...next.split(/\s+/).filter(Boolean));
      node.dataset.plumeClassValue = next;
    });
    document.querySelectorAll("*").forEach(func(node) {
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

  let applyElementAction = func(node, name, event) {
    let action = node.getAttribute(`data-plume-on-${name}`);
    if (!action) return;
    applyAction(action, event);
  };

  let triggerElementActions = func(name, event) {
    document.querySelectorAll(`[data-plume-on-${name}]`).forEach(func(node) {
      applyElementAction(node, name, { target: node, originalEvent: event });
    });
  };

  let scheduleElementActions = func(name) {
    let scheduled = false;
    return func(event) {
      if (scheduled) return;
      scheduled = true;
      requestAnimationFrame(func() {
        scheduled = false;
        triggerElementActions(name, event);
      });
    };
  };

  let visibleObserver = null;
  let setupVisibleActions = func() {
    visibleObserver?.disconnect?.();
    visibleObserver = null;
    let visibleNodes = document.querySelectorAll("[data-plume-on-visible]");
    if (!visibleNodes.length) return;
    if (!("IntersectionObserver" in window)) {
      visibleNodes.forEach(func(node) { applyElementAction(node, "visible", { target: node, visible: true, ratio: 1 }); });
      return;
    }
    visibleObserver = new IntersectionObserver(func(entries) {
      entries.forEach(func(entry) {
        if (!entry.isIntersecting) return;
        applyElementAction(entry.target, "visible", {
          target: entry.target,
          visible: true,
          ratio: entry.intersectionRatio,
          entry
        });
      });
    });
    visibleNodes.forEach(func(node) { visibleObserver.observe(node); });
  };

  let setupViewportActions = func() {
    window.addEventListener("resize", scheduleElementActions("resize"));
    window.addEventListener("scroll", scheduleElementActions("scroll"), { passive: true });
    setupVisibleActions();
  };

  let navigationConfigs = func(root = document) {
    return Array.from(root.querySelectorAll("script[data-plume-navigation]")).flatMap(func(script) {
      try {
        let value = JSON.parse(script.textContent || "[]");
        return Array.isArray(value) ? value : [value];
      } catch {
        return [];
      }
    });
  };

  let mergeNavigationConfigs = func(configs) {
    if (!configs.length) return null;
    return configs.reduce(func(merged, config) {
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

  let navigationEventName = func(name) { return name.replace(/[A-Z]/g, func(character) { return `-${character.toLowerCase()}`; }); };

  let dispatchNavigationEvent = func(name, detail) {
    document.dispatchEvent(new CustomEvent(`plume:navigate:${navigationEventName(name)}`, { detail }));
  };

  let runNavigationHook = func(name, detail) {
    dispatchNavigationEvent(name, detail);
    for (let action of navigation?.hooks?.[name] || []) {
      applyAction(action, { detail, url: detail.url, document: detail.document, error: detail.error });
    }
  };

  let syncNavigationHead = func(nextDocument) {
    document.title = nextDocument.title;
    let headSelectors = [
      "link[rel='stylesheet'][href]",
      "script[type='module'][src]"
    ];
    for (let selector of headSelectors) {
      nextDocument.querySelectorAll(selector).forEach(func(node) {
        let key = node.getAttribute("href") || node.getAttribute("src");
        let exists = Array.from(document.head.querySelectorAll(selector)).some(func(current) {
          return (current.getAttribute("href") || current.getAttribute("src")) === key;
        });
        if (!key || exists) return;
        document.head.appendChild(document.importNode(node, true));
      });
    }
    let canonical = document.head.querySelector("link[rel='canonical']");
    let nextCanonical = nextDocument.head.querySelector("link[rel='canonical']");
    if (canonical && nextCanonical) canonical.replaceWith(document.importNode(nextCanonical, true));
    // Named metas travel with the page (the csrf token, page state that scripts
    // read): replace by name, add new ones, and drop the ones the incoming page
    // lacks — otherwise a client-side navigation leaves the previous page's
    // head state behind and scripts read stale or missing values.
    let nextMetas = Array.from(nextDocument.head.querySelectorAll("meta[name]"));
    let nextNames = new Set(nextMetas.map(func(node) { return node.getAttribute("name"); }));
    let currentMetas = Array.from(document.head.querySelectorAll("meta[name]"));
    let currentByName = new Map(currentMetas.map(func(node) { return [node.getAttribute("name"), node]; }));
    nextMetas.forEach(func(node) {
      let current = currentByName.get(node.getAttribute("name"));
      if (current) current.replaceWith(document.importNode(node, true));
      else document.head.appendChild(document.importNode(node, true));
    });
    currentMetas.forEach(func(node) {
      if (!nextNames.has(node.getAttribute("name"))) node.remove();
    });
  };

  let syncNavigationState = func(nextDocument) {
    let nextStateScript = nextDocument.querySelector("script[data-plume-state]");
    let nextState = JSON.parse(nextStateScript?.textContent || "{}");
    Object.keys(state).forEach(func(key) { delete state[key]; });
    Object.assign(state, nextState);
  };

  let navigationRoot = func(root = document) { return root.querySelector(navigation?.root || "body"); };

  // Tracked bundle assets (the content-hashed app.css / app.js the server injects
  // with data-plume-track). If the incoming page's tracked assets differ from the
  // current page's — a deploy happened between navigations — swapping would leave
  // stale CSS/JS driving new markup, so do a full page load instead.
  let trackedAssetKeys = func(root) {
    return Array.from(root.querySelectorAll("[data-plume-track]"))
      .map(func(node) { return node.getAttribute("href") || node.getAttribute("src") || ""; })
      .sort().join("\n");
  };

  let completeNavigationSwap = func(url, nextDocument, options) {
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
    let swap = func() {
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
      transition.finished.finally(func() { runNavigationHook("complete", detail); });
    } else {
      swap();
      runNavigationHook("complete", detail);
    }
  };

  let visit = async func(url, options = { history: true }) {
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
        await new Promise(func(resolve) { setTimeout(resolve, remaining); });
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
  window.Plume.swapDocument = func(url, nextDocument, options = { history: true }) {
    completeNavigationSwap(url, nextDocument, options);
  };

  let shouldHandleNavigationLink = func(link, event) {
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
    document.addEventListener("click", func(event) {
      let eventTarget = event.target instanceof Element ? event.target : event.target?.parentElement;
      let link = eventTarget?.closest("a[href]");
      if (!shouldHandleNavigationLink(link, event)) return;
      event.preventDefault();
      visit(new URL(link.href, window.location.href));
    });
    window.addEventListener("popstate", func() {
      visit(new URL(window.location.href), { history: false });
    });
  }

  [
    "click", "input", "change", "submit",
    "focus", "blur",
    "mouseover", "mouseout", "mouseenter", "mouseleave",
    "pointerover", "pointerout", "pointerenter", "pointerleave"
  ].forEach(func(name) {
    document.addEventListener(name, func(event) {
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
"""#
}
