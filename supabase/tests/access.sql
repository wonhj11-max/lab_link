-- Run in SQL Editor. Synthetic accounts are rolled back; no email is sent.
begin;
insert into auth.users(id,email) values
('00000000-1111-4000-8000-000000000001','lablink-test-a@example.invalid'),
('00000000-1111-4000-8000-000000000002','lablink-test-b@example.invalid'),
('00000000-1111-4000-8000-000000000003','lablink-test-c@example.invalid');
insert into public.collaboration_posts(id,owner_id,title,kind,description) values
('00000000-2222-4000-8000-000000000001','00000000-1111-4000-8000-000000000002','RLS test post','analysis','This is a temporary database authorization test.');
set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-1111-4000-8000-000000000001',true);
do $$ begin
 if (select count(*) from public.profiles where id in ('00000000-1111-4000-8000-000000000001','00000000-1111-4000-8000-000000000002','00000000-1111-4000-8000-000000000003'))<>1 then raise exception 'Private profile isolation failed'; end if;
 update public.profiles set display_name='Must not change' where id='00000000-1111-4000-8000-000000000002';
 if found then raise exception 'Cross-user profile write allowed'; end if;
 if has_function_privilege(current_user,'public.claim_crawl_job()','EXECUTE') then raise exception 'Browser can execute crawler RPC'; end if;
 if has_function_privilege(current_user,'public.list_paper_candidates(integer)','EXECUTE') then raise exception 'Browser can list paper candidates'; end if;
 if has_function_privilege(current_user,'public.approve_paper_candidate(uuid,jsonb)','EXECUTE') then raise exception 'Browser can approve paper candidates'; end if;
end $$;
select public.send_proposal('Temporary proposal testing recipient-only access.','00000000-2222-4000-8000-000000000001',null);
select set_config('request.jwt.claim.sub','00000000-1111-4000-8000-000000000003',true);
do $$ begin
 if exists(select 1 from public.proposals where post_id='00000000-2222-4000-8000-000000000001') then raise exception 'Third-party proposal disclosure'; end if;
end $$;
select set_config('request.jwt.claim.sub','00000000-1111-4000-8000-000000000002',true);
do $$ declare proposal uuid; begin
 select id into proposal from public.proposals where post_id='00000000-2222-4000-8000-000000000001';
 if proposal is null then raise exception 'Recipient cannot read proposal'; end if;
 perform public.transition_proposal(proposal,'accepted');
 if not exists(select 1 from public.proposals where id=proposal and status='accepted') then raise exception 'Recipient transition failed'; end if;
end $$;
reset role;
set local role anon;
do $$ begin
 if has_schema_privilege(current_user,'private','USAGE') then raise exception 'Anonymous private schema access'; end if;
 if has_function_privilege(current_user,'public.send_proposal(text,uuid,uuid)','EXECUTE') then raise exception 'Anonymous proposal creation'; end if;
 if exists(select 1 from public.labs where publication_state<>'published') then raise exception 'Draft lab exposed'; end if;
end $$;
reset role;
rollback;
select 'PASS: profiles, proposals, transitions, anonymous access, crawler RPC isolation' as result;
