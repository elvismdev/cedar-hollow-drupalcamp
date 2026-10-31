# Upstream of `skill/`

`skill/` is the `skills/security-audit/` directory of
[cloudflare/security-audit-skill](https://github.com/cloudflare/security-audit-skill)
at commit `c1c8a8c1471069fb0e188eeaff69b8e8db6564a8`, copied byte for byte, plus
that repository's root `LICENSE` (MIT, Copyright 2025-2026 Cloudflare, Inc.).

`skill/` is never edited in this repository. To update it, replace the whole
directory from a newer upstream commit, change the commit above, and do both in
a pull request of its own.

Check a copy against upstream:

```
git clone https://github.com/cloudflare/security-audit-skill /tmp/sa-upstream
git -C /tmp/sa-upstream checkout c1c8a8c1471069fb0e188eeaff69b8e8db6564a8
diff -r -x LICENSE /tmp/sa-upstream/skills/security-audit .github/security-audit/skill
cmp /tmp/sa-upstream/LICENSE .github/security-audit/skill/LICENSE
```

Both print nothing when the copy is exact.

The skill's own text uses en and em dashes. Because `skill/` is never edited, the
review practice's dash check excludes `.github/security-audit/skill/`.
