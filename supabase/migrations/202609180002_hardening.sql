begin;
alter table public.labs drop constraint labs_homepage_check;
alter table public.labs add constraint labs_homepage_check check(homepage ~ '^https?://');
alter table private.sources drop constraint sources_url_check;
alter table private.sources add column allow_http boolean not null default false;
alter table private.sources add column expected_tokens text[] not null default '{}';
alter table private.sources add constraint sources_url_check check(url like 'https://%' or (allow_http and url like 'http://%'));
-- Unreviewed generated summaries belong in private.candidates, never in public.papers.
alter table public.papers add constraint summaries_must_be_reviewed check(summary is null or summary_reviewed_at is not null);
alter table private.sources enable row level security;
alter table private.crawl_jobs enable row level security;
alter table private.snapshots enable row level security;
alter table private.candidates enable row level security;
alter table private.audit_logs enable row level security;
-- No browser roles receive private-schema access, including future tables.
alter default privileges in schema private revoke all on tables from anon,authenticated;
alter default privileges in schema private revoke all on functions from public,anon,authenticated;
create index lab_papers_paper_idx on public.lab_papers(paper_id);
create index posts_owner_idx on public.collaboration_posts(owner_id);
create index bookmarks_lab_idx on public.bookmarks(lab_id);
create index proposals_post_idx on public.proposals(post_id);
create index sources_lab_idx on private.sources(lab_id);
create index snapshots_source_idx on private.snapshots(source_id);
create index candidates_source_idx on private.candidates(source_id);
commit;
