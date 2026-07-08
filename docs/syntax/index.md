# Syntax

Plume syntax is deliberately small. Templates stay close to HTML, and the extra syntax is reserved for values, control flow, reusable components, resources and behaviour.

## Output

Use `{expression}` for normal escaped output:

```plume
<h1>{post.title}</h1>
```

Expressions can start with values, literals, function calls or filters:

```plume
{"Draft" | downcase}
{"/photos/a b.jpg" | urlEncode}
{asset("images/avatar.png")}
```

Host-provided `PlumeSafeHTML` renders as HTML. Ordinary strings are escaped. Use `| raw` only for trusted content.

```plume
<article>{post.html}</article>
<article>{customHTML | raw}</article>
```

**Always quote an interpolated attribute value.** Escaping covers text and quoted
attributes, so `<a href="{url}">` is safe. An *unquoted* value like `<a href={url}>`
is not: a value with a space could add an attribute of its own. Quote every attribute
that contains `{...}`.

## Expressions

Expressions can read values from the context, local variables, loop variables, component arguments and host functions:

```plume
{site.title}
{post.author.name}
{posts.size}
{asset("images/avatar.png")}
```

Supported literals include strings, numbers, booleans, `nil`, `null`, `empty`, `blank` and arrays:

```plume
@let widths = [480, 960, 1440]
@let fallbackTitle = "Untitled"
```

Comparisons and boolean operators work in conditionals and bindings:

```plume
@if post.title && post.urlPath.startsWith("/notes/") {
  <a href="{post.urlPath}">{post.title}</a>
}

<button disabled?="{items.size == 0}">Continue</button>
```

Operators follow Swift's precedence: prefix `!` binds tightest, then `??`, then
comparisons, then `&&`, then `||`. So `!a == b` evaluates as `(!a) == b`. (This
changed in Plume 2.0; earlier versions parsed it as `!(a == b)`.)

Use ternaries for small inline choices:

```plume
<span>{post.title ? post.title : "Untitled"}</span>
```

For conditionals, empty strings, empty arrays, `false`, `nil` and `null` are falsey. Non-empty strings, non-empty arrays, numbers, dictionaries and safe HTML are truthy.

## Locals

Use `@let` for local values:

```plume
@let currentPath = meta.canonicalUrl.replace(site.url, "")
@let isActive = currentPath == "/photos/"

<a href="/photos/" class:active="{isActive}">Photos</a>
```

## Conditionals

Use `@if`, `else if` and `else`:

```plume
@if post.title {
  <h1>{post.title}</h1>
} else if site.title {
  <h1>{site.title}</h1>
} else {
  <h1>Untitled</h1>
}
```

Bind an optional with Swift-style `@if let`; the name is in scope for the body:

```plume
@if let author = post.author {
  <p>By {author.name}</p>
} else {
  <p>Anonymous</p>
}
```

Coalesce a missing value with `??` (only nil/null falls back; an empty string is
a value, as in Swift). It binds tighter than comparison and is right-associative:

```plume
<title>{post.title ?? site.title ?? "Untitled"}</title>
```

`@if let` and `??` mean the same thing whether a template runs through the
interpreting renderer or the compiling back-end.

## Loops

Use `@for` to render arrays:

```plume
@for post in posts {
  <article>
    <h2>{post.title}</h2>
  </article>
}
```

Loop metadata is available through `forloop`:

```plume
@for item in items {
  <span>{forloop.index}</span>
}
```

Available loop values are:

- `forloop.index`, starting at 1.
- `forloop.index0`, starting at 0.
- `forloop.rindex`, counting down to 1.
- `forloop.rindex0`, counting down to 0.
- `forloop.first`.
- `forloop.last`.
- `forloop.length`.

## Comments

Use `@comment` when you want Plume to ignore a block entirely:

```plume
@comment {
  <p>This does not render.</p>
  @PostCard(post)
}
```

## Filters

Filters transform values:

```plume
{post.title | default("Untitled")}
{post.dateIso | date("d MMMM yyyy")}
{tags | join(", ")}
{content | raw}
```

The most common filters:

- `default(value)`: substitute for missing or empty values. The number `0` is kept.
- `date(format)`: format a date.
- `join(separator)`, `sort(field)`, `where(field, value)`, `map(field)`: work with arrays.
- `upcase`, `downcase`, `truncate(length)`, `slugify`: transform strings.

See [Filters](filters.md) for the complete reference, covering every string, array, number, date and output filter.

## Methods

Some values also support method-style calls:

```plume
@if post.urlPath.startsWith("/photos/") {
  <span>Photo post</span>
}

{post.title.replace(":", " - ")}
```

Useful methods include `contains`, `startsWith`, `endsWith`, `replace`, `replaceFirst`, `split`, `lowercased`, `uppercased` and `slugify`.

## Attributes

Plume includes helpers for common conditional attributes:

```plume
<a
  href="{post.urlPath}"
  class="nav-link"
  class:active="{isActive}"
  class+="{post.kind}"
  aria-current:page="{isActive}"
  target?="{target}"
>
  {post.title}
</a>
```

- `class:name="{condition}"` appends a class when the condition is true.
- `class+="{value}"` appends dynamic class names.
- `attribute?="{value}"` omits the attribute when the value is empty or false.
- `attribute:value="{condition}"` writes `attribute="value"` when true.
- `style:name="{value}"` binds an inline style property.

Style bindings work with ordinary properties and custom properties:

```plume
<span style:--offset="{offset}px" style:opacity="{visible ? 1 : 0}"></span>
```
