begin;
alter table private.lab_publication_entries add column if not exists metadata jsonb not null default '{}';
create or replace function public.stage_official_publication_entries(p_lab_slug text,p_entries jsonb)
returns integer language plpgsql security definer set search_path='' as $$
declare lab public.labs; entry jsonb; total integer:=0;
begin
  select * into lab from public.labs where slug=p_lab_slug;
  if not found then raise exception 'Unknown lab'; end if;
  if p_entries is null or jsonb_typeof(p_entries)<>'array' then raise exception 'Entries must be an array'; end if;
  if jsonb_array_length(p_entries)>10 then raise exception 'Maximum batch size is 10'; end if;
  for entry in select value from jsonb_array_elements(p_entries) loop
    if nullif(trim(entry->>'title'),'') is null or
       split_part(split_part(entry->>'source_url','://',2),'/',1) is distinct from split_part(split_part(lab.homepage,'://',2),'/',1) then
      raise exception 'Title and official lab source required';
    end if;
    insert into private.lab_publication_entries(lab_id,listing_year,doi,title,journal_citation,authors,source_url,publisher_source_url,metadata,note)
    values(lab.id,(entry->>'listing_year')::integer,lower(trim(entry->>'doi')),entry->>'title',entry->>'journal_citation',
      coalesce(entry->'authors','[]'),entry->>'source_url',entry->>'publisher_source_url',entry,
      'Crossref bibliography is stored for review. Author roles and lab affiliation are not inferred.')
    on conflict(lab_id,publisher_source_url) do update set
      metadata=excluded.metadata,
      authors=case when private.lab_publication_entries.status='published' then private.lab_publication_entries.authors else excluded.authors end,
      doi=coalesce(private.lab_publication_entries.doi,excluded.doi),scraped_at=now();
    total:=total+1;
  end loop;
  return total;
end; $$;
revoke all on function public.stage_official_publication_entries(text,jsonb) from public,anon,authenticated;
grant execute on function public.stage_official_publication_entries(text,jsonb) to service_role;
commit;
