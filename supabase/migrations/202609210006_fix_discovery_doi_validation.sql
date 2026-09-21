-- PostgreSQL ARE does not treat \S as a non-whitespace character class.
-- Replace it with the POSIX class so valid DOI candidates are staged.
begin;

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
    if candidate_doi !~* '^10[.][0-9]{4,9}/[^[:space:]]+$' then continue; end if;
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

revoke all on function public.stage_discovered_papers(text,text,text,jsonb,integer,integer) from public,anon,authenticated;
grant execute on function public.stage_discovered_papers(text,text,text,jsonb,integer,integer) to service_role;

commit;
