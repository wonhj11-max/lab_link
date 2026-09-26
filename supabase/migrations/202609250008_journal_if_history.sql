-- journal_metrics is the normalized source; journals exposes its synchronized yearly history.
begin;
alter table public.journals add column if not exists impact_factors jsonb not null default '{}';
create or replace function private.refresh_journal_if_history() returns trigger
language plpgsql security definer set search_path='' as $$
declare target uuid;
begin
  for target in select distinct x from unnest(array[
    case when TG_OP <> 'INSERT' then OLD.journal_id end,
    case when TG_OP <> 'DELETE' then NEW.journal_id end]) x where x is not null
  loop
    update public.journals j set impact_factors=coalesce((
      select jsonb_object_agg(m.metric_year::text,jsonb_build_object(
        'value',case when m.status='verified' then m.value end,
        'status',m.status,'release_year',m.release_year,'source_url',m.source_url,'checked_at',m.checked_at))
      from public.journal_metrics m where m.journal_id=target and m.metric_type='jif'
    ),'{}'::jsonb) where j.id=target;
  end loop;
  return null;
end; $$;
revoke all on function private.refresh_journal_if_history() from public,anon,authenticated;
drop trigger if exists journal_if_history_sync on public.journal_metrics;
create trigger journal_if_history_sync after insert or update or delete on public.journal_metrics
for each row execute function private.refresh_journal_if_history();
update public.journals j set impact_factors=coalesce((
  select jsonb_object_agg(m.metric_year::text,jsonb_build_object(
    'value',case when m.status='verified' then m.value end,
    'status',m.status,'release_year',m.release_year,'source_url',m.source_url,'checked_at',m.checked_at))
  from public.journal_metrics m where m.journal_id=j.id and m.metric_type='jif'
),'{}'::jsonb);

-- Server-only entry point. One checked journal/year is reused by all matching papers.
create or replace function public.save_journal_impact_factor(p_journal_id uuid,p_metric_year integer,
  p_value numeric,p_status text,p_source_url text,p_release_year integer default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
  if p_metric_year is null or p_metric_year not between 1900 and 2200 then raise exception 'Invalid metric year'; end if;
  if p_status is null or p_status not in ('verified','not_released','not_available','unverified') then raise exception 'Invalid status'; end if;
  if p_status='verified' and (p_value is null or p_value<0 or nullif(trim(p_source_url),'') is null or p_source_url not like 'https://%') then
    raise exception 'Verified JIF requires a nonnegative value and HTTPS evidence';
  end if;
  if p_status<>'verified' and p_value is not null then raise exception 'Unverified JIF must not carry a numeric value'; end if;
  if p_release_year is not null and p_release_year<=p_metric_year then raise exception 'Release year must follow metric year'; end if;
  if not exists(select 1 from public.journals where id=p_journal_id) then raise exception 'Unknown journal'; end if;
  insert into public.journal_metrics(journal_id,metric_year,value,status,source_url,release_year,checked_at)
  values(p_journal_id,p_metric_year,p_value,p_status,p_source_url,p_release_year,now())
  on conflict(journal_id,metric_type,metric_year) do update set value=excluded.value,status=excluded.status,
    source_url=excluded.source_url,release_year=excluded.release_year,checked_at=excluded.checked_at;
  insert into private.audit_logs(action,entity_id,detail) values('journal_if_saved',p_journal_id,
    jsonb_build_object('metric_year',p_metric_year,'value',p_value,'status',p_status,'source_url',p_source_url));
  select impact_factors into result from public.journals where id=p_journal_id;
  return result;
end; $$;
revoke all on function public.save_journal_impact_factor(uuid,integer,numeric,text,text,integer) from public,anon,authenticated;
grant execute on function public.save_journal_impact_factor(uuid,integer,numeric,text,text,integer) to service_role;
commit;
