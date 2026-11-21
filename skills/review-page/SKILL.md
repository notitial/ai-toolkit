---
description: "Build one local review page that shows two or more real options as rendered previews side by side, with a recommendation, Pick buttons, notes and one JSON block to paste back. Run /review-page, or use it when asked for a 'review page', an 'options page' or to 'show me the options side by side' for a screen, layout or flow the person should see before deciding."
disable-model-invocation: false
---

# Review Page

Write one HTML file that lets the person look at the real options, pick, comment and paste one JSON block back. The previews are the app's real markup in real frames, not drawings of it.

## The page is disposable

The page is made for one session and one decision. It has no tests; nobody maintains or reviews it; delete it freely. It is a local file opened in Chrome and is never published, uploaded or committed. Do not polish it beyond what the decision needs.

## When to use

- Two or more real options the person should see: screens, layouts, flows, wording in context.
- Not for a yes/no that fits one chat question, and not for a choice with nothing visual to compare.

## Steps

1. Check that `.archive/` exists and is gitignored (`git check-ignore .archive`). If not, stop and ask where to write.
2. Copy the kit: `cp ~/.claude/skills/review-page/page.html .archive/review/<topic>-YYYY-MM-DD.html` (`mkdir -p` first; `-r2`, `-r3` for a later round). Each round is a new file holding only what is still open.
3. Replace the example spec with one Edit: only the text between `SPEC START` and `SPEC END`. Never edit the kit part; that drifts the export. Start from the app's real markup and stylesheets (below).
4. Open it: `open -a "Google Chrome" <absolute path>`. If that is blocked, give the person the bare absolute path.
5. Tell the person what to do in one line: pick, add notes, press "Copy the JSON", paste it back.

## The spec

```js
window.REVIEW = {
  title: '', intro: ['one or two short paragraphs'],
  preview: { css: ['../../app/dist/styles.css'], head: '' },
  controls: [{ id: 'signal', label: 'Signal', values: [['good', 'Good'], ['down', 'Down']] }],
  sections: [
    { id: 'start', title: 'Start page', rec: 'B', why: 'the reason and what it costs',
      opts: [
        { k: 'A', t: 'Stacked', b: 'one-line blurb', html: (c) => `<main>...</main>` },
        { k: 'B', t: 'Live app', b: '', src: (c) => `http://localhost:5173/start?signal=${c.signal}` }
      ] },
    { id: 'back', title: 'Keep the back button?', rec: 'yes', why: '' }
  ]
};
```

- A section with `opts` is a choice; without `opts` it is a yes/no item (`rec` is `yes` or `no`). `rec` and `why` give the visible recommendation; every section gets one, with its cost. Never pre-pick an option.
- An option has exactly one preview: `html` (a string, or a function of the controls) or `src` (a URL, or a function). With neither, the page shows a dashed "No preview for this option" box.
- The function argument is `{ theme, width, ...page controls }`: `theme` is the resolved `light` or `dark`, `width` is 390, 768 or 1280.
- Ids are plain words: no `::`; `note` is reserved as an option key; `theme` and `width` are reserved control ids.
- Escaping, all together: inside a template string write `` \` `` for a backtick, `\${` for a literal `${`, and `<\/script>` for a closing script tag. A real closing script tag ends the whole spec.
- Paths in `preview.css` and in markup are relative to the page file. Moving the page breaks them.

## Real markup, in this order

Previews must show what the app would actually render. Use the first that fits:

1. `src`: the app's own dev server on localhost. The real app, only sized by the kit.
2. Built output: the app's compiled stylesheet linked in `preview.css`, with the markup using its real class names.
3. Static HTML using the app's real class names with the app's real stylesheet linked.
4. A screen not built yet: write the proposed tokens once in `preview.head` and label them "proposed" in a comment.

Screenshots go in as `<img>` inside `html`. Never invent a look in place of the app's own, and never re-draw the app's components with made-up classes.

## What the page does

- Toolbar: Theme (Device, Light, Dark), Width (Phone 390x780, Tablet 768x1024, Laptop 1280x800), the spec's own controls, and an answered count. Light and dark apply to the page and to every frame.
- Options sit side by side, up to three per row on Phone, two on Tablet and three on Laptop, scaled down to fit the column. The caption under each preview shows the real width and the scale ("1280 px, shown at 30%"); a `src` caption also shows the URL.
- Picks, notes and controls are saved per file path in `localStorage` and survive a reload. Reset clears them after a confirm.

## Limits

State these to the person when one applies.

- Each frame is set up with the iframe's own `color-scheme` style, plus a `<meta name="color-scheme">`, a root `color-scheme` and `data-theme` / `dark` / `light` hooks inside. The iframe element's style is required: a frame with only the meta tag and root style follows the device scheme instead of the control. A spike in Chrome on `file://` confirmed width media queries, `prefers-color-scheme`, and relative stylesheets, images and `@font-face` all work this way.
- A `file://` page runs no ES modules and no `fetch` of local files, so an `html` preview is static markup, CSS, assets and classic inline scripts. A framework app's runtime does not run; use `src`.
- CSS that needs a build (utility frameworks, Sass, CSS modules) must be linked from the built output.
- `src` frames are cross-origin: theme reaches them only through `color-scheme`, page controls only through the URL, and an app that forbids framing shows blank.
- An app themed by a hook other than `data-theme`, a `dark` / `light` class or the media query needs that hook written into `preview.head`.
- Every frame has the fixed viewport height, with scrolling inside it; a sticky bottom bar shows where it really sits.
- Any control change rebuilds the frames, so in-frame state (an open pop-up) resets.
- Web screens only. Native-app screens are out of scope: show them as an `<img>` inside `html`.
- An `html` preview is not sandboxed: a script in it shares the page's storage and can clear or change the saved review.

## The export

"Copy the JSON" gives one object, always these six keys in this order:

```json
{
  "page": "start-page-2026-11-21-r2",
  "picks": { "start": "B", "back": "yes" },
  "notes": { "start": { "A": "too tall", "B": "yes, but keep the icon" }, "back": { "note": "only on Android" } },
  "general": "",
  "unanswered": ["loading"],
  "shownAt": { "theme": "dark", "width": 390, "signal": "down" }
}
```

`page` is the file's base name. `picks` holds only answered sections (an option letter, or `yes` / `no`). `notes` holds only non-empty trimmed notes, keyed by section then option (`note` for a yes/no item). `shownAt.theme` is the resolved `light` or `dark`, not `device`.

## Reading it back

- Check that `page` matches the file you wrote; a paste from an older round names that round.
- `picks` are decisions. `notes` are change requests: read them on unpicked options too.
- For `unanswered` or a structural gap, ask one blocking question.
- Quote the notes you act on in the decision record. The next round is a new file holding only what is still open.

## Don't

- Publish, upload or commit the page, or load anything from the network except a `src` on localhost.
- Pre-pick an option, or add progress strips, identity tags or explanation banners inside the previews.
- Edit the kit part of a page, or add a test or a build step for it.
- Let a page grow slow: when it does, split it by question.
