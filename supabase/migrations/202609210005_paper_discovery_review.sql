-- Five-year paper discovery and authenticated user review.
begin;

create unique index if not exists paper_candidates_source_doi_unique
  on private.paper_candidates(source_id, doi);

create table if not exists private.paper_review_votes (
  candidate_id uuid not null references private.paper_candidates(id) on delete cascade,
  reviewer_id uuid not null references auth.users(id) on delete cascade,
  verdict text not null check(verdict in ('confirmed','hold','excluded')),
  note text not null default '' check(length(note) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(candidate_id, reviewer_id)
);

alter table private.paper_review_votes enable row level security;
revoke all on private.paper_review_votes from public, anon, authenticated;

create or replace function public.stage_discovered_papers(
  p_lab_slug text,
  p_source_url text,
  p_content_hash text,
  p_candidates jsonb,
  p_year_from integer,
  p_year_to integer
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  lab public.labs;
  source private.sources;
  snapshot uuid;
  candidate jsonb;
  candidate_doi text;
  staged integer := 0;
begin
  if p_year_from < 1800 or p_year_to > 2200 or p_year_from > p_year_to then
    raise exception 'Invalid discovery year range';
  end if;
  if p_source_url !~ '^https://' then raise exception 'Source URL must use HTTPS'; end if;
  if p_content_hash !~ '^[a-f0-9]{64}$' then raise exception 'Invalid content hash'; end if;
  if jsonb_typeof(p_candidates) <> 'array' then raise exception 'Candidates must be a JSON array'; end if;

  select * into lab from public.labs where slug=trim(p_lab_slug) for share;
  if not found then raise exception 'Lab not found'; end if;

  insert into private.sources(
    lab_id, url, allowed_host, category, enabled, review_note, interval_hours, next_run_at
  ) values (
    lab.id,
    p_source_url,
    substring(p_source_url from '^https://([^/]+)'),
    'publications',
    false,
    'OpenAlex author record cross-checked with ORCID and current institution; user review required.',
    168,
    now()+interval '7 days'
  )
  on conflict(url) do update set
    lab_id=excluded.lab_id,
    category='publications',
    review_note=excluded.review_note
  returning * into source;

  insert into private.snapshots(source_id, content_hash, extracted_text)
  values(source.id, p_content_hash, left(p_candidates::text, 100000))
  on conflict(source_id, content_hash) do update set retrieved_at=now()
  returning id into snapshot;

  for candidate in select value from jsonb_array_elements(p_candidates)
  loop
    candidate_doi := lower(trim(candidate->>'doi'));
    if candidate_doi !~* '^10\.[0-9]{4,9}/\S+$' then continue; end if;
    if (candidate->>'year')::integer not between p_year_from and p_year_to then continue; end if;

    insert into private.paper_candidates(
      snapshot_id, source_id, doi, title_hint, source_url, payload
    ) values (
      snapshot,
      source.id,
      candidate_doi,
      coalesce(nullif(trim(candidate->>'title'),''), candidate_doi),
      coalesce(nullif(trim(candidate->>'source_url'),''), 'https://doi.org/'||candidate_doi),
      jsonb_build_object(
        'discovery', candidate,
        'year_from', p_year_from,
        'year_to', p_year_to,
        'review_required', true
      )
    )
    on conflict(source_id, doi) do update set
      snapshot_id=excluded.snapshot_id,
      title_hint=excluded.title_hint,
      source_url=excluded.source_url,
      payload=excluded.payload
    where private.paper_candidates.status='pending';
    staged := staged + 1;
  end loop;

  insert into private.audit_logs(action, entity_id, detail)
  values(
    'paper_discovery_staged', source.id,
    jsonb_build_object(
      'lab_slug', lab.slug,
      'year_from', p_year_from,
      'year_to', p_year_to,
      'candidate_count', staged,
      'content_hash', p_content_hash
    )
  );

  return jsonb_build_object('lab_slug',lab.slug,'candidate_count',staged,'snapshot_id',snapshot);
end;
$$;

create or replace function public.list_paper_review_queue(
  p_lab_slug text default null,
  p_year integer default null,
  p_limit integer default 500
) returns jsonb
language plpgsql
security definer
set search_path=''
stable
as $$
declare result jsonb;
begin
  if p_limit < 1 or p_limit > 1000 then raise exception 'Limit must be between 1 and 1000'; end if;
  if p_year is not null and p_year not between 1800 and 2200 then raise exception 'Invalid year'; end if;

  select coalesce(jsonb_agg(to_jsonb(q) order by q.lab_name, q.year desc, q.title), '[]'::jsonb)
  into result
  from (
    select
      pc.id as candidate_id,
      l.slug as lab_slug,
      l.name as lab_name,
      l.professor,
      pc.doi,
      coalesce(nullif(pc.payload#>>'{discovery,title}',''), pc.title_hint) as title,
      nullif(pc.payload#>>'{discovery,year}','')::integer as year,
      nullif(pc.payload#>>'{discovery,publication_date}','') as publication_date,
      nullif(pc.payload#>>'{discovery,journal}','') as journal,
      nullif(pc.payload#>>'{discovery,work_type}','') as work_type,
      coalesce(pc.payload#>'{discovery,authors}', '[]'::jsonb) as authors,
      coalesce(nullif(pc.payload#>>'{discovery,faculty_name}',''), l.professor) as faculty_name,
      coalesce(nullif(pc.payload#>>'{discovery,corresponding_status}',''), 'unknown') as corresponding_status,
      coalesce(nullif(pc.payload#>>'{discovery,affiliation_scope}',''), 'unverified') as affiliation_scope,
      nullif(pc.payload#>>'{discovery,evidence_url}','') as evidence_url,
      pc.source_url,
      count(*) filter(where v.verdict='confirmed')::integer as confirmed_votes,
      count(*) filter(where v.verdict='hold')::integer as hold_votes,
      count(*) filter(where v.verdict='excluded')::integer as excluded_votes,
      max(v.verdict) filter(where v.reviewer_id=auth.uid()) as my_verdict,
      max(v.note) filter(where v.reviewer_id=auth.uid()) as my_note
    from private.paper_candidates pc
    join private.sources s on s.id=pc.source_id
    join public.labs l on l.id=s.lab_id
    left join private.paper_review_votes v on v.candidate_id=pc.id
    where pc.status='pending'
      and (p_lab_slug is null or l.slug=p_lab_slug)
      and (p_year is null or nullif(pc.payload#>>'{discovery,year}','')::integer=p_year)
    group by pc.id,l.slug,l.name,l.professor
    order by l.name, year desc, title
    limit p_limit
  ) q;
  return result;
end;
$$;

create or replace function public.submit_paper_review_vote(
  p_candidate_id uuid,
  p_verdict text,
  p_note text default ''
) returns void
language plpgsql
security definer
set search_path=''
as $$
declare actor uuid := auth.uid();
begin
  if actor is null then raise exception '로그인이 필요합니다'; end if;
  if p_verdict not in ('confirmed','hold','excluded') then raise exception 'Invalid review verdict'; end if;
  if length(coalesce(p_note,'')) > 1000 then raise exception '검토 메모는 1000자 이하여야 합니다'; end if;
  if not exists(select 1 from private.paper_candidates where id=p_candidate_id and status='pending') then
    raise exception '검토 가능한 논문 후보를 찾을 수 없습니다';
  end if;

  insert into private.paper_review_votes(candidate_id,reviewer_id,verdict,note)
  values(p_candidate_id,actor,p_verdict,trim(coalesce(p_note,'')))
  on conflict(candidate_id,reviewer_id) do update set
    verdict=excluded.verdict,
    note=excluded.note,
    updated_at=now();

  insert into private.audit_logs(action,entity_id,detail)
  values('paper_review_vote_submitted',p_candidate_id,jsonb_build_object('reviewer_id',actor,'verdict',p_verdict));
end;
$$;

revoke all on function public.stage_discovered_papers(text,text,text,jsonb,integer,integer) from public,anon,authenticated;
grant execute on function public.stage_discovered_papers(text,text,text,jsonb,integer,integer) to service_role;

revoke all on function public.list_paper_review_queue(text,integer,integer) from public;
grant execute on function public.list_paper_review_queue(text,integer,integer) to anon,authenticated;

revoke all on function public.submit_paper_review_vote(uuid,text,text) from public,anon;
grant execute on function public.submit_paper_review_vote(uuid,text,text) to authenticated;

commit;
