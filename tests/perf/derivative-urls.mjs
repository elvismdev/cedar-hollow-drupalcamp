// Returns the image derivative URLs (paths under /files/styles/) named by a
// page's src and srcset attributes, resolved against base and kept only when
// they are on base's origin. Page text can name any host, and the warm-up's
// requests carry Pantheon's bypass headers, so it never requests another one.
// Candidates that do not parse as a URL are returned in invalid, as written.
export function derivativeUrls(html, base) {
  const origin = new URL(base).origin;
  const urls = new Set();
  const invalid = new Set();
  for (const [, attribute, value] of html.matchAll(/\s(src|srcset)="([^"]+)"/g)) {
    const candidates = attribute === 'src' ? [value] : value.split(',').map((candidate) => candidate.trim().split(/\s+/)[0]);
    for (const candidate of candidates) {
      if (!/\/files\/styles\//.test(candidate)) continue;
      const decoded = candidate.replaceAll('&amp;', '&');
      if (!URL.canParse(decoded, base + '/')) {
        invalid.add(decoded);
        continue;
      }
      const url = new URL(decoded, base + '/');
      if (url.origin === origin) urls.add(url.href);
    }
  }
  return { urls: [...urls], invalid: [...invalid] };
}

// Returns the fetch options for url: the headers only when url is on base's
// origin, and never fetch's own redirect handling, because Node's fetch sends
// custom headers on to whatever host a redirect names. fetchSameOrigin()
// follows the redirects that stay on base's origin, with or without headers.
export function requestInit(url, base, headers) {
  if (Object.keys(headers).length === 0 || new URL(url).origin !== new URL(base).origin) return { redirect: 'manual' };
  return { headers, redirect: 'manual' };
}

export const MAX_REDIRECTS = 5;

// Fetches url, following a redirect only while its Location resolves to base's
// origin and for at most MAX_REDIRECTS hops; each hop gets its options from
// requestInit(). A redirect to another origin, or one past the bound, is
// returned as its 3xx response without requesting the Location.
export async function fetchSameOrigin(url, base, headers) {
  const origin = new URL(base).origin;
  let current = url;
  for (let hop = 0; ; hop += 1) {
    const response = await fetch(current, requestInit(current, base, headers));
    const location = response.headers.get('location');
    if (response.status < 300 || response.status > 399 || !location) return response;
    const next = new URL(location, current);
    if (next.origin !== origin || hop === MAX_REDIRECTS) return response;
    await response.arrayBuffer();
    current = next.href;
  }
}

// Fetches url as fetchSameOrigin() does, without throwing: when fetch refuses
// the URL (credentials in it, a blob: URL) or a Location does not parse, the
// result's status is "error (<reason>)" and response is null, so one bad URL
// is reported as a failure instead of stopping the run.
export async function fetchResult(url, base, headers) {
  try {
    const response = await fetchSameOrigin(url, base, headers);
    return { status: response.status, response };
  } catch (error) {
    return { status: `error (${error.cause?.message ?? error.message})`, response: null };
  }
}
