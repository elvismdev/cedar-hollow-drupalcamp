import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { randomBytes } from 'node:crypto';
import { MAX_REDIRECTS, fetchSameOrigin } from './derivative-urls.mjs';

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
    const location = { '/': '/home', '/home': '/final', '/away': `${otherBase}/x`, '/loop': '/loop' }[req.url];
    if (location) res.writeHead(302, { location });
    res.end(location ? '' : 'ok');
  });
  base = await listen(site);
});

after(() => {
  site.close();
  other.close();
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
