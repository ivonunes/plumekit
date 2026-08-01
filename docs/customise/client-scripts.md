# Client scripts

`@script` blocks use Plume's client script language: a small, declarative way to wire up page behaviour that compiles to plain JavaScript. This page is the language reference. For when to reach for scripts at all, see [Behaviour](behaviour.md).

A script queries elements, declares variables and attaches event handlers:

```plume
@script {
  let menu = page.query("#menu")
  var open = false

  on ".menu-toggle".click {
    event.preventDefault()
    open = !open
    menu.toggleClass("is-open", when: open)
    menu.setText(open ? "Close" : "Menu")
  }
}
```

## Declarations

- `let name = value`: a constant.
- `var name = value`: a mutable variable.

Values can be strings, numbers, booleans, element queries and expressions built from them.

## Queries

- `page.query(selector)`: the first matching element.
- `page.queryAll(selector)`: all matching elements, for loops.

Loop over a query to touch every match:

```plume
@script {
  for card in page.queryAll(".card") {
    card.addClass("ready")
  }
}
```

## Events

`on` blocks attach event handlers:

```plume
@script {
  on ".menu-toggle".click {
    ...
  }

  on page.scroll {
    page.toggleClass("is-scrolled", when: page.scrollY > 24)
  }
}
```

The target can be a selector string, a queried element or `page`. Inside a handler, `event` provides `event.value` for form controls, `event.target` and `event.preventDefault()`.

## Element methods

| Method | Effect |
|--------|--------|
| `element.addClass(name)` | adds a class |
| `element.removeClass(name)` | removes a class |
| `element.toggleClass(name)` | toggles a class |
| `element.toggleClass(name, when: condition)` | sets the class from a condition |
| `element.setText(value)` | sets the element's text content |
| `element.setAttribute(name, value)` | sets an attribute |
| `element.removeAttribute(name)` | removes an attribute |
| `element.setStyle(property, value)` | sets an inline style property |
| `element.removeStyle(property)` | removes an inline style property |
| `element.focus()` | focuses the element |
| `element.blur()` | removes focus from the element |

## Page values and actions

- `page.addClass`, `page.removeClass`, `page.toggleClass`: class helpers on the document element.
- `page.scrollTo(...)` and `page.scrollToTop(...)`: scrolling helpers.
- `page.scrollY`, `page.scrollX`, `page.width` and `page.height`: read-only values for conditions.

## Control flow

- `if condition { ... } else { ... }`
- `for item in items { ... }`
- Ternaries and `&&`, `||` and `!` work in expressions.

## Scoped scripts

Inside `@script(scoped)`, `root` is the rendered fragment's top-level element, and the script runs once per rendered fragment. See [Resources](resources.md).

## Raw JavaScript

When you need browser APIs outside this language, drop down explicitly:

```plume
@script(language: "javascript") {
  document.documentElement.dataset.enhanced = "true";
}
```

Raw JavaScript is emitted as a module and does not get `root`, `page` or `on` blocks.

## Errors

Client scripts are checked at template-check time. Unsupported statements and methods are reported with file, line and column, so typos fail the build instead of failing in the browser.
