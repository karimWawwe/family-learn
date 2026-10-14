-- ============================================================================
--  Family Learn - AI (Phase 8): AI tutor, role-play conversations, parent logs.
--
--  The model (Claude, Anthropic API) is called ONLY by the Edge Function
--  supabase/functions/ai-chat. The API key lives in the Edge Function secrets,
--  never in the app or the database.
--
--  Flow for every message:
--    app  -> Edge Function (with the user's sign-in)
--         -> ai_prepare()  as the user: access, ai_enabled, daily limit, monthly budget,
--                          saves the learner's message, returns the context + history
--         -> Claude
--         -> ai_finish()   as service_role only: saves the reply, tokens, cost, safety flag
--
--  Children: their own conversations only; the parent sees everything (ai_history /
--  ai_conversation). Nobody can delete messages from the app.
--  Safe to run more than once. Nothing else changes.
-- ============================================================================
begin;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin; end if;
end $$;

-- ---------------------------------------------------------------- tables
create table if not exists public.ai_settings (
  family_id          uuid primary key references public.families (id) on delete cascade,
  monthly_budget_usd numeric(8, 2) not null default 5 check (monthly_budget_usd between 0 and 500),
  child_daily_limit  smallint not null default 20 check (child_daily_limit between 0 and 500),
  adult_daily_limit  smallint not null default 60 check (adult_daily_limit between 0 and 500),
  updated_at         timestamptz not null default now()
);

create table if not exists public.ai_scenarios (
  code       text primary key,
  audience   text not null check (audience in ('adult', 'child')),
  grade_min  smallint,
  grade_max  smallint,
  lang       text not null default 'en' check (lang in ('en', 'fr')),
  title      text not null,
  title_ar   text not null,
  persona    text not null,          -- who the AI plays
  goal       text not null,          -- what the learner should achieve
  emoji      text not null default '💬',
  position   smallint not null default 0,
  published  boolean not null default true
);

create table if not exists public.ai_conversations (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid not null references public.profiles (id) on delete cascade,
  kind        text not null check (kind in ('tutor', 'roleplay')),
  title       text not null default '',
  scenario    text references public.ai_scenarios (code),
  question_id text references public.questions (id) on delete set null,
  lesson_id   text references public.lessons (id) on delete set null,
  feedback    jsonb,
  flagged     boolean not null default false,
  started_at  timestamptz not null default now(),
  last_at     timestamptz not null default now()
);
create index if not exists ai_conversations_profile_idx on public.ai_conversations (profile_id, last_at desc);

create table if not exists public.ai_messages (
  id              bigint generated always as identity primary key,
  conversation_id uuid not null references public.ai_conversations (id) on delete cascade,
  role            text not null check (role in ('user', 'assistant', 'feedback')),
  content         text not null,
  flagged         boolean not null default false,
  in_tokens       integer not null default 0,
  out_tokens      integer not null default 0,
  cost_usd        numeric(10, 6) not null default 0,
  created_at      timestamptz not null default now()
);
create index if not exists ai_messages_conv_idx on public.ai_messages (conversation_id, id);
create index if not exists ai_messages_time_idx on public.ai_messages (created_at);

-- No direct table access from the app: functions only.
alter table public.ai_settings      enable row level security;
alter table public.ai_scenarios     enable row level security;
alter table public.ai_conversations enable row level security;
alter table public.ai_messages      enable row level security;
revoke all on public.ai_settings, public.ai_scenarios, public.ai_conversations, public.ai_messages from anon, authenticated;

-- ---------------------------------------------------------------- scenarios
insert into public.ai_scenarios (code, audience, grade_min, grade_max, lang, title, title_ar, persona, goal, emoji, position) values
  -- Kareem (business English)
  ('customer_conversation', 'adult', null, null, 'en', 'Customer conversation', 'محادثة مع عميل', 'A tourist in a perfume shop in a Muscat mall, looking for a gift', 'Recommend 2 perfumes and close the sale', '🛍️', 1),
  ('customer_complaint', 'adult', null, null, 'en', 'Customer complaint', 'شكوى عميل', 'An upset customer whose new perfume bottle is leaking', 'Calm the customer and offer a fair solution', '😠', 2),
  ('monthly_sales_meeting', 'adult', null, null, 'en', 'Monthly sales meeting', 'اجتماع المبيعات الشهري', 'The regional director of a perfume retail company', 'Present last month''s results and next month''s plan', '📊', 3),
  ('supplier_negotiation', 'adult', null, null, 'en', 'Supplier negotiation', 'التفاوض مع مورّد', 'A packaging supplier', 'Get a better price and delivery date for 5,000 gift boxes', '🤝', 4),
  ('performance_discussion', 'adult', null, null, 'en', 'Performance discussion', 'نقاش أداء موظف', 'A salesperson who is below target this month', 'Give clear, fair feedback and agree on a plan', '🗣️', 5),
  ('presenting_perfume', 'adult', null, null, 'en', 'Presenting a perfume', 'تقديم عطر', 'A buyer from a big mall', 'Describe the notes, sillage and story of a perfume', '🌹', 6),
  ('management_meeting', 'adult', null, null, 'en', 'Management meeting', 'اجتماع الإدارة', 'The CEO and the finance manager', 'Defend the budget for a new campaign', '🏢', 7),
  ('marketing_discussion', 'adult', null, null, 'en', 'Marketing discussion', 'نقاش تسويقي', 'The marketing manager', 'Agree on a Ramadan campaign', '📣', 8),
  ('sales_report', 'adult', null, null, 'en', 'Sales report', 'تقرير المبيعات', 'Your manager', 'Explain why one branch dropped 12% and what you will do', '📉', 9),
  ('new_branch', 'adult', null, null, 'en', 'New branch', 'فرع جديد', 'A mall leasing manager', 'Discuss the location, rent and opening date of a new branch', '🏬', 10),
  -- Yassin (grade 3)
  ('kid3_new_friend', 'child', 3, 3, 'en', 'My new friend', 'صديقي الجديد', 'A friendly new classmate called Sam', 'Say hello, say your name and age, and ask about a favourite colour', '🧒', 20),
  ('kid3_toy_shop', 'child', 3, 3, 'en', 'At the toy shop', 'في محل الألعاب', 'A kind shopkeeper in a toy shop', 'Ask for a toy, ask "How much is it?" and say thank you', '🧸', 21),
  ('kid3_fr_bonjour', 'child', 3, 3, 'fr', 'Bonjour, nouvel ami !', 'بونجور يا صديقي!', 'Léo, a friendly French boy of 9', 'Greet Léo, say your name and age in French, and say goodbye', '🇫🇷', 22),
  -- Omar (grade 6)
  ('kid6_restaurant', 'child', 6, 6, 'en', 'At the restaurant', 'في المطعم', 'A friendly waiter in a family restaurant', 'Order a meal and a drink, ask the price and pay politely', '🍽️', 30),
  ('kid6_school_trip', 'child', 6, 6, 'en', 'Planning a school trip', 'نخطط لرحلة مدرسية', 'A classmate who is planning a class trip with you', 'Agree on where to go, when to meet and what to bring', '🚌', 31),
  ('kid6_directions', 'child', 6, 6, 'en', 'Asking for directions', 'أسأل عن الطريق', 'A helpful information-desk worker in a big mall', 'Ask how to get to the bookshop and repeat the directions', '🗺️', 32),
  ('kid6_fr_cafe', 'child', 6, 6, 'fr', 'Au café', 'في المقهى', 'Un serveur sympathique dans un café à Paris', 'Commander une boisson et un croissant, demander le prix', '🥐', 33),
  ('kid6_fr_ville', 'child', 6, 6, 'fr', 'Dans ma ville', 'في مدينتي', 'Une touriste française perdue près de chez toi', 'Lui expliquer le chemin vers la boulangerie (à côté de, devant, entre…)', '🏘️', 34)
on conflict (code) do update set audience = excluded.audience, grade_min = excluded.grade_min, grade_max = excluded.grade_max,
  lang = excluded.lang, title = excluded.title, title_ar = excluded.title_ar, persona = excluded.persona,
  goal = excluded.goal, emoji = excluded.emoji, position = excluded.position;

-- ---------------------------------------------------------------- helpers
create or replace function app.ai_settings_of(p_family uuid) returns public.ai_settings
language plpgsql security definer set search_path = '' as $$
declare
  s public.ai_settings;
begin
  select * into s from public.ai_settings where family_id = p_family;
  if not found then
    insert into public.ai_settings (family_id) values (p_family) on conflict (family_id) do nothing;
    select * into s from public.ai_settings where family_id = p_family;
  end if;
  return s;
end $$;

-- Model calls (replies + feedback) of a profile today (profile's time zone).
create or replace function app.ai_calls_today(p_profile uuid) returns int
language sql stable security definer set search_path = '' as $$
  select count(*)::int from public.ai_messages m join public.ai_conversations c on c.id = m.conversation_id
   where c.profile_id = p_profile and m.role in ('assistant', 'feedback')
     and (m.created_at at time zone app.profile_tz(p_profile))::date = (now() at time zone app.profile_tz(p_profile))::date
$$;

-- Spend of the whole family this calendar month (Muscat time of the given profile).
create or replace function app.ai_month_cost(p_family uuid, p_tz text) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(m.cost_usd), 0) from public.ai_messages m
    join public.ai_conversations c on c.id = m.conversation_id
    join public.profiles p on p.id = c.profile_id
   where p.family_id = p_family
     and date_trunc('month', m.created_at at time zone p_tz) = date_trunc('month', now() at time zone p_tz)
$$;

create or replace function app.ai_scenario_ok(p_profile uuid, p_code text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.ai_scenarios s, public.profiles p
                  where s.code = p_code and p.id = p_profile and s.published
                    and s.audience = p.kind
                    and (p.kind = 'adult' or coalesce(p.grade, 1) between coalesce(s.grade_min, 1) and coalesce(s.grade_max, 12)))
$$;

-- ---------------------------------------------------------------- status & lists (app)
create or replace function public.ai_status(p_profile uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p  public.profiles;
  s  public.ai_settings;
  tz text;
begin
  perform app.require_profile(p_profile);
  select * into p from public.profiles where id = p_profile;
  s := app.ai_settings_of(p.family_id);
  tz := app.profile_tz(p_profile);
  return jsonb_build_object(
    'enabled', p.ai_enabled,
    'used_today', app.ai_calls_today(p_profile),
    'daily_limit', case when p.kind = 'child' then s.child_daily_limit else s.adult_daily_limit end,
    'month_cost', round(app.ai_month_cost(p.family_id, tz), 4),
    'monthly_budget', s.monthly_budget_usd);
end $$;

create or replace function public.ai_scenarios_for(p_profile uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_profile(p_profile);
  return coalesce((
    select jsonb_agg(jsonb_build_object('code', s.code, 'lang', s.lang, 'title', s.title, 'title_ar', s.title_ar,
                                        'persona', s.persona, 'goal', s.goal, 'emoji', s.emoji) order by s.position, s.code)
      from public.ai_scenarios s where app.ai_scenario_ok(p_profile, s.code)), '[]'::jsonb);
end $$;

-- Conversations of a profile, newest first (the child's own; the parent sees the children's).
create or replace function public.ai_history(p_profile uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_profile(p_profile);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'kind', c.kind, 'title', c.title, 'scenario', c.scenario,
             'started_at', c.started_at, 'last_at', c.last_at, 'flagged', c.flagged,
             'has_feedback', c.feedback is not null,
             'messages', (select count(*) from public.ai_messages m where m.conversation_id = c.id and m.role <> 'feedback'),
             'preview', (select left(m.content, 120) from public.ai_messages m
                          where m.conversation_id = c.id and m.role = 'user' order by m.id limit 1))
           order by c.last_at desc)
      from (select * from public.ai_conversations where profile_id = p_profile order by last_at desc limit 100) c), '[]'::jsonb);
end $$;

create or replace function public.ai_conversation(p_conversation uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  c public.ai_conversations;
begin
  select * into c from public.ai_conversations where id = p_conversation;
  if not found or not app.can_use_profile(c.profile_id) then perform app.fail('not_found'); end if;
  return jsonb_build_object(
    'id', c.id, 'profile_id', c.profile_id, 'kind', c.kind, 'title', c.title, 'scenario', c.scenario,
    'question_id', c.question_id, 'lesson_id', c.lesson_id, 'feedback', c.feedback, 'flagged', c.flagged,
    'started_at', c.started_at,
    'messages', coalesce((select jsonb_agg(jsonb_build_object('role', m.role, 'content', m.content,
                                                              'flagged', m.flagged, 'at', m.created_at) order by m.id)
                            from public.ai_messages m where m.conversation_id = c.id and m.role <> 'feedback'), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------- prepare (Edge Function, as the user)
-- p_kind: 'tutor' | 'roleplay' (a reply) | 'feedback' (end of a role-play)
-- p_context: {"question_id": "...", "lesson_id": "..."} (tutor) or {"scenario": "code"} (role-play)
create or replace function public.ai_prepare(p_profile uuid, p_kind text, p_conversation uuid default null,
                                             p_context jsonb default '{}'::jsonb, p_message text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  p       public.profiles;
  s       public.ai_settings;
  c       public.ai_conversations;
  q       public.questions;
  l       public.lessons;
  co      public.courses;
  sc      public.ai_scenarios;
  msg     text := nullif(btrim(coalesce(p_message, '')), '');
  lim     int;
  tz      text;
  ctx     jsonb := '{}'::jsonb;
  answered boolean := false;
  last_ok boolean;
begin
  perform app.require_profile(p_profile);
  if p_kind not in ('tutor', 'roleplay', 'feedback') then perform app.fail('bad_request'); end if;
  select * into p from public.profiles where id = p_profile;
  if not p.ai_enabled then perform app.fail('ai_disabled'); end if;
  s := app.ai_settings_of(p.family_id);
  tz := app.profile_tz(p_profile);

  -- the conversation
  if p_conversation is null then
    if p_kind = 'feedback' then perform app.fail('not_found'); end if;
    if p_kind = 'roleplay' then
      if not app.ai_scenario_ok(p_profile, p_context ->> 'scenario') then perform app.fail('not_found'); end if;
      select * into sc from public.ai_scenarios where code = p_context ->> 'scenario';
      insert into public.ai_conversations (profile_id, kind, title, scenario)
      values (p_profile, 'roleplay', case when p.ui_locale = 'ar' then sc.title_ar else sc.title end, sc.code)
      returning * into c;
    else
      if msg is null then perform app.fail('empty_message'); end if;
      if p_context ? 'question_id' then
        select q2.* into q from public.questions q2 join public.lessons l2 on l2.id = q2.lesson_id
          join app.courses_for(p_profile) cf on cf.id = l2.course_id
         where q2.id = p_context ->> 'question_id';
        if not found then perform app.fail('not_found'); end if;
        select * into l from public.lessons where id = q.lesson_id;
      elsif p_context ? 'lesson_id' then
        select l2.* into l from public.lessons l2 join app.courses_for(p_profile) cf on cf.id = l2.course_id
         where l2.id = p_context ->> 'lesson_id';
        if not found then perform app.fail('not_found'); end if;
      end if;
      insert into public.ai_conversations (profile_id, kind, title, question_id, lesson_id)
      values (p_profile, 'tutor', left(coalesce(l.title, msg), 80), q.id, l.id)
      returning * into c;
    end if;
  else
    select * into c from public.ai_conversations where id = p_conversation and profile_id = p_profile;
    if not found then perform app.fail('not_found'); end if;
    if (p_kind = 'tutor') <> (c.kind = 'tutor') then perform app.fail('bad_request'); end if;
    if c.question_id is not null then select * into q from public.questions where id = c.question_id; end if;
    if c.lesson_id is not null then select * into l from public.lessons where id = c.lesson_id; end if;
    if c.scenario is not null then select * into sc from public.ai_scenarios where code = c.scenario; end if;
  end if;

  -- a finished role-play keeps its feedback (no new model call)
  if p_kind = 'feedback' and c.feedback is not null then
    return jsonb_build_object('conversation_id', c.id, 'kind', 'feedback', 'cached_feedback', c.feedback);
  end if;
  if p_kind = 'feedback' and (select count(*) from public.ai_messages where conversation_id = c.id and role = 'user') < 2 then
    perform app.fail('too_short');
  end if;
  if p_kind = 'tutor' and msg is null then perform app.fail('empty_message'); end if;
  if p_kind = 'roleplay' and msg is null and exists (select 1 from public.ai_messages where conversation_id = c.id) then
    perform app.fail('empty_message');
  end if;
  if msg is not null and char_length(msg) > 600 then perform app.fail('message_too_long'); end if;

  -- limits
  lim := case when p.kind = 'child' then s.child_daily_limit else s.adult_daily_limit end;
  if app.ai_calls_today(p_profile) >= lim then perform app.fail('ai_daily_limit'); end if;
  if app.ai_month_cost(p.family_id, tz) >= s.monthly_budget_usd then perform app.fail('ai_budget'); end if;

  if msg is not null and p_kind <> 'feedback' then
    insert into public.ai_messages (conversation_id, role, content) values (c.id, 'user', msg);
  end if;
  update public.ai_conversations set last_at = now() where id = c.id;

  -- lesson / question context for the tutor (the right answer only once the learner has answered)
  if l.id is not null then
    select * into co from public.courses where id = l.course_id;
    ctx := jsonb_build_object('course', co.title, 'subject', co.subject, 'lesson', l.title,
                              'lesson_intro', l.intro, 'speech_lang', co.speech_lang);
  end if;
  if q.id is not null then
    select true, an.is_correct into answered, last_ok
      from public.answers an join public.lesson_attempts a on a.id = an.attempt_id
     where a.profile_id = p_profile and an.question_id = q.id
     order by an.answered_at desc limit 1;
    if not found then
      select true, ps.is_correct into answered, last_ok
        from public.practice_answers ps join public.practice_sessions se on se.id = ps.session_id
       where se.profile_id = p_profile and ps.question_id = q.id
       order by ps.answered_at desc limit 1;
    end if;
    answered := coalesce(answered, false);
    ctx := ctx || jsonb_build_object(
      'question', q.prompt, 'question_type', q.type,
      'options', q.payload -> 'options', 'passage', q.payload ->> 'passage',
      'before', q.payload ->> 'before', 'after', q.payload ->> 'after',
      'answered', answered,
      'learner_was_right', case when answered then last_ok end,
      'correct_answer', case when answered then q.correct_text end,
      'explanation', case when answered then q.explanation end);
  end if;

  return jsonb_build_object(
    'conversation_id', c.id,
    'kind', p_kind,
    'profile', jsonb_build_object('name', p.display_name, 'kind', p.kind, 'grade', p.grade, 'ui_locale', p.ui_locale),
    'scenario', case when sc.code is null then null else jsonb_build_object(
                  'code', sc.code, 'lang', sc.lang, 'title', sc.title, 'persona', sc.persona, 'goal', sc.goal) end,
    'context', ctx,
    'history', coalesce((select jsonb_agg(jsonb_build_object('role', h.role, 'content', h.content) order by h.id)
                           from (select id, role, content from public.ai_messages
                                  where conversation_id = c.id and role in ('user', 'assistant')
                                  order by id desc limit 24) h), '[]'::jsonb),
    'remaining_today', lim - app.ai_calls_today(p_profile));
end $$;

-- ---------------------------------------------------------------- finish (Edge Function, service_role only)
create or replace function public.ai_finish(p_conversation uuid, p_role text, p_content text,
                                            p_in int, p_out int, p_cost numeric,
                                            p_flagged boolean default false, p_feedback jsonb default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  c public.ai_conversations;
begin
  select * into c from public.ai_conversations where id = p_conversation;
  if not found then perform app.fail('not_found'); end if;
  if p_role not in ('assistant', 'feedback') then perform app.fail('bad_request'); end if;
  insert into public.ai_messages (conversation_id, role, content, in_tokens, out_tokens, cost_usd)
  values (c.id, p_role, coalesce(p_content, ''), greatest(coalesce(p_in, 0), 0), greatest(coalesce(p_out, 0), 0),
          greatest(coalesce(p_cost, 0), 0));
  if coalesce(p_flagged, false) then
    update public.ai_messages set flagged = true
     where id = (select max(id) from public.ai_messages where conversation_id = c.id and role = 'user');
  end if;
  update public.ai_conversations
     set last_at = now(),
         flagged = flagged or coalesce(p_flagged, false),
         feedback = case when p_role = 'feedback' then p_feedback else feedback end
   where id = c.id;
  return jsonb_build_object('ok', true, 'remaining_today',
    (select case when p.kind = 'child' then s.child_daily_limit else s.adult_daily_limit end - app.ai_calls_today(p.id)
       from public.profiles p, app.ai_settings_of(p.family_id) s where p.id = c.profile_id));
end $$;

-- ---------------------------------------------------------------- grants
revoke all on function app.ai_settings_of(uuid)                    from public, anon, authenticated;
revoke all on function app.ai_calls_today(uuid)                    from public, anon, authenticated;
revoke all on function app.ai_month_cost(uuid, text)               from public, anon, authenticated;
revoke all on function app.ai_scenario_ok(uuid, text)              from public, anon, authenticated;
revoke all on function public.ai_status(uuid)                      from public, anon;
revoke all on function public.ai_scenarios_for(uuid)               from public, anon;
revoke all on function public.ai_history(uuid)                     from public, anon;
revoke all on function public.ai_conversation(uuid)                from public, anon;
revoke all on function public.ai_prepare(uuid, text, uuid, jsonb, text) from public, anon;
revoke all on function public.ai_finish(uuid, text, text, int, int, numeric, boolean, jsonb) from public, anon, authenticated;

grant execute on function public.ai_status(uuid)                   to authenticated;
grant execute on function public.ai_scenarios_for(uuid)            to authenticated;
grant execute on function public.ai_history(uuid)                  to authenticated;
grant execute on function public.ai_conversation(uuid)             to authenticated;
grant execute on function public.ai_prepare(uuid, text, uuid, jsonb, text) to authenticated;
grant execute on function public.ai_finish(uuid, text, text, int, int, numeric, boolean, jsonb) to service_role;
grant usage on schema public, app to service_role;
grant execute on function app.ai_settings_of(uuid), app.ai_calls_today(uuid), app.profile_tz(uuid) to service_role;

notify pgrst, 'reload schema';
commit;
