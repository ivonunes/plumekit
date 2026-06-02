module.exports = grammar({
  name: 'plume',

  extras: $ => [],

  rules: {
    source_file: $ => repeat(choice(
      $.directive,
      $.control_word,
      $.component,
      $.interpolation,
      $.html_tag,
      $.comment,
      $.string,
      $.punctuation,
      $.text
    )),

    directive: $ => token(seq('@', choice(
      'if',
      'for',
      'let',
      'component',
      'slot',
      'content',
      'style',
      'script',
      'navigation',
      'image',
      'state',
      'fragment',
      'raw'
    ))),

    control_word: $ => token(choice('else if', 'else')),

    component: $ => token(seq('@', /[A-Z][A-Za-z0-9_]*/)),

    interpolation: $ => token(seq('{', /[^{}\n]+/, '}')),

    html_tag: $ => token(seq(
      '<',
      optional('/'),
      /[A-Za-z][A-Za-z0-9:-]*/,
      /[^>\n]*/,
      '>'
    )),

    comment: $ => token(choice(
      seq('@comment', /[^\n]*/),
      seq('<!--', /[^\n]*-->/)
    )),

    string: $ => token(choice(
      seq('"', repeat(choice(/[^"\\]+/, /\\./)), '"'),
      seq("'", repeat(choice(/[^'\\]+/, /\\./)), "'")
    )),

    identifier: $ => /[A-Za-z_][A-Za-z0-9_.-]*/,
    number: $ => /[0-9]+(?:\.[0-9]+)?/,
    operator: $ => choice('==', '!=', '<=', '>=', '&&', '||', '=', '+', '-', '*', '/', '<', '>', '!', '.', ',', '|'),
    punctuation: $ => token(choice('{', '}', '(', ')', '[', ']', ':')),
    text: $ => token(/[^@{}<'"\s]+|\s+|./)
  }
});
