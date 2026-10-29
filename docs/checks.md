# Manual checks

Run on 2026-10-28 against DDEV after `scripts/rebuild.sh`.

| Check | Steps | Result |
| --- | --- | --- |
| CUJ 3: an editor publishes a change | Log in as a user with only the `demo_editor` role, open "Try Canvas here" in Canvas, select the title component, change its text, Review, select the change, Publish | The new text appears on `/try-canvas` for an anonymous visitor |
| CUJ 4: a story leads to its source | Open a component's Docs tab in Storybook and follow "Source on GitHub" and "Surface original" | Both links open the component's folder (HTTP 200) |
| Mail is logged, not sent (Forward) | Submit "Forward this session to a friend" on a session with a random token in the message | A `cedar_hollow_core` log entry holds the mail with the token; nothing is sent |
| No PHP errors after browsing | Clear the log, request every page, read `/admin/reports/dblog` | No entries other than a deliberate 404 |
| Image review (2026-10-29) | Fetch the 24 photos in `scripts/demo-images.json`, view each fetched file at full size, compare it with its alt text and caption, and look for faces, name badges, screens or other text that identify a person | No identifiable person in any photo; one shows a torso and hands only. Every alt text describes what the photo shows. Each entry's `reviewed` key is set to 2026-10-29 |
