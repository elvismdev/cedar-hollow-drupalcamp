import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { MAX_REDIRECTS, fetchResult, fetchSameOrigin } from './derivative-urls.mjs';

// Two loopback listeners on different ports are two origins: the site and
// another host. Each records the path and the bypass header it received.
const token = randomBytes(8).toString('hex');
const headers = { 'x-pantheon-bot-bypass': token };
const siteHits = [];
const otherHits = [];
let site;
let other;
let base;

function listen(server) {
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(`http://127.0.0.1:${server.address().port}`)));
}

before(async () => {
  other = http.createServer((req, res) => {
    otherHits.push({ path: req.url, bypass: req.headers['x-pantheon-bot-bypass'] });
    res.end('other');
  });
  const otherBase = await listen(other);
  site = http.createServer((req, res) => {
    siteHits.push({ path: req.url, bypass: req.headers['x-pantheon-bot-bypass'] });
    const location = { '/': '/home', '/home': '/final', '/away': `${otherBase}/x`, '/loop': '/loop', '/malformed': 'http://[x/files/styles/a.jpg' }[req.url];
    if (location) res.writeHead(302, { location });
    res.end(location ? '' : 'ok');
  });
  base = await listen(site);
});

// fetch keeps connections alive; ending them lets the servers close at once.
after(() => {
  for (const server of [site, other]) {
    server.closeAllConnections();
    server.close();
  }
});

test('follows same-origin redirects with the headers on every hop', async () => {
  siteHits.length = 0;
  const response = await fetchSameOrigin(`${base}/`, base, headers);
  assert.equal(response.status, 200);
  assert.deepEqual(siteHits, [
    { path: '/', bypass: token },
    { path: '/home', bypass: token },
    { path: '/final', bypass: token },
  ]);
});

test('does not contact the host a cross-origin redirect names', async () => {
  otherHits.length = 0;
  const response = await fetchSameOrigin(`${base}/away`, base, headers);
  assert.equal(response.status, 302);
  assert.deepEqual(otherHits, []);
});

test('stops a redirect loop at the bound', async () => {
  siteHits.length = 0;
  const response = await fetchSameOrigin(`${base}/loop`, base, headers);
  assert.equal(response.status, 302);
  assert.equal(siteHits.length, MAX_REDIRECTS + 1);
});

test('without headers, follows same-origin redirects and not another origin', async () => {
  siteHits.length = 0;
  otherHits.length = 0;
  const followed = await fetchSameOrigin(`${base}/`, base, {});
  assert.equal(followed.status, 200);
  assert.deepEqual(siteHits.map((hit) => hit.path), ['/', '/home', '/final']);
  const refused = await fetchSameOrigin(`${base}/away`, base, {});
  assert.equal(refused.status, 302);
  assert.deepEqual(otherHits, []);
});

test('reports a URL fetch refuses, or a malformed Location, as a failed result', async () => {
  const site = new URL(base);
  for (const url of [
    `${site.protocol}//user@${site.host}/sites/default/files/styles/x/public/a.jpg`,
    `blob:${base}/sites/default/files/styles/x/public/a.jpg`,
    `${base}/malformed`,
  ]) {
    const result = await fetchResult(url, base, headers);
    assert.match(String(result.status), /^error \(.+\)$/, url);
    assert.equal(result.response, null);
  }
  const ok = await fetchResult(`${base}/final`, base, headers);
  assert.equal(ok.status, 200);
  assert.equal(await ok.response.text(), 'ok');
});
