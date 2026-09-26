-- Run after the catalogue migrations. Rolled back, including audit records.
begin;
do $$
declare jid uuid; pid uuid; lid uuid; data jsonb; history jsonb;
begin
  insert into public.journals(name) values('LabLink JIF transaction test') returning id into jid;
  perform public.save_journal_impact_factor(jid,2023,4.4,'verified','https://example.org/jif/2023',2024);
  perform public.save_journal_impact_factor(jid,2025,9.9,'verified','https://example.org/jif/2025',2026);
  select impact_factors into history from public.journals where id=jid;
  if (history->'2023'->>'value')::numeric<>4.4 or (history->'2025'->>'value')::numeric<>9.9 then raise exception 'History mismatch'; end if;
  insert into public.labs(slug,name,university,department,professor,homepage,publication_state)
    values('jif-transaction-test','Test','Test','Test','Test','https://example.org','published') returning id into lid;
  insert into public.papers(title,year,journal,journal_id,source_url) values('Test',2023,'LabLink JIF transaction test',jid,'https://example.org') returning id into pid;
  insert into public.lab_papers(lab_id,paper_id,faculty_name,publication_state) values(lid,pid,'Test','published');
  data:=public.list_lab_publications('jif-transaction-test')->0;
  if (data->'impact_factor'->>'year')::integer<>2023 or (data->'impact_factor'->>'value')::numeric<>4.4 then raise exception 'Wrong year match'; end if;
  update public.papers set year=2024 where id=pid;
  data:=public.list_lab_publications('jif-transaction-test')->0;
  if data->'impact_factor'<>'null'::jsonb then raise exception 'Missing year substituted'; end if;
  begin
    perform public.save_journal_impact_factor(jid,2024,4.4,'verified',null,2025);
    raise exception 'Expected missing evidence rejection';
  exception when others then
    if SQLERRM='Expected missing evidence rejection' then raise; end if;
  end;
  if has_function_privilege('anon','public.save_journal_impact_factor(uuid,integer,numeric,text,text,integer)','execute') or
     has_function_privilege('authenticated','public.save_journal_impact_factor(uuid,integer,numeric,text,text,integer)','execute') then raise exception 'Public write access'; end if;
end; $$;
rollback;
