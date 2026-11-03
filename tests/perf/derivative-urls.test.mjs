import { test } from 'node:test';
import assert from 'node:assert/strict';
import { derivativeUrls } from './derivative-urls.mjs';

const base = 'https://dev-cedar-hollow.example.test';

test('keeps a same-origin derivative, relative or absolute', () => {
  const html = '<img src="/sites/default/files/styles/16_9_640/public/a.jpg?itok=x&amp;h=1">'
    + '<img srcset="https://dev-cedar-hollow.example.test/sites/default/files/styles/16_9_1280/public/a.jpg 1280w">';
  assert.deepEqual(derivativeUrls(html, base), [
    `${base}/sites/default/files/styles/16_9_640/public/a.jpg?itok=x&h=1`,
    `${base}/sites/default/files/styles/16_9_1280/public/a.jpg`,
  ]);
});

test('drops an absolute derivative URL on another host', () => {
  const html = '<img src="https://attacker.test/sites/default/files/styles/x/public/a.jpg">'
    + '<img srcset="https://attacker.test/files/styles/y/a.jpg 640w, http://dev-cedar-hollow.example.test/files/styles/z/a.jpg 1280w">';
  assert.deepEqual(derivativeUrls(html, base), []);
});

test('drops a protocol-relative derivative URL on another host', () => {
  const html = '<img src="//attacker.test/sites/default/files/styles/x/public/a.jpg">';
  assert.deepEqual(derivativeUrls(html, base), []);
});

test('ignores src values that are not derivatives', () => {
  const html = '<script src="/core/misc/drupal.js"></script><img src="/sites/default/files/a.jpg">';
  assert.deepEqual(derivativeUrls(html, base), []);
});
