{
  // Diagram palette, matched to the page's color scheme.
  //
  // The theme splices this object into `var config = ...` in the page footer,
  // long after head_custom.html has run, so the shared helper it exposes is the
  // single source of truth for the precedence (an explicit saved choice first,
  // otherwise the operating system preference) and for the storage key.
  //
  // Mermaid resolves its palette when it initializes, once per page load. A
  // diagram already on screen therefore keeps the previous palette after an
  // in-page toggle until the next navigation or reload; every fresh page load
  // is correct, which is what this aims for.
  theme:
    window.docsColorScheme && window.docsColorScheme.current() === 'dark'
      ? 'dark'
      : 'default',
}
