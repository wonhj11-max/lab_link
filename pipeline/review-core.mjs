const HTTPS_URL = /^https:\/\/[^\s]+$/i;
const DOI = /^10\.\d{4,9}\/\S+$/i;
const CORRESPONDING = new Set(['confirmed', 'unknown', 'not_corresponding']);
const AFFILIATION = new Set(['current_lab', 'previous_affiliation', 'unverified']);
const SUMMARY_BASIS = new Set(['abstract', 'full_text']);

function optionalText(value) {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string') throw Error('Optional text fields must be strings.');
  return value.trim() || null;
}

export function normalizePaperReview(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw Error('Review must be a JSON object.');
  const title = optionalText(input.title);
  const facultyName = optionalText(input.faculty_name);
  const sourceUrl = optionalText(input.source_url);
  const reviewer = optionalText(input.reviewer);
  const year = Number(input.year);
  const doi = optionalText(input.doi)?.toLowerCase() ?? null;
  const journal = optionalText(input.journal);
  const correspondingStatus = optionalText(input.corresponding_status) ?? 'unknown';
  const evidenceUrl = optionalText(input.evidence_url);
  const affiliationScope = optionalText(input.affiliation_scope) ?? 'unverified';
  const summary = optionalText(input.summary);
  const summaryBasis = optionalText(input.summary_basis);
  const reviewNote = optionalText(input.review_note) ?? '';

  if (!title) throw Error('title is required.');
  if (!Number.isInteger(year) || year < 1800 || year > 2200) throw Error('year must be an integer between 1800 and 2200.');
  if (!sourceUrl || !HTTPS_URL.test(sourceUrl)) throw Error('source_url must be an HTTPS URL.');
  if (!facultyName) throw Error('faculty_name is required.');
  if (!reviewer) throw Error('reviewer is required.');
  if (doi && !DOI.test(doi)) throw Error('doi must have a valid DOI shape.');
  if (!CORRESPONDING.has(correspondingStatus)) throw Error('Invalid corresponding_status.');
  if (!AFFILIATION.has(affiliationScope)) throw Error('Invalid affiliation_scope.');
  if (evidenceUrl && !HTTPS_URL.test(evidenceUrl)) throw Error('evidence_url must be an HTTPS URL.');
  if (correspondingStatus === 'confirmed' && !evidenceUrl) throw Error('Confirmed corresponding authorship requires evidence_url.');
  if (summary && !summaryBasis) throw Error('A summary requires summary_basis.');
  if (!summary && summaryBasis) throw Error('summary_basis cannot be set without a summary.');
  if (summaryBasis && !SUMMARY_BASIS.has(summaryBasis)) throw Error('Invalid summary_basis.');

  return {
    title,
    year,
    journal,
    doi,
    source_url: sourceUrl,
    faculty_name: facultyName,
    corresponding_status: correspondingStatus,
    evidence_url: evidenceUrl,
    affiliation_scope: affiliationScope,
    summary,
    summary_basis: summaryBasis,
    reviewer,
    review_note: reviewNote,
  };
}

export function requireUuid(value, label = 'candidate id') {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value ?? '')) {
    throw Error(`${label} must be a UUID.`);
  }
  return value;
}
