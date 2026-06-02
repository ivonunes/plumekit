# Components

Components keep repeated markup in one place without hiding the HTML shape of the page. Define them with `@component`, then call them by name.

## Define And Call

Component names use UpperCamelCase:

```plume
@component PostCard(post, tone = "default") {
  <article class="post-card" class+="{tone}" class+="{post.kind}">
    <h2>{post.title}</h2>
    @slot
  </article>
}

@PostCard(post, tone: "featured") {
  <p>{post.excerpt}</p>
}
```

Arguments can be positional, named, or mixed. Named arguments are clearer once a component accepts more than one optional value.

## Designing Component APIs

Keep the first argument the thing the component renders, then make options named:

```plume
@PostCard(post, tone: "featured", showMeta: false)
```

This keeps call sites readable as components grow. Use defaults for options that should usually disappear from the call site.

Prefer slots for real content and arguments for data or small display options. If a caller needs to pass headings, paragraphs, lists, or buttons, a slot usually reads better than a long string argument.

## Defaults

Parameters can have default values:

```plume
@component Button(label, variant = "plain") {
  <button class+="{variant}">{label}</button>
}

@Button("Save")
@Button("Delete", variant: "danger")
```

## Slots

`@slot` renders the trailing content passed to a component:

```plume
@component Panel(title) {
  <section>
    <h2>{title}</h2>
    <div>@slot</div>
  </section>
}

@Panel("Now") {
  <p>Working on Plume.</p>
}
```

Slots can include fallback content:

```plume
@component EmptyState(title) {
  <section class="empty-state">
    @slot {
      <p>{title}</p>
    }
  </section>
}
```

The fallback renders only when the caller does not pass trailing content.

## Named Content

Use named content when a component has multiple content areas:

```plume
@component PageSection(title) {
  <section>
    <header>
      @slot("header") {
        <h2>{title}</h2>
      }
    </header>

    <div>@slot</div>

    <footer>
      @slot(name: "footer")
    </footer>
  </section>
}

@PageSection("Projects") {
  @content(header) {
    <h1>Selected Work</h1>
  }

  <p>Project list...</p>

  @content(footer) {
    <a href="/projects/">All projects</a>
  }
}
```

`@content` is only valid directly inside a component call. This keeps the ownership of named content clear.

## Component Resources

Components can carry the styles and scripts they need:

```plume
@component Disclosure(title) {
  @style(scoped) {
    .panel {
      border: 1px solid currentColor;
    }
  }

  @state open = false

  <section class="panel" class:open="{open}">
    <button on:click="{open.toggle()}" aria-expanded="{open}">{title}</button>
    <div hidden?="{!open}">@slot</div>
  </section>
}
```

Scoped styles are limited to the rendered component fragment. State and event bindings make the component interactive when the host emits the Plume runtime.

## Composition

Components can call other components:

```plume
@component PostList(posts) {
  <ul class="post-list">
    @for post in posts {
      @PostCard(post)
    }
  </ul>
}
```

Keep components focused. A component that owns layout, data selection, styling, and interaction all at once is harder to reuse than a component with one clear job.

## Errors That Help

Plume checks component calls against their definitions. Unknown arguments and duplicate arguments are reported as template errors:

```plume
@PostCard(post, tone: "featured", tone: "quiet")
```

That makes component APIs safer to evolve than loose includes or partials.

## File Loading

Plume itself does not require a component folder. Hosts decide which component sources to provide to a template environment.

Inkstead Writer loads components from `theme/components`:

```txt
theme/
  components/
    PostCard.plume
    PageSection.plume
```

Inside a Swift host, pass component sources through `PlumeTemplateEnvironment`.
