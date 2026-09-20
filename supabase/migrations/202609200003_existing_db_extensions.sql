-- Safe extension for an existing LabLink core schema.
-- This migration does not delete or rewrite existing public data.
begin;

create extension if not exists pgcrypto;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.sources (
  id uuid primary key default gen_random_uuid(),
  lab_id uuid not null references public.labs(id),
  url text not null unique,
  allowed_host text not null,
  category text not null check(category in ('research','biography','alumni','publications','equipment','recruitment')),
  enabled boolean not null default false,
  review_note text not null default '',
  interval_hours integer not null default 168 check(interval_hours >= 24),
  next_run_at timestamptz not null default now(),
  etag text,
  last_modified text,
  last_hash text,
  last_success_at timestamptz,
  created_at timestamptz not null default now(),
  check(url like 'https://%')
);

create table if not exists private.crawl_jobs (
  id uuid primary key default gen_random_uuid(),
  source_id uuid not null references private.sources(id),
  status text not null default 'queued' check(status in ('queued','running','done','dead')),
  attempts integer not null default 0,
  available_at timestamptz not null default now(),
  lease_until timestamptz,
  lease_token uuid,
  last_error text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create table if not exists private.snapshots (
  id uuid primary key default gen_random_uuid(),
  source_id uuid not null references private.sources(id),
  content_hash text not null,
  extracted_text text not null check(length(extracted_text) <= 100000),
  retrieved_at timestamptz not null default now(),
  unique(source_id, content_hash)
);

create table if not exists private.candidates (
  id uuid primary key default gen_random_uuid(),
  snapshot_id uuid not null references private.snapshots(id),
  source_id uuid not null references private.sources(id),
  category text not null,
  payload jsonb not null,
  extractor_version text not null,
  status text not null default 'pending' check(status in ('pending','approved','rejected')),
  reviewed_at timestamptz,
  reviewed_by text,
  review_note text,
  created_at timestamptz not null default now(),
  unique(snapshot_id, extractor_version)
);

create table if not exists private.audit_logs (
  id bigint generated always as identity primary key,
  action text not null,
  entity_id uuid,
  detail jsonb not null default '{}',
  created_at timestamptz not null default now()
);

create unique index if not exists one_live_job_per_source
  on private.crawl_jobs(source_id) where status in ('queued','running');
create index if not exists jobs_due_idx on private.crawl_jobs(status, available_at);
create index if not exists sources_lab_idx on private.sources(lab_id);
create index if not exists snapshots_source_idx on private.snapshots(source_id);
create index if not exists candidates_source_idx on private.candidates(source_id);

alter table private.sources enable row level security;
alter table private.crawl_jobs enable row level security;
alter table private.snapshots enable row level security;
alter table private.candidates enable row level security;
alter table private.audit_logs enable row level security;

alter default privileges in schema private revoke all on tables from anon, authenticated;
alter default privileges in schema private revoke all on functions from public, anon, authenticated;

create or replace function public.enqueue_crawl_jobs()
returns integer language plpgsql security definer set search_path='' as $$
declare n integer;
begin
  update private.crawl_jobs
    set status='dead', last_error='lease expired after maximum attempts'
    where status='running' and lease_until < now() and attempts >= 3;
  insert into private.crawl_jobs(source_id)
    select id from private.sources s
    where enabled and next_run_at <= now()
      and not exists (
        select 1 from private.crawl_jobs j
        where j.source_id=s.id and j.status in ('queued','running')
      );
  get diagnostics n=row_count;
  update private.sources s
    set next_run_at=now()+make_interval(hours=>interval_hours)
    where exists (
      select 1 from private.crawl_jobs j
      where j.source_id=s.id and j.status in ('queued','running')
    ) and next_run_at <= now();
  return n;
end; $$;

create or replace function public.claim_crawl_job()
returns jsonb language plpgsql security definer set search_path='' as $$
declare j private.crawl_jobs; s private.sources;
begin
  select q.* into j
  from private.crawl_jobs q join private.sources src on src.id=q.source_id
  where src.enabled and q.attempts < 3
    and ((q.status='queued' and q.available_at <= now())
      or (q.status='running' and q.lease_until < now()))
  order by q.available_at for update of q skip locked limit 1;
  if not found then return null; end if;
  update private.crawl_jobs
    set status='running', attempts=attempts+1,
      lease_until=now()+interval '5 minutes', lease_token=gen_random_uuid()
    where id=j.id returning * into j;
  select * into s from private.sources where id=j.source_id;
  return jsonb_build_object('job_id',j.id,'lease_token',j.lease_token,'source',to_jsonb(s));
end; $$;

create or replace function public.finish_crawl_job(
  p_job_id uuid, p_lease_token uuid, p_result jsonb
) returns void language plpgsql security definer set search_path='' as $$
declare j private.crawl_jobs; s private.sources; snapshot uuid;
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

revoke all on function public.enqueue_crawl_jobs(), public.claim_crawl_job(),
  public.finish_crawl_job(uuid,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.enqueue_crawl_jobs(), public.claim_crawl_job(),
  public.finish_crawl_job(uuid,uuid,jsonb) to service_role;

commit;
