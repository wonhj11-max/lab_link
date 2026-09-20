-- Rollback-only integration test for the paper approval transaction.
begin;

do $$
declare
  source_id uuid;
  snapshot_id uuid;
  candidate_id uuid;
  result jsonb;
begin
  select id into source_id from private.sources where category='publications' limit 1;
  if source_id is null then raise exception 'No publications source available for test'; end if;

  insert into private.snapshots(source_id,content_hash,extracted_text)
    values(source_id,'paper-review-test-' || gen_random_uuid()::text,'synthetic rollback-only test')
    returning id into snapshot_id;
  insert into private.paper_candidates(snapshot_id,source_id,doi,title_hint,source_url,payload)
    values(snapshot_id,source_id,'10.9999/lablink-review-test','Synthetic test',
           'https://doi.org/10.9999/lablink-review-test','{}')
    returning id into candidate_id;

  result := public.approve_paper_candidate(candidate_id, jsonb_build_object(
    'title','Synthetic rollback-only paper',
    'year',2026,
    'journal','Test Journal',
    'doi','10.9999/lablink-review-test',
    'source_url','https://doi.org/10.9999/lablink-review-test',
    'faculty_name','Pipeline Test',
    'corresponding_status','unknown',
    'affiliation_scope','unverified',
    'reviewer','pipeline-test',
    'review_note','Rollback-only integration test'
  ));

  if result->>'status' <> 'published' then raise exception 'Approval did not publish'; end if;
  if not exists(
    select 1 from public.lab_papers lp join public.papers p on p.id=lp.paper_id
    where p.doi='10.9999/lablink-review-test' and lp.publication_state='published'
  ) then raise exception 'Published lab-paper relation missing'; end if;
  if not exists(
    select 1 from private.audit_logs
    where action='paper_candidate_approved' and detail->>'candidate_id'=candidate_id::text
  ) then raise exception 'Approval audit entry missing'; end if;
end $$;

rollback;
select 'PASS: approval transaction and rollback' as result;
