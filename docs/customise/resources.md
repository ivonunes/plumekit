# Resources

Plume can collect page resources while rendering. A host application can then emit those resources as real CSS, JavaScript and image files instead of forcing everything inline.

The important idea is locality: write the resource next to the markup that needs it, and let the host decide how to fingerprint, inject, optimise or copy it.

## Lifecycle

When a template renders, Plume records resource declarations in the render result. It does not assume where those files should live in the final site.

A host can then:

- Combine or fingerprint CSS.
- Emit JavaScript as modules.
- Scope component styles.
- Resolve static assets.
- Generate responsive images.
- Inject links and scripts into the final document.

When embedding Plume yourself, [Embedding](../embedding/index.md) explains how to emit collected resources.

## Styles

Use `@style` for CSS that belongs to the current template:

```plume
@style {
  .post-list {
    display: grid;
    gap: 1rem;
  }
}

<section class="post-list">
  @for post in posts {
    <article>{post.title}</article>
  }
</section>
```

Use scoped styles for component CSS that should not leak into the rest of the page:

```plume
@component Button(label, variant = "plain") {
  @style(scoped) {
    .button {
      border-radius: 0.4rem;
    }

    .button.primary {
      background: black;
      color: white;
    }
  }

  <button class="button" class+="{variant}">{label}</button>
}
```

Scoped styles are normal CSS. Plume rewrites selectors and marks the rendered fragment with a generated scope attribute.

CSS files are supported too:

```plume
@style(file: "styles/site.css")
@style(file: "components/card.css", scoped: true)
```

Use inline styles when the CSS only makes sense next to the template. Use CSS files when the stylesheet is shared, large or edited independently.

## Scripts

`@script` uses Plume's client script language by default:

```plume
@script {
  let menu = page.query("#menu")

  on ".menu-toggle".click {
    menu.toggleClass("is-open")
  }
}
```

Use `.plume` files when a script should live outside the template:

```plume
@script(file: "scripts/menu.plume")
```

Raw JavaScript is available as an explicit escape hatch:

```plume
@script(language: "javascript") {
  document.documentElement.dataset.enhanced = "true";
}
```

JavaScript files are treated as raw JavaScript automatically:

```plume
@script(file: "scripts/site.js")
```

## Scoped

Scoped scripts belong to a rendered fragment. Inside the script, `root` is the fragment's top-level element:

```plume
@component Disclosure(title) {
  @script(scoped) {
    let button = root.query("button")

    on button.click {
      root.toggleClass("is-open")
    }
  }

  <section>
    <button>{title}</button>
    @slot
  </section>
}
```

Scoped Plume scripts run once for each rendered fragment. Raw JavaScript modules are copied as modules and do not get `root`.

## Assets

Hosts can expose an `asset()` function to resolve theme or application files:

```plume
<img src="{asset('images/avatar.png')}" alt="Avatar">
```

Plume checks static asset references where the host provides enough information. The host decides the final public URL.

Use `asset()` for files you want to reference from attributes, such as favicons, downloads, fonts and images that do not need generated markup.

`asset()` works in **both** the interpreter and the **compiled** path. In a compiled template it is resolved **at build time** to a baked URL string literal (no runtime lookup in the Wasm build), so the argument must be a **string literal**. In PlumeKit it resolves to the content-hashed Plume bundle for the framework's own files (`asset("app.js")` → `/app.<hash>.js`, `asset("app.css")` → `/app.<hash>.css`) and passes your own `Public/` files through by path (`asset("logo.png")` → `/logo.png`).

## Images

Use `@image` when the host supports image generation:

```plume
@image(
  "hero.jpg",
  alt: "Coastal path",
  widths: [480, 960, 1440],
  sizes: "(min-width: 960px) 960px, 100vw"
)
```

Plume records the image reference and requested attributes. The host can then resolve the file, inspect dimensions, generate responsive variants and emit the final `<img>` markup.

Common arguments:

- `src`
- `alt`
- `class`
- `width`
- `height`
- `loading`
- `decoding`
- `fetchpriority`
- `widths`
- `sizes`

Use `@image` when you want the host to produce the `<img>` element or add image metadata. Use `asset()` when you only need a URL.

A host uses `asset()`, `@image`, `@style` and `@script` to emit fingerprinted resources, typically under a path such as `/assets/plume/`.
