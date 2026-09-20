import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { createClient } from '@supabase/supabase-js';

const YEAR_FROM = Number(process.env.PAPER_YEAR_FROM || 2022);
const YEAR_TO = Number(process.env.PAPER_YEAR_TO || 2026);
const shouldStage = process.argv.includes('--stage');
const contact = process.env.CRAWLER_CONTACT || 'https://github.com/wonhj11-max/lab_link';
const labs = JSON.parse(await readFile(new URL('./lab-paper-sources.json', import.meta.url), 'utf8'));
const PAPER_TYPES = new Set(['article','review','preprint','editorial','conference-paper','book-chapter']);

if (!Number.isInteger(YEAR_FROM) || !Number.isInteger(YEAR_TO) || YEAR_FROM > YEAR_TO) {
  throw Error('PAPER_YEAR_FROM and PAPER_YEAR_TO must define a valid year range.');
}

async function requestJson(url, attempt = 0) {
  const response = await fetch(url, {
    headers: { 'User-Agent': `LabLinkPaperDiscovery/0.1 (${contact})` },
    signal: AbortSignal.timeout(30_000),
  });
  if ((response.status === 429 || response.status >= 500) && attempt < 3) {
    await new Promise(resolve => setTimeout(resolve, 1000 * 2 ** attempt));
    return requestJson(url, attempt + 1);
  }
  if (!response.ok) throw Error(`OpenAlex request failed (${response.status})`);
  return response.json();
}

function shortId(value) {
  return value?.split('/').pop() || '';
}

function normalizeWork(work, lab) {
  if (!PAPER_TYPES.has(work.type)) return null;
  const doi = work.doi?.replace(/^https:\/\/doi\.org\//i, '').trim().toLowerCase();
  if (!doi) return null;
  const faculty = work.authorships?.find(item => shortId(item.author?.id) === lab.openalex_author_id);
  if (!faculty) return null;
  const institutions = faculty.institutions || [];
  const currentLab = institutions.some(item => shortId(item.id) === lab.institution_id);
  const authors = (work.authorships || []).map(item => item.author?.display_name).filter(Boolean);
  return {
    doi,
    title: String(work.title || doi).trim(),
    year: work.publication_year,
    publication_date: work.publication_date,
    journal: work.primary_location?.source?.display_name || null,
    work_type: work.type || null,
    source_url: `https://doi.org/${doi}`,
    authors,
    faculty_name: lab.faculty_name,
    corresponding_status: faculty.is_corresponding === true ? 'confirmed' : 'unknown',
    affiliation_scope: currentLab ? 'current_lab' : 'unverified',
    evidence_url: lab.evidence_url,
    openalex_url: work.id,
    openalex_author_id: lab.openalex_author_id,
    orcid: lab.orcid,
    data_source: 'OpenAlex',
    discovered_at: new Date().toISOString(),
  };
}

async function discover(lab) {
  let cursor = '*';
  const papers = new Map();
  do {
    const filter = [
      `author.id:${lab.openalex_author_id}`,
      `from_publication_date:${YEAR_FROM}-01-01`,
      `to_publication_date:${YEAR_TO}-12-31`,
      'has_doi:true',
    ].join(',');
    const url = new URL('https://api.openalex.org/works');
    url.searchParams.set('filter', filter);
    url.searchParams.set('per-page', '200');
    url.searchParams.set('cursor', cursor);
    url.searchParams.set('mailto', contact.replace(/^mailto:/, '').includes('@') ? contact.replace(/^mailto:/, '') : '');
    const page = await requestJson(url);
    for (const work of page.results || []) {
      const paper = normalizeWork(work, lab);
      if (paper) papers.set(paper.doi, paper);
    }
    cursor = page.meta?.next_cursor;
  } while (cursor);
  return [...papers.values()].sort((a, b) =>
    (b.year - a.year) || String(b.publication_date).localeCompare(String(a.publication_date)) || a.title.localeCompare(b.title),
  );
}

const report = {
  generated_at: new Date().toISOString(),
  year_from: YEAR_FROM,
  year_to: YEAR_TO,
  source: 'https://openalex.org',
  labs: [],
};

for (const lab of labs) {
  const papers = await discover(lab);
  report.labs.push({ ...lab, paper_count: papers.length, papers });
  console.log(JSON.stringify({ lab_slug: lab.lab_slug, paper_count: papers.length }));
}

await mkdir('work', { recursive: true });
await writeFile('work/paper-discovery.json', JSON.stringify(report, null, 2));

if (shouldStage) {
  if (!process.env.SUPABASE_URL || !process.env.SUPABASE_SECRET_KEY) {
    throw Error('SUPABASE_URL and SUPABASE_SECRET_KEY are required with --stage.');
  }
  const db = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SECRET_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  for (const lab of report.labs) {
    const content = JSON.stringify(lab.papers);
    const contentHash = createHash('sha256').update(content).digest('hex');
    const { data, error } = await db.rpc('stage_discovered_papers', {
      p_lab_slug: lab.lab_slug,
      p_source_url: lab.evidence_url,
      p_content_hash: contentHash,
      p_candidates: lab.papers,
      p_year_from: YEAR_FROM,
      p_year_to: YEAR_TO,
    });
    if (error) throw Error(`${lab.lab_slug}: ${error.message}`);
    console.log(JSON.stringify({ lab_slug: lab.lab_slug, staged: data }));
  }
}
