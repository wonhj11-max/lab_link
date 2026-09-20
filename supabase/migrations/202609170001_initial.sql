-- Initial migration. Run once via Supabase SQL Editor or supabase db push.
begin;
create extension if not exists pgcrypto;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table public.labs (
 id uuid primary key default gen_random_uuid(), slug text not null unique,
 name text not null, university text not null, department text not null,
 professor text not null, introduction text not null default '', topics text[] not null default '{}',
 homepage text not null check(homepage like 'https://%'),
 publication_state text not null default 'draft' check(publication_state in ('draft','published','archived')),
 verified_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.lab_facts (
 id uuid primary key default gen_random_uuid(), lab_id uuid not null references public.labs(id),
 kind text not null check(kind in ('research','biography','alumni','equipment','recruitment')),
 title text not null, body text not null, source_url text not null,
 observed_at timestamptz not null, effective_date text,
 publication_state text not null default 'draft' check(publication_state in ('draft','published','archived')),
 created_at timestamptz not null default now()
);
create table public.papers (
 id uuid primary key default gen_random_uuid(), doi text unique, title text not null,
 year integer check(year between 1800 and 2200), journal text, source_url text not null,
 summary text, summary_basis text check(summary_basis in ('abstract','full_text')),
 summary_reviewed_at timestamptz, created_at timestamptz not null default now(),
 check(doi is null or doi = lower(trim(doi))), check(summary is null or summary_basis is not null)
);
create table public.lab_papers (
 lab_id uuid not null references public.labs(id), paper_id uuid not null references public.papers(id),
 faculty_name text not null, corresponding_status text not null default 'unknown'
 check(corresponding_status in ('confirmed','unknown','not_corresponding')),
 evidence_url text, verified_at timestamptz,
 affiliation_scope text not null default 'unverified' check(affiliation_scope in ('current_lab','previous_affiliation','unverified')),
 publication_state text not null default 'draft' check(publication_state in ('draft','published','archived')),
 primary key(lab_id,paper_id),
 check(corresponding_status <> 'confirmed' or (evidence_url is not null and verified_at is not null))
);
create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 display_name text not null default '' check(length(display_name)<=100),
 affiliation text not null default '' check(length(affiliation)<=200),
 bio text not null default '' check(length(bio)<=3000),
 skills text[] not null default '{}', topics text[] not null default '{}',
 accepting_proposals boolean not null default false, is_public boolean not null default false,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.collaboration_posts (
 id uuid primary key default gen_random_uuid(), owner_id uuid not null default auth.uid() references public.profiles(id),
 title text not null check(length(title) between 3 and 160),
 kind text not null check(kind in ('measurement','equipment','analysis','coauthor')),
 description text not null check(length(description) between 20 and 10000),
 skills text[] not null default '{}', location text not null default '',
 status text not null default 'open' check(status in ('draft','open','closed')),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.proposals (
 id uuid primary key default gen_random_uuid(), sender_id uuid not null default auth.uid() references public.profiles(id),
 recipient_id uuid not null references public.profiles(id), post_id uuid references public.collaboration_posts(id),
 message text not null check(length(message) between 20 and 5000),
 status text not null default 'pending' check(status in ('pending','accepted','declined','withdrawn','completed')),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 check(sender_id <> recipient_id)
);
create unique index one_active_post_proposal on public.proposals(sender_id,post_id) where post_id is not null and status in ('pending','accepted');
create table public.bookmarks (
 user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
 lab_id uuid not null references public.labs(id), created_at timestamptz not null default now(), primary key(user_id,lab_id)
);
create table private.sources (
 id uuid primary key default gen_random_uuid(), lab_id uuid not null references public.labs(id),
 url text not null unique check(url like 'https://%'), allowed_host text not null,
 category text not null check(category in ('research','biography','alumni','publications','equipment','recruitment')),
 enabled boolean not null default false, review_note text not null default '',
 interval_hours integer not null default 168 check(interval_hours>=24),
 next_run_at timestamptz not null default now(), etag text, last_modified text,
 last_hash text, last_success_at timestamptz, created_at timestamptz not null default now()
);
create table private.crawl_jobs (
 id uuid primary key default gen_random_uuid(), source_id uuid not null references private.sources(id),
 status text not null default 'queued' check(status in ('queued','running','done','dead')),
 attempts integer not null default 0, available_at timestamptz not null default now(),
 lease_until timestamptz, lease_token uuid, last_error text, created_at timestamptz not null default now(), completed_at timestamptz
);
create unique index one_live_job_per_source on private.crawl_jobs(source_id) where status in ('queued','running');
create table private.snapshots (
 id uuid primary key default gen_random_uuid(), source_id uuid not null references private.sources(id),
 content_hash text not null, extracted_text text not null check(length(extracted_text)<=100000),
 retrieved_at timestamptz not null default now(), unique(source_id,content_hash)
);
create table private.candidates (
 id uuid primary key default gen_random_uuid(), snapshot_id uuid not null references private.snapshots(id),
 source_id uuid not null references private.sources(id), category text not null,
 payload jsonb not null, extractor_version text not null,
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 reviewed_at timestamptz, reviewed_by text, review_note text,
 created_at timestamptz not null default now(), unique(snapshot_id,extractor_version)
);
create table private.audit_logs (
 id bigint generated always as identity primary key, action text not null, entity_id uuid,
 detail jsonb not null default '{}', created_at timestamptz not null default now()
);
create index labs_topics_idx on public.labs using gin(topics);
create index facts_lab_idx on public.lab_facts(lab_id);
create index posts_browse_idx on public.collaboration_posts(status,created_at desc);
create index proposals_recipient_idx on public.proposals(recipient_id,created_at desc);
create index proposals_sender_idx on public.proposals(sender_id,created_at desc);
create index jobs_due_idx on private.crawl_jobs(status,available_at);

create function private.touch_updated_at() returns trigger language plpgsql set search_path='' as $$
begin new.updated_at=now(); return new; end; $$;
create trigger labs_touch before update on public.labs for each row execute function private.touch_updated_at();
create trigger profiles_touch before update on public.profiles for each row execute function private.touch_updated_at();
create trigger posts_touch before update on public.collaboration_posts for each row execute function private.touch_updated_at();
create trigger proposals_touch before update on public.proposals for each row execute function private.touch_updated_at();
create function private.create_profile() returns trigger language plpgsql security definer set search_path='' as $$
begin insert into public.profiles(id) values(new.id); return new; end; $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function private.create_profile();
insert into public.profiles(id) select id from auth.users on conflict do nothing;

alter table public.labs enable row level security;
alter table public.lab_facts enable row level security;
alter table public.papers enable row level security;
alter table public.lab_papers enable row level security;
alter table public.profiles enable row level security;
alter table public.collaboration_posts enable row level security;
alter table public.proposals enable row level security;
alter table public.bookmarks enable row level security;
create policy labs_read on public.labs for select using(publication_state='published');
create policy facts_read on public.lab_facts for select using(publication_state='published' and exists(select 1 from public.labs l where l.id=lab_id and l.publication_state='published'));
create policy lab_papers_read on public.lab_papers for select using(publication_state='published' and exists(select 1 from public.labs l where l.id=lab_id and l.publication_state='published'));
create policy papers_read on public.papers for select using(exists(select 1 from public.lab_papers lp where lp.paper_id=id and lp.publication_state='published'));
create policy profiles_read on public.profiles for select using(is_public or id=(select auth.uid()));
create policy profiles_update on public.profiles for update to authenticated using(id=(select auth.uid())) with check(id=(select auth.uid()));
create policy posts_read on public.collaboration_posts for select using(status in ('open','closed') or owner_id=(select auth.uid()));
create policy posts_insert on public.collaboration_posts for insert to authenticated with check(owner_id=(select auth.uid()));
create policy posts_update on public.collaboration_posts for update to authenticated using(owner_id=(select auth.uid())) with check(owner_id=(select auth.uid()));
create policy proposals_read on public.proposals for select to authenticated using((select auth.uid()) in (sender_id,recipient_id));
create policy bookmarks_own on public.bookmarks for all to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));
revoke all on public.labs,public.lab_facts,public.papers,public.lab_papers,public.profiles,public.collaboration_posts,public.proposals,public.bookmarks from anon,authenticated;
grant select on public.labs,public.lab_facts,public.papers,public.lab_papers,public.profiles,public.collaboration_posts to anon,authenticated;
grant update(display_name,affiliation,bio,skills,topics,accepting_proposals,is_public) on public.profiles to authenticated;
grant insert(title,kind,description,skills,location,status),update(title,kind,description,skills,location,status) on public.collaboration_posts to authenticated;
grant select on public.proposals to authenticated;
grant select,insert,delete on public.bookmarks to authenticated;

-- A single transaction validates the destination and rate limit. Clients cannot assign sender/status.
create function public.send_proposal(p_message text,p_post_id uuid default null,p_recipient_id uuid default null)
returns uuid language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); recipient uuid; new_id uuid;
begin
 if actor is null then raise exception '로그인이 필요합니다'; end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
 if length(p_message) not between 20 and 5000 then raise exception '제안은 20~5000자로 작성해 주세요'; end if;
 if (select count(*) from public.proposals where sender_id=actor and created_at>now()-interval '1 hour')>=10 then raise exception '잠시 후 다시 제안해 주세요'; end if;
 if p_post_id is not null then
  select owner_id into recipient from public.collaboration_posts where id=p_post_id and status='open' for share;
 else
  select id into recipient from public.profiles where id=p_recipient_id and is_public and accepting_proposals for share;
 end if;
 if recipient is null or recipient=actor then raise exception '제안을 보낼 수 없는 대상입니다'; end if;
 insert into public.proposals(sender_id,recipient_id,post_id,message) values(actor,recipient,p_post_id,p_message) returning id into new_id;
 return new_id;
end; $$;
create function public.transition_proposal(p_id uuid,p_status text) returns void language plpgsql security definer set search_path='' as $$
declare row public.proposals; actor uuid:=auth.uid();
begin
 if actor is null then raise exception '로그인이 필요합니다'; end if;
 select * into row from public.proposals where id=p_id for update;
 if not found then raise exception '제안을 찾을 수 없습니다'; end if;
 if not ((actor=row.recipient_id and row.status='pending' and p_status in ('accepted','declined'))
 or (actor=row.sender_id and row.status='pending' and p_status='withdrawn')
 or (actor in (row.sender_id,row.recipient_id) and row.status='accepted' and p_status='completed')) then raise exception '허용되지 않은 상태 변경입니다'; end if;
 update public.proposals set status=p_status where id=p_id;
end; $$;
revoke all on function public.send_proposal(text,uuid,uuid),public.transition_proposal(uuid,text) from public,anon;
grant execute on function public.send_proposal(text,uuid,uuid),public.transition_proposal(uuid,text) to authenticated;

-- Durable DB queue. RPCs are server-only; no crawler tables are exposed through the Data API.
create function public.enqueue_crawl_jobs() returns integer language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 update private.crawl_jobs set status='dead',last_error='lease expired after maximum attempts' where status='running' and lease_until<now() and attempts>=3;
 insert into private.crawl_jobs(source_id) select id from private.sources s where enabled and next_run_at<=now()
 and not exists(select 1 from private.crawl_jobs j where j.source_id=s.id and j.status in ('queued','running')) on conflict do nothing;
 get diagnostics n=row_count;
 update private.sources s set next_run_at=now()+make_interval(hours=>interval_hours) where exists(select 1 from private.crawl_jobs j where j.source_id=s.id and j.status in ('queued','running')) and next_run_at<=now();
 return n;
end; $$;
create function public.claim_crawl_job() returns jsonb language plpgsql security definer set search_path='' as $$
declare j private.crawl_jobs; s private.sources;
begin
 select q.* into j from private.crawl_jobs q join private.sources src on src.id=q.source_id
 where src.enabled and q.attempts<3 and ((q.status='queued' and q.available_at<=now()) or (q.status='running' and q.lease_until<now()))
 order by q.available_at for update of q skip locked limit 1;
 if not found then return null; end if;
 update private.crawl_jobs set status='running',attempts=attempts+1,lease_until=now()+interval '5 minutes',lease_token=gen_random_uuid() where id=j.id returning * into j;
 select * into s from private.sources where id=j.source_id;
 return jsonb_build_object('job_id',j.id,'lease_token',j.lease_token,'source',to_jsonb(s));
end; $$;
create function public.finish_crawl_job(p_job_id uuid,p_lease_token uuid,p_result jsonb) returns void language plpgsql security definer set search_path='' as $$
declare j private.crawl_jobs; s private.sources; snapshot uuid;
begin
 select * into j from private.crawl_jobs where id=p_job_id and status='running' and lease_token=p_lease_token and lease_until>now() for update;
 if not found then raise exception 'Expired or invalid job lease'; end if;
 select * into s from private.sources where id=j.source_id for update;
 if not s.enabled then raise exception 'Source is disabled'; end if;
 if p_result->>'error' is not null then
  update private.crawl_jobs set status=case when attempts>=3 then 'dead' else 'queued' end,
  last_error=left(p_result->>'error',2000),available_at=now()+make_interval(mins=>5*attempts),lease_until=null where id=j.id;
 else
  if p_result->>'hash' is not null and p_result->>'hash' is distinct from s.last_hash then
   insert into private.snapshots(source_id,content_hash,extracted_text) values(s.id,p_result->>'hash',left(p_result->>'text',100000))
   on conflict(source_id,content_hash) do update set retrieved_at=now() returning id into snapshot;
   insert into private.candidates(snapshot_id,source_id,category,payload,extractor_version)
   values(snapshot,s.id,s.category,p_result->'candidate','html-v1') on conflict do nothing;
  end if;
  update private.sources set last_hash=coalesce(p_result->>'hash',last_hash),etag=coalesce(p_result->>'etag',etag),last_modified=coalesce(p_result->>'last_modified',last_modified),last_success_at=now() where id=s.id;
  update private.crawl_jobs set status='done',completed_at=now(),lease_until=null,last_error=null where id=j.id;
 end if;
 insert into private.audit_logs(action,entity_id,detail) values('crawl_finished',j.id,jsonb_build_object('error',p_result->>'error','hash',p_result->>'hash'));
end; $$;
revoke all on function public.enqueue_crawl_jobs(),public.claim_crawl_job(),public.finish_crawl_job(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.enqueue_crawl_jobs(),public.claim_crawl_job(),public.finish_crawl_job(uuid,uuid,jsonb) to service_role;
commit;
