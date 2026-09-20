import { readFile } from 'node:fs/promises';
import { createClient } from '@supabase/supabase-js';
import { normalizePaperReview, requireUuid } from './review-core.mjs';

const [command, candidateId, ...args] = process.argv.slice(2);
const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SECRET_KEY;
if (!url || !key) throw Error('Set server-only SUPABASE_URL and SUPABASE_SECRET_KEY.');
const db = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

async function rpc(name, params = {}) {
  const { data, error } = await db.rpc(name, params);
  if (error) throw Error(`${name}: ${error.message}`);
  return data;
}

function option(name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
}

if (command === 'list') {
  const limit = Number(option('--limit') ?? 50);
  if (!Number.isInteger(limit) || limit < 1 || limit > 200) throw Error('--limit must be between 1 and 200.');
  console.log(JSON.stringify(await rpc('list_paper_candidates', { p_limit: limit }), null, 2));
} else if (command === 'approve') {
  requireUuid(candidateId);
  const file = option('--file');
  if (!file) throw Error('Use --file with a reviewed paper JSON document.');
  const review = normalizePaperReview(JSON.parse(await readFile(file, 'utf8')));
  console.log(JSON.stringify(await rpc('approve_paper_candidate', { p_candidate_id: candidateId, p_review: review }), null, 2));
} else if (command === 'reject') {
  requireUuid(candidateId);
  const reviewer = option('--reviewer')?.trim();
  const note = option('--note')?.trim();
  if (!reviewer || !note) throw Error('Rejection requires --reviewer and --note.');
  console.log(JSON.stringify(await rpc('reject_paper_candidate', {
    p_candidate_id: candidateId,
    p_reviewer: reviewer,
    p_review_note: note,
  }), null, 2));
} else {
  console.error('Usage:\n  node pipeline/review.mjs list [--limit 50]\n  node pipeline/review.mjs approve <candidate-uuid> --file review.json\n  node pipeline/review.mjs reject <candidate-uuid> --reviewer <name> --note <reason>');
  process.exitCode = 1;
}
