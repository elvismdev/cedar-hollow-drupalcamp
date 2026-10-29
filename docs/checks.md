# Manual checks

Run on 2026-10-28 against DDEV after `scripts/rebuild.sh`.

| Check | Steps | Result |
| --- | --- | --- |
| CUJ 3: an editor publishes a change | Log in as a user with only the `demo_editor` role, open "Try Canvas here" in Canvas, select the title component, change its text, Review, select the change, Publish | The new text appears on `/try-canvas` for an anonymous visitor |
| CUJ 4: a story leads to its source | Open a component's Docs tab in Storybook and follow "Source on GitHub" and "Surface original" | Both links open the component's folder (HTTP 200) |
| Mail is logged, not sent (Forward) | Submit "Forward this session to a friend" on a session with a random token in the message | A `cedar_hollow_core` log entry holds the mail with the token; nothing is sent |
| No PHP errors after browsing | Clear the log, request every page, read `/admin/reports/dblog` | No entries other than a deliberate 404 |
| Licence re-check (2026-10-29) | Run `scripts/fetch-demo-images.php`, which reads each file's licence, creator and current revision from Commons and refuses any revision other than the manifest's `revision_timestamp` | All 24 licences are CC0, public domain or CC BY, and every revision matches the manifest |
| Image review (2026-10-29) | Fetch the 24 photos in `scripts/demo-images.json`, view each fetched file at full size, compare it with its alt text and caption, and look for faces, name badges, screens or other text that identify a person | No identifiable person in any photo; one shows a torso and hands only. Every alt text describes what the photo shows. Each entry's `reviewed` key is set to 2026-10-29 |
| Pantheon Lighthouse, home page (2026-10-29 16:56 UTC, commit a7a44acb) | After the warm-up had requested all 118 image derivatives, one Lighthouse 13.4.1 run from Chrome DevTools on `https://dev-cedar-hollow-demo.pantheonsite.io/`: mobile, simulated throttling, performance only. Run from a browser because the edge answered automated clients with a bot challenge at the time | LCP 1829 ms, CLS 0, server response for the document 751 ms, performance score 96. The LCP element is `img.hero__img`, eager with `fetchpriority="high"`, served as a 156 KB AVIF. The edge's challenge script loaded on the same visit and made the longest main-thread task (216 ms); it does not affect LCP or CLS |
