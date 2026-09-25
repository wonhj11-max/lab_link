-- Public, operator-curated paper catalogue. Additive migration; existing review history is retained.
begin;

alter table public.papers
  add column if not exists publication_date date,
  add column if not exists online_publication_date date,
  add column if not exists work_type text not null default 'article'
    check (work_type in ('article','review','proceedings','editorial','correction','preprint','other')),
  add column if not exists publication_status text not null default 'published'
    check (publication_status in ('early_access','published','corrected','retracted'));

create table if not exists public.journals (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  issn text,
  eissn text,
  created_at timestamptz not null default now(),
  unique nulls not distinct(name,issn,eissn)
);

alter table public.papers add column if not exists journal_id uuid references public.journals(id);

create table if not exists public.paper_authors (
  id uuid primary key default gen_random_uuid(),
  paper_id uuid not null references public.papers(id) on delete cascade,
  author_order integer not null check(author_order > 0),
  display_name text not null check(length(trim(display_name)) > 0),
  orcid text,
  affiliation text,
  is_first boolean not null default false,
  is_co_first boolean not null default false,
  is_corresponding boolean not null default false,
  role_status text not null default 'unverified' check(role_status in ('verified','unverified')),
  evidence_url text,
  created_at timestamptz not null default now(),
  unique(paper_id,author_order)
);

create table if not exists public.journal_metrics (
  id uuid primary key default gen_random_uuid(),
  journal_id uuid not null references public.journals(id) on delete cascade,
  metric_type text not null default 'jif' check(metric_type='jif'),
  metric_year integer not null check(metric_year between 1900 and 2200),
  value numeric(10,3) check(value is null or value >= 0),
  release_year integer check(release_year between 1900 and 2200),
  status text not null check(status in ('verified','not_released','not_available','unverified')),
  source_url text,
  checked_at timestamptz not null,
  unique(journal_id,metric_type,metric_year),
  check(status <> 'verified' or (value is not null and source_url like 'https://%'))
);

create table if not exists public.paper_keywords (
  id uuid primary key default gen_random_uuid(),
  paper_id uuid not null references public.papers(id) on delete cascade,
  keyword text not null check(length(trim(keyword)) > 0),
  language text not null default 'en' check(language in ('ko','en','other')),
  origin text not null check(origin in ('author','agent_extracted')),
  position integer not null check(position > 0),
  source_url text not null check(source_url like 'https://%'),
  verification_status text not null default 'verified' check(verification_status in ('verified','unverified')),
  unique(paper_id,keyword,language,origin)
);

create table if not exists public.paper_summaries (
  id uuid primary key default gen_random_uuid(),
  paper_id uuid not null references public.papers(id) on delete cascade,
  language text not null default 'ko' check(language in ('ko','en')),
  summary text not null check(length(trim(summary)) > 0),
  source_basis text not null check(source_basis in ('abstract','full_text')),
  source_url text not null check(source_url like 'https://%'),
  source_hash text not null check(source_hash ~ '^[a-f0-9]{64}$'),
  model_id text not null,
  prompt_version text not null,
  generated_at timestamptz not null,
  verification_status text not null check(verification_status in ('verified','unverified','rejected')),
  verified_at timestamptz,
  is_public boolean not null default false,
  unique(paper_id,language),
  check(not is_public or (verification_status='verified' and verified_at is not null))
);

create table if not exists private.paper_publication_runs (
  id uuid primary key default gen_random_uuid(),
  run_key text not null unique,
  scope jsonb not null default '{}',
  checkpoint jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists private.paper_evidence (
  id uuid primary key default gen_random_uuid(),
  paper_id uuid references public.papers(id) on delete cascade,
  candidate_id uuid references private.paper_candidates(id),
  run_id uuid references private.paper_publication_runs(id) on delete cascade,
  claim_type text not null,
  source_url text not null check(source_url like 'https://%'),
  source_hash text,
  detail jsonb not null default '{}',
  checked_at timestamptz not null default now()
);

create index if not exists paper_authors_paper_order_idx on public.paper_authors(paper_id,author_order);
create index if not exists paper_keywords_paper_position_idx on public.paper_keywords(paper_id,position);
create index if not exists journal_metrics_lookup_idx on public.journal_metrics(journal_id,metric_year);

alter table public.journals enable row level security;
alter table public.paper_authors enable row level security;
alter table public.journal_metrics enable row level security;
alter table public.paper_keywords enable row level security;
alter table public.paper_summaries enable row level security;
alter table private.paper_publication_runs enable row level security;
alter table private.paper_evidence enable row level security;

revoke all on public.journals,public.paper_authors,public.journal_metrics,public.paper_keywords,public.paper_summaries from public,anon,authenticated;
revoke all on private.paper_publication_runs,private.paper_evidence from public,anon,authenticated;

create or replace function public.list_lab_publications(p_lab_slug text)
returns jsonb language sql security definer set search_path='' stable as $$
  select coalesce(jsonb_agg(to_jsonb(q) order by q.year desc nulls last,q.title,q.paper_id),'[]'::jsonb)
  from (
    select p.id paper_id,p.doi,p.title,p.year,p.journal,p.source_url,p.publication_date,
      p.online_publication_date,p.work_type,p.publication_status,
      coalesce((select jsonb_agg(jsonb_build_object(
        'name',a.display_name,'order',a.author_order,'first',a.is_first,
        'co_first',a.is_co_first,'corresponding',a.is_corresponding,
        'role_status',a.role_status) order by a.author_order)
        from public.paper_authors a where a.paper_id=p.id),'[]'::jsonb) authors,
      coalesce((select jsonb_agg(jsonb_build_object('keyword',k.keyword,'language',k.language,'origin',k.origin) order by k.position)
        from public.paper_keywords k where k.paper_id=p.id and k.verification_status='verified'),'[]'::jsonb) keywords,
      (select jsonb_build_object('text',s.summary,'basis',s.source_basis)
        from public.paper_summaries s where s.paper_id=p.id and s.language='ko' and s.is_public and s.verification_status='verified') summary,
      coalesce((select jsonb_build_object('year',m.metric_year,'value',m.value,'status',m.status,'source_url',m.source_url)
        from public.journal_metrics m where m.journal_id=p.journal_id and m.metric_year=p.year and m.metric_type='jif'),'null'::jsonb) impact_factor
    from public.lab_papers lp
    join public.labs l on l.id=lp.lab_id
    join public.papers p on p.id=lp.paper_id
    where l.slug=trim(p_lab_slug) and l.publication_state='published' and lp.publication_state='published'
  ) q;
$$;

revoke all on function public.list_lab_publications(text) from public;
grant execute on function public.list_lab_publications(text) to anon,authenticated;

-- Queue and votes are retained for audit, but no longer exposed to ordinary users.
revoke execute on function public.list_paper_review_queue(text,integer,integer) from anon,authenticated;
revoke execute on function public.submit_paper_review_vote(uuid,text,text) from anon,authenticated;

commit;
