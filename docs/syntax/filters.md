# Filters

Filters transform a value before it is printed or compared. Chain them with `|`:

```plume
{post.title | default("Untitled") | upcase}
{tags | sort | join(", ")}
```

This page lists every built-in filter. Unknown filter names are reported as template errors, with a suggestion when the name is close to a real one.

## Strings

- `append(value)`: add text to the end.
- `prepend(value)`: add text to the start.
- `capitalize`: uppercase the first character.
- `upcase`: uppercase the whole string.
- `downcase`: lowercase the whole string.
- `replace(target, replacement)`: replace every occurrence.
- `replaceFirst(target, replacement)`: replace the first occurrence.
- `remove(value)`: delete every occurrence.
- `removeFirst(value)`: delete the first occurrence.
- `split(separator)`: turn a string into an array.
- `slice(start, length)`: take part of a string or array. Negative starts count from the end.
- `truncate(length, omission)`: shorten to a character length. The omission defaults to `...`.
- `truncateWords(count)`: shorten to a word count with an ellipsis.
- `strip`: trim whitespace from both ends.
- `lstrip`: trim leading whitespace.
- `rstrip`: trim trailing whitespace.
- `stripNewlines`: remove newline characters.
- `stripHTML`: remove HTML tags.
- `newlineToBR`: turn newlines into `<br>` tags.
- `slugify`: lowercase and hyphenate for URLs.
- `urlEncode`: percent-encode for use in URLs.
- `urlDecode`: decode percent-encoding.

## Arrays

- `first`: the first item.
- `last`: the last item.
- `size`: the number of items, or the length of a string.
- `map(field)`: collect one field from each item.
- `where(field, value)`: keep items whose field matches.
- `sort(field)`: sort by a field, or by value without one.
- `sortNatural(field)`: case-insensitive, human-friendly sort.
- `reverse`: reverse the order.
- `unique`: drop duplicate values.
- `compact`: drop nil values.
- `concat(values)`: append another array.
- `join(separator)`: combine items into a string.

## Numbers

- `plus(value)`, `minus(value)`, `times(value)`: arithmetic.
- `dividedBy(value)`: division. Dividing by zero returns 0.
- `modulo(value)`: remainder.
- `round(precision)`: round, optionally to a number of decimal places.
- `abs`: absolute value.
- `ceil`: round up.
- `floor`: round down.
- `atLeast(value)`: clamp up to a minimum.
- `atMost(value)`: clamp down to a maximum.

## Dates

Date filters accept ISO 8601 strings and Unix timestamps.

- `date(format)`: format with an ICU pattern such as `"d MMMM yyyy"`, or Liquid-style `%` patterns.
- `dateToString`: a short standard date.
- `dateToLongString`: a longer standard date.
- `dateToXMLSchema`: ISO 8601, useful for `<time datetime>` and JSON Feed.
- `dateToRFC822`: RFC 822, useful for RSS.

## Output

- `default(value)`: substitute when the value is missing, an empty string, an empty array or `false`. The number `0` is kept.
- `json`: encode the value as JSON.
- `escape`: HTML-escape a string.
- `escape_once`: HTML-escape without double-escaping existing entities.
- `raw`: mark trusted content as safe HTML. Use sparingly; see [Syntax](index.md).
