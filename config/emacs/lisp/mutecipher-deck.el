;;; mutecipher-deck.el --- Org -> minimalist slide-deck HTML  -*- lexical-binding: t -*-
;;
;; Custom Org export backend (derived from `ox-html') that turns an Org
;; document into a single self-contained HTML slide deck with keyboard
;; navigation, paper/mono themes, deep-link hashes, and a print stylesheet
;; pinned to US Letter landscape.
;;
;; Usage in any Org buffer:
;;   `C-c C-e d h'   export to <file>.html
;;   `C-c C-e d o'   export and open in default browser
;;
;; Document keywords (optional):
;;   #+TITLE:    Deck title
;;   #+SUBTITLE: kicker line shown on the auto-generated title slide
;;   #+AUTHOR:   byline
;;   #+DATE:     2026-05-12  (also drives the top-right chrome label)
;;   #+SLUG:     deck.talk   (top-left chrome label;
;;                            falls back to `mutecipher-deck-default-slug')
;;   #+CONTACT:  hello@example.com   (one line per #+CONTACT keyword;
;;   #+CONTACT:  github.com/handle    repeats accumulate into the
;;   #+CONTACT:  @handle@social.test  auto-generated closing slide)
;;   #+CLOSING:  Thank you.  (override the closing slide's headline;
;;                            optional, defaults to \"Thank you.\")
;;
;; Slide structure: each top-level `*` heading is one slide. Deeper
;; headings are dropped. Per-slide properties:
;;
;;   :LAYOUT:  center        -> applies `.slide.center'
;;   :KICKER:  text          -> small uppercase label above the heading
;;   :TYPE:    stat | quote  -> render heading as big-num or blockquote
;;                              instead of h1/h2
;;
;; Inline markup:
;;   /italics/               -> <em> (rendered with the accent underline)
;;   #+BEGIN_QUOTE ...        -> <blockquote>
;;   - bullet lists           -> <ul>
;;
;; Example minimal source:
;;
;;   #+TITLE: My Talk
;;   #+SUBTITLE: a lightning talk
;;   #+AUTHOR: Cory Hutchison
;;   #+DATE: 2026-05-12
;;   #+SLUG: mytalk.talk
;;
;;   * The opening hook.
;;   :PROPERTIES:
;;   :KICKER: somewhere off the Pacific coast
;;   :END:
;;
;;   * Care for life. Care for the chips.
;;   :PROPERTIES:
;;   :LAYOUT: center
;;   :TYPE: quote
;;   :END:

;;; Code:

(require 'ox)
(require 'ox-html)
(require 'cl-lib)
(require 'subr-x)

(defgroup mutecipher-deck nil
  "Org export to minimalist slide-deck HTML."
  :group 'org-export
  :prefix "mutecipher-deck-")

(defcustom mutecipher-deck-default-slug "deck.talk"
  "Default top-left chrome label when `#+SLUG' is not provided."
  :type 'string
  :group 'mutecipher-deck)

;; ─── Bundled CSS ─────────────────────────────────────────────────────────

(defconst mutecipher-deck--css
  "  :root,
  [data-theme=\"paper\"] {
    --bg: #ede0c4;
    --fg: #2a2419;
    --muted: #8a7a5a;
    --accent: #8b4513;
    --rule: #c4b48a;
    --vignette: rgba(40, 30, 10, 0.18);
  }
  [data-theme=\"mono\"] {
    --bg: #f5f5f3;
    --fg: #111111;
    --muted: #8a8a8a;
    --accent: #111111;
    --rule: #d4d4d2;
    --vignette: rgba(0, 0, 0, 0.14);
  }
  [data-theme=\"newsprint\"] {
    --bg: #f4f0e8;
    --fg: #1a1815;
    --muted: #75716a;
    --accent: #9a1f1f;
    --rule: #c9c2b3;
    --vignette: rgba(40, 30, 10, 0.15);
  }
  [data-theme=\"dark-paper\"] {
    --bg: #1f1d18;
    --fg: #e8dfc8;
    --muted: #7a7060;
    --accent: #d4a247;
    --rule: #3a342a;
    --vignette: rgba(0, 0, 0, 0.4);
  }
  [data-theme=\"amber\"] {
    --bg: #0d0700;
    --fg: #ffb000;
    --muted: #806020;
    --accent: #ffb000;
    --rule: #4a3010;
    --vignette: rgba(0, 0, 0, 0.5);
  }
  [data-theme=\"blueprint\"] {
    --bg: #1a3a52;
    --fg: #e8f0f5;
    --muted: #7a98ad;
    --accent: #7dd8ff;
    --rule: #2a4c66;
    --vignette: rgba(0, 0, 0, 0.35);
  }
  * { box-sizing: border-box; }
  html, body {
    margin: 0;
    padding: 0;
    height: 100%;
    overflow: hidden;
    background: var(--bg);
    color: var(--fg);
    font-family: ui-monospace, Menlo, Monaco, \"Cascadia Mono\", \"Roboto Mono\", \"Courier New\", monospace;
    font-weight: 400;
    -webkit-font-smoothing: antialiased;
  }

  body::before {
    content: \"\";
    position: fixed;
    inset: 0;
    pointer-events: none;
    z-index: 1;
    background-image:
      repeating-linear-gradient(0deg, color-mix(in srgb, var(--fg) 3%, transparent) 0 1px, transparent 1px 3px),
      repeating-linear-gradient(90deg, color-mix(in srgb, var(--fg) 3%, transparent) 0 1px, transparent 1px 3px);
  }
  body::after {
    content: \"\";
    position: fixed;
    inset: 0;
    pointer-events: none;
    z-index: 1;
    background: radial-gradient(ellipse at center, transparent 55%, var(--vignette) 100%);
  }

  main { position: relative; height: 100%; width: 100%; }

  .slide {
    display: none;
    position: absolute;
    inset: 0;
    padding: 7vw 9vw;
    flex-direction: column;
    justify-content: center;
    align-items: flex-start;
    gap: 1.4rem;
    line-height: 1.35;
    letter-spacing: -0.005em;
    z-index: 2;
  }
  .slide.active { display: flex; }
  .slide.center { align-items: center; text-align: center; }
  .slide.center .lines, .slide.center ul { align-items: center; text-align: center; }

  .lines {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
  }

  .slide h1 {
    font-size: clamp(2.4rem, 6.8vw, 5.6rem);
    font-weight: 700;
    letter-spacing: -0.02em;
    margin: 0;
    line-height: 1.1;
  }
  .slide h2 {
    font-size: clamp(1.9rem, 4.6vw, 3.6rem);
    font-weight: 600;
    letter-spacing: -0.01em;
    margin: 0;
    line-height: 1.2;
    max-width: 22ch;
  }
  .slide p {
    font-size: clamp(1.2rem, 2.4vw, 1.9rem);
    margin: 0;
    max-width: 28ch;
    font-weight: 500;
  }
  .slide .big-num {
    font-size: clamp(3rem, 9vw, 7.5rem);
    font-weight: 700;
    letter-spacing: -0.03em;
    line-height: 1;
    color: var(--accent);
  }
  .slide .meta {
    color: var(--muted);
    font-size: clamp(0.95rem, 1.5vw, 1.25rem);
    font-weight: 400;
  }
  .slide .kicker {
    color: var(--muted);
    font-size: clamp(0.85rem, 1.3vw, 1.1rem);
    font-weight: 400;
    letter-spacing: 0.18em;
    text-transform: uppercase;
  }
  .slide hr {
    border: 0;
    border-top: 1px solid var(--rule);
    width: 6rem;
    margin: 0.3rem 0;
  }
  .slide.center hr { margin-left: auto; margin-right: auto; }
  .slide em {
    font-style: normal;
    color: var(--accent);
    border-bottom: 2px solid var(--accent);
    padding-bottom: 1px;
  }
  .slide code {
    background: color-mix(in srgb, var(--fg) 15%, transparent);
    padding: 0.05em 0.35em;
    border-radius: 0.2em;
    font-size: 0.92em;
  }
  .slide img {
    display: block;
    max-width: 100%;
    max-height: 70vh;
    height: auto;
    width: auto;
    object-fit: contain;
    cursor: zoom-in;
  }
  .slide.has-media {
    display: none;
    flex-direction: row;
    align-items: center;
    justify-content: center;
    gap: 4rem;
  }
  .slide.has-media.active { display: flex; }
  .slide.has-media > .deck-left {
    flex: 1 1 50%;
    max-width: 50%;
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 1rem;
    min-width: 0;
  }
  .slide.has-media > .deck-left > * { max-width: 100%; }
  .slide.has-media > :is(img, figure) {
    flex: 0 1 50%;
    max-width: 50%;
    max-height: 78vh;
    margin: 0;
  }
  .slide.has-media > figure img {
    max-width: 100%;
    max-height: 78vh;
  }
  .slide.center:has(> :is(img, figure)):has(> :is(p, ul, blockquote)) :is(img, figure) {
    max-height: 38vh;
  }
  .slide figure {
    margin: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 0.6rem;
  }
  .slide figure figcaption {
    color: var(--muted);
    font-size: clamp(0.85rem, 1.3vw, 1.1rem);
  }
  .slide blockquote {
    margin: 0;
    font-size: clamp(1.9rem, 4.6vw, 3.6rem);
    font-weight: 600;
    letter-spacing: -0.01em;
    max-width: 20ch;
    line-height: 1.25;
  }
  .slide blockquote::before { content: \"“\"; color: var(--accent); margin-right: 0.1em; }
  .slide blockquote::after { content: \"”\"; color: var(--accent); margin-left: 0.05em; }

  .slide ul {
    list-style: none;
    padding: 0;
    margin: 0;
    display: flex;
    flex-direction: column;
    gap: 1rem;
    font-size: clamp(1.2rem, 2.4vw, 1.9rem);
    font-weight: 500;
  }
  .slide ul li::before {
    content: \"› \";
    color: var(--accent);
  }

  .lightbox {
    position: fixed;
    inset: 0;
    z-index: 100;
    background: color-mix(in srgb, var(--bg) 88%, black);
    display: none;
    align-items: center;
    justify-content: center;
    padding: 4vh 4vw;
    cursor: zoom-out;
  }
  .lightbox.open { display: flex; }
  .lightbox img {
    max-width: 100%;
    max-height: 100%;
    height: auto;
    width: auto;
    object-fit: contain;
  }

  .cursor {
    display: inline-block;
    width: 0.55em;
    height: 1em;
    background: var(--fg);
    vertical-align: -0.12em;
    margin-left: 0.18em;
    animation: blink 1.05s steps(2, end) infinite;
  }
  @keyframes blink { 50% { opacity: 0; } }

  .chrome {
    position: fixed;
    z-index: 5;
    color: var(--muted);
    font-size: 0.85rem;
    letter-spacing: 0.05em;
  }
  .chrome.tl { top: 1rem; left: 1.25rem; }
  .chrome.tr { top: 1rem; right: 1.25rem; }
  .chrome.bl { bottom: 1rem; left: 1.25rem; }
  .chrome.br { bottom: 1rem; right: 1.25rem; font-variant-numeric: tabular-nums; }

  header.progress {
    position: fixed;
    bottom: 0; left: 0; right: 0;
    padding: 0 1.25rem 1.6rem;
    z-index: 5;
    font-family: inherit;
    font-size: 0.85rem;
    color: var(--muted);
    letter-spacing: 0;
    pointer-events: none;
    text-align: center;
    white-space: nowrap;
    overflow: hidden;
  }

  @media (max-width: 640px) {
    .chrome { display: none; }
  }

  @page {
    size: 11in 8.5in;
    margin: 0;
  }

  @media print {
    html, body {
      overflow: visible;
      height: auto;
      width: 11in;
      margin: 0;
      padding: 0;
      background: white;
    }
    body::before, body::after { display: none; }
    .chrome, header.progress, .lightbox { display: none !important; }
    main {
      position: static;
      height: auto;
      width: 11in;
    }
    .slide {
      display: flex !important;
      position: relative;
      inset: auto;
      width: 11in;
      height: 8.5in;
      padding: 0.6in 0.9in;
      margin: 0;
      box-sizing: border-box;
      page-break-after: always;
      page-break-inside: avoid;
      break-after: page;
      break-inside: avoid;
      overflow: hidden;
    }
    .slide:last-child {
      page-break-after: auto;
      break-after: auto;
    }
    .slide h1 { font-size: 44pt; line-height: 1.1; }
    .slide h2 { font-size: 28pt; line-height: 1.2; max-width: 30ch; }
    .slide p { font-size: 16pt; line-height: 1.35; max-width: 55ch; }
    .slide ul { font-size: 16pt; gap: 0.5rem; }
    .slide .big-num { font-size: 72pt; line-height: 1; }
    .slide .meta { font-size: 11pt; }
    .slide .kicker { font-size: 9pt; letter-spacing: 0.18em; }
    .slide blockquote { font-size: 28pt; line-height: 1.25; max-width: 24ch; }
    .cursor { display: none; }
  }
"
  "Inline CSS bundled into every exported deck.")

;; ─── Bundled JS ──────────────────────────────────────────────────────────

(defconst mutecipher-deck--js
  "  const slides = document.querySelectorAll('.slide');
  const bar = document.getElementById('bar');
  const cur = document.getElementById('cur');
  const tot = document.getElementById('tot');
  const lb = document.getElementById('lightbox');
  const lbImg = document.getElementById('lightbox-img');
  const pad = (n) => String(n).padStart(2, '0');
  tot.textContent = pad(slides.length);

  function openLightbox(src, alt) {
    lbImg.src = src;
    lbImg.alt = alt || '';
    lb.classList.add('open');
    lb.setAttribute('aria-hidden', 'false');
  }
  function closeLightbox() {
    lb.classList.remove('open');
    lb.setAttribute('aria-hidden', 'true');
    lbImg.removeAttribute('src');
  }
  lb.addEventListener('click', closeLightbox);

  const THEMES = ['paper', 'mono', 'newsprint', 'dark-paper', 'amber', 'blueprint'];
  function setTheme(t) {
    document.documentElement.setAttribute('data-theme', t);
    try { localStorage.setItem('deck-theme', t); } catch (e) {}
  }
  function toggleTheme() {
    const c = document.documentElement.getAttribute('data-theme') || 'paper';
    const i = THEMES.indexOf(c);
    setTheme(THEMES[(i + 1) % THEMES.length]);
  }
  try {
    const saved = localStorage.getItem('deck-theme');
    setTheme(THEMES.includes(saved) ? saved : 'paper');
  } catch (e) { setTheme('paper'); }

  let current = 0;
  function indexFromHash() {
    const n = parseInt(location.hash.replace('#', ''), 10);
    if (Number.isFinite(n)) return Math.max(0, Math.min(slides.length - 1, n - 1));
    return 0;
  }
  function renderBar(i, total) {
    const width = 28;
    const ratio = total > 1 ? i / (total - 1) : 1;
    const filled = Math.round(ratio * width);
    return '[' + '█'.repeat(filled) + '░'.repeat(width - filled) + ']';
  }
  function go(i) {
    if (lb.classList.contains('open')) closeLightbox();
    current = Math.max(0, Math.min(slides.length - 1, i));
    slides.forEach((s, idx) => s.classList.toggle('active', idx === current));
    bar.textContent = renderBar(current, slides.length);
    cur.textContent = pad(current + 1);
    const newHash = '#' + (current + 1);
    if (location.hash !== newHash) history.replaceState(null, '', newHash);
  }

  document.addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (lb.classList.contains('open')) {
      if (e.key === 'Escape' || e.key === ' ' || e.key === 'Enter') {
        e.preventDefault();
        closeLightbox();
      }
      return;
    }
    switch (e.key) {
      case 'ArrowRight': case 'ArrowDown': case 'PageDown': case ' ': case 'j':
        e.preventDefault(); go(current + 1); break;
      case 'ArrowLeft': case 'ArrowUp': case 'PageUp': case 'k':
        e.preventDefault(); go(current - 1); break;
      case 'Home':
        e.preventDefault(); go(0); break;
      case 'End':
        e.preventDefault(); go(slides.length - 1); break;
      case 'f': case 'F':
        e.preventDefault();
        if (document.fullscreenElement) document.exitFullscreen();
        else document.documentElement.requestFullscreen();
        break;
      case 't': case 'T':
        e.preventDefault(); toggleTheme(); break;
    }
  });

  window.addEventListener('hashchange', () => go(indexFromHash()));
  document.addEventListener('click', (e) => {
    if (lb.classList.contains('open')) return;
    if (e.target.closest('a, button, input, textarea, select, summary, [data-no-nav]')) return;
    const img = e.target.closest('.slide img');
    if (img) {
      e.stopPropagation();
      openLightbox(img.src, img.alt);
      return;
    }
    if (window.getSelection && window.getSelection().toString()) return;
    go(e.clientX < window.innerWidth / 2 ? current - 1 : current + 1);
  });

  go(indexFromHash());
"
  "Inline JS bundled into every exported deck.")

;; ─── Helpers ─────────────────────────────────────────────────────────────

(defun mutecipher-deck--esc (s)
  "HTML-escape S for safe insertion as text content."
  (if (or (null s) (string-empty-p s))
      ""
    (org-html-encode-plain-text s)))

(defun mutecipher-deck--format-date (raw)
  "Normalise an Org date string RAW to the YYYY.MM.DD chrome format.
Accepts both ISO dates (2026-05-12) and Org timestamps (<2026-05-12 Tue>).
Anything else passes through unchanged."
  (cond
   ((or (null raw) (string-empty-p raw)) "")
   ((string-match "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)" raw)
    (format "%s.%s.%s"
            (match-string 1 raw)
            (match-string 2 raw)
            (match-string 3 raw)))
   (t raw)))

(defun mutecipher-deck--byline (author date)
  "Combine AUTHOR and DATE into a byline string, joined with a middle dot."
  (string-join
   (seq-remove #'string-empty-p (delq nil (list author date)))
   " · "))

(defun mutecipher-deck--title-slide (title subtitle author date)
  "Build the auto-generated title slide HTML.
DATE is the long-form date shown on the title slide (not the chrome short form)."
  (let ((byline (mutecipher-deck--byline author date)))
    (concat
     "<section class=\"slide center\">\n"
     (when (and subtitle (not (string-empty-p subtitle)))
       (format "  <div class=\"kicker\">%s</div>\n" (mutecipher-deck--esc subtitle)))
     (format "  <h1>%s<span class=\"cursor\"></span></h1>\n" title)
     "  <hr>\n"
     (when (not (string-empty-p byline))
       (format "  <p class=\"meta\">%s</p>\n" byline))
     "</section>\n")))

(defun mutecipher-deck--closing-slide (contact closing info)
  "Build the auto-generated closing slide HTML.
Returns nil unless CONTACT (one or more #+CONTACT: lines) is set.
CLOSING may be a string or a parsed Org-element list; INFO renders the
latter."
  (when (and contact
             (stringp contact)
             (not (string-empty-p (string-trim contact))))
    (let* ((heading-rendered
            (cond
             ((null closing) "")
             ((stringp closing) (mutecipher-deck--esc closing))
             (t (string-trim (or (org-export-data closing info) "")))))
           (heading (if (string-empty-p heading-rendered)
                        "Thank you."
                      heading-rendered))
           (lines (split-string contact "\n" t "[ \t]+")))
      (concat
       "<section class=\"slide center\">\n"
       (format "  <h1>%s</h1>\n" heading)
       "  <hr>\n"
       (mapconcat
        (lambda (l)
          (format "  <p class=\"meta\">%s</p>" (mutecipher-deck--esc l)))
        lines "\n")
       "\n</section>\n"))))

;; ─── Transcoders ─────────────────────────────────────────────────────────

(defun mutecipher-deck--extract-media (body)
  "Split BODY into a (TEXT-HTML . MEDIA-HTML) cons.
Top-level standalone <img> tags and <figure> blocks are pulled into
MEDIA-HTML so the headline transcoder can place them in a side column.
Everything else stays in TEXT-HTML.  Assumes `ox-html' output shape:
single-line lowercase tags, attribute values without literal `>'."
  (if (or (null body) (string-empty-p body))
      (cons "" "")
    (let ((text body)
          (media ""))
      (dolist (re '("\\(?:^\\|\n\\)[ \t]*\\(<img\\b[^<>]*/?>\\)[ \t]*"
                    "\\(?:^\\|\n\\)[ \t]*\\(<figure\\b[^>]*>\\(?:.\\|\n\\)*?</figure>\\)[ \t]*"))
        (while (string-match re text)
          (setq media (concat media (match-string 1 text) "\n"))
          (setq text (replace-match "" t t text))))
      (cons (string-trim text) (string-trim media)))))

(defun mutecipher-deck--headline (headline contents info)
  "Render a top-level Org HEADLINE as a <section class=\"slide\">.
Deeper headings and `:noexport:' subtrees are dropped. CONTENTS is the
already-rendered body. INFO is the export communication channel."
  (if (= 1 (org-export-get-relative-level headline info))
      (let* ((title (org-export-data
                     (org-element-property :title headline) info))
             (layout (downcase (or (org-element-property :LAYOUT headline) "")))
             (kicker (org-element-property :KICKER headline))
             (type (downcase (or (org-element-property :TYPE headline) "")))
             (centered (string= layout "center"))
             (body (and contents (string-trim contents)))
             (split (and (not centered) body
                         (mutecipher-deck--extract-media body)))
             (text-html (or (car split) ""))
             (media-html (or (cdr split) ""))
             (has-media (and split
                             (not (string-empty-p media-html))
                             (not (string-empty-p text-html))))
             (class (concat "slide"
                            (when centered " center")
                            (when has-media " has-media")))
             (title-html
              (cond
               ((string= type "stat")
                (format "<div class=\"big-num\">%s</div>" title))
               ((string= type "quote")
                (format "<blockquote>%s</blockquote>" title))
               (centered
                (format "<h1>%s</h1>" title))
               (t
                (format "<h2>%s</h2>" title))))
             (indent (if has-media "    " "  "))
             (head-html
              (concat
               (when kicker
                 (format "%s<div class=\"kicker\">%s</div>\n"
                         indent (mutecipher-deck--esc kicker)))
               (format "%s%s\n" indent title-html))))
        (concat
         (format "<section class=\"%s\">\n" class)
         (cond
          (has-media
           (concat "  <div class=\"deck-left\">\n"
                   head-html
                   "    " text-html "\n"
                   "  </div>\n"
                   "  " media-html "\n"))
          (t
           (concat head-html
                   (when (and body (not (string-empty-p body)))
                     (concat "  " body "\n")))))
         "</section>\n"))
    ""))

(defun mutecipher-deck--section (_section contents _info)
  "Drop ox-html's wrapping <div> for sections.  Just emit CONTENTS."
  (or contents ""))

(defun mutecipher-deck--paragraph (paragraph contents info)
  "Emit a plain <p> with CONTENTS, or just the image when CONTENTS is one.
Unwrapping standalone-image paragraphs makes the <img> a direct child of
the slide so the grid layout for image+text slides can target it."
  (let ((trimmed (string-trim (or contents ""))))
    (if (org-html-standalone-image-p paragraph info)
        trimmed
      (format "<p>%s</p>" trimmed))))

(defun mutecipher-deck--italic (_italic contents _info)
  "Render Org /italic/ as <em> so the deck's accent underline kicks in."
  (format "<em>%s</em>" contents))

(defun mutecipher-deck--quote-block (_quote-block contents _info)
  "Render an Org #+BEGIN_QUOTE block as <blockquote>."
  (format "<blockquote>%s</blockquote>" (string-trim (or contents ""))))

(defun mutecipher-deck--item (_item contents _info)
  "Render a list item without ox-html's inner <p> wrapper."
  (let ((c (string-trim (or contents ""))))
    (when (string-match "\\`<p>\\(\\(?:.\\|\n\\)*\\)</p>\\'" c)
      (setq c (match-string 1 c)))
    (format "<li>%s</li>" c)))

(defun mutecipher-deck--template (contents info)
  "Wrap the rendered slide CONTENTS in the deck's HTML page.
The title slide is generated from document keywords and placed first.
A closing slide is appended automatically when #+CONTACT is provided."
  (let* ((title (org-export-data (plist-get info :title) info))
         (subtitle (let ((s (plist-get info :subtitle)))
                     (if (listp s) (org-export-data s info) (or s ""))))
         (author (org-export-data (plist-get info :author) info))
         (date-raw (org-export-data (plist-get info :date) info))
         (date-chrome (mutecipher-deck--format-date date-raw))
         (slug (or (let ((s (plist-get info :slug)))
                     (when (and s (not (string-empty-p s))) s))
                   mutecipher-deck-default-slug))
         (contact (plist-get info :contact))
         (closing-heading (plist-get info :closing))
         (title-slide (mutecipher-deck--title-slide
                       title subtitle author date-raw))
         (closing-slide (mutecipher-deck--closing-slide
                         contact closing-heading info)))
    (concat
     "<!DOCTYPE html>\n"
     "<html lang=\"en\">\n"
     "<head>\n"
     "<meta charset=\"utf-8\">\n"
     "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
     (format "<title>%s</title>\n" (mutecipher-deck--esc title))
     "<style>\n"
     mutecipher-deck--css
     "</style>\n"
     "</head>\n"
     "<body>\n\n"
     (format "<div class=\"chrome tl\">%s</div>\n" (mutecipher-deck--esc slug))
     (format "<div class=\"chrome tr\">%s</div>\n"
             (mutecipher-deck--esc date-chrome))
     "<div class=\"chrome bl\">⌨ ← → · F · T · esc</div>\n"
     "<div class=\"chrome br\"><span id=\"cur\">01</span> / <span id=\"tot\">01</span></div>\n\n"
     "<header class=\"progress\"><span id=\"bar\"></span></header>\n\n"
     "<main>\n\n"
     title-slide
     "\n"
     contents
     (or closing-slide "")
     "</main>\n\n"
     "<div id=\"lightbox\" class=\"lightbox\" aria-hidden=\"true\">\n"
     "  <img id=\"lightbox-img\" alt=\"\">\n"
     "</div>\n\n"
     "<script>\n"
     mutecipher-deck--js
     "</script>\n"
     "</body>\n"
     "</html>\n")))

;; ─── Backend definition ──────────────────────────────────────────────────

(org-export-define-derived-backend 'mutecipher-deck 'html
  :menu-entry
  '(?d "Export to slide deck"
       ((?H "As HTML buffer" mutecipher-deck-export-as-html)
        (?h "As HTML file"   mutecipher-deck-export-to-html)
        (?o "As HTML file and open"
            (lambda (a s v b)
              (if a (mutecipher-deck-export-to-html t s v b)
                (org-open-file (mutecipher-deck-export-to-html nil s v b)))))))
  :options-alist
  '((:slug      "SLUG"     nil nil t)
    (:subtitle  "SUBTITLE" nil nil t)
    (:contact   "CONTACT"  nil nil newline)
    (:closing   "CLOSING"  nil nil t)
    (:with-toc  nil        "toc" nil)
    (:section-numbers nil  "num" nil))
  :translate-alist
  '((template    . mutecipher-deck--template)
    (headline    . mutecipher-deck--headline)
    (section     . mutecipher-deck--section)
    (paragraph   . mutecipher-deck--paragraph)
    (italic      . mutecipher-deck--italic)
    (quote-block . mutecipher-deck--quote-block)
    (item        . mutecipher-deck--item)))

;;;###autoload
(defun mutecipher-deck-export-as-html
    (&optional async subtreep visible-only body-only ext-plist)
  "Export current Org buffer to a deck HTML buffer.
See `org-export-to-buffer' for the meaning of ASYNC, SUBTREEP, VISIBLE-ONLY,
BODY-ONLY, and EXT-PLIST."
  (interactive)
  (org-export-to-buffer 'mutecipher-deck "*Org Deck Export*"
    async subtreep visible-only body-only ext-plist
    (lambda () (set-auto-mode t))))

;;;###autoload
(defun mutecipher-deck-export-to-html
    (&optional async subtreep visible-only body-only ext-plist)
  "Export current Org buffer to a self-contained deck HTML file.
See `org-export-to-file' for the meaning of ASYNC, SUBTREEP, VISIBLE-ONLY,
BODY-ONLY, and EXT-PLIST."
  (interactive)
  (let* ((extension (concat
                     (when (> (length org-html-extension) 0) ".")
                     (or (plist-get ext-plist :html-extension)
                         org-html-extension
                         "html")))
         (file (org-export-output-file-name extension subtreep))
         (org-export-coding-system org-html-coding-system))
    (org-export-to-file 'mutecipher-deck file
      async subtreep visible-only body-only ext-plist)))

(provide 'mutecipher-deck)
;;; mutecipher-deck.el ends here
