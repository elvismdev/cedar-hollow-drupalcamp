// Returns the image derivative URLs (paths under /files/styles/) named by a
// page's src and srcset attributes, resolved against base and kept only when
// they are on base's origin. Page text can name any host, and the warm-up's
// requests carry Pantheon's bypass headers, so it never requests another one.
export function derivativeUrls(html, base) {
  const origin = new URL(base).origin;
  const urls = new Set();
  for (const [, attribute, value] of html.matchAll(/\s(src|srcset)="([^"]+)"/g)) {
    const candidates = attribute === 'src' ? [value] : value.split(',').map((candidate) => candidate.trim().split(/\s+/)[0]);
    for (const candidate of candidates) {
      if (!/\/files\/styles\//.test(candidate)) continue;
      const url = new URL(candidate.replaceAll('&amp;', '&'), base + '/');
      if (url.origin === origin) urls.add(url.href);
    }
  }
  return [...urls];
}

// Returns the fetch options for url: the headers only when url is on base's
// origin, and then with redirects not followed, because Node's fetch sends
// custom headers on to whatever host a redirect names. A redirect answers
// with its 3xx status instead.
export function requestInit(url, base, headers) {
  if (Object.keys(headers).length === 0 || new URL(url).origin !== new URL(base).origin) return {};
  return { headers, redirect: 'manual' };
}
