-- DOI-level paper review queue. Only service_role may inspect or mutate it.
-- Approval is the sole path from a crawler candidate into public paper tables.
begin;

create table if not exists private.paper_candidates (
  id uuid primary key default gen_random_uuid(),
  snapshot_id uuid not null references private.snapshots(id),
  source_id uuid not null references private.sources(id),
  doi text not null check(doi = lower(trim(doi))),
  title_hint text not null default '',
  source_url text not null check(source_url like 'https://%'),
  payload jsonb not null default '{}',
  status text not null default 'pending' check(status in ('pending','approved','rejected')),
  reviewed_at timestamptz,
  reviewed_by text,
  review_note text,
  paper_id uuid references public.papers(id),
  created_at timestamptz not null default now(),
  unique(snapshot_id, doi),
  check(
    (status = 'pending' and reviewed_at is null and reviewed_by is null)
    or (status in ('approved','rejected') and reviewed_at is not null and reviewed_by is not null)
  )
);

create index if not exists paper_candidates_status_idx
  on private.paper_candidates(status, created_at);
create index if not exists paper_candidates_source_idx
  on private.paper_candidates(source_id);
alter table private.paper_candidates enable row level security;
revoke all on private.paper_candidates from public, anon, authenticated;

-- Existing crawled publication pages are safely expanded into one row per DOI.
insert into private.paper_candidates(snapshot_id, source_id, doi, title_hint, source_url, payload)
select c.snapshot_id, c.source_id, lower(trim(d.doi)),
       coalesce(nullif(c.payload->>'title',''), lower(trim(d.doi))),
       'https://doi.org/' || lower(trim(d.doi)), c.payload
from private.candidates c
cross join lateral jsonb_array_elements_text(coalesce(c.payload->'doi_candidates','[]'::jsonb)) d(doi)
where c.category = 'publications'
  and trim(d.doi) ~* '^10\.[0-9]{4,9}/\S+$'
on conflict(snapshot_id, doi) do nothing;

create or replace function public.finish_crawl_job(
  p_job_id uuid, p_lease_token uuid, p_result jsonb
) returns void language plpgsql security definer set search_path='' as $$
declare
  j private.crawl_jobs;
  s private.sources;
  snapshot uuid;
  paper_doi text;
begin
  select * into j from private.crawl_jobs
    where id=p_job_id and status='running' and lease_token=p_lease_token and lease_until > now()
    for update;
  if not found then raise exception 'Expired or invalid job lease'; end if;
  select * into s from private.sources where id=j.source_id for update;
  if not s.enabled then raise exception 'Source is disabled'; end if;

  if p_result->>'error' is not null then
    update private.crawl_jobs set
      status=case when attempts >= 3 then 'dead' else 'queued' end,
      last_error=left(p_result->>'error',2000),
      available_at=now()+make_interval(mins=>5*attempts), lease_until=null
    where id=j.id;
  else
    if p_result->>'hash' is not null and p_result->>'hash' is distinct from s.last_hash then
      insert into private.snapshots(source_id,content_hash,extracted_text)
        values(s.id,p_result->>'hash',left(p_result->>'text',100000))
        on conflict(source_id,content_hash) do update set retrieved_at=now()
        returning id into snapshot;

      insert into private.candidates(snapshot_id,source_id,category,payload,extractor_version)
        values(snapshot,s.id,s.category,p_result->'candidate','html-v1') on conflict do nothing;

      if s.category = 'publications' then
        for paper_doi in
          select lower(trim(value))
          from jsonb_array_elements_text(coalesce(p_result->'candidate'->'doi_candidates','[]'::jsonb))
          where trim(value) ~* '^10\.[0-9]{4,9}/\S+$'
        loop
          insert into private.paper_candidates(
            snapshot_id, source_id, doi, title_hint, source_url, payload
          ) values (
            snapshot, s.id, paper_doi,
            coalesce(nullif(p_result->'candidate'->>'title',''), paper_doi),
            'https://doi.org/' || paper_doi,
            p_result->'candidate'
          ) on conflict(snapshot_id, doi) do nothing;
        end loop;
      end if;
    end if;

    update private.sources set
      last_hash=coalesce(p_result->>'hash',last_hash),
      etag=coalesce(p_result->>'etag',etag),
      last_modified=coalesce(p_result->>'last_modified',last_modified),
      last_success_at=now()
    where id=s.id;
    update private.crawl_jobs set status='done', completed_at=now(), lease_until=null, last_error=null
      where id=j.id;
  end if;

  insert into private.audit_logs(action,entity_id,detail)
    values('crawl_finished',j.id,jsonb_build_object('error',p_result->>'error','hash',p_result->>'hash'));
end; $$;

create or replace function public.list_paper_candidates(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  if p_limit < 1 or p_limit > 200 then raise exception 'Limit must be between 1 and 200'; end if;
  select coalesce(jsonb_agg(to_jsonb(q) order by q.created_at), '[]'::jsonb) into result
  from (
    select pc.id as candidate_id, pc.created_at, pc.doi, pc.title_hint, pc.source_url,
           l.id as lab_id, l.slug as lab_slug, l.name as lab_name, l.professor,
           s.url as publication_page, pc.payload
    from private.paper_candidates pc
    join private.sources s on s.id=pc.source_id
    join public.labs l on l.id=s.lab_id
    where pc.status='pending'
    order by pc.created_at
    limit p_limit
  ) q;
  return result;
end; $$;

create or replace function public.approve_paper_candidate(p_candidate_id uuid, p_review jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  candidate private.paper_candidates;
  source private.sources;
  paper uuid;
  v_doi text;
  v_title text;
  v_source_url text;
  v_faculty_name text;
  v_reviewer text;
  v_corresponding_status text;
  v_affiliation_scope text;
  v_summary text;
  v_summary_basis text;
  v_evidence_url text;
  v_year integer;
begin
  select * into candidate from private.paper_candidates where id=p_candidate_id for update;
  if not found then raise exception 'Paper candidate not found'; end if;
  if candidate.status <> 'pending' then raise exception 'Paper candidate was already reviewed'; end if;
  select * into source from private.sources where id=candidate.source_id;
  if source.category <> 'publications' then raise exception 'Candidate is not from a publications source'; end if;

  v_title := nullif(trim(p_review->>'title'),'');
  v_source_url := nullif(trim(p_review->>'source_url'),'');
  v_faculty_name := nullif(trim(p_review->>'faculty_name'),'');
  v_reviewer := nullif(trim(p_review->>'reviewer'),'');
  v_doi := nullif(lower(trim(coalesce(p_review->>'doi',candidate.doi))),'');
  v_corresponding_status := coalesce(nullif(p_review->>'corresponding_status',''),'unknown');
  v_affiliation_scope := coalesce(nullif(p_review->>'affiliation_scope',''),'unverified');
  v_summary := nullif(trim(p_review->>'summary'),'');
  v_summary_basis := nullif(p_review->>'summary_basis','');
  v_evidence_url := nullif(trim(p_review->>'evidence_url'),'');

  begin v_year := (p_review->>'year')::integer;
  exception when invalid_text_representation then raise exception 'Invalid paper year'; end;

  if v_title is null or v_faculty_name is null or v_reviewer is null then
    raise exception 'title, faculty_name and reviewer are required';
  end if;
  if v_year < 1800 or v_year > 2200 then raise exception 'Invalid paper year'; end if;
  if v_source_url is null or v_source_url !~ '^https://' then raise exception 'source_url must use HTTPS'; end if;
  if v_doi is not null and v_doi !~* '^10\.[0-9]{4,9}/\S+$' then raise exception 'Invalid DOI'; end if;
  if v_corresponding_status not in ('confirmed','unknown','not_corresponding') then raise exception 'Invalid corresponding_status'; end if;
  if v_affiliation_scope not in ('current_lab','previous_affiliation','unverified') then raise exception 'Invalid affiliation_scope'; end if;
  if v_evidence_url is not null and v_evidence_url !~ '^https://' then raise exception 'evidence_url must use HTTPS'; end if;
  if v_corresponding_status='confirmed' and v_evidence_url is null then raise exception 'Confirmed corresponding authorship requires evidence_url'; end if;
  if v_summary is not null and v_summary_basis not in ('abstract','full_text') then raise exception 'Reviewed summary requires summary_basis'; end if;
  if v_summary is null and v_summary_basis is not null then raise exception 'summary_basis requires a summary'; end if;

  select p.id into paper from public.papers p
    where (v_doi is not null and p.doi=v_doi) or p.source_url=v_source_url
    order by case when p.doi=v_doi then 0 else 1 end limit 1 for update;

  if paper is null then
    insert into public.papers(doi,title,year,journal,source_url,summary,summary_basis,summary_reviewed_at)
    values(v_doi,v_title,v_year,nullif(trim(p_review->>'journal'),''),v_source_url,v_summary,v_summary_basis,
           case when v_summary is null then null else now() end)
    returning id into paper;
  else
    update public.papers p set
      doi=coalesce(v_doi,p.doi), title=v_title,
      year=v_year, journal=nullif(trim(p_review->>'journal'),''),
      source_url=v_source_url,
      summary=coalesce(v_summary,p.summary),
      summary_basis=case when v_summary is null then p.summary_basis else v_summary_basis end,
      summary_reviewed_at=case when v_summary is null then p.summary_reviewed_at else now() end
    where p.id=paper;
  end if;

  insert into public.lab_papers(
    lab_id,paper_id,faculty_name,corresponding_status,evidence_url,verified_at,affiliation_scope,publication_state
  ) values (
    source.lab_id,paper,v_faculty_name,v_corresponding_status,v_evidence_url,
    case when v_corresponding_status='confirmed' then now() else null end,
    v_affiliation_scope,'published'
  ) on conflict(lab_id,paper_id) do update set
    faculty_name=excluded.faculty_name,
    corresponding_status=excluded.corresponding_status,
    evidence_url=excluded.evidence_url,
    verified_at=excluded.verified_at,
    affiliation_scope=excluded.affiliation_scope,
    publication_state='published';

  update private.paper_candidates set status='approved', reviewed_at=now(), reviewed_by=v_reviewer,
    review_note=coalesce(p_review->>'review_note',''), paper_id=paper where id=p_candidate_id;
  insert into private.audit_logs(action,entity_id,detail) values(
    'paper_candidate_approved',paper,
    jsonb_build_object('candidate_id',p_candidate_id,'lab_id',source.lab_id,'reviewer',v_reviewer)
  );
  return jsonb_build_object('paper_id',paper,'lab_id',source.lab_id,'status','published');
end; $$;

create or replace function public.reject_paper_candidate(
  p_candidate_id uuid, p_reviewer text, p_review_note text
) returns void language plpgsql security definer set search_path='' as $$
declare candidate private.paper_candidates;
begin
  if nullif(trim(p_reviewer),'') is null or nullif(trim(p_review_note),'') is null then
    raise exception 'Reviewer and rejection note are required';
  end if;
  select * into candidate from private.paper_candidates where id=p_candidate_id for update;
  if not found then raise exception 'Paper candidate not found'; end if;
  if candidate.status <> 'pending' then raise exception 'Paper candidate was already reviewed'; end if;
  update private.paper_candidates set status='rejected', reviewed_at=now(),
    reviewed_by=trim(p_reviewer), review_note=trim(p_review_note) where id=p_candidate_id;
  insert into private.audit_logs(action,entity_id,detail) values(
    'paper_candidate_rejected',p_candidate_id,
    jsonb_build_object('reviewer',trim(p_reviewer),'note',trim(p_review_note))
  );
end; $$;

revoke all on function public.finish_crawl_job(uuid,uuid,jsonb),
  public.list_paper_candidates(integer),
  public.approve_paper_candidate(uuid,jsonb),
  public.reject_paper_candidate(uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.finish_crawl_job(uuid,uuid,jsonb),
  public.list_paper_candidates(integer),
  public.approve_paper_candidate(uuid,jsonb),
  public.reject_paper_candidate(uuid,text,text)
  to service_role;

commit;
