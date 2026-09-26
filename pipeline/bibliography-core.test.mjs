import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeBibliographyText, extractDoi, extractAuthorRoles } from './bibliography-core.mjs';

test('normalizes harmless title typography but preserves letters and digits', () => {
  assert.equal(normalizeBibliographyText('Ni-rich: Cathode &amp; Cell'), normalizeBibliographyText('NI rich Cathode and Cell'));
});
test('extracts DOI from publisher paths without query strings', () => {
  assert.equal(extractDoi('https://pubs.acs.org/doi/full/10.1021/acsenergylett.5c02831?x=1'), '10.1021/acsenergylett.5c02831');
});
test('extracts explicit contribution markers only', () => {
  assert.deepEqual(extractAuthorRoles('First Author†, Second Author†, Senior Author*'), { corresponding: ['Senior Author'], coFirst: ['First Author', 'Second Author'] });
});
