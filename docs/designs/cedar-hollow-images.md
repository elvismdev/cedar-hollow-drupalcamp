# Cedar Hollow DrupalCamp: an image pipeline

*   **Author:** Elvis Morales
*   **Status:** Approved
*   **Date:** 2026-10-29

--------------------------------------------------------------------------------

## Overview

Cedar Hollow DrupalCamp is the fictional Drupal 11 event site described in its main design document, `docs/designs/cedar-hollow-drupalcamp.md` (called "the main design" below). The main design defines three contracts that several files share: C1 the `/api/agenda` response, C2 the seats display states and C3 the fixed values. Today the site shows no images: the speaker photo field is empty for every speaker, sessions have no image field, the home page has no hero, and the components that accept an image are never given one.

This design adds images to the site and the image pipeline behind them, built from Drupal core, the Focal Point module and its dependency Crop API. Editors keep each photo once, as a Media item with its licence recorded. On the formatter path described below, Drupal crops each photo around a focal point the editor chooses, converts it to AVIF and serves the size the visitor's screen needs. The home page gets a hero image, sessions get images on the listing and on their own pages, speakers get images of their workspaces rather than their faces, and session descriptions become rich text that can embed images with captions. A credits page lists every shipped photo with its title, creator and licence.

The site renders images in two places:

*   **The formatter path:** Media rendered by Drupal's field formatters through responsive image styles. It carries the whole pipeline: ratio-named image styles, Focal Point crops, AVIF, `srcset` and `sizes`, and eager loading with `fetchpriority` for the image each page shows first. The hero, session images, session cards, speaker images, embedded images and the credits thumbnails use it.
*   **The Canvas path:** image props on components placed in Drupal Canvas. Canvas resolves them through its own scale-only image style and its own `srcset` filter, so Focal Point and the site's image styles do not apply there; Canvas images are scaled, not cropped. The featured card and quote components use it, and editors pick their images from the same Media library.

## The Problem

The site has no images, so it does not show how its author handles them. Images are usually the largest files on a page and the most common LCP (Largest Contentful Paint) element, and they cause CLS (Cumulative Layout Shift) when no space is reserved for them (HTTP Archive, Web Almanac 2024, Media and Performance chapters). Without images the demo also does not look like a real event.

Images in Drupal also have problems that appear only on a running site:

*   Image styles named after the page that uses them ("Homepage news") multiply and cannot be reused.
*   Two open core issues (#3516726 and #3523451) make responsive image output carry the `width` and `height` of another image style in the mapping. When one responsive image style mixes aspect ratios, the reserved space is wrong and the page shifts.
*   Core makes every formatted image lazy by default and has no `fetchpriority` setting, so the most important image on a page loads late unless the theme says otherwise.
*   Core's "Convert to AVIF" falls back to another format only when the server's image toolkit cannot encode AVIF. It is not a fallback for browsers.
*   Focal Point stores each crop as a separate entity that a media export does not include, so crops are lost on a rebuild unless they are exported on their own.
*   Exporting a node does not export the media embedded in its text.
*   A recipe never replaces configuration that already exists, so a recipe that composes core's media recipe cannot override its form displays by shipping its own copies.
*   Canvas renders image props through its own pipeline, separate from the site's image styles.

The task is to add images that make the site look like a real event and to build the pipeline behind them so that each problem above is handled, tested where a test can catch it, and explained in the write-up. Everything rebuilds from the repository, and the live Pantheon site receives the images without losing reviewer accounts or reviewer activity. Where this work changes a statement in the main design, that statement is amended in the same commit.

A separate problem surfaced while measuring: on a phone, the main menu collapses after the page first paints, which moves the whole page (image spike I5 recorded a CLS of 0.069 on the home page before any image existed). No image work can meet a CLS target while that shift remains, so this design fixes it.

### Image spikes

These checks were run before the design was written, on a DDEV snapshot that was restored afterwards. Item 1 records them in `docs/spikes.md`.

| Spike | Result |
| --- | --- |
| I1 | Creating an Image media type gives the featured card and quote a new Canvas component version whose image prop references Media through the Media Library widget; stored Canvas pages do not change. |
| I2 | Focal Point 2.1.3 with Crop API 2.6.0 crops a 4.9 MB photo to a 1600x900 AVIF of 194 KB at the focal point. `content:export media --with-dependencies` exports the file but not the crop; `content:export crop` exports it with its file as a UUID, and a recipe import restores it linked to the right file. |
| I3 | `content:export node --with-dependencies` does not export media embedded in a text field. |
| I4 | A responsive image style of one 16:9 ratio, the formatter set to eager and `#attributes['fetchpriority']` render `<img loading="eager" fetchpriority="high">` with an AVIF `srcset`, `width` and `height`. A block placed with front-page visibility renders on the Canvas home page only. |
| I5 | Lighthouse mobile on DDEV, home page, no images: LCP 0.8 s, CLS 0.069. The only layout shift comes from the main menu collapsing about 100 ms after load. |
| I6 | On Pantheon Dev, scale and crop plus Convert to AVIF takes 776 ms at 800x450 (76 KB) and 1623 ms at 1600x900 (195 KB) for the first request. |

## Goals

Every goal must ship. Each names the check that shows it was met.

1.  **One image pipeline on the formatter path, with ratio-named styles.** Image styles exist for three aspect ratios, 16:9 (hero, session images and wide embeds), 3:2 (cards and photo embeds) and 1:1 (speakers and credits), named by ratio and width (for example `16_9_1280` and `3_2_800`). Widths come from each slot's rendered size at the device pixel ratios phones and desktops use. Each style applies Focal Point's scale and crop, then core's Convert to AVIF. Check: the rebuild check generates a `16_9_640` derivative and asserts it is AVIF at 640x360.
2.  **One aspect ratio per responsive image style.** Every responsive image style maps only image styles of a single ratio, and its fallback style is one of them, so the reserved space is right whichever style core takes `width` and `height` from. Check: a unit test fails if any responsive image style mixes ratios or maps a style that does not crop.
3.  **The image a page shows first is fetched first.** The home page hero and the session page image render with `loading="eager"` and `fetchpriority="high"`; session cards render eager; every other image is lazy. Check: Playwright asserts these attributes, and the Lighthouse check fails if the LCP element on `/` is not `img.hero__img` or if any measured page's LCP image is lazy.
4.  **Every shipped image has a recorded open licence and a complete attribution.** One Image media type stores the source URL, creator, licence and licence URL for each photo; all four are required, and only CC0, public domain and CC BY pass validation. The credits page lists every shipped image with its title, creator, licence (linked) and source, and states that the images were cropped, resized and converted to AVIF. Check: a functional test asserts validation violations for a missing licence field or another licence, on the entity and on the Media Library add form; Playwright asserts the modification notice and titles; the credits page passes axe.
5.  **No identifiable person appears in any shipped image.** The fetch script refuses Commons files marked with the personality-rights template, speaker images show workspaces, laptops, hands or silhouettes, and every shipped image is reviewed by hand, with the date recorded in the manifest, before the image script will mark it verified. Alt text describes what the image shows. Check: the fetch script's refusal (shown refusing a marked file), and the manual review of every image and its alt text recorded in `docs/checks.md`.
6.  **Sessions and speakers have images.** Session cards show a 3:2 image, session pages show a 16:9 image, and speaker bylines show a 1:1 image, each with `sizes` derived from its layout. Check: Playwright asserts the image and its attributes on the listing, a session page and a speaker byline.
7.  **Session descriptions can embed images with captions.** Session bodies use a rich-text format whose only image markup is an embedded Media item, in a 16:9 or 3:2 view mode, inside a `figure` with a `figcaption` no wider than the image. Check: a functional test shows the embed rendering in each view mode and disallowed markup removed.
8.  **The site rebuilds with its images and crops.** A rebuild from the repository restores every media item, file and focal point. Check: after `scripts/rebuild.sh`, a check confirms every exported Image media and crop exists with the same crop coordinates, every exported file exists, and the committed originals are within their size budget.
9.  **The page does not move on a phone.** The main menu collapses before first paint. Check: with images loading, a Playwright test sums the `layout-shift` values without recent input on `/` at 412 by 823 CSS pixels and expects 0.
10. **The performance target is met and measured the same way every time.** On DDEV, Lighthouse's default mobile configuration, median of five runs per page, reports LCP under 2.5 s and CLS under 0.1 on `/`, `/sessions` and `/sessions/caching-render-arrays`. CI runs it on the site built from the repository. One Pantheon Dev run, taken after every image derivative has been requested, is recorded with date, commit, method and server response time. Check: the CI step passes; the Pantheon result is in `docs/checks.md`.
11. **Accessibility scans still pass.** axe-core with the existing tags reports zero violations on every page in the main design's Goal 8 list plus `/credits`. Check: the Playwright accessibility suite.
12. **The contracts and the write-up describe what was built.** The main design gains an images contract C4 beside C1 to C3, and the statements this work makes untrue are corrected in the same commit. `docs/how-this-was-built.md` gains a section on the image problems and how each was checked. Check: each superseded statement is changed, and each claim in the write-up section names its evidence.

## Non-Goals

*   **A browser-side AVIF fallback.** Images are served as AVIF only, and the write-up states that core's fallback applies only on the server. The supported browsers (below) all decode AVIF.
*   **Browsers older than Chrome and Edge 121, Safari 17 and Firefox 117.** The main design targets browsers with CSS nesting, cascade layers and container queries; this design raises that floor to the versions that also decode AVIF and support the `scripting` media feature, and amends the main design's browser non-goal to match.
*   **Focal Point and the site's image styles on Canvas image props.** Canvas keeps its own scale-only path. Editors choose Canvas images from the shared Media library, and the Focal Point widget is not shown where Canvas uploads, because it would have no effect there.
*   **Art direction.** No image changes its crop or subject between screen sizes, so `<picture>` with per-breakpoint sources is not used.
*   **Other media types.** No video, audio, document or remote media types.
*   **Image optimisation services or modules.** No CDN image service, no Image Optimize pipelines and no module that pre-generates derivatives; a warm-up step covers deploys and measurement.
*   **Images under CC BY-SA or any licence other than CC0, public domain and CC BY.**
*   **Generated alt text.** Alt text is written and reviewed by hand. Two roles are decorative and render an empty alt: session-card and speaker-byline photos, because the heading or name beside them carries the meaning and a description of a stock photo next to a speaker's name can read as a portrait of that person. The hero, the session page image, embedded figures and the credits thumbnails keep their descriptions.
*   **Edge caching.** The main design keeps page max-age at 0; the server response time this costs is recorded next to LCP rather than tuned away.

## Open Questions

*   **The Media Library check.** Two facts are read on the site when item 6 is built, before it is committed, and recorded in `docs/spikes.md`: the permissions `demo_editor` needs for Canvas's Media Library widget to pick and upload images (from Canvas's and Media Library's route access), and whether the Media Library add form refuses an upload without the licence fields. If it does not refuse it, a form alter on the `media_library` form mode makes them required. `DemoEditorAccessTest` and `MediaLicenceTest` then assert the result.

## Critical User Journeys (CUJs)

### CUJ 1: A visitor on a phone opens the home page

*   **Given**: A phone-sized screen and a mobile network, on the home page of the site built from the repository.
*   **When**: The page loads.
*   **Then**: The hero image is requested first, at a size that fits the screen, as AVIF; the page does not move as images and the menu script load; and Lighthouse's mobile configuration reports LCP under 2.5 s and CLS under 0.1.

### CUJ 2: A visitor browses sessions

*   **Given**: The session listing.
*   **When**: The visitor scrolls the cards and opens a session.
*   **Then**: The cards' 3:2 images load with the page; the session page shows its 16:9 image first, the speaker's 1:1 workspace image, and any image embedded in the description inside a figure with its caption; every image has alt text that describes it.

### CUJ 3: An editor adds an image in Canvas

*   **Given**: The demo editor account on a Canvas page.
*   **When**: The editor places a featured card and chooses or uploads an image through the Media library.
*   **Then**: The image appears in the card, scaled to the card (Canvas images are not cropped by focal point), and the upload's licence fields are recorded. It does not appear on the credits page, which lists only verified images.

### CUJ 4: A developer rebuilds the site

*   **Given**: A clone of the repository and DDEV.
*   **When**: The developer runs `scripts/rebuild.sh`.
*   **Then**: Every image, media item and focal point is restored with the same crop coordinates, and `drush config:status` reports no differences.

### CUJ 5: A reviewer checks where the photos came from

*   **Given**: Any image on the site that shipped with it.
*   **When**: The reviewer opens the credits page.
*   **Then**: The image is listed with its title, creator, source and licence, links to the licence, and the page states how the images were modified.

## Technical Plan (Architecture)

### Two render paths

```text
                         One Image media type (licence fields, Focal Point)
                                          |
             +----------------------------+-----------------------------+
             |                                                          |
   FORMATTER PATH (theme layer)                               CANVAS PATH (Canvas props)
   media view mode -> responsive image style                  src_with_alternate_widths
   -> ratio image styles (Focal point                         -> canvas_parametrized_width
      scale and crop, then Convert to AVIF)                      (scale only, AVIF) + toSrcSet
             |                                                          |
   hero block (eager, fetchpriority high)                     featured-card, quote
   session page image (eager, fetchpriority high)             (editors pick from the Media
   session cards (eager)                                       library; scaled, not cropped)
   speaker byline image, credits thumbnails (lazy)
   media embedded in session bodies (lazy, 16:9 or 3:2)
```

Every image is a Media item of one Image media type, so the licence fields, alt text and focal point live in one place. What differs is how it is rendered:

*   **Formatter path.** A field that references Media is displayed through a Media view mode. Each view mode shows the image field with core's responsive image formatter and one responsive image style. Each responsive image style maps image styles of one aspect ratio only (Goal 2), and each image style applies Focal Point's scale and crop and then core's Convert to AVIF. This path is used wherever the theme renders an entity.
*   **Canvas path.** Components placed in Canvas take the Canvas image prop shape (`src`, `alt`, `width`, `height`). Once the Image media type exists, Canvas stores the prop as a reference to a Media item (I1) and resolves it through three Canvas parts: `src_with_alternate_widths`, a computed property Canvas adds to every image field that gives the file's URL with a template for other widths; `canvas_parametrized_width`, Canvas's image style that scales to a requested width and converts to AVIF; and `toSrcSet`, Canvas's Twig filter that turns that template into a `srcset`. None of them crops.

### Image styles

Named by aspect ratio and width, never by the page or content type that uses them. Every style except `crop_preview` applies Focal point scale and crop to the dimensions given, then Convert to AVIF (fallback extension `webp`).

| Style | Dimensions | Serves |
| --- | --- | --- |
| `16_9_640`, `16_9_1280`, `16_9_2304` | 640x360, 1280x720, 2304x1296 | The hero (up to 72rem, 1152px; 2304 is its 2x), the session page image and wide embeds (up to 44rem, 704px) |
| `3_2_400`, `3_2_800`, `3_2_1200` | 400x267, 800x533, 1200x800 | Session cards (up to 37.5rem, 600px, in one column) and photo embeds (up to 44rem) |
| `1_1_96`, `1_1_144` | 96x96, 144x144 | Speaker bylines and credits thumbnails (3rem, 48px, at two and three device pixels per CSS pixel) |
| `crop_preview` | 600 wide, scale only | The Focal Point widget's preview. It must not crop, or every focal point is chosen on a pre-cropped image. |

Core's Convert to AVIF writes AVIF wherever GD supports it (DDEV and Pantheon Dev both do, checked with `gd_info()`). Its fallback extension applies only when the server cannot write AVIF. The usage-named `speaker_small` and `speaker_large` styles and the `speaker_photo` responsive image style are deleted; core's own usage-named styles (`thumbnail`, `medium`, `large`, `wide`) stay, because core and Canvas reference them.

### Responsive image styles

Named by use, one ratio each, using core's "sizes" mapping on the `responsive_image.viewport_sizing` breakpoint: one `srcset` with width descriptors and a `sizes` attribute. `sizes="auto, ..."` lets a lazy image use its laid-out width; the HTML standard reserves `auto` for lazy images, so it appears only on styles whose images are always lazy.

| Responsive style | Image styles | Fallback | `sizes` |
| --- | --- | --- | --- |
| `wide_16_9` | `16_9_640`, `16_9_1280`, `16_9_2304` | `16_9_1280` | `(min-width: 74rem) 72rem, calc(100vw - 2rem)` |
| `page_16_9` | `16_9_640`, `16_9_1280` | `16_9_1280` | `(min-width: 46rem) 44rem, calc(100vw - 2rem)` |
| `embed_16_9` | `16_9_640`, `16_9_1280` | `16_9_1280` | `auto, (min-width: 46rem) 44rem, calc(100vw - 2rem)` |
| `card_3_2` | `3_2_400`, `3_2_800`, `3_2_1200` | `3_2_800` | `(min-width: 74rem) 23rem, (min-width: 59rem) calc((100vw - 5rem) / 3), (min-width: 39.5rem) calc((100vw - 3.5rem) / 2), calc(100vw - 2rem)` |
| `embed_3_2` | `3_2_400`, `3_2_800`, `3_2_1200` | `3_2_800` | `auto, (min-width: 46rem) 44rem, calc(100vw - 2rem)` |
| `avatar_1_1` | `1_1_96`, `1_1_144` | `1_1_96` | `3rem` |

How each value follows from the theme:

*   **Main column.** `.page__main` is `--page-inline-size`, which is `min(100% - 2 * var(--size-4), 72rem)`: the viewport less 2rem, up to 72rem from a 74rem viewport. The hero sits in it.
*   **Narrow column.** The session page renders its content in `page-section` with width `narrow`, `--content-width-narrow: 44rem`, so the session image and embeds are the viewport less 2rem up to 44rem from a 46rem viewport.
*   **Session listing.** `.session-list` is `repeat(auto-fill, minmax(min(100%, 18rem), 1fr))` with a 1.5rem gap inside the main column. With a column width C, it has three columns when C is at least 57rem (a 59rem viewport), each (C - 3rem) / 3, which is 23rem at C = 72rem; two columns from C = 37.5rem (a 39.5rem viewport), each (C - 1.5rem) / 2; one column below that. The widest single-column card is 37.5rem (600px), so the 3:2 ladder reaches 1200px. The arithmetic assumes the card image spans the card's inline size, which implementation confirms by measuring the rendered widths.
*   **Avatars.** `--size-12` is 3rem.

With one ratio per style, the two open core issues only change which correctly shaped `width` and `height` pair is written, so the browser reserves the right space whichever it picks.

### The Image media type

`cedar_hollow_media` composes core's `image_media_type` recipe (`core/recipes/image_media_type`), which provides `media.type.image`, the `field_media_image` source field with alt text required, and the default and Media Library displays. A recipe never replaces configuration that already exists, so this recipe changes core's configuration through config actions in its `recipe.yml` rather than shipping copies:

*   `setSettings` on `field.field.media.image.field_media_image`: allowed extensions `png jpg jpeg webp avif`, maximum resolution 2560x2560 (core scales larger uploads down on save) and a 5 MB maximum file size.
*   `setComponents` on `core.entity_form_display.media.image.default`: the Focal Point widget on `field_media_image` (preview style `crop_preview`), and the four licence fields and `field_verified`. A single `setComponent` key places one component, so several need the plural action, as core's own `article_content_type` recipe does.
*   `setComponents` on `core.entity_form_display.media.image.media_library` for the four licence fields, and `hideComponents` for `field_verified`. The Focal Point widget is not added there, because Canvas uploads through this form and Canvas does not crop.
*   `hideComponents` on `core.entity_view_display.media.image.default` for the five new fields, which the Field UI would otherwise place on core's default media display.

The recipe adds these fields:

*   `field_source_url` (link, required): where the file was obtained, for example its Wikimedia Commons file page.
*   `field_creator` (plain text, required): the creator, stripped of HTML.
*   `field_licence` (list, required): `cc0` (CC0), `public_domain` (Public domain), `cc_by` (CC BY). Values outside the list fail validation.
*   `field_licence_url` (link, required): the licence's own page; for public-domain files with no licence URL on Commons, the Public Domain Mark 1.0 page.
*   `field_verified` (boolean, optional, shown only on the administrator's default form): set by the image script on each shipped image after its licence and content have been checked (Goal 5). The credits page lists only verified images, so nothing an editor uploads is published with unchecked licence data.

Validation, not saving, enforces the licence rules: `save()` does not validate in Drupal, so forms and code paths that create media call `validate()` and refuse to save on any violation.

### Media view modes

Every mode uses core's responsive image formatter on `field_media_image` and nothing else.

| View mode | Responsive image style | Loading | Used by |
| --- | --- | --- | --- |
| `hero` | `wide_16_9` | eager | The hero block |
| `page` | `page_16_9` | eager | The session page image |
| `card` | `card_3_2` | eager | Session cards |
| `avatar` | `avatar_1_1` | lazy | Speaker bylines |
| `credits` | `avatar_1_1` | lazy | Credits thumbnails |
| `embed_wide` ("Wide 16:9") | `embed_16_9` | lazy | Embeds in session bodies (default) |
| `embed_photo` ("Photo 3:2") | `embed_3_2` | lazy | Embeds in session bodies |

Session cards are eager because the sessions view shows all twelve sessions on one page with no pager (`items_per_page: 0`), and an eager view mode stays correct under render caching, which caches each card by entity and view mode, not by its position in the list. If the Lighthouse check shows twelve eager card images delaying LCP on `/sessions`, the next step is position-dependent loading with the row position added to the cache keys.

### Classes and loading attributes come from the media view mode

Each component that shows an image has its own Image media view mode, so the theme sets the component's image attributes by media view mode: a `preprocess_media` hook copies them into the image formatter item's `#attributes`, which core 11.4 merges into the `<img>` (I4; `#item_attributes` is deprecated in 11.4). Core has no `fetchpriority` formatter setting (issue #3366828), and this one mechanism carries it as well. Media is render-cached per media view mode, so attributes keyed by it are the same whichever page renders a media item first. (An earlier version set them per field in `preprocess_field`; a session rendered in its RSS view mode first cached its `page` image without them, which `ImageAttributesTest` now covers.)

*   `hero` sets `class: hero__img` and `fetchpriority: high`;
*   `page` sets `class: session__img` and `fetchpriority: high`;
*   `card` sets `class: card__img`;
*   `avatar` sets `class: speaker-byline__img`, replacing the attribute `preprocessNodeSpeaker` sets on the formatter today;
*   `credits` and the embed view modes set no class.

### Where images appear

*   **Hero.** Core's `block_content` module provides a `hero` block type with one required Media reference, `field_media` (Image bundle, `hero` view mode); the page's own content carries the heading. One hero block is placed in the theme's existing `highlighted` region, which `page.html.twig` renders first inside `<main>`, with front-page visibility only. Its template, `block--block-content--type--hero.html.twig`, includes a new `hero` component with the rendered image. The component is in the `Components` group and marked `noUi: true`, so Canvas does not offer it in its component library.
*   **Sessions.** A new `field_image` on the session node type references Image media. The full display shows it in the `page` view mode, above the session summary, in a wrapper with the extra class `session__image`. The teaser display uses the `card` view mode, and `node--session--teaser.html.twig` passes the rendered field into the card component's existing image slot. Cards placed in Canvas stay without images, because Canvas cannot fill a slot with an image.
*   **Speakers.** `field_photo` (a plain image field, empty for every speaker) is replaced by `field_image`, a Media reference. The speaker teaser renders it in the `avatar` view mode into the speaker-byline slot.
*   **Embeds.** Session bodies embed Image media in the `embed_wide` or `embed_photo` view mode, rendered inside a `figure` with its caption.
*   **Credits.** A View at `/credits` lists published Image media with `field_verified` set, 50 per page with a pager: a thumbnail in the `credits` view mode, the media name (the Commons file title), creator, licence linked to its licence URL, and the source link. A line above the list states that the images were cropped, resized and converted to AVIF from the linked originals. The footer menu links to it.

### Rich-text session bodies

The session body is already a `text_with_summary` field using `plain_text`, and its storage is shared with the speaker body. A new text format, `session_html`, uses CKEditor 5 with:

*   allowed HTML: `<p> <br> <a href> <strong> <em> <ul> <ol> <li> <h2> <h3> <drupal-media data-entity-type data-entity-uuid alt data-view-mode data-caption>`; the `alt` attribute is required by core's CKEditor 5 Media plugin, and `data-view-mode` is produced only when the plugin's `allow_view_mode_override` is on;
*   filters in this order: `filter_html` (weight -10), `filter_caption` (weight 5), `media_embed` (weight 100; Image bundle only; view modes `embed_wide` and `embed_photo`, default `embed_wide`). Core requires `media_embed` to run after `filter_caption`, which turns `data-caption` into a `figure` with a `figcaption`;
*   the CKEditor 5 Media plugin with `allow_view_mode_override: true`, the list plugin with `properties: {reversed: false, startIndex: false, styles: false}` and `multiBlock: true` (with `styles` on, the plugin would require `<ul type> <ol type>`, which the allowed HTML does not include), and the heading plugin with Heading 2 and Heading 3.

The session field instance's allowed formats are limited to `session_html`, so speaker bodies keep `plain_text`. On this site the image script inserts the shipped embeds, and the administrator is the only account that edits session bodies (the demo editor cannot edit sessions under the main design). The editor configuration is kept because it is how an administrator authors embeds on a real site, and its Media settings are where embeds commonly break; a functional test installs it from the recipe, which validates it. The session template wraps the body in `.prose`, and `css/prose.css` regains rules for the markup this format produces: `h2`, `h3`, `figure` and `figcaption`. The figure is `inline-size: fit-content` and the caption has `contain: inline-size`, so a caption is never wider than its image (Mario Hernandez, "Normalize images captions in your website").

Embedded media are not exported with the node that embeds them (I3), so the export script exports all Image media as a set.

### Main menu without layout shift

The menu starts expanded and collapses when its script runs, which moved the home page (I5). It changes to collapse before first paint:

*   The toggle button is rendered without `hidden`. CSS hides it under `@media (scripting: none)` and at widths of 48rem and above.
*   Below 48rem, the list is hidden under `@media (scripting: enabled)` until it has `.is-open`, instead of under a class the script adds after load.
*   The script only handles the button's click and `aria-expanded`. Without JavaScript the links stay visible and the button stays hidden, as today. If scripting is on but the script fails to load, the list stays collapsed behind a button that does nothing; this is accepted and stated in the write-up.

### Theme and CSS

*   `components/molecules/hero`: an image slot only. The image fills the region's width at its intrinsic ratio, from its `width` and `height` attributes. No text is placed over the photo, so contrast never depends on the image, and the page's title stays its only top-level heading.
*   `hero__img`, `card__img`, `session__img` and `speaker-byline__img` are each sized by their block (`inline-size: 100%`, `block-size: auto`) and keep the shape their image style cropped them to.
*   The `--ratio-*` tokens are not restored. The brief recorded a decision to bring them back for these consumers; it is revised here because every image arrives cropped to its ratio, with `width` and `height`, so no CSS needs an aspect-ratio value.

### Configuration and recipes

*   **`recipes/cedar_hollow_media`** composes `core/recipes/image_media_type`, installs `responsive_image`, `breakpoint`, `block_content`, `crop`, `focal_point`, `views`, `link` and `options`, applies the config actions above, imports the licence fields, image styles, responsive image styles, Media view modes, the `hero` block type and the credits View, and grants `view media` to the anonymous and authenticated roles. A module installed by a recipe creates only its simple configuration, so the recipe imports Focal Point's `crop.type.focal_point` explicitly with `config.import`; without it every focal-point image style would fail to crop.
*   **`recipes/cedar_hollow_sessions`** composes `cedar_hollow_media`, installs `editor` and `ckeditor5`, and adds the session image field, the speaker image field change and the `session_html` format and editor. Functional tests keep building their site from `cedar_hollow_sessions`.
*   Changes are made on the site and exported with `ddev drush config:export -y` into `config/`, which stays the source of truth. The exported files a change touches are then copied into the recipe that installs them, without their `uuid` and `_core` keys, as the existing recipe copies are. `recipe.yml` files, recipe `composer.json` files and scripts are written by hand.

### Content, licences and files

*   Photos come from Wikimedia Commons through its API, with a descriptive User-Agent. The fetch script downloads Commons' own scaled rendition fitted inside a 2560-pixel box (`iiurlwidth=2560&iiurlheight=2560`). It refuses licences outside the mapping below and files carrying the personality-rights template. Commons scales only to fixed steps (a request between steps gets the next step up) and serves the original above 1920 pixels, which was measured while fetching: a 1600-pixel request returned the 1920-pixel file, and 2304 and 2560 returned the original. A non-hero rendition above 400 KB is therefore fetched again at 1920 and then at 1280 pixels, the width of the largest non-hero image style, so no style upscales it; if it is still too large, the entry is refused and another photo chosen. The hero must be landscape and at least 2304 pixels wide, which Commons offers only as the original, and openly licensed originals that wide are almost always above 900 KB; the fetch script scales the hero original to 2304 pixels wide with the site's own image toolkit, the one image resized before Drupal.
*   Licence mapping from Commons' `LicenseShortName`: `CC0` and `CC0 1.0` become `cc0`; `Public domain` and `PD-*` become `public_domain`; `CC BY 2.0`, `CC BY 2.5`, `CC BY 3.0` and `CC BY 4.0` become `cc_by`; anything else is refused. `Artist` is stripped of HTML for `field_creator`, without a user link's "(talk · contribs)"; when it is absent, `Attribution` is used (museum uploads put the required attribution there), and when it says "own work", the file's first uploader. A file with neither is refused. Commons gives no licence URL for public domain files, so they link to the Creative Commons Public Domain Mark.
*   Size budget for committed originals: 900 KB for the hero, 400 KB for every other image and 10 MB in total, checked by the fetch script and again by the rebuild check.
*   Each manifest entry has a fixed media UUID, so the same media item exists on every site the content reaches, and a revision timestamp, so a later licence change on Commons can be detected.
*   Order of work: fetch; review every fetched image and its alt text by hand and record the date in the manifest's `reviewed` key and in `docs/checks.md`; run the image script on DDEV; export; commit `recipes/cedar_hollow_demo_content/content`. The image script refuses to set `field_verified` on an entry without `reviewed`. The existing seed script is not changed.

### The image script

`scripts/place-demo-images.php`, run with `drush php:script`, is the one place images are put on a site. It is idempotent: on a site that already has everything, it changes nothing. For each manifest entry it:

1.  creates the Image media item with the entry's fixed UUID if it does not exist, from the fetched file and licence data, sets its focal point through Focal Point's manager, sets `field_verified` only if the entry has `reviewed`, and calls `validate()`, refusing to save on any violation;
2.  attaches the media to its target: the session found by path alias or the speaker found by name;
3.  for embed entries, converts the target session's body from `plain_text` to `session_html` (each paragraph wrapped in `<p>`) if it has not been converted, and inserts the embed with its caption.

It then creates the hero block content and the footer menu link to `/credits` with fixed UUIDs if they do not exist. Because it finds nodes by alias and name rather than UUID, it works on DDEV, on a rebuilt site and on Pantheon alike.

### Pantheon rollout

Content on Pantheon came from a one-time database copy, and the live site now holds a reviewer account and reviewer activity that a new copy would erase. Applying the content recipe there imports only entities that do not exist yet (core imports default content with `Existing::Skip`), so it creates the new media, files and crops and skips every existing session, speaker, Canvas page and menu link. The one-time image rollout is:

1.  `terminus backup:create cedar-hollow-demo.dev`.
2.  Push the code to Pantheon's `master`, then `terminus drush cedar-hollow-demo.dev -- deploy -y`. The hero block placement is imported here, before its block content exists, and renders nothing until step 3.
3.  `terminus drush cedar-hollow-demo.dev -- recipe ../recipes/cedar_hollow_demo_content`, which creates the media, files, crops and the hero block content.
4.  `terminus drush cedar-hollow-demo.dev -- php:script ../scripts/place-demo-images.php`, which attaches images to the existing sessions and speakers, converts the bodies, and creates the credits link (the hero block already exists from step 3).
5.  The warm-up against the Pantheon URL, so the first visitors do not pay for derivative generation (I6).
6.  The smoke and accessibility suites against Pantheon; the smoke suite includes a check that a session page shows its AVIF image.

Every later deploy needs only the backup, `drush deploy` and the warm-up; the main design's standing runbook gains those two additions.

### Measurement

*   **Method.** Lighthouse CI runs Lighthouse's default mobile configuration, performance category only, five times on each of `/`, `/sessions` and `/sessions/caching-render-arrays`, and asserts on the median run (Lighthouse CI's `median-run` aggregation; its default passes if any run passes): LCP under 2.5 s and CLS under 0.1 as errors, LCP of 2.0 s or more as a warning. A small script reads the median reports and fails if the LCP element on `/` does not end in `img.hero__img`, if any page's LCP image is lazy, or if any stylesheet or script request returned 403. The server response time is recorded next to LCP.
*   **Warm-up.** Before each measurement and after each Pantheon deploy, every image URL in the `src` and `srcset` of `/`, `/sessions`, `/credits` and every session page is requested once.
*   **Pantheon.** The sandbox's edge refuses CSS and JavaScript to the HeadlessChrome agent (recorded in `docs/accessibility.md`) and serves Chromium's new headless mode, so Lighthouse runs Playwright's Chromium in new headless mode there.
*   **CI.** The warm-up and the measurement run as steps in the existing end-to-end job, after its rebuild, against CI's `BASE_URL` (no port), with their own timeout and one retry run by the step's shell.

### Tests

*   **PHPUnit (unit):** `ResponsiveImageRatioTest` fails if any responsive image style maps image styles of more than one ratio, maps a style without a scale and crop, or has a fallback outside its mapping; a committed mixed-ratio fixture shows it failing.
*   **PHPUnit (functional, from the sessions recipe):** licence validation on the entity and on the fields the Media Library upload form validates (its flow is AJAX, which only FunctionalJavascript tests drive, and this project's CI does not run them); the `session_html` format and editor install, and an embed renders in each view mode inside a `figure` with its caption, with disallowed markup removed; `demo_editor` can pick and upload images through the Media Library and has no other new access.
*   **Playwright:** the loading and `fetchpriority` attributes of Goal 3; `sizes` on cards, the session image and bylines; the credits modification notice and titles; the layout-shift sum of Goal 9; axe on the existing page list plus `/credits`; the Pantheon smoke check of a session image.
*   **Storybook:** stories for `hero`, `card`, `speaker-byline` and the session image with real image markup from committed AVIF fixtures that each story imports, so Vite copies them into the static build; visual baselines regenerated after review.
*   **Test first:** each test is written in the stage whose behaviour it covers, run first against the code before the change, and the failing output is recorded in the commit message; no commit contains a failing test.

## Alternatives Considered

### Alternative A: The hero as a Canvas component on Canvas's image path

*   **Pros**: Editors change the hero inside Canvas with the rest of the page; no block type.
*   **Cons**: Canvas renders image props through its own scale-only style.
*   **Reason for Rejection**: The hero is the home page's LCP image. On the Canvas path it would lose focal-point crops, ratio styles and a responsive image style.

### Alternative B: A Canvas component that references a Media entity and renders it through a formatter

*   **Pros**: Editor control in Canvas and the formatter path together.
*   **Cons**: It needs custom code that depends on Canvas internals outside its documented API, and whether a component can hand the referenced entity to a field formatter is unverified.
*   **Reason for Rejection**: The theme-layer hero gets the same result with no custom code between Canvas and the formatter.

### Alternative C: The hero chosen in theme settings

*   **Pros**: No new module.
*   **Cons**: A theme setting holding a media UUID is configuration pointing at content; it breaks when that media item is missing and needs a custom settings form.
*   **Reason for Rejection**: A block content type is Drupal's own way to place editable content in a region.

### Alternative D: The hero stored as a field on the Canvas page

*   **Pros**: The hero travels with the page's content.
*   **Cons**: Whether Canvas 1.12 pages accept fields is unverified, and the page template would depend on one field.
*   **Reason for Rejection**: Unverified, and a block needs no change to Canvas pages.

### Alternative E: The card takes a Canvas image prop

*   **Pros**: Canvas editors could put images on cards; one input.
*   **Cons**: Session cards would lose focal-point crops, because the Canvas path only scales.
*   **Reason for Rejection**: Session cards are where card images matter on this site, and the slot keeps them on the full pipeline.

### Alternative F: The card takes both a prop and a slot

*   **Pros**: Both kinds of card get images.
*   **Cons**: Two ways in, a precedence rule, and twice the stories and tests.
*   **Reason for Rejection**: No Canvas page needs card images, so the second input would have no user.

### Alternative G: Plain image fields instead of Media

*   **Pros**: Fewer parts; the speaker photo already works this way.
*   **Cons**: No reuse of one photo in several places, no single home for alt text and licence data, no Media Library for Canvas or embeds.
*   **Reason for Rejection**: Canvas's image picker and CKEditor's embeds both need Media, and both sources consulted (Mario Hernandez's series and the Drupal Asheville talk) recommend it.

### Alternative H: WebP instead of AVIF

*   **Pros**: Decodes in older browsers.
*   **Cons**: Larger files than AVIF at the same quality.
*   **Reason for Rejection**: Every supported browser decodes AVIF.

### Alternative I: AVIF with a browser-side WebP fallback through `<picture>`

*   **Pros**: Each browser gets its best format.
*   **Cons**: Twice the derivatives, custom markup outside core's formatters, and a second set of `sizes`.
*   **Reason for Rejection**: No supported browser would use the fallback.

### Alternative J: Art direction with `<picture>` and per-breakpoint crops

*   **Pros**: A wide crop on desktop and a tall crop on phones.
*   **Cons**: A style set and a manual crop per breakpoint, and per-breakpoint sources that core issue #3523451 also affects.
*   **Reason for Rejection**: No image here needs a different subject per screen size.

### Alternative K: No responsive image styles, one converted size per slot

*   **Pros**: The simplest setup; the Drupal Asheville talk argues format conversion alone is enough.
*   **Cons**: A phone downloads the desktop-sized file; conversion reduces bytes per pixel, not pixels.
*   **Reason for Rejection**: The mobile LCP target depends on phone-sized files, and Mario Hernandez's series treats responsive images as standard practice.

### Alternative L: Mixed aspect ratios in one responsive image style, with core patches

*   **Pros**: Fewer responsive image styles.
*   **Cons**: Needs patches for #3516726 and #3523451, neither committed.
*   **Reason for Rejection**: One ratio per style avoids both issues with configuration alone.

### Alternative M: Contributed modules for `fetchpriority`, optimisation and pre-generation

*   **Pros**: `image_fetchpriority` adds a formatter setting; Image Optimize adds compression; pre-generation removes first-request delays.
*   **Cons**: Each is a dependency to maintain.
*   **Reason for Rejection**: The theme sets `fetchpriority` on two images through one mechanism; AVIF already compresses a 4.9 MB photo to 195 KB at 1600x900 (I6); the main design rejected pre-generation, and the warm-up covers deploys.

### Alternative N: Centre crops without Focal Point

*   **Pros**: No contributed module and no crop entities to export.
*   **Cons**: Subjects that are not centred are cut; I2's portrait photo would have lost its canopy in a 16:9 crop.
*   **Reason for Rejection**: Crops round-trip through the content export once exported on their own (I2).

### Alternative O: Lighthouse on Pantheon Dev as the target of record

*   **Pros**: It is the site reviewers open.
*   **Cons**: The sandbox's edge refuses CSS and JavaScript to HeadlessChrome (recorded in `docs/accessibility.md`), its response time varies, and first requests pay for derivative generation.
*   **Reason for Rejection**: DDEV gives a repeatable check that runs in CI; one warmed Pantheon run is recorded as evidence.

### Alternative P: Openverse as the image source

*   **Pros**: Searches many collections at once.
*   **Cons**: Its API answered with a bot challenge during research.
*   **Reason for Rejection**: Wikimedia Commons' API works and returns licence data.

### Alternative Q: CC BY-SA images

*   **Pros**: A wider choice of photos.
*   **Cons**: Share-alike terms reach adapted versions, and every crop and resize here is an adaptation.
*   **Reason for Rejection**: CC0, public domain and CC BY cover the photos needed without share-alike obligations.

### Alternative R: Reserve the header's height, or collapse the menu from an inline head script

*   **Pros**: A reserved height needs no media query; an inline script runs before first paint in every browser.
*   **Cons**: A fixed height breaks when the header wraps or text is enlarged; an inline script is JavaScript the theme would have to add outside its libraries.
*   **Reason for Rejection**: `@media (scripting: enabled)` collapses the menu in CSS before first paint in every supported browser.

### Alternative S: A caption on each image instead of a credits page

*   **Pros**: Attribution sits beside the image.
*   **Cons**: Credits on cards, avatars and the hero clutter the design, and Canvas images have no caption field.
*   **Reason for Rejection**: CC BY allows attribution in any reasonable manner; one credits page with titles, licences and the modification notice is complete and is linked from every page's footer.

### Alternative T: Media configuration inside the sessions recipe

*   **Pros**: One recipe fewer.
*   **Cons**: Media, image styles and the hero have nothing to do with sessions.
*   **Reason for Rejection**: A separate media recipe can be applied on its own and composed by the sessions recipe, which keeps each recipe about one feature.

### Alternative U: A separate image field on sessions instead of rich-text embeds

*   **Pros**: No new text format and no embed export.
*   **Cons**: Images can only appear in one fixed place, with no caption in the text's flow.
*   **Reason for Rejection**: Embeds with captions exercise Drupal's Media embed and caption filters, which a field cannot.

### Alternative V: Leave rich-text bodies to a later design

*   **Pros**: A smaller first delivery: no text format, editor configuration, embed view modes or caption CSS.
*   **Cons**: The pipeline's text path (embeds in two ratios, captions no wider than their image, embeds exported as a set) would go unshown; the photo embed costs one responsive image style (`embed_3_2`) for one seeded embed.
*   **Reason for Rejection**: Embedded media is where editors place images in running text, and its export and caption problems are among those this design exists to handle.

### Alternative W: A custom Lighthouse script instead of Lighthouse CI

*   **Pros**: No extra dependency.
*   **Cons**: It would reimplement runs, median selection and assertions that Lighthouse CI provides.
*   **Reason for Rejection**: Lighthouse CI already does them; only the LCP-element checks need a small script.

### Alternative X: Extend the seed script and attach images by node UUID

*   **Pros**: Reuses the existing seed script.
*   **Cons**: The seed script recreates every node with new UUIDs, so a re-seed would make Pantheon import duplicate content and leave an attach-by-UUID step matching nothing.
*   **Reason for Rejection**: An image script that finds nodes by alias and name and gives media fixed UUIDs works on every site without touching the seed.

--------------------------------------------------------------------------------

## Non-Functional Requirements

### Risks and mitigations

| Risk | Trigger | Impact | Mitigation | Check |
| --- | --- | --- | --- | --- |
| Live content not updated | The content recipe is applied on Pantheon, where sessions and speakers already exist | Sessions and speakers show no images | The image script attaches media by path alias and name after the recipe | Rollout step 6 smoke check |
| Reviewer state lost | A database copy is used to deliver content | The reviewer account, registrations and Canvas edits are erased | Content is delivered by recipe plus the image script, never by database copy | Rollout steps; backup in step 1 |
| Unchecked uploads published | A reviewer uploads an image through Canvas | A face or a false licence appears on the credits page or in a Canvas featured card | Credits lists only verified images; uploads are capped at 5 MB and 2560 pixels; after the review, unverified media are deleted (`drush entity:delete media` filtered to unverified items). An upload remains visible in its featured card until then. | Manual, recorded in `docs/checks.md` |
| Upload volume on the sandbox | Many uploads | Disk use and generation time grow | The size cap and the post-review deletion | Manual, recorded |
| Missing binary on import | An exported file is absent from the recipe | Core logs a warning and the image is missing | The rebuild check fails on any missing file | Item 32 |
| File name collision | Two Commons files share a base name | One binary overwrites the other on export | Files are named by Commons page ID | Item 32 counts files |
| Licence or file changes on Commons | A file is deleted or relicensed after commit | Credits state an outdated licence | Revision timestamps in the manifest; licences re-checked before sharing | Manual, recorded |
| Rollback is restore-only | Configuration is reverted after media and crops exist | The media bundle cannot be removed and Focal Point cannot be uninstalled while crops exist | Roll back by restoring the backup | Backup before every deploy |
| Cold derivatives | A deploy saves an image style, or a new deploy | First visitors wait 0.8 to 1.6 s per derivative (I6) | Warm-up after every deploy | Rollout step 5 |
| Noisy performance check | Shared CI runners | Intermittent failures | Median of five, one retry, a warning band below the limit | CI history |
| Eager cards delay LCP | Twelve eager card images on `/sessions` | LCP on the listing rises | The Lighthouse check measures it; the fallback is position-dependent loading with the position in the cache keys | Item 39 |

### Security and privacy

*   No identifiable person appears in any shipped image: the fetch script refuses Commons files marked with the personality-rights template, and every shipped image is reviewed by hand, with the date recorded in the manifest, before the image script will mark it verified. Editor uploads are not checked; they are not listed on the credits page and are deleted after the review.
*   The `session_html` format allows a fixed tag list; `filter_html` removes everything else, and `media_embed` renders only Image media. A functional test covers the removal.
*   `demo_editor` gains Media Library pick and upload, and nothing more; `DemoEditorAccessTest` asserts the boundary.

### Performance

*   Targets (Goal 10): LCP under 2.5 s and CLS under 0.1, Lighthouse's mobile configuration, median of five runs, on `/`, `/sessions` and `/sessions/caching-render-arrays`, on DDEV.
*   The hero and the session page image are eager with high fetch priority, session cards are eager, and every other image is lazy.
*   Originals are stored at no more than 2560 pixels on the long side and within the size budget.

### Rollout and rollback

*   The one-time Pantheon image rollout is the six steps in the Technical Plan; later deploys add only the backup and the warm-up.
*   Rollback is restoring the backup taken in step 1 and redeploying the previous commit; configuration cannot simply be reverted once media and crops exist.

### Future Improvements

*   **Remove the one-ratio explanation** from the write-up when core issues #3516726 and #3523451 are fixed; the one-ratio rule itself stays.
*   **Use core's `fetchpriority` setting** in place of the theme's attribute when issue #3366828 lands.
*   **A callout image prop** when a Canvas page needs a callout with an image.

### Additional Resources

*   The main design: `docs/designs/cedar-hollow-drupalcamp.md`.
*   Mario Hernandez, "Responsive images in Drupal" series: https://mariohernandez.io/blog/responsive-images-in-drupal-a-series/
*   Mario Hernandez, "Two Drupal core issues in responsive images you may be experiencing and not know it": https://mariohernandez.io/blog/two-drupal-core-issues-in-responsive-images-you-may-be-experiencing-and-not-know-it/
*   Mario Hernandez, "Normalize images captions in your website": https://mariohernandez.io/blog/normalize-images-captions-in-your-website/
*   Mario Hernandez, "Using modern image formats to improve performance": https://mariohernandez.io/blog/using-modern-image-formats-to-improve-performance/
*   Mario Hernandez, "Managing image embeds with Drupal media": https://mariohernandez.io/blog/managing-image-embeds-with-drupal-media/
*   Drupal Asheville, "Image Styles - Beyond the Basics" (2025): https://www.youtube.com/watch?v=7SN2meOSpi0
*   Specbee, "8 Ways to fully optimize images in Drupal": https://www.specbee.com/blogs/optimize-images-in-drupal-for-core-web-vitals
*   HTTP Archive, Web Almanac 2024, Media and Performance chapters: https://almanac.httparchive.org/en/2024/
*   Drupal change record for Convert to AVIF: https://www.drupal.org/node/3511540
*   Core issues: https://www.drupal.org/node/3516726, https://www.drupal.org/node/3523451, https://www.drupal.org/node/3366828

--------------------------------------------------------------------------------

## Detailed Implementation Plan

Paths are relative to the repository root. Configuration follows the workflow in "Configuration and recipes": made on the site, exported to `config/`, and copied into the installing recipe. Each stage is a set of single-concern commits that leave `config:status` clean and every suite green; tests follow the "Test first" rule in Tests.

### Stage 1: Contracts and spikes (documentation only)

#### 1. `docs/spikes.md` (Modify)

*   **Type / Scope**: Spike record.
*   **Proposed Changes**: Append image spikes I1 to I6 with their commands and results, numbered to keep them apart from the existing lettered spikes.

#### 2. `docs/designs/cedar-hollow-drupalcamp.md` (Modify)

*   **Type / Scope**: The main design (binding under AGENTS.md).
*   **Proposed Changes**: Add contract C4, Images: the Image media type and its licence fields; the ratio-named image styles; one ratio per responsive image style; the two render paths and the surfaces each serves; the loading rules. Correct in place: replace the speaker photo (a core image field with no seeded photos) with the Media reference `field_image`; remove `speaker_small`, `speaker_large` and `speaker_photo` wherever they are named; add Focal Point and Crop API to the contributed module list and `block_content` to the core module list; raise the browser floor to Chrome and Edge 121, Safari 17 and Firefox 117; add `/credits` to Goal 8's page list; replace the CI non-goal with the CI job, which now also measures performance; add the backup and the warm-up to the standing deploy runbook; raise the write-up's word budget from 1,500 to 1,900 words for the images section. Add a dated revision note.

#### 3. `docs/designs/cedar-hollow-images.md` (Modify)

*   **Type / Scope**: This design.
*   **Proposed Changes**: Status changes to Approved after review.

### Stage 2: Pipeline configuration

#### 4. `composer.json`, `composer.lock` (Modify)

*   **Type / Scope**: Dependencies.
*   **Proposed Changes**: `drupal/focal_point:~2.1.3` and `drupal/crop:~2.6.0`, the versions tested in I2.

#### 5. `recipes/cedar_hollow_media/recipe.yml`, `recipes/cedar_hollow_media/composer.json` (Create), `recipes/cedar_hollow_sessions/recipe.yml` (Modify)

*   **Type / Scope**: Site feature recipe, and its composition into the sessions recipe.
*   **Proposed Changes**:
    *   `recipes: [core/recipes/image_media_type]`.
    *   `install:` `responsive_image`, `breakpoint`, `block_content`, `crop`, `focal_point`, `views`, `link`, `options`.
    *   `setSettings` on `field.field.media.image.field_media_image`: `file_extensions: 'png jpg jpeg webp avif'`, `max_resolution: '2560x2560'`, `max_filesize: '5 MB'`.
    *   `setComponents` on `core.entity_form_display.media.image.default`, one `{name, options: {type, weight, region: content, settings}}` entry each: `field_media_image` with `image_focal_point` (settings `preview_image_style: crop_preview`, `preview_link: true`, `offsets: '50,50'`, `progress_indicator: throbber`; the plugin id is confirmed when the module is installed), then `field_source_url` (`link_default`), `field_creator` (`string_textfield`), `field_licence` (`options_select`), `field_licence_url` (`link_default`) and `field_verified` (`boolean_checkbox`), weights 0 to 5.
    *   `setComponents` on `core.entity_form_display.media.image.media_library` for the four licence fields with the same widgets; `hideComponents: [field_verified]`.
    *   `hideComponents` on `core.entity_view_display.media.image.default`: the five new fields.
    *   `grantPermissions`: `view media` to `anonymous` and `authenticated`.
    *   `composer.json` requires `drupal/focal_point: ~2.1.3` and `drupal/crop: ~2.6.0`.
    *   `recipes/cedar_hollow_sessions/recipe.yml` gains `cedar_hollow_media` in `recipes:` in the same commit, so every functional test from this stage on builds a site with the Image media type.
*   **Order**: on DDEV, `ddev drush recipe /var/www/html/recipes/cedar_hollow_media` is first applied with only `recipes:` and `install:`, so item 6's fields and styles can be built in the UI; the actions are added once that configuration exists, because an action naming a field that does not exist yet is stored without defaults. The functional tests then prove the whole recipe on a fresh site.

#### 6. `recipes/cedar_hollow_media/config/` and `config/` (Create), `config/core.extension.yml` (Modify)

*   **Type / Scope**: Exported configuration.
*   **Proposed Changes**:
    *   Licence fields: storage and field files for `field_source_url` (link), `field_creator` (string), `field_licence` (list_string: `cc0`, `public_domain`, `cc_by`) and `field_licence_url` (link), each required; `field_verified` (boolean, optional).
    *   Image styles: `image.style.<name>.yml` for `16_9_640`, `16_9_1280`, `16_9_2304`, `3_2_400`, `3_2_800`, `3_2_1200`, `1_1_96`, `1_1_144` (each `focal_point_scale_and_crop` to the dimensions in the Technical Plan, then `image_convert_avif` with fallback `webp`), and `image.style.crop_preview.yml` (`image_scale` 600 wide).
    *   Responsive image styles: `responsive_image.styles.<name>.yml` for `wide_16_9`, `page_16_9`, `embed_16_9`, `card_3_2`, `embed_3_2`, `avatar_1_1`, with the mappings, fallbacks and `sizes` in the Technical Plan.
    *   Media view modes: `core.entity_view_mode.media.<name>.yml` for `hero`, `page`, `card`, `avatar`, `credits`, `embed_wide`, `embed_photo`, and the matching `core.entity_view_display.media.image.<name>.yml` files (responsive image formatter, loading as in the view mode table, image only).
    *   Hero block type: `block_content.type.hero.yml`, `field.storage.block_content.field_media.yml`, `field.field.block_content.hero.field_media.yml` (required, Image bundle), `core.entity_form_display.block_content.hero.default.yml`, `core.entity_view_display.block_content.hero.default.yml` (`hero` view mode).
    *   Credits: `views.view.credits.yml`, a page at `/credits` with a table of published Image media with `field_verified` set (columns: thumbnail, title, creator, licence, source), sorted by name, 50 per page with a pager, cached by tag, with this header: "The photos on this site come from Wikimedia Commons. Each was cropped, resized and converted to AVIF from the original linked below."
    *   Link fields `field_source_url` and `field_licence_url` accept external links only (`link_type: 16`) with no link text (`title: 0`).
    *   `config/core.extension.yml` gains the new modules (it is not copied into a recipe).
*   **Before committing**: run the Media Library check (Open Questions) and record it in `docs/spikes.md`.

#### 7. `config/canvas.component.sdc.cedar_hollow.featured-card.yml`, `config/canvas.component.sdc.cedar_hollow.quote.yml` (Modify)

*   **Type / Scope**: Canvas component versions.
*   **Proposed Changes**: Re-exported in the same commit as the media type, because creating the Image media type gives both components a new version whose image prop uses the Media Library widget (I1).

#### 8. `config/user.role.demo_editor.yml` (Modify)

*   **Type / Scope**: Permissions.
*   **Proposed Changes**: `create image media`, the only permission the Media Library check (image spike I7) found missing; `access media overview` is not granted.

#### 9. `web/modules/custom/cedar_hollow_core/tests/src/Functional/MediaLicenceTest.php` (Create)

*   **Type / Scope**: Functional test, site built from the sessions recipe.
*   **Proposed Changes**: `$media->validate()` reports a `NotNull` violation for each missing licence field and an `AllowedValues` violation for a licence outside the list; Media Library's add form (built inline by `AddFormBase`, not an entity form handler) validates only the fields on the `media_library` form display, so the test asserts the four licence fields are on that display and that validation filtered to it still reports each missing one.

#### 10. `web/modules/custom/cedar_hollow_core/tests/src/Functional/DemoEditorAccessTest.php` (Modify)

*   **Type / Scope**: Functional test.
*   **Proposed Changes**: as `demo_editor`: `/media/add/image` answers 200; `/admin/content/media` answers 403 (`access media overview` is not granted); `/media/{id}/edit` and `/media/{id}/delete` for media created by another user answer 403; `/admin/structure/media` answers 403; the routes it is refused today stay refused. (Field UI is not enabled, so its pages answer 404 for every user and are not asserted.)

### Stage 3: Rich-text session bodies

#### 11. `config/filter.format.session_html.yml`, `config/editor.editor.session_html.yml` and their copies in `recipes/cedar_hollow_sessions/config/` (Create); `recipes/cedar_hollow_sessions/recipe.yml` (Modify)

*   **Type / Scope**: Text format, editor and recipe install list.
*   **Proposed Changes**: The allowed tags, filters and weights, and the Media (`allow_view_mode_override: true`), list (`properties: {reversed: false, startIndex: false, styles: false}`, `multiBlock: true`) and heading (Heading 2, Heading 3) plugin settings from the Technical Plan; the toolbar has Heading, Bold, Italic, Link, Bulleted list, Numbered list and Media. The sessions recipe gains `editor` and `ckeditor5` in `install:`.

#### 12. `config/field.field.node.session.body.yml` and its recipe copy (Modify)

*   **Type / Scope**: Field instance.
*   **Proposed Changes**: `allowed_formats: [session_html]` on the session body only.

#### 13. `web/themes/custom/cedar_hollow/css/prose.css` (Modify)

*   **Type / Scope**: Rich-text CSS.
*   **Proposed Changes**: `h2` at `var(--font-size-4)` and `h3` at `var(--font-size-3)`, in the heading font; `figure` with `inline-size: fit-content`, centred, block margin `var(--size-6)`; `figcaption` with `contain: inline-size`, colour `var(--color-text-muted)`, font size `var(--font-size-0)`, top margin `var(--size-2)`. The file comment names `session_html` as a second source of prose content.

#### 14. `web/modules/custom/cedar_hollow_core/tests/src/Functional/SessionBodyEmbedTest.php` (Create)

*   **Type / Scope**: Functional test.
*   **Proposed Changes**: The sessions recipe installs the `session_html` format and editor without validation errors; a body embedding Image media with `data-view-mode="embed_wide"` and another with `embed_photo`, each with a caption, renders a `figure`, a `figcaption` and the `embed_16_9` or `embed_3_2` image; a `<script>`, an `<img>` and a `style` attribute are removed.

### Stage 4: Content model and rendering

#### 15. Session and speaker fields in `recipes/cedar_hollow_sessions/config/` and `config/` (Create, Modify, Delete)

*   **Type / Scope**: Content model.
*   **Proposed Changes**:
    *   Create `field.storage.node.field_image.yml` (entity reference to media, cardinality 1), `field.field.node.session.field_image.yml` ("Image", optional) and `field.field.node.speaker.field_image.yml` ("Image", optional), both with `handler_settings.target_bundles: {image: image}` and the Media Library widget.
    *   Delete `field.field.node.speaker.field_photo.yml`, `field.storage.node.field_photo.yml`, `image.style.speaker_small.yml`, `image.style.speaker_large.yml` and `responsive_image.styles.speaker_photo.yml`.
    *   Modify `core.entity_form_display.node.session.default.yml`, `core.entity_form_display.node.speaker.default.yml`, `core.entity_view_display.node.session.default.yml` (`page` view mode), `core.entity_view_display.node.session.teaser.yml` (`card`) and `core.entity_view_display.node.speaker.teaser.yml` (`avatar`), and every other file that `grep -l field_photo config/ recipes/` returns, listed in the commit message.
    *   Create `core.entity_view_display.node.speaker.default.yml` with `field_image` hidden: adding the field in the Field UI would otherwise create this display and show the image on speaker pages.

#### 16. `web/modules/custom/cedar_hollow_core/tests/src/Unit/ResponsiveImageRatioTest.php` and `web/modules/custom/cedar_hollow_core/tests/fixtures/responsive_image_mixed/` (Create)

*   **Type / Scope**: PHPUnit unit test and its committed fixture.
*   **Proposed Changes**: A checker method takes a directory, reads each `responsive_image.styles.*.yml`, loads its mapped image styles and fallback, and returns one violation per responsive style that maps a style without `focal_point_scale_and_crop`, maps more than one width-to-height ratio (compared with a tolerance of ±0.01), or has a fallback outside its mapping. `testSiteConfig()` asserts `config/` yields none; `testMixedFixture()` asserts the fixture (one responsive style mapping `16_9_640` and `3_2_400`, plus those two image styles) yields exactly that one violation. Written before item 15, it fails first on `speaker_photo` (scale only), which is recorded in item 15's commit message, and passes once item 15 deletes that style.

#### 17. `web/themes/custom/cedar_hollow/components/molecules/hero/` (Create: `hero.component.yml`, `hero.twig`, `hero.css`, `hero.stories.js`)

*   **Type / Scope**: Component (molecule, group `Components`, `noUi: true`).
*   **Proposed Changes**: Slot `image`, rendered in the hero block; `.hero__img` takes `inline-size: 100%` and `block-size: auto`. The story file's title is `Components/Hero`, which gives the story id `components-hero--default`. The `Default` story imports its fixture image and uses real `<img>` markup with `loading="eager"`, `fetchpriority="high"`, an AVIF `srcset` from the committed fixtures, `width` and `height`.

#### 18. `web/themes/custom/cedar_hollow/stories/fixtures/images/` (Create)

*   **Type / Scope**: Storybook image fixtures.
*   **Proposed Changes**: AVIF files at 640x360, 400x267 and 96x96, each under 60 KB (GD writes AVIF at PHP's default quality, which the site cannot set, and the 640x360 crop comes out at 52 KB), made on DDEV by running the `16_9_640`, `3_2_400` and `1_1_96` styles on the CC0 photo used in spike I2 ("Forest of Himalayan Cedar Tress in Shimla", Wikimedia Commons), with a `LICENCE.md` beside them naming the source and licence. Stories `import` each file, so Vite copies it into the static Storybook build the visual test serves (the Storybook config has no static directory). Visual baselines never depend on a remote image.

#### 19. `web/themes/custom/cedar_hollow/templates/block/block--block-content--type--hero.html.twig` (Create)

*   **Type / Scope**: Block template (core suggestion `block__block_content__type__hero`).
*   **Proposed Changes**: Includes `cedar_hollow:hero` with `image: content`. Block content builds its fields in a `#pre_render` callback (`EntityViewBuilder::view()`), after the block template's variables are prepared, so `content.field_media` does not exist there; the hero view display shows only the image, so passing `content` renders just that.

#### 20. `web/themes/custom/cedar_hollow/src/Hook/ThemeHooks.php` (Modify)

*   **Type / Scope**: Theme hooks.
*   **Proposed Changes**:
    *   `preprocess_media` (Image bundle): merges the attributes for the media view mode (a constant map: `hero`, `page`, `card`, `avatar`, with the classes and attributes in the Technical Plan) into each `field_media_image` item's `#attributes`, keeping the `loading` value the formatter already set unless the map sets its own.
    *   `preprocessNodeSpeaker` no longer adds the `speaker-byline__img` class to the image formatter's `#attributes`; the `avatar` view mode carries it.

#### 21. `web/themes/custom/cedar_hollow/templates/content/node--session--full.html.twig`, `node--session--teaser.html.twig`, `node--speaker--teaser.html.twig` (Modify)

*   **Type / Scope**: Node templates.
*   **Proposed Changes**: The full page renders `content.field_image` above `.session__summary` in a wrapper with the extra class `session__image`, adds `'field_image'` to its `content|without(...)` list, and wraps the body in `prose`. The teaser passes `content.field_image` into the card's `image` slot. The speaker teaser passes `content.field_image` instead of `content.field_photo` and changes `content|without('field_photo')` to `content|without('field_image')`.

#### 22. `web/themes/custom/cedar_hollow/css/sessions.css` (Modify)

*   **Type / Scope**: Session page CSS.
*   **Proposed Changes**: `.session__image` sits above `.session__summary` in the session layout; `.session__img` takes `inline-size: 100%` and `block-size: auto`.

#### 23. `web/themes/custom/cedar_hollow/components/molecules/card/` (Modify: `card.css`, `card.stories.js`)

*   **Type / Scope**: Component.
*   **Proposed Changes**: `.card__img` takes `inline-size: 100%` and `block-size: auto` in the card's image area; a `SessionCardWithImage` story whose imported 3:2 fixture `<img>` carries `class="card__img"`, which the BEM parity test compares with `/sessions`.

#### 24. `web/themes/custom/cedar_hollow/components/molecules/speaker-byline/speaker-byline.stories.js` (Modify)

*   **Type / Scope**: Story.
*   **Proposed Changes**: The `WithPhoto` story uses the `avatar_1_1` markup with the 96x96 fixture.

#### 25. `tests/visual/visual.spec.ts` and `tests/visual/visual.spec.ts-snapshots/` (Modify)

*   **Type / Scope**: Visual regression.
*   **Proposed Changes**: Adds `components-hero--default`, `components-card--session-card-with-image` and `components-speaker-byline--with-photo` to the story list, adds `image/avif` to the served types, and regenerates baselines for the new stories, each reviewed before it is accepted.

### Stage 5: Main menu without layout shift

#### 26. `tests/e2e/layout-shift.spec.ts` (Create)

*   **Type / Scope**: Playwright.
*   **Proposed Changes**: At 412 by 823 CSS pixels, with images loading normally (blocked image requests log console errors, which every test refuses, and a loaded image with `width` and `height` reserves its space anyway), sums the `layout-shift` entries whose `hadRecentInput` is false on `/` and fails when the sum is above 0. Run first against the current menu, where it fails; the failure is recorded in item 27's commit message.

#### 27. `web/themes/custom/cedar_hollow/templates/navigation/menu--main.html.twig`, `css/main-menu.css`, `js/menu-toggle.js` (Modify)

*   **Type / Scope**: Main menu.
*   **Proposed Changes**: The button renders without `hidden`; CSS hides it under `@media (scripting: none)` and at widths of 48rem and above; below 48rem the list is hidden under `@media (scripting: enabled)` until it has `.is-open`; the open list's column layout, scoped today to `.main-menu--collapsible`, moves under `@media (scripting: enabled) and (width < 48rem)`, and the script no longer adds that class; it only handles the button's click and `aria-expanded`.

#### 28. `web/themes/custom/cedar_hollow/components/organisms/site-header/site-header.stories.js` and its visual baseline (Modify)

*   **Type / Scope**: Story.
*   **Proposed Changes**: Updated to the new menu markup: the button renders without `hidden`; the baseline is regenerated after review.

### Stage 6: Images and content

#### 29. `scripts/demo-images.json` (Create)

*   **Type / Scope**: Image manifest, the contract between the fetch script, the image script and the rebuild check.
*   **Proposed Changes**: One entry per photo:

    | Key | Type | Rule |
    | --- | --- | --- |
    | `uuid` | UUID | The media item's fixed UUID. |
    | `commons_title` | string | The Commons file title, `File:...`; the media name is this title without `File:` and the extension. |
    | `commons_page_id` | integer | Also the local file name. |
    | `revision_timestamp` | ISO 8601 | The Commons revision the licence was read from. |
    | `use` | string | `hero`, `session`, `speaker` or `embed`. |
    | `target` | string or null | A session path alias for `session` and `embed`, a speaker name for `speaker`, null for `hero`. |
    | `ratio` | string | `16:9`, `3:2` or `1:1`; for `embed`, `16:9` selects `embed_wide` and `3:2` selects `embed_photo`. |
    | `alt` | string | What the image shows. |
    | `focal` | object | `x` and `y` as percentages of width and height, 0 to 100. |
    | `caption` | string or null | Required for `embed`, otherwise null. |
    | `reviewed` | date or null | The date the image and its alt text were reviewed by hand (also recorded in `docs/checks.md`); null until then. |

    One hero, twelve session images, one image per speaker, and three embeds (two `16:9`, one `3:2`) in three sessions.

#### 30. `scripts/fetch-demo-images.php` (Create)

*   **Type / Scope**: One-time preparation script, run with `ddev drush php:script`.
*   **Proposed Changes**: For each entry, queries the Commons API for `LicenseShortName`, `Artist`, `LicenseUrl`, the file page URL, the page's templates and the rendition fitted in 2560 by 2560; fetches the hero at 2304 pixels wide; applies the licence mapping, the personality-rights refusal, the hero rule and the size caps (900 KB hero, 400 KB others) from the Technical Plan; writes each file as `<page ID>.<extension>` and a `fetched.json` keyed by page ID (`file`, `source_url`, `creator`, `licence`, `licence_url`, `width`, `height`, `bytes`, `revision_timestamp`) to `/tmp/cedar-hollow-images/` in the DDEV web container; checks the 10 MB total.

#### 31. `scripts/place-demo-images.php` (Create)

*   **Type / Scope**: The image script, run with `drush php:script`.
*   **Proposed Changes**: Creates media with fixed UUIDs and focal points, sets `field_verified` only on entries with `reviewed`, validates before saving, and stores files as `public://demo-images/<page id>.<extension>`; attaches media by path alias and speaker name; converts a session body by splitting the plain text on blank lines, escaping each paragraph, turning single newlines into `<br>` and wrapping each paragraph in `<p>` (the summary is left as it is); inserts each embed after the first paragraph and skips a body that already contains the media UUID; creates the hero block content and the credits menu link with fixed UUIDs. It finds the manifest through `__DIR__`, because Pantheon runs it from `web/`. Prints what it created or changed.

#### 32. `scripts/check-demo-images.php` (Create) and `scripts/rebuild.sh` (Modify)

*   **Type / Scope**: Rebuild check; `rebuild.sh` gains `ddev drush php:script scripts/check-demo-images.php` after `drush deploy`.
*   **Proposed Changes**: Checks that every Image media and crop UUID in the export exists on the site and that each crop's `x`, `y`, `width` and `height` match the exported values; that every exported file exists in `public://`; that the hero original is at most 900 KB, every other original at most 400 KB and their total at most 10 MB; and that a `16_9_640` derivative of one shipped image is AVIF at 640x360. Exits non-zero, listing each failure.

#### 33. `scripts/export-demo-content.sh` (Modify)

*   **Type / Scope**: Content export.
*   **Proposed Changes**: Adds `ddev drush content:export media --bundle=image --with-dependencies --dir="$DIR"`, `ddev drush content:export crop --dir="$DIR"` and `ddev drush content:export block_content --bundle=hero --with-dependencies --dir="$DIR"`.

#### 34. `recipes/cedar_hollow_demo_content/content/`, `recipes/cedar_hollow_demo_content/recipe.yml` and `config/block.block.cedar_hollow_hero.yml` (Modify, Create)

*   **Type / Scope**: Default content and the hero placement.
*   **Proposed Changes**: Re-exported after the fetch and image scripts run on DDEV: media, files and binaries, crops, the hero block content, the updated sessions and speakers, and the credits menu link; the recipe description mentions images. The hero placement (theme `cedar_hollow`, region `highlighted`, front-page visibility) is committed together with the content it depends on.

#### 35. `tests/e2e/images.spec.ts` (Create)

*   **Type / Scope**: Playwright, DDEV.
*   **Proposed Changes**: `loading="eager"` and `fetchpriority="high"` on `img.hero__img` and `img.session__img`; `loading="eager"` on `img.card__img`; `loading="lazy"` on byline and embed images; a `sizes` attribute on card, session, byline and embed images; `/credits` lists titles and licence links and shows the header notice. Run first against the site before item 34's content, where it fails; the failure is recorded in item 34's commit message.

#### 36. `tests/smoke/smoke.spec.ts` (Modify)

*   **Type / Scope**: Playwright, read-only, runs against DDEV and Pantheon.
*   **Proposed Changes**: `/sessions/caching-render-arrays` has `img.session__img` with an `.avif` URL in its `srcset`, and its `src` answers 200.

#### 37. `tests/a11y/a11y.spec.ts` (Modify)

*   **Type / Scope**: Playwright accessibility.
*   **Proposed Changes**: Adds `/credits`.

### Stage 7: Measurement and documentation

#### 38. `tests/perf/warm-derivatives.mjs` and `tests/package.json` (Create, Modify)

*   **Type / Scope**: Warm-up script.
*   **Proposed Changes**: Given a base URL, fetches the HTML of `/`, `/sessions`, `/credits` and each session path from `scripts/demo-images.json`, collects every URL in `src` and `srcset`, requests each once, and reports any response other than 200; sends `Deterrence-Bypass: 1` (the header that skips Pantheon's sandbox warning page) to hosts ending in `.pantheonsite.io`. No browser is needed. Node does not trust DDEV's local certificate, so on DDEV it runs with `NODE_EXTRA_CA_CERTS="$(mkcert -CAROOT)/rootCA.pem"` (in CI, the CA DDEV installs in the runner). Run as `npm run warm -- "$BASE_URL"` in CI (which serves `https://cedar-hollow.ddev.site` without a port), `npm run warm -- https://cedar-hollow.ddev.site:30001` locally, and `npm run warm -- https://dev-cedar-hollow-demo.pantheonsite.io` after a Pantheon deploy.

#### 39. `tests/lighthouserc.cjs`, `tests/perf/lcp-checks.mjs`, `tests/package.json`, `tests/package-lock.json` (Create, Modify)

*   **Type / Scope**: Performance check.
*   **Proposed Changes**:
    *   `@lhci/cli` pinned to 0.15.1 (which runs Lighthouse 12.6.1) as a dev dependency, and a `test:perf` script running `lhci autorun` then `node perf/lcp-checks.mjs`.
    *   `lighthouserc.cjs` builds `ci.collect.url` from `process.env.BASE_URL` for `/`, `/sessions` and `/sessions/caching-render-arrays`; `numberOfRuns: 5`; `settings.onlyCategories: ["performance"]`; `settings.chromeFlags: "--headless=new --ignore-certificate-errors"`.
    *   `ci.assert.assertMatrix` with two entries matching all three URLs, both with `aggregationMethod: "median-run"`: one with `largest-contentful-paint` error at `maxNumericValue: 2500` and `cumulative-layout-shift` error at `maxNumericValue: 0.1`, one with `largest-contentful-paint` warn at `maxNumericValue: 2000`.
    *   `ci.upload: {target: "filesystem", outputDir: "perf/reports"}`.
    *   `lcp-checks.mjs` reads `perf/reports/manifest.json`, opens each entry with `isRepresentativeRun: true`, and fails if the `largest-contentful-paint-element` node selector on `/` does not end in `img.hero__img`, if `lcp-lazy-loaded` reports a lazy LCP image, or if `network-requests` contains a stylesheet or script with status 403; it prints `server-response-time` beside LCP.
    *   Pantheon run: `CHROME_PATH` set to Playwright's `chromium.executablePath()`, `BASE_URL=https://dev-cedar-hollow-demo.pantheonsite.io`, and `--collect.settings.extraHeaders='{"Deterrence-Bypass":"1"}'`.

#### 40. `.github/workflows/ci.yml` (Modify)

*   **Type / Scope**: CI.
*   **Proposed Changes**: In the existing end-to-end job, after the rebuild and the Playwright projects, one step with `timeout-minutes: 20` running `npm run warm -- "$BASE_URL" && (npm run test:perf || npm run test:perf)`: GitHub Actions has no built-in step retry, so the shell runs the check a second time only if the first fails. A following step uploads `tests/perf/reports/` with `if: always()`. The PHPCS step adds `scripts/fetch-demo-images.php`, `scripts/place-demo-images.php` and `scripts/check-demo-images.php`. The workflow passes `act --dryrun` before it is pushed.

#### 41. `docs/checks.md`, `docs/accessibility.md` (Modify)

*   **Type / Scope**: Records.
*   **Proposed Changes**: The warmed Pantheon run (date, commit, method, LCP, CLS, server response time, LCP element); the manual review of every shipped image and its alt text (the dates match the manifest's `reviewed` keys); each licence re-checked against its Commons file page and `revision_timestamp` before the demo URL is shared with reviewers, with the date; the post-review deletion of unverified uploads; `/credits` in the accessibility page list with its axe result.

#### 42. `docs/how-this-was-built.md` (Modify)

*   **Type / Scope**: Write-up.
*   **Proposed Changes**: A section on images: the two render paths; ratio naming and one ratio per responsive style as the workaround for core issues #3516726 and #3523451; AVIF, and its WebP fallback, which applies only when the server's image toolkit cannot encode AVIF; eager first images with `fetchpriority` set by the theme; Focal Point crops and why crops are exported separately; embeds and their export; config actions where a recipe cannot replace existing config; the menu layout shift found while measuring; licences, the credits page and the Pantheon rollout. Each claim names its evidence.

#### 43. `README.md` (Modify)

*   **Type / Scope**: Project README.
*   **Proposed Changes**: Where the image pipeline lives (the media recipe, the ratio test, the image tests and the performance check), how to run `npm run warm` and `npm run test:perf`, and a pointer to the one-time Pantheon image rollout in this design.

### Verification Plan

*   **Build**: `scripts/rebuild.sh` (including `check-demo-images.php`), then `ddev drush config:status` with no differences; `ddev exec -d /var/www/html/web/themes/custom/cedar_hollow npm run build`.
*   **PHP**: `ddev exec vendor/bin/phpunit -c web/core/phpunit.xml.dist web/modules/custom/cedar_hollow_core`; `ddev exec vendor/bin/phpcs --standard=Drupal,DrupalPractice --extensions=php,module,inc,install,theme web/modules/custom web/themes/custom/cedar_hollow/src scripts/fetch-demo-images.php scripts/place-demo-images.php scripts/check-demo-images.php`; `ddev exec vendor/bin/phpstan analyse --no-progress`.
*   **Theme**: `ddev exec -d /var/www/html/web/themes/custom/cedar_hollow npm run lint:css`; `ddev exec -d /var/www/html/web/themes/custom/cedar_hollow npm run build` (the Storybook build) with no errors, and the Playwright `visual` project rendering every listed story; each component without `noUi` passes Canvas's `SingleDirectoryComponentDiscovery::checkRequirements()`, run with `ddev drush php:eval`.
*   **Browser**: Playwright `e2e`, `a11y`, `smoke` and `visual` projects on DDEV; every changed page viewed at 412 and 1280 CSS pixels wide with no console errors.
*   **Performance**: `npm run warm` then `npm run test:perf` on DDEV; one warmed run against Pantheon Dev recorded in `docs/checks.md`.
*   **CI**: every job green on the final commit.
*   **Deploy**: the six rollout steps, then `config:status` with no differences on Pantheon.
*   **Coverage**: Goal 1 item 32; Goal 2 item 16; Goal 3 items 35 and 39; Goal 4 items 9 and 35; Goal 5 items 30 and 41; Goal 6 item 35; Goal 7 item 14; Goal 8 item 32; Goal 9 item 26; Goal 10 items 39 and 41; Goal 11 item 37; Goal 12 items 2 and 42. CUJ 1 items 26, 35 and 39; CUJ 2 item 35; CUJ 3 items 9 and 10; CUJ 4 item 32; CUJ 5 item 35.

--------------------------------------------------------------------------------

*Drafted with EGM*
