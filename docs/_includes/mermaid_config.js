{%- comment -%}
  Diagram palette, matched to the page's color scheme.

  The theme splices this object into `var config = ...` in the page footer, long
  after head_custom.html has run, so the shared helper it exposes is the single
  source of truth for the precedence (an explicit saved choice first, otherwise
  the operating system preference) and for the storage key.

  Mermaid resolves its palette when it initializes, once per page load. A diagram
  already on screen therefore keeps the previous palette after an in-page toggle
  until the next navigation or reload; every fresh page load is correct, which is
  what this aims for.

  The prose lives in this Liquid comment rather than in JavaScript comments on
  purpose: the theme compresses each rendered page onto a single line, so a `//`
  comment here would swallow the object it is meant to describe. A Liquid comment
  emits nothing at all, so there is nothing left to swallow.
{%- endcomment -%}
{
  theme:
    window.docsColorScheme && window.docsColorScheme.current() === 'dark'
      ? 'dark'
      : 'default',
}
