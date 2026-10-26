CREATE OR REPLACE FUNCTION account_intel.canonical_domain(w text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select nullif(
    regexp_replace(
      regexp_replace(lower(trim(w)), '^(https?://)?(www\.)?', ''),
      '[/?#:].*$', ''),
  '')
$function$
;

CREATE OR REPLACE FUNCTION account_intel.clean_registered_name(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select initcap(trim(regexp_replace(regexp_replace(coalesce(p,''), '\s+(LIMITED|LTD\.?|L\.T\.D\.?|PLC|P\.L\.C\.?|LLP)\s*$', '', 'i'), '\s+', ' ', 'g')))
$function$
;

CREATE OR REPLACE FUNCTION account_intel.fmt_money_k(k numeric)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case when k is null then '?' when k >= 1000 then '£' || to_char(round(k / 1000.0, 1), 'FM999,990.0') || 'm' else '£' || to_char(round(k), 'FM999,999') || 'k' end
$function$
;

CREATE OR REPLACE FUNCTION account_intel.must_replace(s text, a text, b text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
begin
  if position(a in s) = 0 then raise exception 'anchor not found: %', left(a, 80); end if;
  return replace(s, a, b);
end $function$
;

CREATE OR REPLACE FUNCTION account_intel.register_promote(p_transaction_id text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
declare e record; v_acc uuid; v_name text; v_week numeric; v_sig_url text; v_prof jsonb; r record;
begin
  select * into e from account_intel.register_events where transaction_id = p_transaction_id;
  if e.transaction_id is null then return null; end if;
  v_prof := coalesce(e.profile, '{}'::jsonb);
  v_name := account_intel.clean_registered_name(e.company_name);
  -- someone may have matched this company since
  select account_id into v_acc from account_intel.registry where company_number = e.company_number limit 1;
  if v_acc is null then
    insert into account_intel.accounts (name, hq_country, origin, net_new_at, sf_status, is_ai)
    values (v_name, 'GB', 'register', now(), 'unchecked', false) returning account_id into v_acc;
    perform public.intel_save_registry(v_acc, 'CH', e.company_number, e.company_name, v_prof->>'company_status', nullif(v_prof->>'date_of_creation','')::date,
      (select array_agg(x) from jsonb_array_elements_text(coalesce(v_prof->'sic_codes','[]'::jsonb)) x), v_prof->'accounts'->'last_accounts'->>'type', null, null, 1.0, 'stream', v_prof);
  end if;
  -- move every staged event for this company (within 60 days) onto the account as filings
  for r in select * from account_intel.register_events x where x.company_number = e.company_number and x.outcome in ('staged','too_small','promoted') and x.action_date >= current_date - 60 loop
    insert into account_intel.filings (account_id, company_number, transaction_id, filing_type, category, description, filed_on, action_date, capital, raw, doc_url, amount_raised, shares_allotted, parse_attempted_at, amount_parsed_at, parse_note)
    values (v_acc, r.company_number, r.transaction_id, 'SH01', 'capital', coalesce(r.filing->>'description','capital-allotment-shares'), r.filed_on, r.action_date, r.capital, r.filing, r.doc_url, r.amount_raised, r.shares_allotted, r.parse_attempted_at, r.amount_parsed_at, r.parse_note)
    on conflict (account_id, transaction_id) do update set amount_raised = coalesce(excluded.amount_raised, account_intel.filings.amount_raised), amount_parsed_at = coalesce(excluded.amount_parsed_at, account_intel.filings.amount_parsed_at), doc_url = coalesce(account_intel.filings.doc_url, excluded.doc_url);
    update account_intel.register_events set outcome = 'promoted', account_id = v_acc, updated_at = now() where transaction_id = r.transaction_id;
  end loop;
  select coalesce(sum(amount_raised),0) into v_week from account_intel.filings where account_id = v_acc and filing_type = 'SH01' and amount_raised is not null and abs(action_date - e.action_date) <= 7;
  v_sig_url := 'https://find-and-update.company-information.service.gov.uk/company/' || e.company_number || '/filing-history/' || e.transaction_id || '/document?format=pdf';
  insert into account_intel.news_signals (account_id, kind, event_date, url, title, snippet, amount, source, confidence)
  values (v_acc, 'funding', e.action_date, v_sig_url, 'SH01 share allotment filed ' || to_char(e.filed_on, 'DD Mon YYYY') || ' (register, unannounced)',
          'Seen on the Companies House stream before any announcement. ' || coalesce('Capital ' || (e.capital->0->>'figure') || ' ' || (e.capital->0->>'currency'), ''),
          case when v_week >= 1000 and v_week <= 50000000 then '£' || to_char(round(v_week / 1000.0), 'FM999,999') || 'k' else null end,
          'companies_house', case when v_week > 50000000 then 'check' else 'likely' end)
  on conflict (account_id, url) do update set confidence = excluded.confidence, amount = excluded.amount;
  return v_acc;
end $function$
;

CREATE OR REPLACE FUNCTION account_intel.touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$ begin new.updated_at = now(); return new; end $function$
;

CREATE OR REPLACE FUNCTION ops.bump_last_signal()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  update ops.agencies set last_signal_at = greatest(coalesce(last_signal_at, new.seen_at), new.seen_at)
  where id = new.agency_id;
  return new;
end $function$
;

CREATE OR REPLACE FUNCTION ops.normalise_company_name(n text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select regexp_replace(
           regexp_replace(lower(n), '\m(ltd|limited|llp|plc|uk|group|holdings)\M', '', 'g'),
           '[^a-z0-9]', '', 'g')
$function$
;

CREATE OR REPLACE FUNCTION ops.touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin new.updated_at = now(); return new; end $function$
;

CREATE OR REPLACE FUNCTION public.agencies_to_score(p_limit integer DEFAULT 100)
 RETURNS TABLE(agency_id uuid, name text, ch_name text, company_number text, incorporated_on date, sic_codes text[], region text, status text, advert_count bigint, adverts jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public'
AS $function$
  select a.id, a.name, a.ch_name, a.company_number, a.incorporated_on, a.sic_codes, a.region, a.status::text,
         count(s.id),
         jsonb_agg(jsonb_build_object('url', s.source_url, 'detail', s.detail, 'seen_at', s.seen_at)
                   order by s.seen_at desc)
    from ops.agencies a
    join ops.signals s on s.agency_id = a.id and s.seen_at > now() - interval '45 days'
   where a.status in ('new','scored')
   group by a.id
   order by a.last_signal_at desc
   limit p_limit;
$function$
;

CREATE OR REPLACE FUNCTION public.agencies_to_score_v2(p_limit integer DEFAULT 100)
 RETURNS TABLE(agency_id uuid, name text, ch_name text, company_number text, incorporated_on date, sic_codes text[], region text, status text, owner_name text, owner_role text, active_directors smallint, advert_count bigint, total_applications bigint, hiring_resourcer boolean, adverts jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public'
AS $function$
  select a.id, a.name, a.ch_name, a.company_number, a.incorporated_on, a.sic_codes, a.region, a.status::text,
         a.owner_name, a.owner_role, a.active_directors,
         count(s.id) filter (where s.type = 'job_advert'),
         coalesce(sum(s.applications), 0),
         bool_or(s.type = 'hiring_resourcer'),
         jsonb_agg(jsonb_build_object('type', s.type, 'url', s.source_url, 'detail', s.detail, 'applications', s.applications, 'seen_at', s.seen_at)
                   order by s.seen_at desc)
    from ops.agencies a
    join ops.signals s on s.agency_id = a.id and s.seen_at > now() - interval '45 days'
   where a.status in ('new','scored')
   group by a.id
   order by (a.status = 'new') desc, a.last_signal_at desc
   limit p_limit;
$function$
;

CREATE OR REPLACE FUNCTION public.intel_accounts_for_filings(p_limit integer DEFAULT 100)
 RETURNS TABLE(account_id uuid, company_number text, name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
#variable_conflict use_column
begin
  return query
  with pick as (
    select a.account_id, r.company_number, a.name
    from account_intel.accounts a join account_intel.registry r on r.account_id = a.account_id
    where a.disqualified_reason is null and r.company_number is not null and r.match_confidence >= 0.85 and r.status = 'active'
      and (a.ch_filings_checked_at is null or a.ch_filings_checked_at < now() - interval '3 days')
    order by a.ch_filings_checked_at nulls first, a.score desc nulls last
    limit p_limit
  ), upd as (
    update account_intel.accounts x set ch_filings_checked_at = now() from pick p where p.account_id = x.account_id returning x.account_id
  )
  select p.account_id, p.company_number, p.name from pick p;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_accounts_for_jobs(p_limit integer DEFAULT 200)
 RETURNS TABLE(account_id uuid, name text, linkedin_url text, slug text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
  with pick as (
    select a.account_id from account_intel.accounts a
    where a.disqualified_reason is null and a.linkedin_url is not null
      and (a.jobs_attempted_at is null or a.jobs_attempted_at < now() - interval '6 days')
    order by a.jobs_attempted_at nulls first, a.created_at limit p_limit
  ), upd as (
    update account_intel.accounts a set jobs_attempted_at = now() from pick where a.account_id = pick.account_id
    returning a.account_id, a.name, a.linkedin_url,
      lower(regexp_replace(a.linkedin_url, '^.*linkedin\.com/(company|school|showcase)/([^/?#]+).*$', '\2')) as slug
  ) select * from upd
$function$
;

CREATE OR REPLACE FUNCTION public.intel_accounts_for_news(p_limit integer DEFAULT 150)
 RETURNS TABLE(account_id uuid, name text, domain text, li_industry text, hq_country text, posts jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
  with pick as (
    select a.account_id from account_intel.accounts a
    where a.disqualified_reason is null
      and (a.news_attempted_at is null or a.news_attempted_at < now() - interval '6 days')
    order by a.news_attempted_at nulls first, a.created_at limit p_limit
  ), upd as (
    update account_intel.accounts a set news_attempted_at = now() from pick where a.account_id = pick.account_id
    returning a.account_id, a.name, a.domain, a.li_industry, a.hq_country
  )
  select u.account_id, u.name, u.domain, u.li_industry, u.hq_country,
         (select coalesce(jsonb_agg(p), '[]'::jsonb) from (
            select x as p from account_intel.linkedin_raw lr, jsonb_array_elements(coalesce(lr.item->'posts','[]'::jsonb)) x
            where lr.account_id = u.account_id order by lr.received_at desc limit 10) q) as posts
  from upd u
$function$
;

CREATE OR REPLACE FUNCTION public.intel_accounts_for_why_now(p_limit integer DEFAULT 150)
 RETURNS TABLE(account_id uuid, name text, domain text, band text, score numeric, lead_product text, cross_sell text, convo_starter text, headcount integer, industry text, hq_country text, evidence_line text, breakdown jsonb, jobs jsonb, news jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
  select a.account_id, a.name, a.domain, a.band::text, a.score, a.lead_product::text, a.cross_sell::text, a.convo_starter, a.headcount, a.li_industry, a.hq_country,
         a.evidence_line, a.score_breakdown,
         (select coalesce(jsonb_agg(jsonb_build_object('title', j.title, 'location', j.location, 'country', j.country, 'posted', j.posted_at, 'type', j.employment_type, 'remote', j.remote_anywhere, 'contract', j.contract_language, 'visa', j.visa_language) order by j.posted_at desc nulls last), '[]'::jsonb)
            from (select * from account_intel.jobs j0 where j0.account_id = a.account_id and j0.closed_at is null and coalesce(j0.posted_at, j0.first_seen_at::date) >= current_date - 90 order by j0.posted_at desc nulls last limit 12) j),
         (select coalesce(jsonb_agg(jsonb_build_object('kind', s.kind, 'date', s.event_date, 'title', s.title, 'snippet', s.snippet, 'amount', s.amount, 'source', s.source) order by s.event_date desc), '[]'::jsonb)
            from account_intel.news_signals s where s.account_id = a.account_id and s.event_date >= current_date - 270 and s.kind <> 'ignored' and s.confidence <> 'pending')
  from account_intel.accounts a
  left join account_intel.why_now w on w.account_id = a.account_id
  where a.band in ('A','B') and a.disqualified_reason is null and coalesce(a.is_customer, false) = false
    and (w.account_id is null
         or w.score_version is distinct from a.score_version
         or w.scorer_evidence is distinct from a.evidence_line
         or (w.band_at_generation = 'B' and a.band = 'A'))
  order by a.score desc limit p_limit
$function$
;

CREATE OR REPLACE FUNCTION public.intel_accounts_to_enrich(p_limit integer DEFAULT 100)
 RETURNS TABLE(account_id uuid, name text, domain text, linkedin_url text, slug text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
  with pick as (
    select a.account_id from account_intel.accounts a
    where a.disqualified_reason is null and a.li_enriched_at is null
      and (a.li_attempts = 0 or (a.li_attempts = 1 and a.li_attempted_at < now() - interval '1 hour'))
    order by a.li_attempts, a.created_at
    limit p_limit
  ), upd as (
    update account_intel.accounts a set li_attempts = a.li_attempts + 1, li_attempted_at = now()
    from pick where a.account_id = pick.account_id
    returning a.account_id, a.name, a.domain,
      -- attempt 1: by URL; attempt 2: by name search (linkedin_url returned null so the batch builder uses searches)
      case when a.li_attempts = 1 then a.linkedin_url else null end as linkedin_url,
      lower(nullif(regexp_replace(coalesce(a.linkedin_url,''), '^.*linkedin\.com/(company|school|showcase)/([^/?#]+).*$', '\2'), coalesce(a.linkedin_url,''))) as slug
  )
  select * from upd
$function$
;

CREATE OR REPLACE FUNCTION public.intel_accounts_to_resolve(p_limit integer DEFAULT 500)
 RETURNS TABLE(account_id uuid, name text, domain text, registry_hint text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
  with pick as (
    select a.account_id from account_intel.accounts a
    left join account_intel.registry r on r.account_id = a.account_id
    where (r.account_id is null or r.matched_by = 'retry')
      and (a.resolve_attempted_at is null or a.resolve_attempted_at < now() - interval '2 hours')
    order by a.created_at limit p_limit
  ), upd as (
    update account_intel.accounts a set resolve_attempted_at = now() from pick where a.account_id = pick.account_id
    returning a.account_id, a.name, a.domain, case when a.domain ~ '\.ie$' then 'CRO' else 'CH' end as registry_hint
  ) select * from upd
$function$
;

CREATE OR REPLACE FUNCTION public.intel_accounts_to_scan(p_limit integer DEFAULT 250)
 RETURNS TABLE(account_id uuid, name text, domain text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
  with pick as (
    select a.account_id from account_intel.accounts a
    where a.domain is not null and a.disqualified_reason is null and a.scanned_at is null
      and (a.scan_attempted_at is null or a.scan_attempted_at < now() - interval '30 minutes')
    order by a.scan_attempted_at nulls first, a.created_at limit p_limit
  ), upd as (
    update account_intel.accounts a set scan_attempted_at = now() from pick where a.account_id = pick.account_id
    returning a.account_id, a.name, a.domain
  ) select * from upd
$function$
;

CREATE OR REPLACE FUNCTION public.intel_accounts_with_ats(p_limit integer DEFAULT 200)
 RETURNS TABLE(account_id uuid, name text, ats_provider text, ats_token text, careers_url text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
  with pick as (
    select a.account_id from account_intel.accounts a
    where a.disqualified_reason is null and a.ats_provider is not null
      and (a.ats_jobs_attempted_at is null or a.ats_jobs_attempted_at < now() - interval '6 days')
    order by a.ats_jobs_attempted_at nulls first limit p_limit
  ), upd as (
    update account_intel.accounts a set ats_jobs_attempted_at = now() from pick where a.account_id = pick.account_id
    returning a.account_id, a.name, a.ats_provider, a.ats_token, a.careers_url
  ) select * from upd
$function$
;

CREATE OR REPLACE FUNCTION public.intel_add_net_new(p_name text, p_domain text, p_amount text, p_stage text, p_url text, p_event_date date, p_is_ai boolean, p_summary text, p_location text DEFAULT NULL::text)
 RETURNS TABLE(outcome text, account_id uuid, name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
declare acc uuid; nm text; dom text; existing_name text; v_sf text;
begin
  nm := ops.normalise_company_name(p_name);
  dom := case when p_domain is not null and p_domain <> '' then account_intel.canonical_domain(p_domain) else null end;
  -- a raise announced in the last 3 days may still be unclaimed: on the sheet. Older: off the sheet until Jamie releases it.
  v_sf := case when p_event_date is not null and p_event_date >= current_date - 3 then null else 'unchecked' end;
  select a.account_id, a.name into acc, existing_name from account_intel.accounts a
  where (dom is not null and a.domain = dom) or a.normalised_name = nm
  order by (a.domain is not null) desc, a.created_at limit 1;
  if acc is null and length(nm) >= 5 then
    select a.account_id, a.name into acc, existing_name from account_intel.accounts a
    where a.origin = 'net_new' and a.disqualified_reason is null
      and (a.normalised_name like nm || ' %' or nm like a.normalised_name || ' %')
    order by length(a.normalised_name) desc limit 1;
  end if;
  if acc is null then
    insert into account_intel.accounts (name, domain, website, hq_country, origin, is_ai, net_new_at, sf_status)
    values (p_name, dom, case when dom is not null then 'https://' || dom else null end, case when p_location ~* 'ireland|dublin|cork|galway' then 'IE' else 'GB' end, 'net_new', coalesce(p_is_ai, false), now(), v_sf)
    returning account_intel.accounts.account_id into acc;
    insert into account_intel.news_signals (account_id, kind, event_date, url, title, snippet, amount, source)
    values (acc, 'funding', p_event_date, p_url, left(p_name || ' raises ' || coalesce(p_amount, ''), 200), left(p_summary, 300), p_amount, 'news')
    on conflict do nothing;
    return query select 'new'::text, acc, p_name;
  else
    update account_intel.accounts set is_ai = is_ai or coalesce(p_is_ai, false),
      domain = coalesce(account_intel.accounts.domain, dom),
      website = coalesce(account_intel.accounts.website, case when dom is not null then 'https://' || dom else null end)
    where account_intel.accounts.account_id = acc;
    insert into account_intel.news_signals (account_id, kind, event_date, url, title, snippet, amount, source)
    values (acc, 'funding', p_event_date, p_url, left(p_name || ' raises ' || coalesce(p_amount, ''), 200), left(p_summary, 300), p_amount, 'news')
    on conflict do nothing;
    return query select 'existing'::text, acc, existing_name;
  end if;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_alert_answer(p_alert_id bigint, p_answer text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
declare acc uuid;
begin
  update account_intel.alerts set answer = p_answer, answered_at = now() where id = p_alert_id returning account_id into acc;
  if acc is null then return 'no alert'; end if;
  if p_answer = 'mine' then
    update account_intel.accounts set sf_status = null where account_id = acc;
    update account_intel.sheet_state set removed_at = null, remove_reason = null where account_id = acc;
  elsif p_answer = 'owned' then
    update account_intel.accounts set sf_status = 'owned', disqualified_reason = 'owned by another rep (Telegram ' || to_char(now(), 'DD Mon') || ')', band = null, score = null where account_id = acc;
  elsif p_answer = 'timeout' then
    update account_intel.accounts set sf_status = coalesce(sf_status, 'unchecked') where account_id = acc and origin <> 'book';
  end if;
  return p_answer;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_alert_answer_v2(p_alert_id bigint, p_answer text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
declare r text; acc uuid; nm text;
begin
  r := public.intel_alert_answer(p_alert_id, p_answer);
  select account_id into acc from account_intel.alerts where id = p_alert_id;
  select name into nm from account_intel.accounts where account_id = acc;
  return jsonb_build_object('ok', r = p_answer, 'answer', r, 'account_id', acc, 'name', nm);
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_alert_next()
 RETURNS TABLE(alert_id bigint, account_id uuid, chat_id text, kind text, text text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
#variable_conflict use_column
declare v_chat text; r record; v_text text; v_kind text; v_id bigint;
begin
  select value into v_chat from account_intel.settings where key = 'telegram_chat_id';
  if v_chat is null then return; end if;
  select a.account_id, a.name, a.origin, a.headcount, a.li_industry, a.is_ai, a.band, n.source, n.amount, n.event_date, n.url,
         (select count(*) from account_intel.jobs j where j.account_id = a.account_id and j.closed_at is null and j.country not in ('GB','IE','','OO','XX')) as foreign_roles,
         (select round(sum(f.amount_raised) / 1000.0) from account_intel.filings f where f.account_id = a.account_id and f.filing_type = 'SH01' and f.amount_raised is not null and abs(f.action_date - n.event_date) <= 7) as register_k
  into r
  from account_intel.accounts a
  join lateral (
    select s.* from account_intel.news_signals s
    where s.account_id = a.account_id and s.kind = 'funding'
      and (
        (s.source = 'news' and a.origin in ('net_new', 'register') and nullif(trim(s.amount), '') is not null
           and s.observed_at >= now() - interval '24 hours' and s.event_date >= current_date - 2)
        or
        (s.source = 'companies_house' and s.confidence = 'likely' and s.observed_at >= now() - interval '14 days'
           and (select coalesce(sum(f.amount_raised), 0) from account_intel.filings f where f.account_id = a.account_id and f.filing_type = 'SH01' and f.amount_raised is not null and abs(f.action_date - s.event_date) <= 7) between 500000 and 50000000
           and exists (select 1 from account_intel.filings f where f.account_id = a.account_id and f.filing_type = 'SH01' and f.filed_on >= current_date - 14)
           and a.headcount between 10 and 500
           and not exists (select 1 from account_intel.news_signals p where p.account_id = a.account_id and p.kind = 'funding' and p.source = 'news'))
      )
    order by s.event_date desc limit 1
  ) n on true
  where a.disqualified_reason is null and coalesce(a.is_customer, false) = false and a.alerted_at is null
    and coalesce(a.headcount, 0) <= 500
    and coalesce(a.li_industry, '') !~* 'investment|venture|private equity|wealth|banking|capital markets|real estate|property|hospitality|restaurant|food and beverage|non-profit|charit|education|staffing|recruiting|insurance|accounting'
  order by n.event_date desc, a.score desc nulls last
  limit 1;
  if r.account_id is null then return; end if;
  v_kind := case when r.origin = 'book' then 'book' else 'net_new' end;
  v_text := r.name || case when r.source = 'news' then ' raised ' || r.amount || ', announced ' || to_char(r.event_date, 'DD Mon') || '.'
                      else ' has just taken about ' || account_intel.fmt_money_k(r.register_k) || ' of new investment (on the register ' || to_char(r.event_date, 'DD Mon') || ', nothing in the press).' end
         || E'\n' || concat_ws(', ', nullif(r.headcount::text || ' staff', ' staff'), nullif(r.li_industry, ''), case when r.is_ai then 'AI' end, case when r.foreign_roles > 0 then r.foreign_roles || ' foreign role' || case when r.foreign_roles > 1 then 's' else '' end end)
         || E'\n' || case when v_kind = 'book' then 'Your account, band ' || coalesce(r.band::text, '-') || '. Nobody else can see this yet. the SDR should call this week.'
                          when r.origin = 'register' then 'Not in your book. Found on the register before any announcement, so probably nobody on the team has it yet. Check the CRM, then tap.'
                          else 'Not in your book. Check the CRM, then tap.' end
         || case when r.url is not null and r.source = 'news' then E'\n' || r.url else '' end;
  update account_intel.accounts set alerted_at = now() where account_id = r.account_id;
  insert into account_intel.alerts (account_id, source, summary) values (r.account_id, case when r.source = 'news' then 'news' when r.origin = 'book' then 'register_book' else 'register_stream' end, v_text) returning id into v_id;
  return query select v_id, r.account_id, v_chat, v_kind, v_text;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_apply_disqualifiers()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
declare n int;
begin
  -- only the two rule-based reasons are recomputed; anything else (registry_*, owned by another rep, duplicate, test row, manual) is kept as written
  update account_intel.accounts a set
    disqualified_reason = case
      when a.disqualified_reason is not null and a.disqualified_reason not in ('size_over_500', 'never_buy_industry') then a.disqualified_reason
      when a.headcount > 500 then 'size_over_500'
      when exists (select 1 from account_intel.never_buy_industries n where n.li_industry = a.li_industry) then 'never_buy_industry'
      else null end,
    size_check = coalesce(a.headcount between 400 and 500, false)
  where a.li_enriched_at is not null;
  select count(*) into n from account_intel.accounts where disqualified_reason in ('size_over_500','never_buy_industry');
  return n;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_apply_jobs()
 RETURNS TABLE(applied integer, unmatched integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
 SET statement_timeout TO '600s'
AS $function$
declare r record; acc uuid; n_app int := 0; n_un int := 0; t text; d text; loc text; cc text; url text; posted date; etype text; wtype text; cname text; slug text;
begin
  for r in select id, item, source, account_id as pre_acc from account_intel.jobs_raw where applied_at is null loop
    acc := r.pre_acc;
    if acc is null and (r.item->>'account_id') is not null then
      begin acc := (r.item->>'account_id')::uuid; exception when others then acc := null; end;
    end if;
    if acc is null then
      slug := lower(regexp_replace(coalesce(r.item->'company'->>'linkedinUrl', r.item->>'companyLinkedinUrl', ''), '^.*linkedin\.com/(company|school|showcase)/([^/?#]+).*$', '\2'));
      if slug <> '' then
        select a.account_id into acc from account_intel.accounts a where lower(a.li_slug) = slug limit 1;
        if acc is null then
          select a.account_id into acc from account_intel.accounts a
           where lower(regexp_replace(coalesce(a.linkedin_url,''), '^.*linkedin\.com/(company|school|showcase)/([^/?#]+).*$', '\2')) = slug limit 1;
        end if;
      end if;
    end if;
    if acc is null and (r.item->'company'->>'website') is not null then
      select a.account_id into acc from account_intel.accounts a where a.domain = account_intel.canonical_domain(r.item->'company'->>'website') limit 1;
    end if;
    if acc is null then
      cname := regexp_replace(coalesce(r.item->'company'->>'name', r.item->>'companyName', ''), '\s*\(.*\)\s*$', '');
      if cname <> '' then
        select a.account_id into acc from account_intel.accounts a where a.normalised_name = ops.normalise_company_name(cname) limit 1;
      end if;
      if acc is null then
        cname := regexp_replace(coalesce(r.item->'company'->>'name', ''), '^.*\((.*)\)\s*$', '\1');
        if cname <> '' then
          select a.account_id into acc from account_intel.accounts a where a.normalised_name = ops.normalise_company_name(cname) limit 1;
        end if;
      end if;
    end if;
    if acc is null then n_un := n_un + 1; update account_intel.jobs_raw set applied_at = now() where id = r.id; continue; end if;

    url := coalesce(r.item->>'linkedinUrl', r.item->>'url', r.item->>'jobUrl', r.item->>'id');
    if url is null then update account_intel.jobs_raw set applied_at = now(), account_id = acc where id = r.id; continue; end if;
    t := coalesce(r.item->>'title', '');
    d := coalesce(r.item->>'descriptionText', r.item->>'description', '');
    loc := coalesce(r.item->'location'->>'linkedinText', r.item->>'location', '');
    cc := coalesce(r.item->>'countryCode', r.item->'location'->>'countryCode', r.item->'location'->'parsed'->>'countryCode', r.item->'location'->'parsed'->>'country');
    etype := coalesce(r.item->>'employmentType', '');
    wtype := coalesce(r.item->>'workplaceType', '');
    begin posted := (coalesce(r.item->>'postedDate', r.item->>'postedAt', r.item->>'listedAt'))::date; exception when others then posted := null; end;

    insert into account_intel.jobs (job_url, account_id, source, title, location, country, remote_anywhere, employment_type, workplace_type,
      contract_language, visa_language, onsite_language, it_role, people_role, posted_at, first_seen_at, last_seen_at, snippet, salary_text, raw)
    values (url, acc, r.source, left(t, 200), left(loc, 200), nullif(upper(left(cc, 2)), ''),
      coalesce(wtype ilike 'remote' or loc ~* 'remote' or d ~* 'remote[- ]?(anywhere|first|only)|fully remote|work from anywhere', false),
      nullif(etype, ''), nullif(wtype, ''),
      coalesce(etype ~* 'contract|temporary|freelance' or t ~* '\m(contract|contractor|freelance|day rate|fixed[- ]term|interim)\M' or d ~* 'day rate|outside ir35|inside ir35|\bfreelance\b|fixed[- ]term contract', false),
      coalesce(d ~* 'visa sponsorship|sponsorship (is )?available|relocation (package|support|assistance)|skilled worker visa', false),
      coalesce(d ~* '\brotational?\b|\boffshore\b|\bfifo\b|fly[- ]in|on[- ]site crew|site[- ]based', false),
      coalesce(t ~* '\b(it support|it manager|it technician|systems administrator|sysadmin|it engineer|helpdesk|desktop support|infrastructure engineer)\b', false),
      coalesce(t ~* '\b(people|hr|human resources|talent|recruit)\w*\b', false),
      posted, now(), now(), left(regexp_replace(d, '\s+', ' ', 'g'), 400), coalesce(r.item->'salary'->>'text', r.item->>'salaryText'),
      jsonb_build_object('applicants', coalesce(r.item->>'applicants', r.item->>'applicantsCount'), 'hiring_team', r.item->'hiringTeam', 'job_state', r.item->>'jobState'))
    on conflict (job_url) do update set last_seen_at = now(), posted_at = coalesce(excluded.posted_at, account_intel.jobs.posted_at), closed_at = null;
    update account_intel.jobs_raw set applied_at = now(), account_id = acc where id = r.id;
    n_app := n_app + 1;
  end loop;
  update account_intel.accounts a set jobs_fetched_at = now() where a.jobs_attempted_at is not null and a.jobs_fetched_at is null;
  return query select n_app, n_un;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_apply_linkedin()
 RETURNS TABLE(applied integer, unmatched integer, disqualified integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
declare r record; acc uuid; n_app int := 0; n_un int := 0; n_dq int := 0; hq text; emp_c jsonb; offices text[];
begin
  for r in select id, item from account_intel.linkedin_raw where applied_at is null loop
    acc := null;
    select a.account_id into acc from account_intel.accounts a
      where lower(regexp_replace(coalesce(a.linkedin_url,''), '^.*linkedin\.com/(company|school|showcase)/([^/?#]+).*$', '\2')) = lower(r.item->>'universalName')
      limit 1;
    if acc is null and (r.item->>'website') is not null then
      select a.account_id into acc from account_intel.accounts a where a.domain = account_intel.canonical_domain(r.item->>'website') limit 1;
    end if;
    if acc is null then
      select a.account_id into acc from account_intel.accounts a
        where a.normalised_name = ops.normalise_company_name(r.item->>'name') and a.li_enriched_at is null limit 1;
    end if;
    if acc is null then
      n_un := n_un + 1;
      update account_intel.linkedin_raw set applied_at = now() where id = r.id;
      continue;
    end if;

    select l->>'country' into hq from jsonb_array_elements(coalesce(r.item->'locations','[]'::jsonb)) l
      where (l->>'headquarter')::boolean limit 1;
    select array_agg(distinct l->>'country') into offices from jsonb_array_elements(coalesce(r.item->'locations','[]'::jsonb)) l
      where l->>'country' is not null;
    -- peopleStats "Locations": keep country-level entries (no comma in the title)
    select jsonb_agg(jsonb_build_object('country', v->>'title', 'count', (v->>'count')::int)) into emp_c
      from jsonb_array_elements(coalesce(r.item->'peopleStats','[]'::jsonb)) s,
           jsonb_array_elements(s->'values') v
      where s->>'statTitle' = 'Locations' and (v->>'title') !~ ',';

    update account_intel.accounts a set
      headcount = nullif(r.item->>'employeeCount','')::int,
      hq_country = coalesce(hq, a.hq_country),
      li_industry = r.item->'industries'->0->>'name',
      li_slug = r.item->>'universalName',
      li_founded = nullif(r.item->'foundedOn'->>'year','')::int,
      li_followers = nullif(r.item->>'followerCount','')::int,
      li_specialities = (select array_agg(x::text) from jsonb_array_elements_text(coalesce(r.item->'specialities','[]'::jsonb)) x),
      li_office_countries = offices,
      li_employee_countries = emp_c,
      website = coalesce(a.website, r.item->>'website'),
      domain = coalesce(a.domain, account_intel.canonical_domain(r.item->>'website')),
      linkedin_url = coalesce(a.linkedin_url, r.item->>'linkedinUrl'),
      li_enriched_at = now()
    where a.account_id = acc;
    update account_intel.linkedin_raw set applied_at = now(), account_id = acc where id = r.id;
    n_app := n_app + 1;
  end loop;

  select * into n_dq from public.intel_apply_disqualifiers();
  return query select n_app, n_un, n_dq;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_band_accounts_for_contacts(p_limit integer DEFAULT 10)
 RETURNS TABLE(account_id uuid, company text, domain text, band text, lead_product text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'own_brand'
AS $function$
begin
  return query
  with picked as (
    select a.account_id from account_intel.accounts a
    where a.band in ('A','B') and a.contacts_requested_at is null
      and coalesce(a.is_customer, false) = false and a.disqualified_reason is null
      and a.sf_status is null
      and a.linkedin_url ~ 'linkedin\.com/company/'
      and not exists (select 1 from account_intel.contact_requests cr where cr.account_id = a.account_id)
    order by a.band, a.score desc nulls last limit p_limit for update skip locked)
  update account_intel.accounts a set contacts_requested_at = now()
  from picked p where a.account_id = p.account_id
  returning a.account_id, a.name, a.domain, a.band::text, a.lead_product::text;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_contact_request_no_linkedin(p_request_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'own_brand'
AS $function$
  update account_intel.contact_requests set status = 'no_linkedin', completed_at = now() where request_id = p_request_id;
$function$
;

CREATE OR REPLACE FUNCTION public.intel_contact_requests_claim(p_limit integer DEFAULT 20)
 RETURNS TABLE(request_id uuid, sheet_row integer, company text, domain text, account_id uuid, linkedin_url text, headcount integer, country_of_interest text, open_roles text, status text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'own_brand'
AS $function$
declare ids uuid[];
begin
  select array_agg(cr.request_id) into ids from (
    select cr.request_id from account_intel.contact_requests cr
    where (cr.status = 'pending' and (cr.attempted_at is null or cr.attempted_at < now() - interval '1 hour'))
       or (cr.status = 'error' and cr.attempted_at < now() - interval '1 hour')
    order by cr.requested_at limit p_limit for update skip locked) cr;
  if ids is null then return; end if;

  update account_intel.contact_requests cr set
    attempted_at = now(), status = 'pending',
    account_id = coalesce(cr.account_id,
      (select a.account_id from account_intel.accounts a where cr.domain is not null and a.domain = cr.domain limit 1),
      (select a.account_id from account_intel.accounts a where a.normalised_name = lower(regexp_replace(cr.company, '\s*(ltd|limited|llp|plc|uk|group|holdings|inc|co)\.?$', '', 'i')) limit 1))
  where cr.request_id = any(ids);

  update account_intel.contact_requests cr set
    linkedin_url = a.linkedin_url,
    headcount = a.headcount,
    open_roles = (
      select string_agg(j.title || case when coalesce(j.location,'') <> '' then ' (' || j.location || ')' else '' end, '; ')
      from (select j.title, j.location from account_intel.jobs j where j.account_id = a.account_id and j.closed_at is null
              and coalesce(j.posted_at, j.first_seen_at::date) >= current_date - 45
            order by (cr.country_of_interest is not null and j.country ilike '%' || coalesce(cr.country_of_interest,'') || '%') desc, j.posted_at desc nulls last
            limit 12) j),
    status = case when a.linkedin_url ~ 'linkedin\.com/company/' then 'pending' else 'no_linkedin' end,
    completed_at = case when a.linkedin_url ~ 'linkedin\.com/company/' then null else now() end
  from account_intel.accounts a where a.account_id = cr.account_id and cr.request_id = any(ids);

  update account_intel.contact_requests cr set status = 'no_match', completed_at = now()
  where cr.request_id = any(ids) and cr.account_id is null;

  return query select cr.request_id, cr.sheet_row, cr.company, cr.domain, cr.account_id, cr.linkedin_url, cr.headcount, cr.country_of_interest, cr.open_roles, cr.status
    from account_intel.contact_requests cr where cr.request_id = any(ids);
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_contacts_guard()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'own_brand'
AS $function$
declare claimed int; landed int; released int;
begin
  select count(*) into claimed from account_intel.accounts a where a.contacts_requested_at > now() - interval '2 hours';
  select count(*) into landed from account_intel.contact_requests cr where cr.requested_at > now() - interval '2 hours';
  if claimed >= 10 and landed = 0 then
    -- release the orphaned claims so they re-queue, then report
    with r as (update account_intel.accounts a set contacts_requested_at = null where a.contacts_requested_at > now() - interval '2 hours'
               and not exists (select 1 from account_intel.contact_requests cr where cr.account_id = a.account_id) returning 1)
    select count(*) into released from r;
    return 'D15 contact requests: ' || claimed || ' accounts claimed in 2h but no rows reached the tab (append or read failing, check the header row and the Append node); ' || released || ' claims released';
  end if;
  return null;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_filings_to_parse(p_limit integer DEFAULT 20)
 RETURNS TABLE(account_id uuid, transaction_id text, doc_url text, name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
#variable_conflict use_column
begin
  return query
  with pick as (
    select f.account_id, f.transaction_id, f.doc_url, a.name, 1 as pri, f.filed_on
    from account_intel.filings f join account_intel.accounts a on a.account_id = f.account_id
    where f.filing_type = 'SH01' and f.doc_url is not null and f.amount_parsed_at is null
      and (f.parse_attempted_at is null or f.parse_attempted_at < now() - interval '1 day')
      and f.filed_on >= current_date - 180
    union all
    select null::uuid, e.transaction_id, e.doc_url, e.company_name, 2, e.filed_on
    from account_intel.register_events e
    where e.outcome = 'staged' and e.doc_url is not null and e.amount_parsed_at is null
      and (e.parse_attempted_at is null or e.parse_attempted_at < now() - interval '1 day')
    order by pri, filed_on desc limit p_limit
  ), u1 as (
    update account_intel.filings x set parse_attempted_at = now() from pick p where p.account_id is not null and p.account_id = x.account_id and p.transaction_id = x.transaction_id returning x.transaction_id
  ), u2 as (
    update account_intel.register_events x set parse_attempted_at = now() from pick p where p.account_id is null and p.transaction_id = x.transaction_id returning x.transaction_id
  )
  select p.account_id, p.transaction_id, p.doc_url, p.name from pick p;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_get_setting(p_key text)
 RETURNS text
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
  select value from account_intel.settings where key = p_key;
$function$
;

CREATE OR REPLACE FUNCTION public.intel_health()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
declare
  li_applied int; li_unmatched int; li_disq int; j_applied int; j_unmatched int;
  issues text[] := '{}'; r jsonb;
  li_todo int; li_raw_2h int; li_todo_fresh int;
  scan_todo int; scan_2h int; news_todo int; news_2h int;
  jobs_raw_unapplied int; li_raw_unapplied int;
  a int; b int; c int; d int; last_push timestamptz; last_score timestamptz;
  stale_signals int; rescored boolean := false;
  apify jsonb; apify_used numeric; apify_limit numeric; cr_err int; cr_pending int; guard text; purged int;
begin
  select applied, unmatched, disqualified into li_applied, li_unmatched, li_disq from public.intel_apply_linkedin();
  select applied, unmatched into j_applied, j_unmatched from public.intel_apply_jobs();

  select count(*) into stale_signals from account_intel.accounts x
  where x.disqualified_reason is null
    and (x.scored_at is null
         or exists (select 1 from account_intel.news_signals n where n.account_id = x.account_id and n.observed_at > x.scored_at)
         or exists (select 1 from account_intel.jobs j where j.account_id = x.account_id and j.first_seen_at > x.scored_at)
         or x.li_enriched_at > x.scored_at or x.scanned_at > x.scored_at);
  if li_applied > 0 or j_applied > 0 or stale_signals > 0 then
    perform public.intel_score_accounts(coalesce((select score_version from account_intel.accounts where score_version is not null order by scored_at desc limit 1), 'v1.4'));
    rescored := true;
  end if;

  select count(*) into li_todo from account_intel.accounts where disqualified_reason is null and li_enriched_at is null and li_attempts < 2;
  select count(*) into li_todo_fresh from account_intel.accounts where disqualified_reason is null and li_enriched_at is null;
  select count(*) into li_raw_2h from account_intel.linkedin_raw where received_at > now() - interval '2 hours';
  select count(*) into li_raw_unapplied from account_intel.linkedin_raw where applied_at is null and account_id is not null;
  select count(*) into scan_todo from account_intel.accounts where disqualified_reason is null and scanned_at is null and domain is not null;
  select count(*) into scan_2h from account_intel.page_signals p join account_intel.accounts x on x.account_id = p.account_id where x.scanned_at > now() - interval '2 hours';
  select count(*) into news_todo from account_intel.accounts where disqualified_reason is null and news_attempted_at is null;
  select count(*) into news_2h from account_intel.accounts where news_attempted_at > now() - interval '2 hours';
  select count(*) into jobs_raw_unapplied from account_intel.jobs_raw where applied_at is null;
  select count(*) filter (where band='A'), count(*) filter (where band='B'), count(*) filter (where band='C'), count(*) filter (where band='D'), max(scored_at) into a, b, c, d, last_score from account_intel.accounts;
  select max(last_pushed_at) into last_push from account_intel.sheet_state;
  select count(*) filter (where status = 'error'), count(*) filter (where status = 'pending') into cr_err, cr_pending from account_intel.contact_requests;

  begin apify := (select value::jsonb from account_intel.settings where key = 'apify_usage'); exception when others then apify := null; end;
  apify_used := (apify->>'used_usd')::numeric; apify_limit := (apify->>'limit_usd')::numeric;
  guard := public.intel_contacts_guard();
  purged := public.intel_purge_contacts();

  if li_todo > 50 and li_raw_2h = 0 then issues := issues || ('D2 LinkedIn enrich stalled: ' || li_todo || ' to do, nothing received in 2h'); end if;
  if scan_todo > 50 and scan_2h = 0 then issues := issues || ('D3 careers scan stalled: ' || scan_todo || ' to do, nothing scanned in 2h'); end if;
  if news_todo > 50 and news_2h = 0 then issues := issues || ('D5 news stalled: ' || news_todo || ' to do, nothing attempted in 2h'); end if;
  if jobs_raw_unapplied > 0 then issues := issues || ('D4b jobs: ' || jobs_raw_unapplied || ' raw rows could not be matched to an account'); end if;
  if li_raw_unapplied > 0 then issues := issues || ('D2 LinkedIn: ' || li_raw_unapplied || ' raw rows matched but not applied'); end if;
  if last_push is not null and last_push < now() - interval '8 days' then issues := issues || 'D8 sheet not pushed for over a week'; end if;
  if a + b < 20 then issues := issues || ('Only ' || a || ' A and ' || b || ' B on the sheet'); end if;
  if apify_used is not null and apify_limit is not null and apify_used >= apify_limit * 0.8 then
    issues := issues || ('Apify usage $' || round(apify_used, 2) || ' of $' || apify_limit || ' this cycle (' || round(100 * apify_used / nullif(apify_limit, 0)) || '%). Payment decision for Jamie: raise the limit in Apify Console → Billing → Limits, or let D2/D4b/D15 pause until the cycle resets.');
  end if;
  if cr_err >= 5 then issues := issues || ('D15 contact requests: ' || cr_err || ' rows failing (check Apify limit or actor)'); end if;
  if guard is not null then issues := issues || guard; end if;

  r := jsonb_build_object(
    'checked_at', now(),
    'applied_now', jsonb_build_object('linkedin', li_applied, 'linkedin_disqualified', li_disq, 'jobs', j_applied, 'stale_signals', stale_signals, 'rescored', rescored, 'contacts_purged', purged),
    'bands', jsonb_build_object('A', a, 'B', b, 'C', c, 'D', d, 'last_scored', last_score),
    'queues', jsonb_build_object('linkedin_todo', li_todo, 'linkedin_never_enriched', li_todo_fresh, 'linkedin_received_2h', li_raw_2h, 'scan_todo', scan_todo, 'scan_2h', scan_2h, 'news_todo', news_todo, 'news_2h', news_2h,
                                 'jobs_with_roles', (select count(distinct account_id) from account_intel.jobs where closed_at is null), 'foreign_role_accounts', (select count(distinct account_id) from account_intel.jobs where closed_at is null and country not in ('GB','IE','','OO','XX')),
                                 'contact_requests_pending', cr_pending, 'contact_requests_error', cr_err),
    'apify', apify,
    'sheet', jsonb_build_object('last_push', last_push),
    'issues', to_jsonb(issues),
    'digest_due', extract(hour from now() at time zone 'Europe/London') = 7
  );
  return r;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_mark_customer(p_account_id uuid, p_won_at date, p_products text[], p_notes text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
begin
  update account_intel.accounts set is_customer = true, customer_since = p_won_at, customer_products = p_products,
    disqualified_reason = case when disqualified_reason = 'existing_customer' then null else disqualified_reason end
    where account_id = p_account_id;
  insert into account_intel.customer_wins (account_id, won_at, products, notes, score_at_win, band_at_win, lead_product_at_win, breakdown_at_win, evidence_at_win)
  select account_id, p_won_at, p_products, p_notes, score, band::text, lead_product::text, score_breakdown, evidence_line from account_intel.accounts where account_id = p_account_id
  on conflict (account_id) do update set won_at = excluded.won_at, products = excluded.products, notes = excluded.notes, recorded_at = now();
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_net_new_mark_seen(p_url text, p_outcome text, p_company text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
  insert into account_intel.net_new_seen (url, outcome, company) values (p_url, p_outcome, p_company) on conflict (url) do update set outcome = excluded.outcome, company = excluded.company, seen_at = now();
$function$
;

CREATE OR REPLACE FUNCTION public.intel_net_new_rows()
 RETURNS TABLE(account_id text, "Company" text, "Funded" text, "Amount" text, "AI" text, "Age" text, "Likely unowned" text, "Website" text, "LinkedIn" text, "Source" text, "Found" text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
  select a.account_id::text, a.name,
         to_char(s.event_date, 'DD Mon YY'),
         coalesce(s.amount, ''),
         case when a.is_ai then 'yes' else '' end,
         case when g.incorporated_on is not null then (extract(year from age(current_date, g.incorporated_on))::int * 12 + extract(month from age(current_date, g.incorporated_on))::int) || ' months' else 'unknown' end,
         case when g.incorporated_on is not null and g.incorporated_on > current_date - interval '12 months' then 'yes' when g.incorporated_on is null then '?' else '' end,
         coalesce(a.website, ''),
         coalesce(a.linkedin_url, ''),
         coalesce(s.url, ''),
         to_char(a.net_new_at at time zone 'Europe/London', 'DD Mon HH24:MI')
  from account_intel.accounts a
  join lateral (select * from account_intel.news_signals n where n.account_id = a.account_id and n.kind = 'funding' order by n.event_date desc limit 1) s on true
  left join account_intel.registry g on g.account_id = a.account_id and g.match_confidence >= 0.8
  where a.origin = 'net_new' and coalesce(a.sf_status, '') <> 'owned'
  order by a.net_new_at desc;
$function$
;

CREATE OR REPLACE FUNCTION public.intel_net_new_seen(p_urls text[])
 RETURNS TABLE(url text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
  select s.url from account_intel.net_new_seen s where s.url = any(p_urls) and s.outcome is not null and s.outcome <> 'error';
$function$
;

CREATE OR REPLACE FUNCTION public.intel_net_new_set_sf(p_account_id uuid, p_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
begin
  update account_intel.accounts set sf_status = case lower(coalesce(p_status, '')) when 'free' then 'free' when 'owned' then 'owned' when 'owned by someone else' then 'owned' else null end
  where account_id = p_account_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_new_since(p_hours integer DEFAULT 25)
 RETURNS TABLE(account text, band text, lead_product text, trigger_line text, evidence text)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
  select a.name, a.band::text,
         case a.lead_product when 'eor' then 'EOR' when 'field_services' then 'Field Services' when 'contractors' then 'Contractors' when 'us_peo' then 'US PEO' when 'it_equipment' then 'IT equipment' else '' end,
         coalesce(w.trigger_line, ''), coalesce(a.evidence_line, '')
  from account_intel.sheet_state s
  join account_intel.accounts a on a.account_id = s.account_id
  left join account_intel.why_now w on w.account_id = a.account_id
  where s.first_pushed_at > now() - make_interval(hours => p_hours) and a.band in ('A','B')
  order by a.band, a.score desc;
$function$
;

CREATE OR REPLACE FUNCTION public.intel_purge_contacts()
 RETURNS integer
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'own_brand'
AS $function$
  with d as (delete from account_intel.contacts where fetched_at < now() - interval '90 days' returning 1) select count(*)::int from d;
$function$
;

CREATE OR REPLACE FUNCTION public.intel_record_outcome(p_account_id uuid, p_status text, p_notes text DEFAULT NULL::text, p_contact_name text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
declare s account_intel.outcome_status;
begin
  s := case lower(trim(coalesce(p_status, '')))
         when 'worked' then 'worked'::account_intel.outcome_status
         when 'meeting booked' then 'meeting_booked'::account_intel.outcome_status
         when 'meeting_booked' then 'meeting_booked'::account_intel.outcome_status
         when 'not a fit' then 'not_a_fit'::account_intel.outcome_status
         when 'not_a_fit' then 'not_a_fit'::account_intel.outcome_status
         else null end;
  if s is null then return; end if;
  insert into account_intel.outcomes (account_id, status, notes, contact_name, last_touched, synced_at)
  values (p_account_id, s, nullif(p_notes, ''), nullif(p_contact_name, ''), now(), now())
  on conflict (account_id) do update set status = excluded.status, notes = coalesce(excluded.notes, account_intel.outcomes.notes),
    contact_name = coalesce(excluded.contact_name, account_intel.outcomes.contact_name),
    last_touched = case when account_intel.outcomes.status is distinct from excluded.status or account_intel.outcomes.notes is distinct from excluded.notes then now() else account_intel.outcomes.last_touched end,
    synced_at = now();
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_register_intake(p_event jsonb)
 RETURNS TABLE(outcome text, reason text, account_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
#variable_conflict use_column
declare
  v_num text := p_event->>'company_number';
  v_tx text := p_event->>'transaction_id';
  v_prof jsonb := coalesce(p_event->'profile', '{}'::jsonb);
  v_name text := coalesce(v_prof->>'company_name', p_event->>'company_name');
  v_status text := v_prof->>'company_status';
  v_type text := v_prof->>'type';
  v_inc date := nullif(v_prof->>'date_of_creation','')::date;
  v_sic text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(v_prof->'sic_codes','[]'::jsonb)) x), '{}');
  v_filed date := nullif(p_event->>'date','')::date;
  v_action date := coalesce(nullif(p_event->>'action_date','')::date, nullif(p_event->>'date','')::date);
  v_doc text := nullif(p_event->>'doc','');
  v_out text := 'staged'; v_why text := null; v_acc uuid := null;
  v_existing uuid;
begin
  if v_num is null or v_tx is null then return query select 'rejected'::text, 'no company number or transaction id'::text, null::uuid; return; end if;

  -- already one of ours (book or net-new)? route the filing to that account like D13 would.
  select r.account_id into v_existing from account_intel.registry r where r.company_number = v_num and r.match_confidence >= 0.85 limit 1;
  if v_existing is not null then
    perform public.intel_save_filings(jsonb_build_array(jsonb_build_object(
      'account_id', v_existing, 'company_number', v_num, 'transaction_id', v_tx, 'type', p_event->>'type', 'category', p_event->>'category',
      'description', p_event->>'description', 'date', p_event->>'date', 'action_date', p_event->>'action_date', 'capital', p_event->'capital', 'doc', v_doc)));
    v_out := 'existing'; v_acc := v_existing;
  else
    -- filter: the kind of company that raises a round and hires
    if upper(coalesce(p_event->>'type','')) <> 'SH01' then v_out := 'rejected'; v_why := 'not SH01';
    elsif v_status is distinct from 'active' then v_out := 'rejected'; v_why := 'status ' || coalesce(v_status,'unknown');
    elsif v_type not in ('ltd') then v_out := 'rejected'; v_why := 'type ' || coalesce(v_type,'unknown');
    elsif v_inc is null or v_inc < current_date - interval '10 years' then v_out := 'rejected'; v_why := 'incorporated ' || coalesce(v_inc::text,'unknown');
    elsif array_length(v_sic,1) is null then v_out := 'rejected'; v_why := 'no SIC';
    elsif exists (select 1 from unnest(v_sic) s where left(s,2) in ('01','02','03','05','06','07','08','09','35','36','37','38','39','41','42','43','45','46','47','49','50','51','52','53','55','56','64','65','66','68','77','78','80','81','84','85','86','87','88','90','91','92','93','94','95','96','97','98','99'))
      then v_out := 'rejected'; v_why := 'SIC ' || array_to_string(v_sic, ',');
    elsif coalesce(v_name,'') ~* '\m(holdings?|nominees?|trustees?|pension|propert(y|ies)|estates?|investments?|capital|ventures?|partners|fund|assets?|land|developments?|realty|group)\M'
      then v_out := 'rejected'; v_why := 'name pattern';
    end if;
  end if;

  insert into account_intel.register_events (transaction_id, company_number, company_name, filed_on, action_date, capital, doc_url, profile, filing, outcome, reason, account_id)
  values (v_tx, v_num, v_name, v_filed, v_action, p_event->'capital', v_doc, v_prof, p_event, v_out, v_why, v_acc)
  on conflict (transaction_id) do update set
    doc_url = coalesce(account_intel.register_events.doc_url, excluded.doc_url),
    profile = case when excluded.profile <> '{}'::jsonb then excluded.profile else account_intel.register_events.profile end,
    filing = excluded.filing,
    outcome = case when account_intel.register_events.outcome in ('promoted','too_small') then account_intel.register_events.outcome else excluded.outcome end,
    reason = coalesce(account_intel.register_events.reason, excluded.reason),
    account_id = coalesce(account_intel.register_events.account_id, excluded.account_id),
    updated_at = now();
  return query select v_out, v_why, v_acc;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_save_allotment_amount(p_account_id uuid, p_transaction_id text, p_amount numeric, p_shares bigint, p_note text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
declare v_filed date; v_action date; v_week_total numeric; v_conf text; v_press boolean; v_url text; v_num text; v_acc uuid;
begin
  if p_account_id is null then
    update account_intel.register_events set amount_raised = p_amount, shares_allotted = p_shares, amount_parsed_at = now(), parse_note = left(p_note, 300), updated_at = now()
    where transaction_id = p_transaction_id returning action_date, company_number into v_action, v_num;
    if v_num is null then return 'not found'; end if;
    select coalesce(sum(amount_raised),0) into v_week_total from account_intel.register_events where company_number = v_num and amount_raised is not null and abs(action_date - v_action) <= 7;
    if v_week_total >= 250000 then
      v_acc := account_intel.register_promote(p_transaction_id);
      return 'promoted ' || coalesce(v_acc::text, '?');
    else
      update account_intel.register_events set outcome = 'too_small', updated_at = now() where transaction_id = p_transaction_id;
      return 'too_small';
    end if;
  end if;
  update account_intel.filings set amount_raised = p_amount, shares_allotted = p_shares, amount_parsed_at = now(), parse_note = left(p_note, 300)
  where account_id = p_account_id and transaction_id = p_transaction_id
  returning filed_on, action_date, company_number into v_filed, v_action, v_num;
  if v_filed is null then return 'not found'; end if;
  select coalesce(sum(amount_raised), 0) into v_week_total from account_intel.filings
  where account_id = p_account_id and filing_type = 'SH01' and amount_raised is not null and abs(action_date - v_action) <= 7;
  select exists (select 1 from account_intel.news_signals n where n.account_id = p_account_id and n.kind = 'funding' and n.source = 'news' and abs(n.event_date - v_action) <= 60) into v_press;
  v_conf := case when v_press then 'confirmed'
                 when v_week_total > 50000000 then 'check'
                 when v_week_total >= 250000 then 'likely'
                 when p_amount is null then 'pending' else 'weak' end;
  v_url := 'https://find-and-update.company-information.service.gov.uk/company/' || v_num || '/filing-history/' || p_transaction_id || '/document?format=pdf';
  update account_intel.news_signals set confidence = v_conf,
    amount = case when v_week_total >= 1000 and v_week_total <= 50000000 then '£' || to_char(round(v_week_total / 1000.0), 'FM999,999') || 'k' else null end,
    kind = case when v_conf = 'weak' then 'ignored'::account_intel.news_kind else 'funding'::account_intel.news_kind end
  where account_id = p_account_id and url = v_url;
  return v_conf;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_save_contacts(p_request_id uuid, p_items jsonb, p_error text DEFAULT NULL::text)
 RETURNS TABLE(sheet_row integer, status text, headcount integer, open_roles text, contacts jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'own_brand'
AS $function$
declare v_account uuid; it jsonb; n integer := 0; v_status text;
begin
  select cr.account_id into v_account from account_intel.contact_requests cr where cr.request_id = p_request_id;
  if p_error is not null then
    update account_intel.contact_requests set status = 'error', error = left(p_error, 500), completed_at = now() where request_id = p_request_id;
  else
    for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
      if coalesce(it->>'linkedin_url','') = '' then continue; end if;
      insert into account_intel.contacts (request_id, account_id, full_name, title, headline, linkedin_url, location, seniority)
      values (p_request_id, v_account, it->>'full_name', it->>'title', it->>'headline', it->>'linkedin_url', it->>'location', it->>'rank')
      on conflict (request_id, linkedin_url) do update set title = excluded.title, headline = excluded.headline, seniority = excluded.seniority, fetched_at = now();
      n := n + 1;
    end loop;
    v_status := case when n > 0 then 'found' else 'none_found' end;
    update account_intel.contact_requests set status = v_status, error = null, completed_at = now() where request_id = p_request_id;
  end if;
  return query
    select cr.sheet_row, cr.status, cr.headcount, cr.open_roles,
      coalesce((select jsonb_agg(jsonb_build_object('name', c.full_name, 'title', c.title, 'url', c.linkedin_url) order by c.seniority::int, c.fetched_at)
                from account_intel.contacts c where c.request_id = cr.request_id), '[]'::jsonb)
    from account_intel.contact_requests cr where cr.request_id = p_request_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_save_filings(p_rows jsonb)
 RETURNS TABLE(saved integer, allotments integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
declare n_saved int := 0; n_allot int := 0; r jsonb; acc uuid; d date; ad date; v_url text;
begin
  for r in select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    acc := (r->>'account_id')::uuid;
    d := nullif(r->>'date', '')::date;
    ad := coalesce(nullif(r->>'action_date', '')::date, d);
    insert into account_intel.filings (account_id, company_number, transaction_id, filing_type, category, description, filed_on, action_date, capital, raw, doc_url)
    values (acc, r->>'company_number', r->>'transaction_id', r->>'type', r->>'category', r->>'description', d, ad, r->'capital', r, nullif(r->>'doc', ''))
    on conflict (account_id, transaction_id) do update set raw = excluded.raw, doc_url = coalesce(account_intel.filings.doc_url, excluded.doc_url);
    if found then n_saved := n_saved + 1; end if;
    if upper(coalesce(r->>'type', '')) = 'SH01' and d >= current_date - 180 then
      v_url := 'https://find-and-update.company-information.service.gov.uk/company/' || (r->>'company_number') || '/filing-history/' || (r->>'transaction_id') || '/document?format=pdf';
      insert into account_intel.news_signals (account_id, kind, event_date, url, title, snippet, amount, source, confidence)
      values (acc, 'funding', ad, v_url, 'SH01 share allotment filed ' || to_char(d, 'DD Mon YYYY') || ' (register, may be unannounced)',
              left(coalesce(r->>'description', 'Statement of capital following an allotment of shares') || coalesce(' · capital ' || (r->'capital'->0->>'figure') || ' ' || (r->'capital'->0->>'currency'), ''), 300),
              null, 'companies_house', 'pending')
      on conflict (account_id, url) do nothing;
      if found then n_allot := n_allot + 1; end if;
    end if;
  end loop;
  return query select n_saved, n_allot;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_save_jobs_raw(p_source text, p_batch_id text, p_items jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
declare n int;
begin
  insert into account_intel.jobs_raw (source, batch_id, item) select p_source, p_batch_id, x from jsonb_array_elements(p_items) x;
  get diagnostics n = row_count; return n;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_save_linkedin_raw(p_batch_id text, p_items jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
declare n int;
begin
  insert into account_intel.linkedin_raw (batch_id, item)
  select p_batch_id, x from jsonb_array_elements(p_items) x;
  get diagnostics n = row_count;
  return n;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_save_news(p_account_id uuid, p_items jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
declare x jsonb; n int := 0; k text; d date;
begin
  for x in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    k := x->>'kind';
    if k is null or k = 'none' or k not in ('funding','expansion','new_office','project_win','people_hire','layoffs','acquisition') then continue; end if;
    begin d := (x->>'event_date')::date; exception when others then d := null; end;
    if d is null or (x->>'url') is null then continue; end if;
    insert into account_intel.news_signals (account_id, kind, amount, event_date, url, snippet, source, title, observed_at)
    values (p_account_id, k::account_intel.news_kind, x->>'amount', d, x->>'url', left(x->>'snippet', 400), coalesce(x->>'source','news'), left(x->>'title', 200), now())
    on conflict (account_id, url) do update set kind = excluded.kind, event_date = excluded.event_date, amount = excluded.amount, observed_at = now();
    n := n + 1;
  end loop;
  update account_intel.accounts set news_checked_at = now() where account_id = p_account_id;
  return n;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_save_page_scan(p_account_id uuid, p_http_status integer, p_title text, p_ats_provider text, p_ats_token text, p_careers_url text, p_ats_links text[], p_careers_links text[], p_competitor_mentions text[], p_pages_fetched text[])
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
begin
  insert into account_intel.page_signals (account_id, competitor_mentions, pages_fetched, ats_links, careers_links, http_status, title, observed_at)
  values (p_account_id, p_competitor_mentions, p_pages_fetched, p_ats_links, p_careers_links, p_http_status, p_title, now())
  on conflict (account_id) do update set competitor_mentions = excluded.competitor_mentions, pages_fetched = excluded.pages_fetched,
    ats_links = excluded.ats_links, careers_links = excluded.careers_links, http_status = excluded.http_status, title = excluded.title, observed_at = now();
  update account_intel.accounts set ats_provider = p_ats_provider, ats_token = p_ats_token, careers_url = coalesce(p_careers_url, careers_url), scanned_at = now()
  where account_id = p_account_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_save_registry(p_account_id uuid, p_registry text, p_company_number text, p_registered_name text, p_status text, p_incorporated_on date, p_sic_codes text[], p_accounts_type text, p_foreign_psc boolean, p_officer_countries text[], p_match_confidence numeric, p_matched_by text, p_raw jsonb DEFAULT NULL::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
declare dead boolean := p_status in ('dissolved','liquidation','administration','receivership','converted-closed','closed');
begin
  insert into account_intel.registry (account_id, registry, company_number, registered_name, status, incorporated_on,
    sic_codes, accounts_type, foreign_psc, officer_countries, match_confidence, matched_by, raw, observed_at)
  values (p_account_id, p_registry, p_company_number, p_registered_name, p_status, p_incorporated_on,
    p_sic_codes, p_accounts_type, p_foreign_psc, p_officer_countries, p_match_confidence, p_matched_by, p_raw, now())
  on conflict (account_id) do update set
    registry = excluded.registry, company_number = excluded.company_number, registered_name = excluded.registered_name,
    status = excluded.status, incorporated_on = excluded.incorporated_on, sic_codes = excluded.sic_codes,
    accounts_type = excluded.accounts_type, foreign_psc = excluded.foreign_psc, officer_countries = excluded.officer_countries,
    match_confidence = excluded.match_confidence, matched_by = excluded.matched_by, raw = excluded.raw, observed_at = now();

  update account_intel.accounts a set
    -- dead company disqualifies only on an exact (1.0) match; weaker matches to a dead company go to review
    disqualified_reason = case
      when p_company_number is not null and dead and p_match_confidence >= 1.0 then 'registry_' || p_status
      when a.disqualified_reason like 'registry_%' then null
      else a.disqualified_reason end,
    needs_review = case
      when p_company_number is not null and (p_match_confidence < 0.8 or (dead and p_match_confidence < 1.0)) then true
      else a.needs_review end,
    hq_country = coalesce(a.hq_country, case when p_company_number is not null and p_match_confidence >= 0.8
                                              then case when p_registry = 'CRO' then 'IE' else 'GB' end end)
  where a.account_id = p_account_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_save_why_now(p_account_id uuid, p_trigger_line text, p_discovery_q text, p_persona text, p_proof text, p_evidence_line text, p_context text, p_model text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
declare v account_intel.persona; sv text; ev text; bd text;
begin
  v := case lower(coalesce(p_persona, '')) when 'founder' then 'founder'::account_intel.persona when 'hr' then 'hr'::account_intel.persona when 'finance' then 'finance'::account_intel.persona when 'ops' then 'ops'::account_intel.persona else null end;
  select score_version, evidence_line, band::text into sv, ev, bd from account_intel.accounts where account_id = p_account_id;
  insert into account_intel.why_now (account_id, trigger_line, discovery_q, persona, proof, evidence_line, context, model, score_version, generated_at, scorer_evidence, band_at_generation)
  values (p_account_id, nullif(trim(p_trigger_line), ''), nullif(trim(p_discovery_q), ''), v, nullif(trim(p_proof), ''), nullif(trim(p_evidence_line), ''), nullif(trim(p_context), ''), p_model, sv, now(), ev, bd)
  on conflict (account_id) do update set trigger_line = excluded.trigger_line, discovery_q = excluded.discovery_q, persona = excluded.persona, proof = excluded.proof,
    evidence_line = excluded.evidence_line, context = excluded.context, model = excluded.model, score_version = excluded.score_version, generated_at = now(),
    scorer_evidence = excluded.scorer_evidence, band_at_generation = excluded.band_at_generation;
  -- no usable trigger: never an A
  update account_intel.accounts set band = 'B', needs_review = true where account_id = p_account_id and band = 'A' and nullif(trim(p_trigger_line), '') is null;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_score_accounts(p_version text DEFAULT 'v1'::text)
 RETURNS TABLE(scored integer, a_count integer, b_count integer, c_count integer, d_count integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
 SET statement_timeout TO '240s'
AS $function$
declare r record; n int := 0;
  home text; w numeric; j record;
  fr numeric; fr_countries text[]; contract_w numeric; remote_w numeric; us_w numeric; visa boolean; onsite boolean; it_open boolean; cor_w numeric; cheap_w numeric;
  emp_abroad text[]; offices_abroad text[]; n_emp_abroad int;
  funding boolean; expansion boolean; people boolean; projwin boolean; layoffs boolean;
  eor numeric; fs numeric; ic numeric; peo numeric; dit numeric; neg numeric;
  fit jsonb; best text; second text; bestv numeric; secondv numeric; band_v account_intel.band; ev text; brk jsonb; starter text;
  fs_sector boolean; ic_sector boolean; dead_site boolean; comp boolean; foreign_hq boolean; is_agency boolean; n_jobs int; funding_days int; funding_pts numeric; is_ai boolean; register_only boolean; n_foreign_staff int; distributed boolean; new_uk boolean;
begin
  for r in
    select a.*, p.competitor_mentions, p.title as page_title, g.incorporated_on, g.foreign_psc
    from account_intel.accounts a
    left join account_intel.page_signals p on p.account_id = a.account_id
    left join account_intel.registry g on g.account_id = a.account_id and g.match_confidence >= 0.8
    where a.disqualified_reason is null
  loop
    home := case when r.hq_country = 'IE' or r.domain ~ '\.ie$' then 'IE' else 'GB' end;
    foreign_hq := r.hq_country is not null and r.hq_country not in ('GB','IE');
    fr := 0; fr_countries := '{}'; contract_w := 0; remote_w := 0; us_w := 0; visa := false; onsite := false; it_open := false; cor_w := 0; cheap_w := 0;
    select count(*) into n_jobs from account_intel.jobs where account_id = r.account_id and closed_at is null and coalesce(posted_at, first_seen_at::date) >= current_date - 90;
    is_agency := coalesce(r.li_industry, '') ~* 'staffing|recruiting|employment agenc|executive search|outsourcing' or r.name ~* '\m(recruit\w*|staffing|talent|search|resourcing|personnel|headhunt\w*)\M'
                 or (r.headcount is not null and n_jobs > greatest(10, r.headcount)) or (r.headcount is null and n_jobs >= 10);
    for j in select * from account_intel.jobs where account_id = r.account_id and closed_at is null and coalesce(posted_at, first_seen_at::date) >= current_date - 90 loop
      w := case when coalesce(j.posted_at, j.first_seen_at::date) >= current_date - 45 then 1 else 0.5 end;
      if j.country is not null and j.country <> '' and j.country not in ('GB','IE','OO','XX') then
        fr := fr + w; if not (j.country = any(fr_countries)) then fr_countries := fr_countries || j.country; end if;
        if j.country = 'US' then us_w := us_w + w; end if;
        if j.country in ('BR','MX','AR','CO','CL','PE','PL','RO','BG','HU','CZ','SK','UA','RS','HR','LT','LV','EE','IN','PK','BD','LK','PH','VN','ID') then cheap_w := cheap_w + w; end if;
      end if;
      if j.contract_language then contract_w := contract_w + w; if j.country in ('GB','FR','DE') then cor_w := cor_w + w; end if; end if;
      if j.remote_anywhere then remote_w := remote_w + w; end if;
      if j.visa_language then visa := true; end if;
      if j.onsite_language then onsite := true; end if;
      if j.it_role then it_open := true; end if;
    end loop;

    select array_agg(c.iso2) into emp_abroad from jsonb_array_elements(coalesce(r.li_employee_countries, '[]'::jsonb)) e
      join account_intel.country_names c on c.name = e->>'country' where c.iso2 not in ('GB','IE') and (e->>'count')::int >= 1;
    n_emp_abroad := coalesce(array_length(emp_abroad, 1), 0);
    select coalesce(sum((e->>'count')::int), 0) into n_foreign_staff from jsonb_array_elements(coalesce(r.li_employee_countries, '[]'::jsonb)) e join account_intel.country_names c on c.name = e->>'country' where c.iso2 not in ('GB','IE');
    -- v1.6: a small team spread across many countries is the contractor-conversion profile; the structure is the trigger
    distributed := not is_agency and coalesce(r.headcount, 0) between 3 and 100 and n_emp_abroad >= 4 and (n_foreign_staff >= 0.4 * r.headcount or n_emp_abroad >= 5);
    new_uk := foreign_hq and r.incorporated_on >= current_date - interval '18 months';
    offices_abroad := (select array_agg(x) from unnest(coalesce(r.li_office_countries, '{}'::text[])) x where x not in ('GB','IE'));

    select min(current_date - s.event_date) into funding_days from account_intel.news_signals s where s.account_id = r.account_id and s.kind = 'funding' and s.event_date >= current_date - 270
      and (s.source is distinct from 'companies_house' or s.confidence in ('likely', 'confirmed'));
    funding := funding_days is not null;
    register_only := funding and not exists (select 1 from account_intel.news_signals s where s.account_id = r.account_id and s.kind = 'funding' and s.event_date >= current_date - 270 and s.source is distinct from 'companies_house');
    funding_pts := case when funding_days is null then 0 when funding_days <= 90 then 55 when funding_days <= 180 then 40 else 25 end;
    is_ai := coalesce(r.is_ai, false) or coalesce(r.li_industry, '') ~* 'artificial intelligence' or r.name ~* '\mAI\M' or array_to_string(coalesce(r.li_specialities, '{}'::text[]), ' ') ~* 'artificial intelligence|machine learning|\mAI\M|\mLLMs?\M|generative';
    expansion := exists (select 1 from account_intel.news_signals s where s.account_id = r.account_id and s.kind in ('expansion','new_office') and s.event_date >= current_date - 180);
    people := exists (select 1 from account_intel.news_signals s where s.account_id = r.account_id and s.kind = 'people_hire' and s.event_date >= current_date - 180);
    projwin := exists (select 1 from account_intel.news_signals s where s.account_id = r.account_id and s.kind = 'project_win' and s.event_date >= current_date - 180);
    layoffs := exists (select 1 from account_intel.news_signals s where s.account_id = r.account_id and s.kind = 'layoffs' and s.event_date >= current_date - 180);

    fs_sector := coalesce(r.li_industry, '') ~* 'oil|gas|mining|construction|civil engineering|utilities|telecommunications|renewable|maritime|shipbuilding|aviation|aerospace|airlines|freight|logistics|transportation|industrial machinery|electric power|defense';
    ic_sector := coalesce(r.li_industry, '') ~* 'staffing|recruiting|advertising|marketing|design|it services|consulting|software development|technology, information|internet|e-?commerce|retail apparel|online';
    comp := exists (select 1 from unnest(coalesce(r.competitor_mentions, '{}'::text[])) c where c <> 'own_brand');
    dead_site := coalesce(r.page_title, '') ~* 'suspended|parked|for sale|casino|coming soon|under construction|not found|default web';

    eor := case when is_agency then 0 else least(40, 40 * fr) + least(15, 5 * greatest(0, coalesce(array_length(fr_countries, 1), 0) - 1)) end
         + case when not is_agency and coalesce(array_length(fr_countries, 1), 0) = 1 and not coalesce(r.foreign_psc, false) and coalesce(array_length(offices_abroad, 1), 0) = 0 and n_emp_abroad = 0 then 15 else 0 end
         + case when n_emp_abroad > 0 and (coalesce(r.headcount, 999) <= 100 or not (emp_abroad && coalesce(offices_abroad, '{}'))) then least(35, 20 + 5 * (n_emp_abroad - 1)) else 0 end + case when distributed then 30 else 0 end + case when new_uk then 10 else 0 end
         + funding_pts + case when expansion then 15 else 0 end + case when people then 10 else 0 end
         + case when is_ai and not is_agency then 15 else 0 end
         + case when remote_w > 0 and not is_agency then 10 else 0 end
         + case when r.incorporated_on >= current_date - interval '5 years' or r.li_founded >= extract(year from current_date)::int - 5 then 5 else 0 end
         + case when cor_w > 0 and not is_agency then 10 else 0 end + case when visa and not is_agency then 15 else 0 end;
    fs := case when fs_sector and not is_agency then 30 else 0 end + case when projwin then 30 else 0 end + case when fs_sector and not is_agency and fr > 0 then 20 else 0 end + case when onsite then 15 else 0 end
         + case when fs_sector and n_emp_abroad > 0 then 10 else 0 end;
    ic := least(40, 40 * contract_w) + case when ic_sector then 15 else 0 end + case when cheap_w > 0 then 15 else 0 end + round(funding_pts * 0.4) + case when is_ai then 10 else 0 end
         + case when distributed then 25 else 0 end + case when is_agency and fr > 0 then least(25, 10 + 5 * coalesce(array_length(fr_countries, 1), 0)) else 0 end;
    peo := case when is_agency then 0 else least(45, 45 * us_w) end + case when 'US' = any(coalesce(offices_abroad, '{}')) and 'US' = any(coalesce(emp_abroad, '{}')) then 30 when 'US' = any(coalesce(offices_abroad, '{}')) then 10 else 0 end + case when 'US' = any(coalesce(emp_abroad, '{}')) and not ('US' = any(coalesce(offices_abroad, '{}'))) then 20 else 0 end + round(funding_pts * 0.4);
    dit := case when remote_w > 0 then 30 else 0 end + case when fr > 0 then 20 else 0 end + case when not it_open then 15 else 0 end + case when r.headcount between 20 and 200 then 10 else 0 end;
    if (fr = 0 and remote_w = 0) or is_agency then dit := 0; end if;
    neg := case when comp then -50 else 0 end + case when layoffs then -30 else 0 end + case when dead_site then -40 else 0 end;

    fit := jsonb_build_object('eor', round(eor * 1.0 + neg, 1), 'field_services', round(fs * 0.9 + neg, 1), 'contractors', round(ic * 0.85 + neg, 1), 'us_peo', round(peo * 0.75 + neg, 1), 'it_equipment', round(dit * 0.6 + neg, 1));
    select t.key, t.value::numeric into best, bestv from jsonb_each_text(fit) t order by t.value::numeric desc, case t.key when 'eor' then 0 when 'contractors' then 1 when 'us_peo' then 2 when 'field_services' then 3 else 4 end limit 1;
    select t.key, t.value::numeric into second, secondv from jsonb_each_text(fit) t where t.key <> best order by t.value::numeric desc limit 1;
    if coalesce(r.headcount, 999) < 10 and fr = 0 and coalesce(funding_days, 999) > 90 then bestv := least(bestv, 69); end if;
    if register_only and fr = 0 and n_jobs = 0 then bestv := least(bestv, 69); end if;
    -- v1.6b: a distributed team with no live trigger is a good call, not an obvious one: B at most
    if distributed and fr = 0 and not funding and not expansion and not projwin and not visa then bestv := least(bestv, 69); end if;
    if coalesce(r.li_industry, '') ~* 'hospitality|restaurant|food and beverage services|retail' and best in ('eor','it_equipment') then bestv := least(bestv, 69); end if;
    if exists (select 1 from account_intel.why_now w where w.account_id = r.account_id and w.trigger_line is null and w.generated_at > now() - interval '7 days') and not distributed then bestv := least(bestv, 69); end if;
    bestv := greatest(bestv, 0);
    band_v := case when bestv >= 70 then 'A' when bestv >= 45 then 'B' when bestv >= 20 then 'C' else 'D' end;
    starter := case when visa then 'immigration' when projwin then 'project_win' when funding then 'funding' when expansion then 'expansion' when distributed then 'distributed' else null end;

    ev := concat_ws(' · ',
      case when is_agency then 'agency' end,
      case when funding_days is not null and funding_days <= 90 then 'FUNDED ' || funding_days || 'd ago' || case when register_only then ' (register, unannounced)' else '' end end,
      case when is_ai then 'AI' end,
      case when r.origin = 'net_new' then 'net new' end,
      case when fr > 0 then (select count(*) || case when is_agency then ' advert' else ' foreign role' end || case when count(*) > 1 then 's' else '' end || ' (' || string_agg(distinct j2.country, ', ') || ')' from account_intel.jobs j2 where j2.account_id = r.account_id and j2.closed_at is null and j2.country is not null and j2.country not in ('GB','IE','','OO','XX') and coalesce(j2.posted_at, j2.first_seen_at::date) >= current_date - 90) end,
      case when contract_w > 0 then 'contract roles open' end,
      case when us_w > 0 then 'US role open' end,
      case when remote_w > 0 then 'remote roles' end,
      case when distributed then 'DISTRIBUTED TEAM (' || n_emp_abroad || ' countries, ' || r.headcount || ' staff)' end,
      case when new_uk then 'new UK entity' end,
      case when n_emp_abroad > 0 then 'staff in ' || array_to_string(emp_abroad, ', ') end,
      case when coalesce(array_length(offices_abroad, 1), 0) > 0 then 'offices in ' || array_to_string(offices_abroad, ', ') end,
      case when foreign_hq then 'HQ ' || r.hq_country end,
      (select string_agg(s.kind::text || case when s.source = 'companies_house' then ' (register)' else '' end || ' ' || to_char(s.event_date, 'Mon YY'), ', ') from account_intel.news_signals s where s.account_id = r.account_id and s.event_date >= current_date - 270 and s.kind <> 'ignored' and s.confidence <> 'pending'),
      case when r.headcount is not null then r.headcount || ' staff' end,
      nullif(r.li_industry, ''),
      case when comp then 'competitor on site' end,
      case when dead_site then 'site looks dead' end);

    brk := jsonb_build_object('foreign_roles_w', fr, 'foreign_countries', fr_countries, 'contract_w', contract_w, 'remote_w', remote_w, 'us_w', us_w, 'cheap_geo_w', cheap_w, 'visa', visa, 'onsite', onsite, 'it_open', it_open,
      'emp_abroad', emp_abroad, 'offices_abroad', offices_abroad, 'foreign_hq', foreign_hq, 'funding', funding, 'expansion', expansion, 'people_hire', people, 'project_win', projwin, 'layoffs', layoffs,
      'fs_sector', fs_sector, 'ic_sector', ic_sector, 'is_agency', is_agency, 'n_jobs', n_jobs, 'is_ai', is_ai, 'funding_days', funding_days, 'funding_pts', funding_pts, 'register_only', register_only, 'distributed', distributed, 'new_uk', new_uk, 'foreign_staff', n_foreign_staff, 'competitor', comp, 'dead_site', dead_site, 'raw', jsonb_build_object('eor', eor, 'fs', fs, 'ic', ic, 'peo', peo, 'it', dit, 'neg', neg));

    update account_intel.accounts set score = bestv, band = band_v, lead_product = best::account_intel.product, cross_sell = case when secondv > 0 then second::account_intel.product else null end,
      convo_starter = starter, product_fit = fit, score_breakdown = brk, score_version = p_version, scored_at = now(), evidence_line = nullif(ev, '')
    where account_id = r.account_id;
    n := n + 1;
  end loop;
  update account_intel.accounts set score = 0, band = 'D', lead_product = null, cross_sell = null, product_fit = null, score_version = p_version, scored_at = now(),
    evidence_line = 'disqualified: ' || disqualified_reason where disqualified_reason is not null;
  return query select n,
    (select count(*)::int from account_intel.accounts where band = 'A'), (select count(*)::int from account_intel.accounts where band = 'B'),
    (select count(*)::int from account_intel.accounts where band = 'C'), (select count(*)::int from account_intel.accounts where band = 'D');
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_score_one(p_account_id uuid, p_version text DEFAULT 'v1.6'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
 SET statement_timeout TO '240s'
AS $function$
declare nm text; b text; s numeric;
begin
  perform public.intel_score_accounts(p_version, p_account_id);
  select name, band, score into nm, b, s from account_intel.accounts where account_id = p_account_id;
  return jsonb_build_object('name', nm, 'band', b, 'score', s);
exception when undefined_function then
  -- scorer has no per-account signature: fall back to the full run
  perform public.intel_score_accounts(p_version);
  select name, band, score into nm, b, s from account_intel.accounts where account_id = p_account_id;
  return jsonb_build_object('name', nm, 'band', b, 'score', s, 'fallback', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_set_setting(p_key text, p_value text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
  insert into account_intel.settings (key, value) values (p_key, p_value) on conflict (key) do update set value = excluded.value, updated_at = now();
$function$
;

CREATE OR REPLACE FUNCTION public.intel_sheet_removals()
 RETURNS TABLE(account_id text, reason text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
#variable_conflict use_column
begin
  return query
  with cand as (
    select ss.account_id,
           case when a.is_customer then 'customer' when a.sf_status is not null then a.sf_status when a.disqualified_reason is not null then 'disqualified: ' || a.disqualified_reason end as reason
    from account_intel.sheet_state ss join account_intel.accounts a on a.account_id = ss.account_id
    where ss.removed_at is null and (a.is_customer or a.sf_status is not null or a.disqualified_reason is not null)
  ), upd as (
    update account_intel.sheet_state s set removed_at = now(), remove_reason = c.reason from cand c where c.account_id = s.account_id
    returning s.account_id, s.remove_reason
  )
  select account_id::text, remove_reason from upd;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_sheet_rows()
 RETURNS TABLE(account_id text, "Account" text, "Band" text, "New" text, "Lead product" text, "Who to call" text, "Trigger line" text, "Discovery question" text, "Evidence" text, "LinkedIn" text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
 SET statement_timeout TO '120s'
AS $function$
#variable_conflict use_column
begin
  return query
  with pick as (
    select a.account_id, a.name, a.band, a.lead_product, a.headcount, a.evidence_line, a.linkedin_url, a.is_customer, a.origin,
           ss.first_pushed_at, o.status,
           exists (select 1 from account_intel.jobs j where j.account_id = a.account_id and j.people_role and j.closed_at is null) as people_open,
           (select max(n.event_date) from account_intel.news_signals n where n.account_id = a.account_id and n.kind::text = 'funding') as last_raise
    from account_intel.accounts a
    left join account_intel.sheet_state ss on ss.account_id = a.account_id
    left join account_intel.outcomes o on o.account_id = a.account_id
    left join account_intel.why_now w0 on w0.account_id = a.account_id
    where coalesce(a.is_customer, false) = false and a.sf_status is null and a.disqualified_reason is null
      and (ss.removed_at is null)
      and ((a.band in ('A','B') and o.status is null and w0.account_id is not null and w0.trigger_line is not null)
           or ss.account_id is not null)
  ), upd as (
    insert into account_intel.sheet_state (account_id, first_pushed_at, last_pushed_at, band_at_push)
    select p.account_id, now(), now(), p.band from pick p
    on conflict (account_id) do update set last_pushed_at = now(), band_at_push = excluded.band_at_push
    returning sheet_state.account_id
  )
  select p.account_id::text, p.name,
         p.band::text,
         case when p.origin = 'net_new' then 'NET NEW' || case when p.last_raise is not null then ' · raised ' || (current_date - p.last_raise) || 'd ago' else '' end
              when p.first_pushed_at is null or p.first_pushed_at > now() - interval '7 days' then 'yes'
              else '' end,
         case p.lead_product when 'eor' then 'EOR' when 'field_services' then 'Field Services' when 'contractors' then 'Contractors' when 'us_peo' then 'US PEO' when 'it_equipment' then 'IT equipment' else '' end,
         case lower(coalesce(w.persona::text, ''))
            when 'hr' then 'HR / People' when 'people' then 'HR / People' when 'finance' then 'Finance' when 'ops' then 'Ops' when 'founder' then 'Founder'
            else case when p.lead_product = 'contractors' then 'Finance' when p.lead_product in ('field_services','it_equipment') then 'Ops' when p.people_open then 'HR / People' when coalesce(p.headcount, 0) < 30 then 'Founder' else 'HR / People' end end,
         coalesce(w.trigger_line, ''),
         coalesce(w.discovery_q, ''),
         case when p.origin = 'net_new' then 'NET NEW, check the CRM first · ' || coalesce(p.evidence_line, '') else coalesce(p.evidence_line, '') end,
         coalesce(p.linkedin_url, '')
  from pick p
  left join account_intel.why_now w on w.account_id = p.account_id
  order by p.band, p.first_pushed_at nulls first, p.name;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_upsert_accounts(rows jsonb)
 RETURNS TABLE(inserted integer, updated integer, skipped integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'ops', 'public'
AS $function$
declare
  r jsonb; v_name text; v_web text; v_dom text; v_li text; v_kind text;
  n_ins int := 0; n_upd int := 0; n_skip int := 0; existing uuid;
begin
  for r in select * from jsonb_array_elements(rows) loop
    v_name := trim(r->>'name');
    if v_name is null or v_name = '' then n_skip := n_skip + 1; continue; end if;
    v_web := nullif(trim(r->>'website'), '');
    -- a website value with no dot is not a URL (two rows have a company name in that column)
    if v_web is not null and v_web !~ '\.' then v_web := null; end if;
    v_dom := account_intel.canonical_domain(v_web);
    v_li := nullif(trim(r->>'linkedin_url'), '');
    if v_li is not null then
      v_li := regexp_replace(v_li, '^(https?://)?(www\.)?', 'https://www.');
      v_li := regexp_replace(v_li, '/+$', '');
    end if;
    v_kind := case when v_li ~ '/school/' then 'school'
                   when v_li ~ '/showcase/' then 'showcase'
                   when v_li ~ '/company/' then 'company' end;

    select account_id into existing from account_intel.accounts
     where (v_dom is not null and domain = v_dom)
        or (v_dom is null and normalised_name = ops.normalise_company_name(v_name))
     limit 1;

    if existing is null then
      insert into account_intel.accounts (name, domain, linkedin_url, linkedin_kind, website)
      values (v_name, v_dom, v_li, v_kind, v_web);
      n_ins := n_ins + 1;
    else
      update account_intel.accounts set
        linkedin_url = coalesce(linkedin_url, v_li),
        linkedin_kind = coalesce(linkedin_kind, v_kind),
        website = coalesce(website, v_web)
      where account_id = existing;
      n_upd := n_upd + 1;
    end if;
  end loop;
  return query select n_ins, n_upd, n_skip;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_upsert_contact_requests(p_rows jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'own_brand'
AS $function$
declare n integer := 0; r jsonb; v_domain text;
begin
  for r in select * from jsonb_array_elements(p_rows) loop
    if coalesce(trim(r->>'company'),'') = '' then continue; end if;
    v_domain := nullif(lower(regexp_replace(trim(coalesce(r->>'domain','')), '^(https?://)?(www\.)?|/.*$', '', 'g')), '');
    insert into account_intel.contact_requests (sheet_row, company, domain, page_visited, country_of_interest)
    values ((r->>'sheet_row')::int, trim(r->>'company'), v_domain, nullif(trim(coalesce(r->>'page','')),''), nullif(trim(coalesce(r->>'country','')),''))
    on conflict (sheet_row, company) do nothing;
    if found then n := n + 1; end if;
  end loop;
  return n;
end $function$
;

CREATE OR REPLACE FUNCTION public.intel_watchdog_log(p_alert text, p_cause text, p_action text, p_left text DEFAULT NULL::text, p_session_url text DEFAULT NULL::text)
 RETURNS bigint
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'own_brand', 'public'
AS $function$
  insert into account_intel.watchdog_log (alert, cause, action, left_to_do, session_url) values (p_alert, p_cause, p_action, p_left, p_session_url) returning id;
$function$
;

CREATE OR REPLACE FUNCTION public.enrich_agency(p_agency_id uuid, p_company_number text, p_ch_name text DEFAULT NULL::text, p_incorporated_on date DEFAULT NULL::date, p_sic_codes text[] DEFAULT NULL::text[], p_region text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public'
AS $function$
declare v_clash uuid;
begin
  select id into v_clash from ops.agencies
   where company_number = p_company_number and id <> p_agency_id;
  if v_clash is not null then
    update ops.agencies
       set notes = concat_ws(E'\n', notes, 'CH number ' || p_company_number || ' already on agency ' || v_clash),
           updated_at = now()
     where id = p_agency_id;
    return jsonb_build_object('agency_id', p_agency_id, 'enriched', false, 'clash_with', v_clash);
  end if;

  update ops.agencies
     set company_number  = coalesce(p_company_number, company_number),
         ch_name         = coalesce(p_ch_name, ch_name),
         incorporated_on = coalesce(p_incorporated_on, incorporated_on),
         sic_codes       = coalesce(p_sic_codes, sic_codes),
         region          = coalesce(region, p_region),
         updated_at      = now()
   where id = p_agency_id;
  return jsonb_build_object('agency_id', p_agency_id, 'enriched', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.enrich_agency(p_agency_id uuid, p_company_number text, p_ch_name text DEFAULT NULL::text, p_incorporated_on date DEFAULT NULL::date, p_sic_codes text[] DEFAULT NULL::text[], p_region text DEFAULT NULL::text, p_owner_name text DEFAULT NULL::text, p_owner_role text DEFAULT NULL::text, p_active_directors integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public'
AS $function$
declare v_clash uuid;
begin
  select id into v_clash from ops.agencies
   where company_number = p_company_number and id <> p_agency_id;
  if v_clash is not null then
    update ops.agencies
       set notes = concat_ws(E'\n', notes, 'CH number ' || p_company_number || ' already on agency ' || v_clash),
           updated_at = now()
     where id = p_agency_id;
    return jsonb_build_object('agency_id', p_agency_id, 'enriched', false, 'clash_with', v_clash);
  end if;

  update ops.agencies
     set company_number   = coalesce(p_company_number, company_number),
         ch_name          = coalesce(p_ch_name, ch_name),
         incorporated_on  = coalesce(p_incorporated_on, incorporated_on),
         sic_codes        = coalesce(p_sic_codes, sic_codes),
         region           = coalesce(region, p_region),
         owner_name       = coalesce(p_owner_name, owner_name),
         owner_role       = coalesce(p_owner_role, owner_role),
         active_directors = coalesce(p_active_directors, active_directors),
         updated_at       = now()
   where id = p_agency_id;
  return jsonb_build_object('agency_id', p_agency_id, 'enriched', true);
end $function$
;

CREATE OR REPLACE FUNCTION public.ingest_signal(p_name text, p_region text DEFAULT NULL::text, p_source_url text DEFAULT NULL::text, p_detail text DEFAULT NULL::text, p_seen_at timestamp with time zone DEFAULT now(), p_type text DEFAULT 'job_advert'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public'
AS $function$
declare
  v_id uuid;
  v_status ops.agency_status;
  v_new_agency boolean;
  v_new_signal boolean := false;
begin
  if p_name is null or length(trim(p_name)) = 0 then
    return jsonb_build_object('error', 'empty name');
  end if;

  -- Atomic upsert on the generated normalised_name, safe under concurrent callers.
  insert into ops.agencies (name, region, last_signal_at)
  values (trim(p_name), p_region, p_seen_at)
  on conflict (normalised_name) do update
     set last_signal_at = greatest(coalesce(ops.agencies.last_signal_at, excluded.last_signal_at), excluded.last_signal_at),
         region = coalesce(ops.agencies.region, excluded.region),
         updated_at = now()
  returning id, status, (xmax = 0) into v_id, v_status, v_new_agency;

  insert into ops.signals (agency_id, type, source_url, detail, seen_at)
  values (v_id, p_type::ops.signal_type, p_source_url, p_detail, p_seen_at)
  on conflict (agency_id, type, source_url) do nothing;
  v_new_signal := found;

  return jsonb_build_object(
    'agency_id', v_id, 'status', v_status,
    'new_agency', v_new_agency, 'new_signal', v_new_signal);
end $function$
;

CREATE OR REPLACE FUNCTION public.ingest_signal(p_name text, p_region text DEFAULT NULL::text, p_source_url text DEFAULT NULL::text, p_detail text DEFAULT NULL::text, p_seen_at timestamp with time zone DEFAULT now(), p_type text DEFAULT 'job_advert'::text, p_applications integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public'
AS $function$
declare
  v_id uuid;
  v_status ops.agency_status;
  v_new_agency boolean;
  v_new_signal boolean := false;
begin
  if p_name is null or length(trim(p_name)) = 0 then
    return jsonb_build_object('error', 'empty name');
  end if;

  insert into ops.agencies (name, region, last_signal_at)
  values (trim(p_name), p_region, p_seen_at)
  on conflict (normalised_name) do update
     set last_signal_at = greatest(coalesce(ops.agencies.last_signal_at, excluded.last_signal_at), excluded.last_signal_at),
         region = coalesce(ops.agencies.region, excluded.region),
         updated_at = now()
  returning id, status, (xmax = 0) into v_id, v_status, v_new_agency;

  insert into ops.signals (agency_id, type, source_url, detail, seen_at, applications)
  values (v_id, p_type::ops.signal_type, p_source_url, p_detail, p_seen_at, p_applications)
  on conflict (agency_id, type, source_url) do update
     set applications = coalesce(excluded.applications, ops.signals.applications),
         detail = coalesce(excluded.detail, ops.signals.detail);
  v_new_signal := found;

  return jsonb_build_object(
    'agency_id', v_id, 'status', v_status,
    'new_agency', v_new_agency, 'new_signal', v_new_signal);
end $function$
;

CREATE OR REPLACE FUNCTION public.ops_create_approval(p_client text, p_received_at text, p_job_ref text, p_candidate jsonb, p_job jsonb, p_cfg jsonb)
 RETURNS TABLE(token text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public', 'extensions'
AS $function$
declare t text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  insert into ops.approvals (token, client, received_at, job_ref, candidate, job, cfg)
  values (t, p_client, p_received_at, p_job_ref, p_candidate, p_job, p_cfg);
  return query select t;
end $function$
;

CREATE OR REPLACE FUNCTION public.ops_decide(p_token text, p_decision text)
 RETURNS TABLE(outcome text, token text, client text, received_at text, job_ref text, candidate jsonb, job jsonb, cfg jsonb, status text, decided_at timestamp with time zone, sent_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public'
AS $function$
declare r ops.approvals%rowtype; o text;
begin
  if p_decision not in ('approve','hold') then
    return query select 'bad_decision', null::text, null::text, null::text, null::text, null::jsonb, null::jsonb, null::jsonb, null::text, null::timestamptz, null::timestamptz; return;
  end if;
  select * into r from ops.approvals a where a.token = p_token for update;
  if not found then
    return query select 'invalid', null::text, null::text, null::text, null::text, null::jsonb, null::jsonb, null::jsonb, null::text, null::timestamptz, null::timestamptz; return;
  end if;
  if r.status = 'sent' then o := 'already_sent';
  elsif p_decision = 'approve' and r.status = 'pending' then o := 'sent';
  elsif p_decision = 'approve' and r.status = 'held' then o := 'changed_to_sent';
  elsif p_decision = 'hold' and r.status = 'pending' then o := 'held';
  else o := 'already_held';
  end if;
  if o in ('sent','changed_to_sent') then
    update ops.approvals a set status = 'sent', sent_at = now(), decided_at = now(), decisions = a.decisions + 1 where a.token = p_token returning * into r;
  elsif o = 'held' then
    update ops.approvals a set status = 'held', decided_at = now(), decisions = a.decisions + 1 where a.token = p_token returning * into r;
  end if;
  return query select o, r.token, r.client, r.received_at, r.job_ref, r.candidate, r.job, r.cfg, r.status, r.decided_at, r.sent_at;
end $function$
;

CREATE OR REPLACE FUNCTION public.ops_mark_outreach(p_agency_id uuid, p_status text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public'
AS $function$
  update ops.agencies set outreach_status = p_status, outreach_sent_at = case when p_status = 'sent' then now() else outreach_sent_at end, updated_at = now() where id = p_agency_id;
$function$
;

CREATE OR REPLACE FUNCTION public.ops_outreach_candidates(p_limit integer DEFAULT 40, p_region text DEFAULT 'london'::text)
 RETURNS TABLE(agency_id uuid, name text, owner_name text, region text, icp_score smallint)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public'
AS $function$
  select a.id, a.name, a.owner_name, a.region, a.icp_score
  from ops.agencies a
  where a.status = 'scored' and a.owner_name is not null and a.owner_linkedin is null and a.outreach_status is null
  order by case when p_region = 'london' and (a.region ilike '%london%' or a.region ~ '^(E|EC|N|NW|SE|SW|W|WC)[0-9]') then 0 else 1 end, a.icp_score desc, a.name
  limit p_limit;
$function$
;

CREATE OR REPLACE FUNCTION public.ops_outreach_queue()
 RETURNS TABLE(agency text, owner text, title text, linkedin text, icp smallint, note text, on_accept text, status text, sent_at timestamp with time zone, agency_id uuid)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public'
AS $function$
  select a.name, a.owner_name, a.owner_title, a.owner_linkedin, a.icp_score,
    split_part(a.outreach_message, E'\n\n--- on accept ---\n', 1),
    nullif(split_part(a.outreach_message, E'\n\n--- on accept ---\n', 2), ''),
    a.outreach_status, a.outreach_sent_at, a.id
  from ops.agencies a where a.outreach_status in ('ready','sent','accepted','replied','booked','declined')
  order by case a.outreach_status when 'replied' then 0 when 'accepted' then 1 when 'ready' then 2 else 3 end, a.icp_score desc, a.name;
$function$
;

CREATE OR REPLACE FUNCTION public.ops_set_owner_linkedin(p_agency_id uuid, p_url text, p_title text, p_name text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public'
AS $function$
  update ops.agencies set owner_linkedin = nullif(p_url, ''), owner_title = nullif(p_title, ''), owner_name = coalesce(nullif(p_name, ''), owner_name), updated_at = now() where id = p_agency_id;
$function$
;

CREATE OR REPLACE FUNCTION public.score_agency(p_agency_id uuid, p_icp_score integer, p_why_now text, p_vertical text DEFAULT NULL::text, p_headcount_band text DEFAULT NULL::text, p_disqualify boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'ops', 'public'
AS $function$
begin
  update ops.agencies
     set icp_score      = greatest(1, least(10, p_icp_score)),
         why_now        = p_why_now,
         vertical       = coalesce(p_vertical, vertical),
         headcount_band = coalesce(p_headcount_band, headcount_band),
         status         = case
                            when status in ('new','scored') and p_disqualify then 'disqualified'::ops.agency_status
                            when status in ('new','scored') then 'scored'::ops.agency_status
                            else status end,
         updated_at     = now()
   where id = p_agency_id;
  return jsonb_build_object('agency_id', p_agency_id, 'scored', found);
end $function$
;
