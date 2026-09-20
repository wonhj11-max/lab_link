import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizePaperReview, requireUuid } from './review-core.mjs';

const valid = {
  title: 'A reviewed paper', year: 2026, journal: 'Journal', doi: '10.1000/ABC',
  source_url: 'https://doi.org/10.1000/abc', faculty_name: 'Kim', reviewer: 'operator',
};

test('normalizes a minimal reviewed paper', () => {
  const result = normalizePaperReview(valid);
  assert.equal(result.doi, '10.1000/abc');
  assert.equal(result.corresponding_status, 'unknown');
  assert.equal(result.affiliation_scope, 'unverified');
  assert.equal(result.summary, null);
});

test('requires evidence before confirming corresponding authorship', () => {
  assert.throws(() => normalizePaperReview({ ...valid, corresponding_status: 'confirmed' }), /evidence_url/);
  assert.equal(normalizePaperReview({ ...valid, corresponding_status: 'confirmed', evidence_url: 'https://example.org/evidence' }).corresponding_status, 'confirmed');
});

test('does not accept an ungrounded summary', () => {
  assert.throws(() => normalizePaperReview({ ...valid, summary: 'Summary' }), /summary_basis/);
  assert.throws(() => normalizePaperReview({ ...valid, summary_basis: 'abstract' }), /without a summary/);
});

test('rejects malformed identifiers and URLs', () => {
  assert.throws(() => normalizePaperReview({ ...valid, doi: 'not-a-doi' }), /valid DOI/);
  assert.throws(() => normalizePaperReview({ ...valid, source_url: 'http://example.org' }), /HTTPS/);
  assert.throws(() => requireUuid('candidate-1'), /UUID/);
});
