import Foundation

/// CSS tuned for the Xteink X4: 4.3", 480×800 @ 220ppi, e-ink, no frontlight.
///
/// The CrossPoint renderer's internal format only retains word-level styles
/// (regular/bold/italic/bold-italic) and block-level alignment. Most
/// declarative CSS is therefore advisory; we still ship a clean stylesheet
/// because some readers (Calibre, KOReader, generic EPUB viewers) honor it,
/// and structural rules (tags, semantic order) are what really matter.
///
/// Goals on the X4 specifically:
///   - generous line-height for the small panel
///   - serif body for paper-like long-form
///   - tight side margins (the screen is small)
///   - justified text — CrossPoint does its own hyphenation
///   - no color (the panel is grayscale anyway)
///   - never use `font-family` for body text we can't ship; rely on the
///     reader's default serif so user font preference still applies
public enum X4Stylesheet {
    public static let css: String = """
    /* Send to X4 — e-ink stylesheet for the Xteink X4 */
    @namespace epub "http://www.idpf.org/2007/ops";

    @page {
      margin: 0.6em 0.5em;
    }

    html, body {
      margin: 0;
      padding: 0;
      color: #000;
      background: #fff;
      font-family: serif;
      font-size: 1em;
      line-height: 1.5;
      hyphens: auto;
      -epub-hyphens: auto;
      -webkit-hyphens: auto;
      orphans: 2;
      widows: 2;
    }

    body {
      padding: 0 0.5em;
    }

    p {
      margin: 0;
      text-align: justify;
      text-indent: 1.2em;
    }
    p + p { margin-top: 0; }

    /* First paragraph after a heading: no indent, looks better at chapter top */
    h1 + p, h2 + p, h3 + p,
    .chapter > p:first-of-type,
    .section-break + p {
      text-indent: 0;
    }

    h1, h2, h3 {
      font-weight: bold;
      text-align: left;
      page-break-after: avoid;
      break-after: avoid;
      hyphens: none;
      -webkit-hyphens: none;
      line-height: 1.25;
    }
    h1 {
      font-size: 1.4em;
      margin: 1.4em 0 0.6em;
      page-break-before: always;
      break-before: page;
      text-align: center;
    }
    h2 {
      font-size: 1.2em;
      margin: 1.2em 0 0.4em;
    }
    h3 {
      font-size: 1.05em;
      margin: 1em 0 0.3em;
    }

    blockquote {
      margin: 0.6em 0.4em;
      padding: 0 0.4em;
      font-style: italic;
      text-align: justify;
    }
    blockquote p { text-indent: 0; }

    em, i { font-style: italic; }
    strong, b { font-weight: bold; }

    a {
      color: inherit;
      text-decoration: underline;
    }

    /* The X4 renderer doesn't honor `code` font, so we keep them inline */
    code, pre, kbd, samp {
      font-family: monospace;
      font-size: 0.95em;
    }
    pre {
      white-space: pre-wrap;
      word-wrap: break-word;
      margin: 0.6em 0;
      padding: 0.4em 0.5em;
      border-left: 1pt solid #000;
    }

    ul, ol {
      margin: 0.4em 0 0.4em 1.2em;
      padding: 0;
    }
    li { margin: 0.15em 0; text-align: left; }

    figure { margin: 0.8em 0; text-align: center; page-break-inside: avoid; break-inside: avoid; }
    figcaption {
      font-size: 0.9em;
      text-align: center;
      margin-top: 0.2em;
      font-style: italic;
    }

    img, svg {
      max-width: 100%;
      height: auto;
      display: block;
      margin: 0.6em auto;
    }

    hr.section-break {
      border: 0;
      text-align: center;
      margin: 1em 0;
      overflow: visible;
    }
    hr.section-break::after {
      content: "* * *";
      letter-spacing: 0.4em;
      font-size: 0.9em;
    }

    /* Cover page: title-card layout */
    body.cover {
      padding: 2em 1em;
      text-align: center;
    }
    .cover-title {
      font-size: 1.6em;
      font-weight: bold;
      line-height: 1.2;
      margin: 1.5em 0 0.4em;
      hyphens: none;
      -webkit-hyphens: none;
    }
    .cover-author {
      font-size: 1em;
      font-style: italic;
      margin: 0.5em 0;
    }
    .cover-source {
      font-size: 0.85em;
      margin-top: auto;
      letter-spacing: 0.05em;
      text-transform: uppercase;
    }
    .cover-rule {
      width: 30%;
      border: 0;
      border-top: 0.5pt solid #000;
      margin: 1.2em auto;
    }

    /* Endnotes-style footnotes */
    .footnotes {
      margin-top: 2em;
      font-size: 0.92em;
    }
    .footnotes h2 {
      text-align: left;
      page-break-before: always;
      break-before: page;
    }
    .footnotes ol { margin-left: 1.4em; }
    .footnotes li { margin: 0.4em 0; }

    /* Tables — collapse to single column flow on small panels */
    table { width: 100%; border-collapse: collapse; margin: 0.6em 0; }
    th, td { padding: 0.2em 0.3em; border-bottom: 0.25pt solid #000; text-align: left; }
    """
}
