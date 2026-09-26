import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { load } from 'cheerio';
import { createClient } from '@supabase/supabase-js';
import { cleanAuthorName as cleanName, extractAuthorRoles as roleNames, extractDoi as doiFrom, normalizeBibliographyText as normalize } from './bibliography-core.mjs';

const YEAR_FROM = Number(process.env.PAPER_YEAR_FROM || 2022);
const YEAR_TO = Number(process.env.PAPER_YEAR_TO || 2026);
const shouldPublish = process.argv.includes('--publish');
const selected = process.env.LAB_SLUG?.split(',').filter(Boolean) || ['snu-mest', 'snu-aeml'];
const contact = process.env.CRAWLER_CONTACT || 'https://github.com/wonhj11-max/lab_link';
const root = 'work/scale-publications';
await mkdir(root, { recursive: true });

const configs = {
  'snu-mest': { faculty: 'Jang Wook Choi', source: 'https://mest.snu.ac.kr/%EB%85%BC%EB%AC%B8/', kind: 'mest' },
  'snu-aeml': { faculty: 'Kisuk Kang', source: 'https://energylab.snu.ac.kr/publications/journals.html', kind: 'aeml' },
};
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

async function fetchText(url) {
  const response = await fetch(url, { headers: { 'User-Agent': `LabLinkBibliography/2.0 (${contact})` }, signal: AbortSignal.timeout(30_000) });
  if (!response.ok) throw Error(`${url}: HTTP ${response.status}`);
  return response.text();
}
async function crossref(url) {
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const response = await fetch(url, { headers: { 'User-Agent': `LabLinkBibliography/2.0 (${contact})` }, signal: AbortSignal.timeout(30_000) });
    if (response.ok) return (await response.json()).message;
    if (response.status !== 429 && response.status < 500) throw Error(`Crossref ${response.status}`);
    await pause(1000 * 2 ** attempt);
  }
  throw Error('Crossref retry limit');
}
function fromRecord(base, record, officialAuthors) {
  const title = record.title?.[0]?.trim();
  if (!title || normalize(title) !== normalize(base.title)) throw Error('Crossref title mismatch');
  const authors = (record.author || []).map((author, index) => ({
    name: [author.given, author.family].filter(Boolean).join(' ') || author.name,
    order: index + 1,
    affiliations: (author.affiliation || []).map(x => x.name).filter(Boolean),
  }));
  if (!authors.some(author => normalize(author.name) === normalize(base.faculty))) throw Error('Faculty missing from Crossref authors');
  const roles = roleNames(officialAuthors);
  for (const author of authors) {
    author.first = author.order === 1;
    author.co_first = roles.coFirst.some(name => normalize(name) === normalize(author.name));
    author.corresponding = roles.corresponding.some(name => normalize(name) === normalize(author.name));
  }
  const date = record['published-print']?.['date-parts']?.[0] || record.published?.['date-parts']?.[0] || record['published-online']?.['date-parts']?.[0];
  const online = record['published-online']?.['date-parts']?.[0] || null;
  const year = Number(date?.[0]);
  if (year < YEAR_FROM || year > YEAR_TO) throw Error('Crossref year outside requested range');
  return {
    ...base, doi: record.DOI?.toLowerCase(), title, listing_year: base.listing_year, publication_year: year,
    publisher_source_url: `https://doi.org/${record.DOI?.toLowerCase()}`,
    publication_date: date || null, online_publication_date: online, journal: record['container-title']?.[0] || base.journal_citation,
    issn: record.ISSN || [], work_type: record.type, authors, metadata_status: 'matched',
    verification: { tier: 'official_exact', official_title_match: true, faculty_author_match: true, model_tokens: 0 },
    metadata_source: `https://api.crossref.org/works/${encodeURIComponent(record.DOI)}`, checked_at: new Date().toISOString(),
  };
}
async function mestEntries(config) {
  const $ = load(await fetchText(config.source));
  const rows = [];
  $('.e-loop-item.publication').each((_index, element) => {
    const node = $(element); const paragraphs = node.find('p').map((_i, p) => $(p).text().replace(/\s+/g, ' ').trim()).get();
    const listingYear = Number(paragraphs[0]); const link = node.find('a[href]').map((_i, a) => $(a).attr('href')).get().find(href => doiFrom(href));
    if (listingYear < YEAR_FROM || listingYear > YEAR_TO || !link) return;
    rows.push({ lab_slug: 'snu-mest', faculty: config.faculty, listing_year: listingYear, title: node.find('h1,h2,h3,h4,h5,h6').first().text().replace(/^\s*\d+\.\s*/, '').trim(), journal_citation: paragraphs[2] || '', official_authors: paragraphs[1] || '', source_url: config.source, publisher_source_url: link, doi: doiFrom(link) });
  });
  return rows;
}
async function aemlEntries(config) {
  const rows = [];
  for (let page = 1; page <= 25; page += 1) {
    const url = page === 1 ? config.source : `${config.source}?page=${page}&`;
    const $ = load(await fetchText(url)); const pageRows = [];
    $('.journals_wrap .tit').each((_index, element) => {
      const node = $(element); const titleText = node.find('.tit_01').text().replace(/\s+/g, ' ').trim();
      const match = titleText.match(/^\[(\d{4})\]\s*(.+)$/); if (!match) return;
      pageRows.push({ lab_slug: 'snu-aeml', faculty: config.faculty, listing_year: Number(match[1]), title: match[2].trim(), journal_citation: node.find('.tit_03').text().replace(/\s+/g, ' ').trim(), official_authors: node.find('.tit_02').text().replace(/\s+/g, ' ').trim(), source_url: url, publisher_source_url: url, doi: null });
    });
    rows.push(...pageRows.filter(row => row.listing_year >= YEAR_FROM && row.listing_year <= YEAR_TO));
    if (!pageRows.length || pageRows.every(row => row.listing_year < YEAR_FROM)) break;
    await pause(250);
  }
  return rows;
}
async function enrich(row) {
  const key = createHash('sha256').update(`${row.lab_slug}\n${row.doi || normalize(row.title)}`).digest('hex');
  const file = `${root}/${key}.json`;
  try { const cached = JSON.parse(await readFile(file, 'utf8')); if (cached.metadata_status === 'matched') return cached; } catch {}
  try {
    let record;
    if (row.doi) record = await crossref(`https://api.crossref.org/works/${encodeURIComponent(row.doi)}`);
    else {
      const response = await crossref(`https://api.crossref.org/works?query.title=${encodeURIComponent(row.title)}&rows=5`);
      const matches = response.items.filter(item => normalize(item.title?.[0]) === normalize(row.title));
      if (matches.length !== 1) throw Error('No unique exact Crossref title match');
      record = matches[0];
    }
    const result = fromRecord(row, record, row.official_authors); await writeFile(file, JSON.stringify(result, null, 2)); return result;
  } catch (error) { return { ...row, metadata_status: 'held', note: error.message, verification: { tier: 'held', model_tokens: 0 } }; }
}

const report = { generated_at: new Date().toISOString(), year_from: YEAR_FROM, year_to: YEAR_TO, strategy: 'official HTML + exact Crossref match; no LLM', labs: [] };
const db = shouldPublish ? createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SECRET_KEY, { auth: { persistSession: false, autoRefreshToken: false } }) : null;
for (const slug of selected) {
  const config = configs[slug]; if (!config) throw Error(`Unsupported LAB_SLUG: ${slug}`);
  const sourceRows = config.kind === 'mest' ? await mestEntries(config) : await aemlEntries(config);
  const entries = [];
  for (const row of sourceRows) { entries.push(await enrich(row)); await pause(150); }
  const matched = entries.filter(entry => entry.metadata_status === 'matched');
  report.labs.push({ lab_slug: slug, official_count: sourceRows.length, matched: matched.length, held: entries.length - matched.length, entries });
  await writeFile(`${root}/${slug}.json`, JSON.stringify(entries, null, 2));
  if (db) for (let index = 0; index < matched.length; index += 20) {
    const { error } = await db.rpc('publish_verified_bibliography', { p_lab_slug: slug, p_entries: matched.slice(index, index + 20) });
    if (error) throw Error(`${slug}: ${error.message}`);
  }
  console.log(JSON.stringify({ lab_slug: slug, official: sourceRows.length, matched: matched.length, held: entries.length - matched.length }));
}
await writeFile(`${root}/report.json`, JSON.stringify(report, null, 2));
console.log(JSON.stringify({ total: report.labs.reduce((n, lab) => n + lab.official_count, 0), matched: report.labs.reduce((n, lab) => n + lab.matched, 0), held: report.labs.reduce((n, lab) => n + lab.held, 0), estimated_model_tokens: 0 }));
