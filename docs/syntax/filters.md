# Filters

Filters transform a value before it is printed or compared. Chain them with `|`:

```plume
{post.title | default("Untitled") | upcase}
{tags | sort | join(", ")}
```

This page lists every built-in filter. Unknown filter names are reported as template errors, with a suggestion when the name is close to a real one.

## Strings

| Filter | What it does |
| --- | --- |
| `append(value)` | Adds text to the end |
| `prepend(value)` | Adds text to the start |
| `capitalize` | Uppercases the first character |
| `upcase` | Uppercases the whole string |
| `downcase` | Lowercases the whole string |
| `replace(target, replacement)` | Replaces every occurrence |
| `replaceFirst(target, replacement)` | Replaces the first occurrence |
| `remove(value)` | Deletes every occurrence |
| `removeFirst(value)` | Deletes the first occurrence |
| `split(separator)` | Turns a string into an array |
| `slice(start, length)` | Takes part of a string or array; negative starts count from the end |
| `truncate(length, omission)` | Shortens to a character length; the omission defaults to `...` |
| `truncateWords(count)` | Shortens to a word count with an ellipsis |
| `strip` | Trims whitespace from both ends |
| `lstrip` | Trims leading whitespace |
| `rstrip` | Trims trailing whitespace |
| `stripNewlines` | Removes newline characters |
| `stripHTML` | Removes HTML tags |
| `newlineToBR` | Turns newlines into `<br>` tags |
| `slugify` | Lowercases and hyphenates for URLs |
| `urlEncode` | Percent-encodes for use in URLs |
| `urlDecode` | Decodes percent-encoding |

## Arrays

| Filter | What it does |
| --- | --- |
| `first` | The first item |
| `last` | The last item |
| `size` | The number of items, or the length of a string |
| `map(field)` | Collects one field from each item |
| `where(field, value)` | Keeps items whose field matches |
| `sort(field)` | Sorts by a field, or by value without one |
| `sortNatural(field)` | Case-insensitive, human-friendly sort |
| `reverse` | Reverses the order |
| `unique` | Drops duplicate values |
| `compact` | Drops nil values |
| `concat(values)` | Appends another array |
| `join(separator)` | Combines items into a string |

## Numbers

| Filter | What it does |
| --- | --- |
| `plus(value)` | Addition |
| `minus(value)` | Subtraction |
| `times(value)` | Multiplication |
| `dividedBy(value)` | Division; dividing by zero returns 0 |
| `modulo(value)` | Remainder |
| `round(precision)` | Rounds, optionally to a number of decimal places |
| `abs` | Absolute value |
| `ceil` | Rounds up |
| `floor` | Rounds down |
| `atLeast(value)` | Clamps up to a minimum |
| `atMost(value)` | Clamps down to a maximum |

## Dates

Date filters accept ISO 8601 strings and Unix timestamps.

| Filter | What it does |
| --- | --- |
| `date(format)` | Formats with an ICU pattern such as `"d MMMM yyyy"`, or Liquid-style `%` patterns |
| `dateToString` | A short standard date |
| `dateToLongString` | A longer standard date |
| `dateToXMLSchema` | ISO 8601, useful for `<time datetime>` and JSON Feed |
| `dateToRFC822` | RFC 822, useful for RSS |

## Output

| Filter | What it does |
| --- | --- |
| `default(value)` | Substitutes when the value is missing, an empty string, an empty array or `false`; the number `0` is kept |
| `json` | Encodes the value as JSON |
| `escape` | HTML-escapes a string |
| `escape_once` | HTML-escapes without double-escaping existing entities |
| `raw` | Marks trusted content as safe HTML |

Use `raw` sparingly; see [Syntax](index.md) for how escaping works.
