begin;

create or replace function public.enrich_verified_publication(p_doi text,p_summary text,p_summary_source_url text,p_summary_hash text,p_keywords jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_paper_id uuid; v_keyword jsonb; v_position integer := 0;
begin
 select id into v_paper_id from public.papers where doi=lower(trim(p_doi));
 if v_paper_id is null then raise exception 'Unknown DOI'; end if;
 if nullif(trim(p_summary),'') is null or length(trim(p_summary)) < 80 then raise exception 'Abstract-based summary is too short'; end if;
 if p_summary_source_url not like 'https://%' or p_summary_hash !~ '^[a-f0-9]{64}$' then raise exception 'Valid HTTPS evidence and SHA-256 hash are required'; end if;
 insert into public.paper_summaries(paper_id,language,summary,source_basis,source_url,source_hash,model_id,prompt_version,generated_at,verification_status,verified_at,is_public)
 values(v_paper_id,'en',trim(p_summary),'abstract',p_summary_source_url,p_summary_hash,'deterministic-extractive-v1','abstract-sentences-v1',now(),'verified',now(),true)
 on conflict(paper_id,language) do update set summary=excluded.summary,source_basis='abstract',source_url=excluded.source_url,source_hash=excluded.source_hash,model_id=excluded.model_id,prompt_version=excluded.prompt_version,generated_at=now(),verification_status='verified',verified_at=now(),is_public=true;
 delete from public.paper_keywords where paper_id=v_paper_id and origin='agent_extracted';
 for v_keyword in select value from jsonb_array_elements(coalesce(p_keywords,'[]'::jsonb)) loop
  v_position:=v_position+1; exit when v_position > 8;
  if length(trim(v_keyword->>'keyword')) between 2 and 120 then
   insert into public.paper_keywords(paper_id,keyword,language,origin,position,source_url,verification_status)
   values(v_paper_id,trim(v_keyword->>'keyword'),'en','agent_extracted',v_position,p_summary_source_url,'verified')
   on conflict(paper_id,keyword,language,origin) do update set position=excluded.position,source_url=excluded.source_url,verification_status='verified';
  end if;
 end loop;
 insert into private.paper_evidence(paper_id,claim_type,source_url,source_hash,detail) values(v_paper_id,'abstract_summary',p_summary_source_url,p_summary_hash,jsonb_build_object('method','deterministic-extractive-v1','model_tokens',0));
 return jsonb_build_object('paper_id',v_paper_id,'keywords',v_position);
end; $$;
revoke all on function public.enrich_verified_publication(text,text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.enrich_verified_publication(text,text,text,text,jsonb) to service_role;

create or replace function public.list_lab_publications(p_lab_slug text)
returns jsonb language sql security definer set search_path='' stable as $$
 select coalesce(jsonb_agg(to_jsonb(q) order by q.year desc nulls last,q.title,q.paper_id),'[]'::jsonb)
 from (
  select p.id paper_id,p.doi,p.title,p.year,p.journal,p.source_url,p.publication_date,p.online_publication_date,p.work_type,p.publication_status,
   coalesce((select jsonb_agg(jsonb_build_object('name',a.display_name,'order',a.author_order,'first',a.is_first,'co_first',a.is_co_first,'corresponding',a.is_corresponding,'role_status',a.role_status) order by a.author_order) from public.paper_authors a where a.paper_id=p.id),'[]'::jsonb) authors,
   coalesce((select jsonb_agg(jsonb_build_object('keyword',k.keyword,'language',k.language,'origin',k.origin) order by k.position) from public.paper_keywords k where k.paper_id=p.id and k.verification_status='verified'),'[]'::jsonb) keywords,
   (select jsonb_build_object('text',s.summary,'basis',s.source_basis) from public.paper_summaries s where s.paper_id=p.id and s.is_public and s.verification_status='verified' order by case s.language when 'ko' then 0 else 1 end limit 1) summary,
   coalesce((select jsonb_build_object('year',m.metric_year,'value',m.value,'status',m.status,'source_url',m.source_url) from public.journal_metrics m where m.journal_id=p.journal_id and m.metric_year=p.year and m.metric_type='jif'),'null'::jsonb) impact_factor
  from public.lab_papers lp join public.labs l on l.id=lp.lab_id join public.papers p on p.id=lp.paper_id
  where l.slug=trim(p_lab_slug) and l.publication_state='published' and lp.publication_state='published'
 ) q;
$$;
revoke all on function public.list_lab_publications(text) from public;
grant execute on function public.list_lab_publications(text) to anon,authenticated;

commit;
