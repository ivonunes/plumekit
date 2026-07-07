# Driving the page

`PlumeBrowserRuntime.javaScript` is the single, dependency-free script Plume ships
to the browser. It has two layers:

- the **binding core**: wires up `data-plume-*` attributes (text/class/style/attr
  bindings, event actions) and declarative `@navigation`;
- the **drive layer**: a Hotwire-equivalent set of behaviours exposed on a public
  `Plume` global, so any transport can drive the page without Plume knowing the
  transport.

Plume defines and drives the DOM only. `visit`, frames, and forms just `fetch` a
URL and apply whatever comes back; `apply` takes an envelope from *any* source.
How a request reaches a server, and what server answers, is not Plume's concern.

## The runtime is injected automatically

When a page opts into client behaviour (most commonly by declaring `@navigation`
in its layout), the render layer **injects the runtime `<script>` for you**. The
author writes `@navigation` and **never** a manual `<script src="app.js">`. This
matches the interpreter, which emits the runtime only when `requiresRuntime` is
true, so a purely static page ships no JavaScript at all. The scaffold's
`Views/Layout.plume` enables it with:

```plume
@navigation(root: "body", viewTransitions: true, scroll: "top")
```

The no-JavaScript baseline is preserved either way: with the script absent or
disabled, links do full-page navigations and forms do normal submits.

## `Plume.apply(envelope)`

Applies a [stream envelope](../streaming/index.md) (a string of `<plume-stream>`
elements, or a DOM node containing them) to the current page. Each operation
targets an element by `id` and runs its action:

```js
Plume.apply(
  '<plume-stream action="append" target="messages">' +
  '<template><li>New message</li></template></plume-stream>'
);
```

The envelope may come from a fetch response, a WebSocket message, an SSE event, or
be hand-built; Plume does not care.

## `Plume.visit(url, options?)`

Programmatic navigation: fetches `url` (sending `X-Plume-Navigation: true`). If the
response is a stream envelope it is applied; otherwise the page body is swapped.
`options.method` and `options.body` are forwarded to the request.

## Navigation progress bar

Visits (link clicks, `Plume.visit`) and intercepted form submissions show a slim
progress bar fixed to the top of the viewport when the request outlasts a delay
threshold; it completes and fades when the response lands (success or error).
Defaults: enabled, 500 ms delay, 3 px tall. The runtime injects the style
itself under the namespaced `.plume-progress-bar` class, so no app CSS is
required.

Configure it through `@navigation`:

```plume
@navigation(root: "body", progressBar: true, progressBarDelay: 300)
```

`progressBar: false` disables it; `progressBarDelay` tunes the threshold in
milliseconds. The color is overridable from plain app CSS — the bar paints with
`background: var(--plume-progress-color, #0076ff)`, so:

```css
:root {
  --plume-progress-color: #16a34a;
}
```

`Plume.progress.start()` / `Plume.progress.finish()` expose the same bar to
custom transports (calls nest; the bar hides when every started request has
finished).

## Frames

```html
<plume-frame id="cart" src="/cart"></plume-frame>
```

A `<plume-frame>` is a region with an `id` that **scopes navigation to itself**:

- with a `src`, it lazy-loads that URL and swaps in the response (add
  `loading="lazy"` to defer until it scrolls into view);
- links and forms **inside** the frame fetch-and-swap the frame's own content
  instead of navigating the whole page.

## Form interception (progressive)

Same-origin form submits are progressively enhanced: the runtime intercepts the
submit, fetches the form's `action` with its method and data, and applies the
returned envelope (or swaps the enclosing frame). With JavaScript disabled, or
on a form marked `data-plume-navigation="false"`, nothing is intercepted and the
browser performs a normal full submit. The form markup is never rewritten, so the
no-JS path always works.

## Morph

`replace`/`update` swap elements wholesale. `morph` (also `Plume.morph(target,
html)`) diffs the new markup into the target **in place**, idiomorph-style:
matching elements by `id` then position, syncing attributes, and recursing. It
preserves the focused element, its text selection, and scroll position, so a live
update never interrupts a user who is typing.
