# Manual checks

Run on 2026-10-28 against DDEV after `scripts/rebuild.sh`.

| Check | Steps | Result |
| --- | --- | --- |
| CUJ 3: an editor publishes a change | Log in as a user with only the `demo_editor` role, open "Try Canvas here" in Canvas, select the title component, change its text, Review, select the change, Publish | The new text appears on `/try-canvas` for an anonymous visitor |
| CUJ 4: a story leads to its source | Open a component's Docs tab in Storybook and follow "Source on GitHub" and "Surface original" | Both links open the component's folder (HTTP 200) |
| Mail is logged, not sent (Forward) | Submit "Forward this session to a friend" on a session with a random token in the message | A `cedar_hollow_core` log entry holds the mail with the token; nothing is sent |
| No PHP errors after browsing | Clear the log, request every page, read `/admin/reports/dblog` | No entries other than a deliberate 404 |
