create schema if not exists ops;
create schema if not exists client_data;
create schema if not exists own_brand;

-- ----

create type account_intel.band as enum ('A', 'B', 'C', 'D');
create type account_intel.news_kind as enum ('funding', 'expansion', 'new_office', 'project_win', 'people_hire', 'layoffs', 'acquisition', 'ignored');
create type account_intel.outcome_status as enum ('worked', 'meeting_booked', 'not_a_fit');
create type account_intel.persona as enum ('founder', 'hr', 'finance', 'ops');
create type account_intel.product as enum ('eor', 'field_services', 'contractors', 'us_peo', 'it_equipment');
create type ops.agency_status as enum ('new', 'scored', 'shortlisted', 'contacted', 'replied', 'discovery', 'proposal', 'signed', 'disqualified');
create type ops.ats as enum ('zoho_recruit', 'bullhorn', 'jobadder', 'vincere', 'recruit_crm', 'firefish', 'loxo', 'other', 'unknown');
create type ops.signal_type as enum ('job_advert', 'hiring_resourcer', 'linkedin_post', 'companies_house', 'manual');

-- ----

create sequence if not exists account_intel.watchdog_log_id_seq;
create sequence if not exists account_intel.alerts_id_seq;

-- ----

create table account_intel.accounts (
  account_id uuid not null default gen_random_uuid(),
  name text not null,
  domain text,
  linkedin_url text,
  linkedin_kind text,
  website text,
  hq_country text,
  headcount integer,
  li_industry text,
  sector text,
  ats_provider text,
  ats_token text,
  careers_url text,
  disqualified_reason text,
  size_check boolean not null default false,
  score numeric(6,1),
  band account_intel.band,
  lead_product account_intel.product,
  cross_sell account_intel.product,
  convo_starter text,
  product_fit jsonb,
  score_breakdown jsonb,
  score_version text,
  scored_at timestamp with time zone,
  needs_review boolean not null default false,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  li_attempts smallint not null default 0,
  li_attempted_at timestamp with time zone,
  li_slug text,
  li_founded integer,
  li_followers integer,
  li_specialities text[],
  li_office_countries text[],
  li_employee_countries jsonb,
  li_enriched_at timestamp with time zone,
  scan_attempted_at timestamp with time zone,
  scanned_at timestamp with time zone,
  resolve_attempted_at timestamp with time zone,
  jobs_attempted_at timestamp with time zone,
  jobs_fetched_at timestamp with time zone,
  ats_jobs_attempted_at timestamp with time zone,
  news_attempted_at timestamp with time zone,
  news_checked_at timestamp with time zone,
  evidence_line text,
  is_customer boolean not null default false,
  customer_since date,
  customer_products text[],
  origin text not null default 'book'::text,
  is_ai boolean not null default false,
  net_new_at timestamp with time zone,
  sf_status text,
  net_new_pushed_at timestamp with time zone,
  ch_filings_checked_at timestamp with time zone,
  alerted_at timestamp with time zone,
  contacts_requested_at timestamp with time zone
);

create table account_intel.alerts (
  id bigint not null default nextval('account_intel.alerts_id_seq'::regclass),
  account_id uuid,
  source text not null,
  summary text,
  sent_at timestamp with time zone not null default now(),
  answered_at timestamp with time zone,
  answer text
);

create table account_intel.contact_requests (
  request_id uuid not null default gen_random_uuid(),
  sheet_row integer not null,
  company text not null,
  domain text,
  account_id uuid,
  linkedin_url text,
  status text not null default 'pending'::text,
  error text,
  requested_at timestamp with time zone not null default now(),
  attempted_at timestamp with time zone,
  completed_at timestamp with time zone,
  page_visited text,
  country_of_interest text,
  open_roles text,
  headcount integer
);

create table account_intel.contacts (
  contact_id uuid not null default gen_random_uuid(),
  request_id uuid,
  account_id uuid,
  full_name text not null,
  title text,
  headline text,
  linkedin_url text not null,
  location text,
  seniority text,
  source text not null default 'apify_harvestapi'::text,
  fetched_at timestamp with time zone not null default now()
);

create table account_intel.country_names (
  name text not null,
  iso2 text
);

create table account_intel.customer_wins (
  account_id uuid not null,
  won_at date not null,
  products text[],
  notes text,
  score_at_win numeric,
  band_at_win text,
  lead_product_at_win text,
  breakdown_at_win jsonb,
  evidence_at_win text,
  recorded_at timestamp with time zone default now()
);

create table account_intel.filings (
  account_id uuid not null,
  company_number text not null,
  transaction_id text not null,
  filing_type text,
  category text,
  description text,
  filed_on date,
  action_date date,
  capital jsonb,
  raw jsonb,
  observed_at timestamp with time zone not null default now(),
  doc_url text,
  amount_raised numeric,
  shares_allotted bigint,
  parse_attempted_at timestamp with time zone,
  amount_parsed_at timestamp with time zone,
  parse_note text
);

create table account_intel.jobs (
  job_url text not null,
  account_id uuid not null,
  source text not null,
  title text,
  location text,
  country text,
  remote_anywhere boolean not null default false,
  employment_type text,
  contract_language boolean not null default false,
  visa_language boolean not null default false,
  onsite_language boolean not null default false,
  it_role boolean not null default false,
  people_role boolean not null default false,
  posted_at date,
  first_seen_at timestamp with time zone not null default now(),
  last_seen_at timestamp with time zone not null default now(),
  closed_at timestamp with time zone,
  snippet text,
  raw jsonb,
  workplace_type text,
  salary_text text
);

create table account_intel.jobs_raw (
  id uuid not null default gen_random_uuid(),
  source text not null,
  batch_id text,
  item jsonb not null,
  received_at timestamp with time zone not null default now(),
  applied_at timestamp with time zone,
  account_id uuid
);

create table account_intel.linkedin_raw (
  id uuid not null default gen_random_uuid(),
  batch_id text,
  item jsonb not null,
  received_at timestamp with time zone not null default now(),
  applied_at timestamp with time zone,
  account_id uuid
);

create table account_intel.net_new_seen (
  url text not null,
  seen_at timestamp with time zone default now(),
  outcome text,
  company text
);

create table account_intel.never_buy_industries (
  li_industry text not null,
  reason text
);

create table account_intel.news_signals (
  id uuid not null default gen_random_uuid(),
  account_id uuid not null,
  kind account_intel.news_kind not null,
  amount text,
  event_date date not null,
  url text not null,
  snippet text,
  observed_at timestamp with time zone not null default now(),
  source text default 'news'::text,
  title text,
  confidence text not null default 'confirmed'::text
);

create table account_intel.outcomes (
  account_id uuid not null,
  status account_intel.outcome_status not null,
  contact_name text,
  notes text,
  last_touched timestamp with time zone,
  synced_at timestamp with time zone not null default now()
);

create table account_intel.page_signals (
  account_id uuid not null,
  competitor_mentions text[],
  foreign_office_countries text[],
  pages_fetched text[],
  observed_at timestamp with time zone not null default now(),
  ats_links text[],
  careers_links text[],
  http_status integer,
  title text
);

create table account_intel.register_events (
  transaction_id text not null,
  company_number text not null,
  company_name text,
  filed_on date,
  action_date date,
  capital jsonb,
  doc_url text,
  profile jsonb,
  filing jsonb,
  outcome text,
  reason text,
  amount_raised numeric,
  shares_allotted bigint,
  parse_note text,
  parse_attempted_at timestamp with time zone,
  amount_parsed_at timestamp with time zone,
  account_id uuid,
  received_at timestamp with time zone default now(),
  updated_at timestamp with time zone default now()
);

create table account_intel.registry (
  account_id uuid not null,
  registry text not null,
  company_number text,
  registered_name text,
  status text,
  incorporated_on date,
  sic_codes text[],
  accounts_type text,
  foreign_psc boolean,
  officer_countries text[],
  licensed_sponsor boolean,
  match_confidence numeric(3,2),
  matched_by text,
  raw jsonb,
  observed_at timestamp with time zone not null default now()
);

create table account_intel.sector_map (
  key text not null,
  sector text not null,
  field_services boolean not null default false,
  contractor_heavy boolean not null default false
);

create table account_intel.settings (
  key text not null,
  value text,
  updated_at timestamp with time zone not null default now()
);

create table account_intel.sheet_state (
  account_id uuid not null,
  first_pushed_at timestamp with time zone not null default now(),
  last_pushed_at timestamp with time zone not null default now(),
  band_at_push account_intel.band,
  removed_at timestamp with time zone,
  remove_reason text
);

create table account_intel.watchdog_log (
  id bigint not null default nextval('account_intel.watchdog_log_id_seq'::regclass),
  logged_at timestamp with time zone default now(),
  alert text,
  cause text,
  action text,
  left_to_do text,
  session_url text
);

create table account_intel.why_now (
  account_id uuid not null,
  trigger_line text,
  discovery_q text,
  persona account_intel.persona,
  proof text,
  evidence_line text,
  context text,
  model text,
  score_version text,
  generated_at timestamp with time zone not null default now(),
  scorer_evidence text,
  band_at_generation text
);

create table ops.agencies (
  id uuid not null default gen_random_uuid(),
  company_number text,
  name text not null,
  website text,
  careers_url text,
  ats ops.ats not null default 'unknown'::ops.ats,
  region text,
  vertical text,
  headcount_band text,
  incorporated_on date,
  status ops.agency_status not null default 'new'::ops.agency_status,
  icp_score smallint,
  why_now text,
  owner_name text,
  owner_linkedin text,
  last_signal_at timestamp with time zone,
  notes text,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  sic_codes text[],
  ch_name text,
  active_directors smallint,
  owner_role text,
  outreach_status text,
  outreach_message text,
  outreach_sent_at timestamp with time zone,
  owner_title text
);

create table ops.approvals (
  token text not null,
  created_at timestamp with time zone not null default now(),
  client text not null,
  received_at text not null,
  job_ref text,
  candidate jsonb not null,
  job jsonb not null default '{}'::jsonb,
  cfg jsonb not null default '{}'::jsonb,
  status text not null default 'pending'::text,
  decided_at timestamp with time zone,
  sent_at timestamp with time zone,
  decisions integer not null default 0
);

create table ops.messages (
  id uuid not null default gen_random_uuid(),
  agency_id uuid not null,
  channel text not null,
  template text,
  body text,
  sent_at timestamp with time zone not null default now(),
  replied_at timestamp with time zone,
  outcome text
);

create table ops.signals (
  id uuid not null default gen_random_uuid(),
  agency_id uuid not null,
  type ops.signal_type not null,
  source_url text,
  detail text,
  seen_at timestamp with time zone not null default now(),
  applications integer
);

-- ---- generated columns (depend on ops.normalise_company_name, defined in 0002)

alter table ops.agencies add column normalised_name text generated always as (ops.normalise_company_name(name)) stored;
alter table account_intel.accounts add column normalised_name text generated always as (ops.normalise_company_name(name)) stored;

-- ---- constraints

alter table account_intel.contact_requests add constraint contact_requests_sheet_row_company_key UNIQUE (sheet_row, company);
alter table account_intel.contacts add constraint contacts_request_id_linkedin_url_key UNIQUE (request_id, linkedin_url);
alter table account_intel.news_signals add constraint news_signals_account_id_url_key UNIQUE (account_id, url);
alter table ops.agencies add constraint agencies_company_number_key UNIQUE (company_number);
alter table ops.signals add constraint signals_agency_id_type_source_url_key UNIQUE (agency_id, type, source_url);
alter table account_intel.accounts add constraint accounts_pkey PRIMARY KEY (account_id);
alter table account_intel.alerts add constraint alerts_pkey PRIMARY KEY (id);
alter table account_intel.contact_requests add constraint contact_requests_pkey PRIMARY KEY (request_id);
alter table account_intel.contacts add constraint contacts_pkey PRIMARY KEY (contact_id);
alter table account_intel.country_names add constraint country_names_pkey PRIMARY KEY (name);
alter table account_intel.customer_wins add constraint customer_wins_pkey PRIMARY KEY (account_id);
alter table account_intel.filings add constraint filings_pkey PRIMARY KEY (account_id, transaction_id);
alter table account_intel.jobs add constraint jobs_pkey PRIMARY KEY (job_url);
alter table account_intel.jobs_raw add constraint jobs_raw_pkey PRIMARY KEY (id);
alter table account_intel.linkedin_raw add constraint linkedin_raw_pkey PRIMARY KEY (id);
alter table account_intel.net_new_seen add constraint net_new_seen_pkey PRIMARY KEY (url);
alter table account_intel.never_buy_industries add constraint never_buy_industries_pkey PRIMARY KEY (li_industry);
alter table account_intel.news_signals add constraint news_signals_pkey PRIMARY KEY (id);
alter table account_intel.outcomes add constraint outcomes_pkey PRIMARY KEY (account_id);
alter table account_intel.page_signals add constraint page_signals_pkey PRIMARY KEY (account_id);
alter table account_intel.register_events add constraint register_events_pkey PRIMARY KEY (transaction_id);
alter table account_intel.registry add constraint registry_pkey PRIMARY KEY (account_id);
alter table account_intel.sector_map add constraint sector_map_pkey PRIMARY KEY (key);
alter table account_intel.settings add constraint settings_pkey PRIMARY KEY (key);
alter table account_intel.sheet_state add constraint sheet_state_pkey PRIMARY KEY (account_id);
alter table account_intel.watchdog_log add constraint watchdog_log_pkey PRIMARY KEY (id);
alter table account_intel.why_now add constraint why_now_pkey PRIMARY KEY (account_id);
alter table ops.agencies add constraint agencies_pkey PRIMARY KEY (id);
alter table ops.approvals add constraint approvals_pkey PRIMARY KEY (token);
alter table ops.messages add constraint messages_pkey PRIMARY KEY (id);
alter table ops.signals add constraint signals_pkey PRIMARY KEY (id);
alter table account_intel.alerts add constraint alerts_account_id_fkey FOREIGN KEY (account_id) REFERENCES account_intel.accounts(account_id) ON DELETE CASCADE;
alter table account_intel.contact_requests add constraint contact_requests_account_id_fkey FOREIGN KEY (account_id) REFERENCES account_intel.accounts(account_id);
alter table account_intel.contacts add constraint contacts_account_id_fkey FOREIGN KEY (account_id) REFERENCES account_intel.accounts(account_id);
alter table account_intel.contacts add constraint contacts_request_id_fkey FOREIGN KEY (request_id) REFERENCES account_intel.contact_requests(request_id) ON DELETE CASCADE;
alter table account_intel.customer_wins add constraint customer_wins_account_id_fkey FOREIGN KEY (account_id) REFERENCES account_intel.accounts(account_id);
alter table account_intel.filings add constraint filings_account_id_fkey FOREIGN KEY (account_id) REFERENCES account_intel.accounts(account_id) ON DELETE CASCADE;
alter table account_intel.jobs add constraint jobs_account_id_fkey FOREIGN KEY (account_id) REFERENCES account_intel.accounts(account_id) ON DELETE CASCADE;
alter table account_intel.news_signals add constraint news_signals_account_id_fkey FOREIGN KEY (account_id) REFERENCES account_intel.accounts(account_id) ON DELETE CASCADE;
alter table account_intel.outcomes add constraint outcomes_account_id_fkey FOREIGN KEY (account_id) REFERENCES account_intel.accounts(account_id) ON DELETE CASCADE;
alter table account_intel.page_signals add constraint page_signals_account_id_fkey FOREIGN KEY (account_id) REFERENCES account_intel.accounts(account_id) ON DELETE CASCADE;
alter table account_intel.registry add constraint registry_account_id_fkey FOREIGN KEY (account_id) REFERENCES account_intel.accounts(account_id) ON DELETE CASCADE;
alter table account_intel.sheet_state add constraint sheet_state_account_id_fkey FOREIGN KEY (account_id) REFERENCES account_intel.accounts(account_id) ON DELETE CASCADE;
alter table account_intel.why_now add constraint why_now_account_id_fkey FOREIGN KEY (account_id) REFERENCES account_intel.accounts(account_id) ON DELETE CASCADE;
alter table ops.messages add constraint messages_agency_id_fkey FOREIGN KEY (agency_id) REFERENCES ops.agencies(id) ON DELETE CASCADE;
alter table ops.signals add constraint signals_agency_id_fkey FOREIGN KEY (agency_id) REFERENCES ops.agencies(id) ON DELETE CASCADE;
alter table ops.agencies add constraint agencies_icp_score_check CHECK (((icp_score >= 1) AND (icp_score <= 10)));
alter table ops.approvals add constraint approvals_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'sent'::text, 'held'::text])));

-- ---- indexes

CREATE INDEX signals_agency_seen_idx ON ops.signals USING btree (agency_id, seen_at DESC);
CREATE INDEX agencies_status_idx ON ops.agencies USING btree (status);
CREATE UNIQUE INDEX agencies_normalised_name_idx ON ops.agencies USING btree (normalised_name);
CREATE INDEX jobs_account_ix ON account_intel.jobs USING btree (account_id);
CREATE UNIQUE INDEX accounts_domain_uq ON account_intel.accounts USING btree (domain) WHERE (domain IS NOT NULL);
CREATE INDEX accounts_normalised_name_ix ON account_intel.accounts USING btree (normalised_name);
CREATE INDEX accounts_band_ix ON account_intel.accounts USING btree (band);
CREATE INDEX accounts_li_slug_idx ON account_intel.accounts USING btree (lower(li_slug));
CREATE INDEX accounts_linkedin_slug_expr_idx ON account_intel.accounts USING btree (lower(regexp_replace(COALESCE(linkedin_url, ''::text), '^.*linkedin\.com/(company|school|showcase)/([^/?#]+).*$'::text, '\2'::text)));
CREATE INDEX jobs_raw_unapplied_idx ON account_intel.jobs_raw USING btree (applied_at) WHERE (applied_at IS NULL);
CREATE INDEX approvals_client_status ON ops.approvals USING btree (client, status);
CREATE INDEX register_events_company_idx ON account_intel.register_events USING btree (company_number, action_date);
CREATE INDEX register_events_outcome_idx ON account_intel.register_events USING btree (outcome, received_at DESC);
CREATE INDEX contacts_account_idx ON account_intel.contacts USING btree (account_id);

-- ---- views

create or replace view account_intel.v_calibration as
 SELECT a.name,
    a.is_customer,
    a.customer_since,
    a.customer_products,
    a.band,
    a.score,
    a.lead_product,
    a.headcount,
    a.li_industry,
    (a.score_breakdown ->> 'foreign_roles_w'::text)::numeric AS foreign_roles_w,
    a.score_breakdown ->> 'emp_abroad'::text AS emp_abroad,
    (a.score_breakdown ->> 'contract_w'::text)::numeric AS contract_w,
    (a.score_breakdown ->> 'us_w'::text)::numeric AS us_w,
    w.score_at_win,
    w.band_at_win,
    w.lead_product_at_win
   FROM account_intel.accounts a
     LEFT JOIN account_intel.customer_wins w ON w.account_id = a.account_id
  WHERE a.disqualified_reason IS NULL;

-- ---- triggers

CREATE TRIGGER agencies_touch BEFORE UPDATE ON ops.agencies FOR EACH ROW EXECUTE FUNCTION ops.touch_updated_at();
CREATE TRIGGER signals_bump AFTER INSERT ON ops.signals FOR EACH ROW EXECUTE FUNCTION ops.bump_last_signal();
CREATE TRIGGER accounts_touch BEFORE UPDATE ON account_intel.accounts FOR EACH ROW EXECUTE FUNCTION account_intel.touch_updated_at();

-- ---- row level security (as currently enabled on the live database)

alter table ops.messages enable row level security;
alter table ops.signals enable row level security;
alter table ops.agencies enable row level security;
alter table ops.approvals enable row level security;
alter table account_intel.filings enable row level security;
alter table account_intel.settings enable row level security;
alter table account_intel.alerts enable row level security;
alter table account_intel.contact_requests enable row level security;
alter table account_intel.contacts enable row level security;
