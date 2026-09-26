begin;

create or replace function public.publish_verified_bibliography(p_lab_slug text,p_entries jsonb)
returns integer language plpgsql security definer set search_path='' as $$
declare
  lab public.labs;
  entry jsonb;
  author jsonb;
  journal_id uuid;
  paper_id uuid;
  source_host text;
  homepage_host text;
  total integer := 0;
  faculty_corresponding boolean;
begin
  select * into lab from public.labs where slug=trim(p_lab_slug) and publication_state='published';
  if not found then raise exception 'Unknown or unpublished lab'; end if;
  if jsonb_typeof(p_entries)<>'array' or jsonb_array_length(p_entries)>20 then raise exception 'Entries must be an array of at most 20'; end if;
  homepage_host:=split_part(split_part(lab.homepage,'://',2),'/',1);
  for entry in select value from jsonb_array_elements(p_entries) loop
    source_host:=split_part(split_part(entry->>'source_url','://',2),'/',1);
    if source_host is distinct from homepage_host then raise exception 'Official source host does not match lab homepage'; end if;
    if entry->>'metadata_status'<>'matched' or entry#>>'{verification,tier}'<>'official_exact'
       or entry#>>'{verification,official_title_match}'<>'true' or entry#>>'{verification,faculty_author_match}'<>'true' then
      raise exception 'Only exact official bibliography matches may be published';
    end if;
    if nullif(trim(entry->>'doi'),'') is null or nullif(trim(entry->>'title'),'') is null
       or nullif(trim(entry->>'journal'),'') is null or jsonb_array_length(coalesce(entry->'authors','[]'))=0 then
      raise exception 'DOI, title, journal and ordered authors are required';
    end if;

    insert into public.journals(name,issn)
    values(entry->>'journal',nullif(entry#>>'{issn,0}','')) on conflict do nothing;
    select j.id into journal_id from public.journals j
      where j.name=entry->>'journal' order by (j.issn=nullif(entry#>>'{issn,0}','')) desc nulls last,j.created_at limit 1;

    insert into public.papers(doi,title,year,journal,source_url,journal_id,work_type,publication_status)
    values(lower(entry->>'doi'),entry->>'title',(entry->>'publication_year')::integer,entry->>'journal',
      'https://doi.org/'||lower(entry->>'doi'),journal_id,
      case entry->>'work_type' when 'journal-article' then 'article' when 'proceedings-article' then 'proceedings'
        when 'posted-content' then 'preprint' when 'book-chapter' then 'other' else 'article' end,'published')
    on conflict(doi) do update set title=excluded.title,year=excluded.year,journal=excluded.journal,
      source_url=excluded.source_url,journal_id=excluded.journal_id
    returning id into paper_id;

    select coalesce(bool_or(lower(a->>'name')=lower(lab.professor) and coalesce((a->>'corresponding')::boolean,false)),false)
      into faculty_corresponding from jsonb_array_elements(entry->'authors') a;
    insert into public.lab_papers(lab_id,paper_id,faculty_name,corresponding_status,evidence_url,verified_at,affiliation_scope,publication_state)
    values(lab.id,paper_id,lab.professor,case when faculty_corresponding then 'confirmed' else 'unknown' end,
      entry->>'source_url',case when faculty_corresponding then now() else null end,'current_lab','published')
    on conflict(lab_id,paper_id) do update set faculty_name=excluded.faculty_name,
      corresponding_status=excluded.corresponding_status,evidence_url=excluded.evidence_url,
      verified_at=excluded.verified_at,affiliation_scope='current_lab',publication_state='published';

    for author in select value from jsonb_array_elements(entry->'authors') loop
      insert into public.paper_authors(paper_id,author_order,display_name,affiliation,is_first,is_co_first,is_corresponding,role_status,evidence_url)
      values(paper_id,(author->>'order')::integer,author->>'name',nullif(author#>>'{affiliations,0}',''),
        coalesce((author->>'first')::boolean,false),coalesce((author->>'co_first')::boolean,false),
        coalesce((author->>'corresponding')::boolean,false),'verified',entry->>'source_url')
      on conflict(paper_id,author_order) do update set display_name=excluded.display_name,affiliation=excluded.affiliation,
        is_first=excluded.is_first,is_co_first=excluded.is_co_first,is_corresponding=excluded.is_corresponding,
        role_status='verified',evidence_url=excluded.evidence_url;
    end loop;

    insert into private.lab_publication_entries(lab_id,listing_year,doi,title,journal_citation,authors,source_url,publisher_source_url,metadata,verified_at,paper_id,status,note)
    values(lab.id,(entry->>'listing_year')::integer,lower(entry->>'doi'),entry->>'title',entry->>'journal_citation',
      entry->'authors',entry->>'source_url','https://doi.org/'||lower(entry->>'doi'),entry,now(),paper_id,'published',
      'Published by zero-token exact official-list and Crossref verification.')
    on conflict(lab_id,publisher_source_url) do update set doi=excluded.doi,title=excluded.title,
      journal_citation=excluded.journal_citation,authors=excluded.authors,metadata=excluded.metadata,
      verified_at=now(),paper_id=excluded.paper_id,status='published',note=excluded.note;
    insert into private.audit_logs(action,entity_id,detail) values('verified_bibliography_published',paper_id,
      jsonb_build_object('lab_id',lab.id,'doi',entry->>'doi','strategy','official_exact_crossref','model_tokens',0));
    total:=total+1;
  end loop;
  return total;
end; $$;

revoke all on function public.publish_verified_bibliography(text,jsonb) from public,anon,authenticated;
grant execute on function public.publish_verified_bibliography(text,jsonb) to service_role;

commit;
