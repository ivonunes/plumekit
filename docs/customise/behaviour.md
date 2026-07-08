# Behaviour

Plume is not trying to turn every website into an app. Its interactive layer is for small, local behaviour: disclosures, menus, filters, sliders, page transitions and progressive enhancement.

When you are embedding Plume yourself, [Embedding](../embedding/index.md) explains when these features need the runtime.

## Choosing a layer

Use the smallest layer that describes the behaviour:

- Use HTML and CSS first.
- Use `@state` and `on:*` for local UI state.
- Use browser actions such as `page.scrollToTop` or `page.measure` for common page behaviour.
- Use `@script` when an interaction needs several steps or shared event handling.
- Use `@script(language: "javascript")` only when you need browser APIs outside Plume's client script language.

## State

Declare local state with `@state`:

```plume
@state expanded = false

<button on:click="{expanded.toggle()}" aria-expanded="{expanded}">
  {expanded ? "Hide" : "Show"} details
</button>

<section hidden?="{!expanded}" class:open="{expanded}">
  Details
</section>
```

State can be rendered into:

- Text content
- Attributes
- Conditional classes
- Optional attributes
- Inline style properties

State is local to the rendered page. It is not a persistence layer and it is not shared with the server.

## Actions

State actions are intentionally small:

```plume
on:click="{expanded.toggle()}"
on:click="{count.increment()}"
on:click="{count.decrement()}"
on:input="{query.set(event.value)}"
```

Supported state actions:

- `name.toggle()`
- `name.set(value)`
- `name.increment()`
- `name.decrement()`

For form controls, `event.value` is available:

```plume
@state query = ""

<input value="{query}" on:input="{query.set(event.value)}">
<p hidden?="{query == ''}">Searching for {query}</p>
```

## Browser

Use `page` for common browser actions:

```plume
<button on:click="{page.scrollToTop(smooth: true)}">Top</button>
```

Supported page actions:

- `page.scrollToTop(smooth: true)`
- `page.scrollTo(selector: "#main", smooth: true)`
- `page.addClass("is-open")`
- `page.removeClass("is-open")`
- `page.toggleClass("nav-open")`
- `page.measure(selector, into: ["x", "width"])`

Class actions target the document element by default. Pass `target: "body"` or another selector to target a specific element.

## Measuring

Use `page.measure` when an interaction needs live element geometry but CSS should still do the animation:

```plume
@state sliderX = 0
@state sliderWidth = 0

<nav on:resize="{page.measure('.nav-link[aria-current=page]', into: ['sliderX', 'sliderWidth'])}">
  <a
    class="nav-link"
    href="/projects/"
    on:pointerenter="{page.measure(event.target, into: ['sliderX', 'sliderWidth'], round: true)}"
  >
    Projects
  </a>

  <span
    class="nav-slider"
    style:--slider-x="{sliderX}px"
    style:--slider-width="{sliderWidth}px"
  ></span>
</nav>
```

By default, two `into` values receive the measured element's `x` and `width`. Pass `properties: ['y', 'height']` when you need different measurements.

Available properties include `x`, `y`, `width`, `height`, `top`, `left`, `right`, `bottom`, `viewportX`, `viewportY`, `centerX` and `centerY`.

## Viewport

`on:visible` fires when an element enters the viewport:

```plume
@state introSeen = false

<section on:visible="{introSeen.set(true)}" class:seen="{introSeen}">
  ...
</section>
```

`on:resize` and `on:scroll` run on animation frames and can update state from page geometry.

## Scripts

Use `@script` when an interaction needs more than a single action:

```plume
@script {
  let menu = page.query("#menu")

  on ".menu-toggle".click {
    event.preventDefault()
    menu.toggleClass("is-open")
  }

  on page.scroll {
    page.toggleClass("is-scrolled", when: page.scrollY > 24)
  }
}
```

Client scripts support `let`, `var`, `if`, `else`, `for item in items`, `on target.event` blocks, query helpers, class helpers, text and attribute helpers, and scroll helpers. See [Client scripts](client-scripts.md) for the full language reference. Use `@script(language: "javascript")` when you need raw browser APIs.

Keep scripts close to the markup they enhance. If the script belongs to one component instance, use `@script(scoped)`. If it coordinates the whole page, put it in a page or layout template.

## Navigation

Use `@navigation` when same-origin links should fetch and swap page content instead of doing a full browser reload:

```plume
@navigation(root: "main", viewTransitions: true, scroll: "top") {
  on:beforeSwap {
    page.addClass("is-leaving")
  }

  on:afterSwap {
    page.removeClass("is-leaving")
  }
}
```

Put it in a layout template when the whole site should use it.

Available options:

- `root`: the selector for the element swapped on navigation (default `"body"`).
- `viewTransitions`: animate swaps with the View Transitions API when the
  browser supports it (default `true`).
- `scroll`: `"top"`, `"preserve"` or `"none"` (default `"top"`).
- `minimumDuration`: a minimum visit duration in milliseconds, useful to let a
  leave animation finish (default `0`).
- `progressBar`: show a slim progress bar at the top of the viewport while a
  visit or intercepted form submission is in flight (default `true`). Set
  `progressBar: false` to disable it.
- `progressBarDelay`: how long a request must run, in milliseconds, before the
  bar appears (default `500`), so fast navigations never flash it.

The progress bar needs no app CSS: the runtime injects its own namespaced
style (`.plume-progress-bar`, 3px tall, fixed to the top of the viewport). To
match your brand, override its colour from plain CSS with a custom property:

```css
:root {
  --plume-progress-color: #16a34a;
}
```

Available hooks:

- `on:start`
- `on:beforeSwap`
- `on:afterSwap`
- `on:complete`
- `on:error`

Use `data-plume-navigation="false"` on a link to opt out.
