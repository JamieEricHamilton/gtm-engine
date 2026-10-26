-- Aggregate-only results for the public repo. No account names, no contacts, no ids. Service role only, like every other function here.
create or replace function public.intel_results()
returns jsonb
language sql
stable
security definer
set search_path to 'own_brand', 'public'
as $function$
select jsonb_build_object(
 'generated_at', now(),
 'pipeline', jsonb_build_object(
   'accounts_total', (select count(*) from account_intel.accounts),
   'by_origin', (select jsonb_object_agg(origin, n) from (select origin, count(*) n from account_intel.accounts group by 1) x),
   'registry_matched', (select count(*) from account_intel.registry where company_number is not null),
   'registry_confident', (select count(*) from account_intel.registry where match_confidence >= 0.85),
   'registry_dead_disqualified', (select count(*) from account_intel.accounts where disqualified_reason like 'registry_%'),
   'linkedin_attempted', (select count(*) from account_intel.accounts where li_attempts > 0),
   'linkedin_enriched', (select count(*) from account_intel.accounts where li_enriched_at is not null),
   'disqualified_total', (select count(*) from account_intel.accounts where disqualified_reason is not null),
   'disqualified_by_reason', (select jsonb_object_agg(r, n) from (select case when disqualified_reason like 'registry_%' then 'registry_dead' when disqualified_reason in ('size_over_500','never_buy_industry') then disqualified_reason else 'manual' end r, count(*) n from account_intel.accounts where disqualified_reason is not null group by 1) x),
   'careers_pages_scanned', (select count(*) from account_intel.accounts where scanned_at is not null),
   'ats_detected', (select count(*) from account_intel.accounts where ats_provider is not null),
   'ats_by_provider', (select jsonb_object_agg(ats_provider, n) from (select ats_provider, count(*) n from account_intel.accounts where ats_provider is not null group by 1) x),
   'jobs_attempted', (select count(*) from account_intel.accounts where jobs_attempted_at is not null),
   'accounts_with_live_roles', (select count(distinct account_id) from account_intel.jobs where closed_at is null),
   'accounts_with_foreign_roles', (select count(distinct account_id) from account_intel.jobs where closed_at is null and country not in ('GB','IE','','OO','XX')),
   'job_rows', (select count(*) from account_intel.jobs),
   'news_attempted', (select count(*) from account_intel.accounts where news_attempted_at is not null),
   'news_signals_by_kind', (select jsonb_object_agg(kind, n) from (select kind::text, count(*) n from account_intel.news_signals group by 1) x),
   'why_now_lines', (select count(*) from account_intel.why_now where trigger_line is not null),
   'bands', (select jsonb_object_agg(coalesce(band::text,'unscored'), n) from (select band, count(*) n from account_intel.accounts group by 1) x),
   'score_version', (select score_version from account_intel.accounts where score_version is not null order by scored_at desc limit 1)
 ),
 'funding', jsonb_build_object(
   'accounts_with_press_raise', (select count(distinct account_id) from account_intel.news_signals where kind='funding' and source='news'),
   'accounts_with_register_raise', (select count(distinct account_id) from account_intel.news_signals where kind='funding' and source='companies_house' and confidence in ('likely','confirmed')),
   'register_raises_no_press_within_60d', (select count(*) from (select f.account_id from account_intel.filings f where f.filing_type='SH01' and f.amount_raised between 250000 and 50000000 and f.action_date >= current_date - 180 and not exists (select 1 from account_intel.news_signals p where p.account_id=f.account_id and p.kind='funding' and p.source='news' and p.event_date <= f.action_date + 60) group by 1) y),
   'register_raise_gbp_capped_180d', (select sum(a) from (select f.account_id, sum(f.amount_raised) a from account_intel.filings f where f.filing_type='SH01' and f.amount_raised between 1000 and 50000000 and f.action_date >= current_date - 180 group by 1) x),
   'filings_total', (select count(*) from account_intel.filings),
   'sh01_pdfs_parsed', (select count(*) from account_intel.filings where filing_type='SH01' and amount_parsed_at is not null),
   'net_new_total', (select count(*) from account_intel.accounts where origin='net_new'),
   'net_new_owned_by_colleague', (select count(*) from account_intel.accounts where origin='net_new' and sf_status='owned'),
   'net_new_released', (select count(*) from account_intel.accounts where origin='net_new' and sf_status is null)
 ),
 'register_stream', jsonb_build_object(
   'events_total', (select count(*) from account_intel.register_events),
   'by_outcome', (select jsonb_object_agg(outcome, n) from (select outcome, count(*) n from account_intel.register_events group by 1) x),
   'reject_reasons', (select jsonb_object_agg(r, n) from (select coalesce(split_part(reason,' ',1),'none') r, count(*) n from account_intel.register_events where outcome='rejected' group by 1) x),
   'first_event', (select min(received_at) from account_intel.register_events),
   'last_event', (select max(received_at) from account_intel.register_events),
   'promoted_accounts', (select count(*) from account_intel.accounts where origin='register')
 ),
 'alerts', jsonb_build_object(
   'total', (select count(*) from account_intel.alerts where source <> 'test'),
   'by_source', (select jsonb_object_agg(source, n) from (select source, count(*) n from account_intel.alerts where source <> 'test' group by 1) x),
   'by_answer', (select jsonb_object_agg(coalesce(answer,'unanswered'), n) from (select case when answer in ('mine','owned','timeout') then answer when answer is null then null else 'other' end answer, count(*) n from account_intel.alerts where source <> 'test' group by 1) x)
 ),
 'contacts', jsonb_build_object(
   'requests_by_status', (select jsonb_object_agg(status, n) from (select status, count(*) n from account_intel.contact_requests group by 1) x),
   'contacts_total', (select count(*) from account_intel.contacts),
   'contacts_per_found_request', (select round(avg(c),2) from (select count(*) c from account_intel.contacts group by request_id) x),
   'found_rate', (select round(100.0 * count(*) filter (where status='found') / nullif(count(*) filter (where status in ('found','none_found','no_match','no_linkedin')),0), 1) from account_intel.contact_requests)
 ),
 'outcomes', jsonb_build_object(
   'sheet_rows_live', (select count(*) from account_intel.sheet_state where removed_at is null),
   'sheet_first_push', (select min(first_pushed_at) from account_intel.sheet_state),
   'sheet_removed_by_reason', (select jsonb_object_agg(r, n) from (select case when remove_reason like 'disqualified%' then 'disqualified' when remove_reason in ('owned','customer') then remove_reason else 'manual' end r, count(*) n from account_intel.sheet_state where removed_at is not null group by 1) x),
   'by_status', (select jsonb_object_agg(status, n) from (select status::text, count(*) n from account_intel.outcomes group by 1) x),
   'first_outcome', (select min(last_touched) from account_intel.outcomes),
   'meetings_by_band', (select jsonb_object_agg(coalesce(band::text,'none'), n) from (select a.band, count(*) n from account_intel.outcomes o join account_intel.accounts a on a.account_id=o.account_id where o.status='meeting_booked' group by 1) x),
   'meetings_first_7_days', (select count(*) from account_intel.outcomes o where o.status='meeting_booked' and o.last_touched < (select min(first_pushed_at) from account_intel.sheet_state) + interval '7 days'),
   'calibration', (select jsonb_agg(jsonb_build_object('band_at_win', band_at_win, 'score_at_win', score_at_win, 'lead_product_at_win', lead_product_at_win, 'band_now', band) order by score_at_win desc) from account_intel.v_calibration where is_customer)
 ),
 'ops', jsonb_build_object(
   'watchdog_entries', (select count(*) from account_intel.watchdog_log),
   'apify_usage', (select value::jsonb from account_intel.settings where key='apify_usage')
 )
);
$function$;
