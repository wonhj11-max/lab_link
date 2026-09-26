begin;
-- Preserve the lab's own list before DOI/publisher enrichment. No public access.
create table if not exists private.lab_publication_entries (
  id uuid primary key default gen_random_uuid(),
  lab_id uuid not null references public.labs(id),
  listing_year integer not null check(listing_year between 1900 and 2200),
  doi text check(doi=lower(trim(doi))),
  title text not null check(length(trim(title))>0),
  journal_citation text not null,
  authors jsonb not null default '[]' check(jsonb_typeof(authors)='array'),
  source_url text not null check(source_url like 'http://%' or source_url like 'https://%'),
  publisher_source_url text not null,
  scraped_at timestamptz not null default now(),
  verified_at timestamptz,
  paper_id uuid references public.papers(id),
  status text not null default 'scraped' check(status in ('scraped','verified','published','held')),
  note text,
  unique(lab_id,publisher_source_url)
);
alter table private.lab_publication_entries enable row level security;
revoke all on private.lab_publication_entries from public,anon,authenticated;
commit;
