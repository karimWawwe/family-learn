-- ============================================================================
--  Family Learn - math games: "جدول الضرب" (times tables) and "تعلّم الوقت" (clock)
--  + prophets stories in the existing bedtime-stories section
--  + the follow report now counts the math games too.
--
--  Needs migrations 0001-0008. Safe to run again: progress is kept.
--  Rules enforced here:
--   * a child's phone reads and writes only its own math progress;
--   * clock levels open one after another (level n needs a finished level n-1);
--   * numbers sent by the app are checked and capped.
-- ============================================================================

do $$
begin
  if to_regclass('public.math_plays') is null then
    create table public.math_plays (
      id          bigint generated always as identity primary key,
      profile_id  uuid not null references public.profiles (id) on delete cascade,
      game        text not null check (game in ('times', 'clock')),
      level       text not null,
      correct     int  not null check (correct >= 0),
      total       int  not null check (total between 1 and 30),
      stars       int  not null check (stars between 1 and 3),
      points      int  not null check (points >= 0),
      seconds     int  not null default 0 check (seconds between 0 and 3600),
      created_at  timestamptz not null default now(),
      check (correct <= total)
    );
    create index math_plays_profile on public.math_plays (profile_id, created_at desc);
    alter table public.math_plays enable row level security;
    revoke all on public.math_plays from anon, authenticated;
  end if;
end $$;

-- ---------------------------------------------------------------- helpers
create or replace function app.math_level_ok(p_game text, p_level text) returns boolean
language sql immutable set search_path = '' as $$
  select case p_game
    when 'times' then p_level ~ '^(t([1-9]|1[0-2])|mixed)-(easy|medium|hard)$'
    when 'clock' then p_level ~ '^clock-[1-5]$'
    else false end
$$;

create or replace function app.math_minutes(p_profile uuid, d1 date, d2 date, tz text) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(seconds), 0) / 60.0 from public.math_plays
   where profile_id = p_profile and (created_at at time zone tz)::date between d1 and d2
$$;

-- Points: the best result of every game level (replays can only improve it).
create or replace function app.math_best_points(p_profile uuid) returns int
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(b.best), 0)::int
    from (select max(points) best from public.math_plays where profile_id = p_profile group by game, level) b
$$;

create or replace function app.clock_level_open(p_profile uuid, p_level text) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_level = 'clock-1'
      or exists (select 1 from public.math_plays
                  where profile_id = p_profile and game = 'clock'
                    and level = 'clock-' || (substring(p_level from 7)::int - 1))
$$;

revoke all on function app.math_level_ok(text, text) from public, anon;
revoke all on function app.math_minutes(uuid, date, date, text) from public, anon;
revoke all on function app.math_best_points(uuid) from public, anon;
revoke all on function app.clock_level_open(uuid, text) from public, anon;
grant execute on function app.math_level_ok(text, text) to authenticated;
grant execute on function app.math_minutes(uuid, date, date, text) to authenticated;
grant execute on function app.math_best_points(uuid) to authenticated;
grant execute on function app.clock_level_open(uuid, text) to authenticated;

-- ---------------------------------------------------------------- API (RPC)

-- Best result of every level the child played, plus totals.
create or replace function public.math_state(p_profile uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform app.require_profile(p_profile);
  return jsonb_build_object(
    'levels', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'game', b.game, 'level', b.level, 'best_stars', b.best_stars, 'best_points', b.best_points,
               'best_correct', b.best_correct, 'total', b.total, 'plays', b.plays, 'last_at', b.last_at)
             order by b.game, b.level), '[]'::jsonb)
        from (select game, level, max(stars) best_stars, max(points) best_points, max(correct) best_correct,
                     max(total) total, count(*) plays, max(created_at) last_at
                from public.math_plays where profile_id = p_profile group by game, level) b),
    'points', app.math_best_points(p_profile),
    'stars', (select coalesce(sum(m), 0) from (select max(stars) m from public.math_plays
                                               where profile_id = p_profile group by game, level) x),
    'rounds', (select count(*) from public.math_plays where profile_id = p_profile));
end $$;

-- One round played to the end. Returns the new state.
create or replace function public.math_finish(
  p_profile uuid, p_game text, p_level text, p_correct int, p_total int, p_stars int, p_points int, p_seconds int
) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform app.require_profile(p_profile);
  if not app.math_level_ok(p_game, p_level) then perform app.fail('not_found'); end if;
  if p_game = 'clock' and not app.clock_level_open(p_profile, p_level) then perform app.fail('lesson_locked'); end if;
  if coalesce(p_total, 0) not between 1 and 30 then perform app.fail('unknown'); end if;
  if (select count(*) from public.math_plays
       where profile_id = p_profile and created_at > now() - interval '1 minute') >= 10 then
    perform app.fail('rate_limited');
  end if;
  insert into public.math_plays (profile_id, game, level, correct, total, stars, points, seconds)
  values (p_profile, p_game, p_level,
          least(greatest(coalesce(p_correct, 0), 0), p_total),
          p_total,
          least(greatest(coalesce(p_stars, 1), 1), 3),
          least(greatest(coalesce(p_points, 0), 0), p_total * 20 + 30),
          least(greatest(coalesce(p_seconds, 0), 0), 3600));
  return public.math_state(p_profile);
end $$;

revoke all on function public.math_state(uuid) from public, anon;
revoke all on function public.math_finish(uuid, text, text, int, int, int, int, int) from public, anon;
grant execute on function public.math_state(uuid) to authenticated;
grant execute on function public.math_finish(uuid, text, text, int, int, int, int, int) to authenticated;

-- ---------------------------------------------------------------- prophets stories (same section)
alter table public.bedtime_stories drop constraint if exists bedtime_stories_kind_check;
alter table public.bedtime_stories add constraint bedtime_stories_kind_check
  check (kind in ('value', 'hadith', 'prophet'));

-- ---------------------------------------------------------------- display name
-- The child's name is shown as "Yassin" (only the shown name; ids and progress stay the same).
update public.profiles set display_name = 'Yassin'
 where kind = 'child' and lower(btrim(display_name)) in ('yasen', 'yaseen', 'yassen', 'yasin', 'ياسين', 'يسين');

-- ============================================================================
--  Parent follow report (latest version): lessons + speaking game + stories
--  + math games (times tables, clock). Generated into the newest migration.
-- ============================================================================

-- ---------------------------------------------------------------- follow report helpers

-- Speaking-game minutes per day, estimated from the saved tries:
-- time to the next try (max 60 s), 20 s for the last try of a session.
create or replace function app.speak_minutes(p_profile uuid, d1 date, d2 date, tz text) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(case when nxt is null or nxt - created_at > interval '5 minutes' then 20
                           else least(extract(epoch from (nxt - created_at)), 60) end), 0) / 60.0
    from (select created_at, lead(created_at) over (order by created_at) nxt
            from public.speak_attempts where profile_id = p_profile) a
   where (created_at at time zone tz)::date between d1 and d2
$$;

-- Days (in the family time zone) with any saved activity.
create or replace function app.active_days(p_profile uuid, d1 date, d2 date, tz text) returns setof date
language sql stable security definer set search_path = '' as $$
  select distinct d from (
    select (started_at at time zone tz)::date d from public.lesson_attempts where profile_id = p_profile
    union all
    select (created_at at time zone tz)::date from public.speak_attempts where profile_id = p_profile
    union all
    select (started_at at time zone tz)::date from public.bedtime_listens where profile_id = p_profile
    union all
    select (created_at at time zone tz)::date from public.math_plays where profile_id = p_profile
  ) x where d between d1 and d2
$$;

-- All figures for one date range.
create or replace function app.follow_range(p_profile uuid, d1 date, d2 date, tz text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_lesson numeric; v_story numeric; v_speak numeric; v_math numeric;
  r jsonb;
begin
  select coalesce(sum(app.attempt_minutes(a)), 0) into v_lesson
    from public.lesson_attempts a
   where a.profile_id = p_profile and a.finished_at is not null
     and (a.finished_at at time zone tz)::date between d1 and d2;
  select coalesce(sum(seconds), 0) / 60.0 into v_story
    from public.bedtime_listens where profile_id = p_profile
     and (started_at at time zone tz)::date between d1 and d2;
  v_speak := app.speak_minutes(p_profile, d1, d2, tz);
  v_math := app.math_minutes(p_profile, d1, d2, tz);

  select jsonb_build_object(
    'from', d1, 'to', d2,
    'minutes_lessons', round(v_lesson),
    'minutes_stories', round(v_story),
    'minutes_speaking', round(v_speak),
    'minutes_math', round(v_math),
    'minutes_total', ceil(v_lesson + v_story + v_speak + v_math),
    'math_rounds', (select count(*) from public.math_plays
                     where profile_id = p_profile and (created_at at time zone tz)::date between d1 and d2),
    'math_correct', (select coalesce(sum(correct), 0) from public.math_plays
                      where profile_id = p_profile and (created_at at time zone tz)::date between d1 and d2),
    'math_total', (select coalesce(sum(total), 0) from public.math_plays
                    where profile_id = p_profile and (created_at at time zone tz)::date between d1 and d2),
    'days_used', (select count(*) from app.active_days(p_profile, d1, d2, tz)),
    'stories_listened', (select count(*) from public.bedtime_listens
                          where profile_id = p_profile and (started_at at time zone tz)::date between d1 and d2),
    'stories_completed', (select count(*) from public.bedtime_listens
                           where profile_id = p_profile and completed_at is not null
                             and (completed_at at time zone tz)::date between d1 and d2),
    'values', (select coalesce(jsonb_agg(distinct s.value_name), '[]'::jsonb)
                 from public.bedtime_listens l join public.bedtime_stories s on s.id = l.story_id
                where l.profile_id = p_profile and l.completed_at is not null
                  and (l.completed_at at time zone tz)::date between d1 and d2),
    'lessons_done', (select count(*) from public.lesson_attempts
                      where profile_id = p_profile and finished_at is not null
                        and (finished_at at time zone tz)::date between d1 and d2),
    'questions', (select count(*) from public.answers an join public.lesson_attempts a on a.id = an.attempt_id
                   where a.profile_id = p_profile and (an.answered_at at time zone tz)::date between d1 and d2),
    'correct', (select count(*) filter (where an.is_correct) from public.answers an
                  join public.lesson_attempts a on a.id = an.attempt_id
                 where a.profile_id = p_profile and (an.answered_at at time zone tz)::date between d1 and d2),
    'speak_words', (select count(distinct lower(word)) from public.speak_attempts
                     where profile_id = p_profile and result = 'correct'
                       and (created_at at time zone tz)::date between d1 and d2),
    'speak_levels', (select count(*) from public.speak_plays
                      where profile_id = p_profile and (created_at at time zone tz)::date between d1 and d2),
    'speak_points', (select coalesce(sum(points), 0) from public.speak_plays
                      where profile_id = p_profile and (created_at at time zone tz)::date between d1 and d2)
  ) into r;
  return r;
end $$;

revoke all on function app.speak_minutes(uuid, date, date, text) from public, anon;
revoke all on function app.active_days(uuid, date, date, text) from public, anon;
revoke all on function app.follow_range(uuid, date, date, text) from public, anon;
grant execute on function app.speak_minutes(uuid, date, date, text) to authenticated;
grant execute on function app.active_days(uuid, date, date, text) to authenticated;
grant execute on function app.follow_range(uuid, date, date, text) to authenticated;

-- ---------------------------------------------------------------- follow report (parent only)
-- p_period: day (today vs yesterday) | week (last 7 days vs the 7 before)
--           | month (last 30 days vs the 30 before)
create or replace function public.parent_follow(p_profile uuid, p_period text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  tz    text;
  today date;
  n     int;
  v_xp  int;
  v_speak_pts int;
  v_math_pts int;
  v_stories_done int;
  v_top text;
  r     jsonb;
begin
  if not app.i_am_parent() then perform app.fail('parent_only'); end if;
  perform app.require_profile(p_profile);
  tz := app.profile_tz(p_profile);
  today := (now() at time zone tz)::date;
  n := case p_period when 'day' then 1 when 'month' then 30 else 7 end;

  select coalesce(sum(xp), 0) into v_xp from public.lesson_attempts
   where profile_id = p_profile and finished_at is not null;
  -- best result of each speaking stage (replays improve it, they don't add up)
  v_speak_pts := app.speak_best_points(p_profile);
  v_math_pts := app.math_best_points(p_profile);
  select count(*) into v_stories_done from public.bedtime_listens
   where profile_id = p_profile and completed_at is not null;
  select s.value_name into v_top
    from public.bedtime_listens l join public.bedtime_stories s on s.id = l.story_id
   where l.profile_id = p_profile and l.completed_at is not null
   group by s.value_name order by count(*) desc, max(l.completed_at) desc limit 1;

  r := jsonb_build_object(
    'period', case n when 1 then 'day' when 30 then 'month' else 'week' end,
    'today', today,
    'current', app.follow_range(p_profile, today - (n - 1), today, tz),
    'previous', app.follow_range(p_profile, today - (2 * n - 1), today - n, tz),
    'by_day', (
      select jsonb_agg(jsonb_build_object(
               'day', d,
               'minutes', ceil(
                   coalesce((select sum(app.attempt_minutes(a)) from public.lesson_attempts a
                              where a.profile_id = p_profile and a.finished_at is not null
                                and (a.finished_at at time zone tz)::date = d), 0)
                 + coalesce((select sum(seconds) / 60.0 from public.bedtime_listens
                              where profile_id = p_profile and (started_at at time zone tz)::date = d), 0)
                 + app.speak_minutes(p_profile, d, d, tz)
                 + app.math_minutes(p_profile, d, d, tz))) order by d)
        from generate_series(today - (greatest(n, 7) - 1), today, interval '1 day') g(dd),
             lateral (select g.dd::date d) x),
    'totals', jsonb_build_object(
      'minutes', (app.follow_range(p_profile, '2000-01-01'::date, today, tz) ->> 'minutes_total')::int,
      'days', (select count(*) from app.active_days(p_profile, '2000-01-01'::date, today, tz)),
      'stories_listened', (select count(*) from public.bedtime_listens where profile_id = p_profile),
      'stories_completed', v_stories_done,
      'distinct_stories', (select count(distinct story_id) from public.bedtime_listens
                            where profile_id = p_profile and completed_at is not null),
      'lessons_done', (select count(distinct lesson_id) from public.lesson_attempts
                        where profile_id = p_profile and finished_at is not null),
      'speak_words', (select count(distinct lower(word)) from public.speak_attempts
                       where profile_id = p_profile and result = 'correct'),
      'speak_levels_done', (select count(distinct level_id) from public.speak_plays where profile_id = p_profile)),
    'progress', jsonb_build_object(
      'points', v_xp + v_speak_pts + v_math_pts + 20 * v_stories_done,
      'lesson_xp', v_xp, 'speak_points', v_speak_pts, 'math_points', v_math_pts, 'story_points', 20 * v_stories_done,
      'level', 1 + (v_xp + v_speak_pts + v_math_pts + 20 * v_stories_done) / 500,
      'into_level', (v_xp + v_speak_pts + v_math_pts + 20 * v_stories_done) % 500),
    'last_story', (
      select jsonb_build_object('id', s.id, 'title', s.title, 'emoji', s.emoji, 'value', s.value_name,
                                'completed', l.completed_at is not null, 'at', l.updated_at)
        from public.bedtime_listens l join public.bedtime_stories s on s.id = l.story_id
       where l.profile_id = p_profile order by l.updated_at desc limit 1),
    'favorites', (
      select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'emoji', s.emoji)
                                order by f.created_at desc), '[]'::jsonb)
        from public.bedtime_favorites f join public.bedtime_stories s on s.id = f.story_id
       where f.profile_id = p_profile),
    'values_all', (
      select coalesce(jsonb_agg(jsonb_build_object('value', v.value_name, 'count', v.n) order by v.n desc), '[]'::jsonb)
        from (select s.value_name, count(*) n
                from public.bedtime_listens l join public.bedtime_stories s on s.id = l.story_id
               where l.profile_id = p_profile and l.completed_at is not null
               group by s.value_name) v),
    'top_value', v_top,
    'last_activity', (
      select jsonb_build_object('kind', x.kind, 'title', x.title, 'at', x.at)
        from (
          select 'lesson' kind, le.title, a.finished_at at
            from public.lesson_attempts a join public.lessons le on le.id = a.lesson_id
           where a.profile_id = p_profile and a.finished_at is not null
          union all
          select 'speak', sl.title, sa.created_at
            from public.speak_attempts sa join public.speak_levels sl on sl.id = sa.level_id
           where sa.profile_id = p_profile
          union all
          select 'story', s.title, coalesce(l.completed_at, l.updated_at)
            from public.bedtime_listens l join public.bedtime_stories s on s.id = l.story_id
           where l.profile_id = p_profile
          union all
          select 'math', case mp.game when 'times' then 'جدول الضرب' else 'تعلّم الوقت' end, mp.created_at
            from public.math_plays mp
           where mp.profile_id = p_profile
        ) x order by x.at desc limit 1),
    -- a story to suggest: not finished yet; same value as the favourite theme first,
    -- then a value the child has not met yet, then any unfinished story.
    'suggestion', (
      select jsonb_build_object('id', s.id, 'title', s.title, 'emoji', s.emoji, 'value', s.value_name)
        from public.bedtime_stories s
       where app.bedtime_fits(p_profile, s)
         and not exists (select 1 from public.bedtime_listens l
                          where l.profile_id = p_profile and l.story_id = s.id and l.completed_at is not null)
       order by (s.value_name = v_top) desc nulls last,
                exists (select 1 from public.bedtime_listens l2 join public.bedtime_stories s2 on s2.id = l2.story_id
                         where l2.profile_id = p_profile and l2.completed_at is not null
                           and s2.value_name = s.value_name),
                s.sort
       limit 1),
    'tricky_words', (
      select coalesce(jsonb_agg(t.word), '[]'::jsonb)
        from (select word from public.speak_attempts
               where profile_id = p_profile and result in ('close', 'wrong')
                 and created_at > now() - interval '14 days'
               group by word order by count(*) desc limit 3) t),
    'weak_skills', (
      select coalesce(jsonb_agg(w.name), '[]'::jsonb)
        from (select sk.name
                from public.answers an
                join public.lesson_attempts a on a.id = an.attempt_id
                join public.questions q on q.id = an.question_id
                join public.skills sk on sk.code = q.skill
               where a.profile_id = p_profile and an.answered_at > now() - interval '30 days'
               group by sk.name
              having count(*) >= 3 and avg(case when an.is_correct then 1.0 else 0 end) < 0.6
               order by avg(case when an.is_correct then 1.0 else 0 end) limit 2) w)
  );
  return r;
end $$;

revoke all on function public.parent_follow(uuid, text) from public, anon;
grant execute on function public.parent_follow(uuid, text) to authenticated;

-- ---------------------------------------------------------------- stories (now with the prophets stories)

do $$
declare
  st jsonb;
  data jsonb := $json$[{"id":"s01-honest-rabbit","sort":10,"title":"الأرنب الصادق","emoji":"🐰","value_code":"sidq","value_name":"الصدق","kind":"value","minutes":4,"source":"","min_grade":1,"max_grade":12,"pages":[{"bg":"garden","scene":["🐰","🌷","🏡"],"text":"في قريةٍ صغيرةٍ خضراء، كان يعيش أرنبٌ أبيضُ لطيفٌ اسمه رَنّوش. كان رنّوش يحبُّ القفزَ بين الأزهار، ويحبُّ جدّتَه الأرنبةَ العجوزَ كثيرًا. وكانت جدّتُه تزرعُ في شرفةِ بيتها أصيصًا جميلًا فيه زهرةٌ حمراءُ، تسقيها كلَّ صباحٍ وتبتسمُ لها، وتقول: هذه الزهرةُ هديةٌ من جدِّك، أحبُّها كثيرًا."},{"bg":"garden","scene":["🐰","⚽","🪴"],"text":"وفي يومٍ مشمس، كان رنّوش يلعبُ بالكرةِ قربَ الشرفة. ركلَ الكرةَ بقوّةٍ فارتفعتْ عاليًا، ثم نزلتْ على الأصيص، فسقطَ على الأرض، وانكسرَ قليلًا، وتناثرَ التراب. توقّفَ رنّوش مكانَه، ونظرَ إلى الزهرةِ الحمراءِ المائلة، وشعرَ بقلبِه يدقُّ بسرعة."},{"bg":"garden","scene":["🐰","🤔","🌳"],"text":"لم يكنْ أحدٌ قد رآه. فكّرَ رنّوش: هل أختبئُ خلفَ الشجرة؟ هل أقولُ إنَّ الريحَ هي التي أسقطتْه؟ لكنَّه تذكّرَ كلامَ أمِّه حين قالت له: الصدقُ يا صغيري نورٌ في القلب، ومَن يقولُ الحقَّ يرتاحُ ويطمئنّ. أخذَ رنّوش نفسًا عميقًا، ثم نفسًا آخر، وقرّرَ أنْ يكونَ صادقًا."},{"bg":"home","scene":["🐰","👵","🪴"],"text":"مشى رنّوش ببطءٍ إلى جدّتِه، وقال بصوتٍ هادئ: جدّتي، أنا آسف. كنتُ ألعبُ بالكرة، فأسقطتُ الأصيصَ من غيرِ قصد، وانكسرَ قليلًا. نظرتْ إليه الجدّةُ طويلًا، ثم ابتسمتْ ابتسامةً دافئة، وضمّتْه إلى صدرِها، وقالت: شكرًا لأنّك قلتَ الحقيقة يا رنّوش. الأصيصُ يمكنُ إصلاحُه، أمّا الصدقُ فهو أغلى من كلِّ الأصص."},{"bg":"garden","scene":["🐰","👵","🌷"],"text":"ثم قالت الجدّة: تعالَ نُصلحْه معًا. أحضرا أصيصًا جديدًا، ووضعا فيه ترابًا ناعمًا، وزرعا الزهرةَ الحمراءَ بعناية، وسقياها بالماء. وبعد أيّامٍ قليلة، صارت الزهرةُ أجملَ من قبل، وظهرتْ بجانبِها زهرةٌ صغيرةٌ جديدة. قالت الجدّة وهي تضحك: انظرْ يا رنّوش، حتّى الزهرةُ فرحتْ بصدقِك."},{"bg":"night","scene":["🐰","🌙","✨"],"text":"في تلك الليلة، نامَ رنّوش في سريرِه الدافئ وهو مرتاحُ البال. لم يكنْ في قلبِه خوفٌ ولا همّ، لأنَّه قال الحقيقة. نظرَ إلى القمرِ من النافذة، وهمسَ: الصدقُ يجعلُ القلبَ خفيفًا مثلَ الريشة. ثم أغمضَ عينيه، ونامَ نومًا هادئًا جميلًا. تصبحُ على خير يا صغيري، وكنْ دائمًا صادقًا مثلَ رنّوش."}],"question":{"q":"ماذا فعلَ رنّوش بعدَ أنْ انكسرَ الأصيص؟","options":["اختبأَ خلفَ الشجرة","قالَ الحقيقةَ لجدّتِه","قالَ إنَّ الريحَ أسقطتْه"],"answer":1},"activity":"قبلَ أنْ تنام، تذكّرْ موقفًا قلتَ فيه الحقيقة، واحكِه لأمِّك أو لأبيك بصوتٍ هادئ."},
{"id":"s02-blue-bag","sort":20,"title":"الحقيبةُ الزرقاء","emoji":"🎒","value_code":"amana","value_name":"الأمانة","kind":"value","minutes":4,"source":"","min_grade":1,"max_grade":12,"pages":[{"bg":"garden","scene":["👦","🌳","🪑"],"text":"كان سالمٌ ولدًا في الثامنةِ من عمرِه، يحبُّ الذهابَ مع أبيه إلى الحديقةِ القريبةِ من البيت كلَّ مساء. هناك يركضُ على العشبِ الأخضر، ويُطعمُ العصافيرَ فُتاتَ الخبز، ويجلسُ مع أبيه على المقعدِ الخشبيِّ يتحدّثان ويضحكان حتّى تغيبَ الشمس."},{"bg":"garden","scene":["👦","🎒","🪑"],"text":"وفي مساءٍ هادئ، رأى سالمٌ حقيبةً زرقاءَ صغيرةً تحتَ أحدِ المقاعد. نظرَ حولَه فلم يجدْ أحدًا. فتحَ الحقيبةَ بلطفٍ ليعرفَ صاحبَها، فوجدَ فيها نقودًا، ومفاتيحَ، وصورةً لطفلةٍ صغيرةٍ تبتسم، وبطاقةً مكتوبًا عليها اسمٌ ورقمُ هاتف."},{"bg":"garden","scene":["👦","💭","🍦"],"text":"خطرَ في بالِ سالمٍ خاطرٌ صغير: بهذه النقودِ أستطيعُ أنْ أشتريَ مثلّجاتٍ كثيرة. لكنّه هزَّ رأسَه وقال في نفسِه: هذه ليستْ لي، إنّها أمانة. وتذكّرَ أنَّ صاحبَ الحقيبةِ قد يكونُ حزينًا الآن ويبحثُ عنها في كلِّ مكان. حملَ الحقيبةَ بحرصٍ، وركضَ إلى أبيه."},{"bg":"garden","scene":["👨","👦","📱"],"text":"قال سالم: يا أبي، وجدتُ هذه الحقيبة، وفيها رقمُ هاتفِ صاحبِها. ابتسمَ الأبُ وربّتَ على كتفِه وقال: أحسنتَ يا بنيّ، هيّا نتّصلُ به. اتّصلَ الأبُ بالرقم، فأجابتْه امرأةٌ بصوتٍ قلق، وقالت: نعم، إنّها حقيبتي، أضعتُها وأنا ألعبُ مع ابنتي، وقد بحثتُ عنها طويلًا."},{"bg":"garden","scene":["👩","👧","🎒"],"text":"بعدَ دقائقَ جاءتْ المرأةُ ومعها ابنتُها الصغيرة، الطفلةُ نفسُها التي في الصورة. سلّمَها سالمٌ الحقيبةَ كما هي، لم ينقصْ منها شيء. فرحتِ المرأةُ فرحًا كبيرًا، وقالت: جزاك اللهُ خيرًا يا سالم، أنتَ ولدٌ أمين. وأهدتْه الطفلةُ الصغيرةُ وردةً بيضاءَ وهي تبتسم."},{"bg":"night","scene":["👦","🌼","🌙"],"text":"في طريقِ العودة، قال الأبُ: يا سالم، الأمانةُ أنْ نحفظَ أشياءَ الناسِ ونردَّها إليهم، والأمينُ يحبُّه اللهُ ويحبُّه الناس. وفي الليل، وضعَ سالمٌ الوردةَ البيضاءَ في كوبِ ماءٍ بجانبِ سريرِه، ونظرَ إليها وهو يشعرُ بسعادةٍ لا تُشترى بالنقود. ثم أغمضَ عينيه ونامَ مطمئنًّا. تصبحُ على خير يا صغيري الأمين."}],"question":{"q":"ماذا فعلَ سالمٌ بالحقيبةِ الزرقاء؟","options":["اشترى بها مثلّجات","تركَها تحتَ المقعد","أعادَها إلى صاحبتِها"],"answer":2},"activity":"اختَرْ مع أهلِك مكانًا ثابتًا لأغراضِك وأغراضِ إخوتِك، وتذكّرْ أنْ تُعيدَ كلَّ شيءٍ تستعيرُه إلى صاحبِه."},
{"id":"s03-warm-milk","sort":30,"title":"كوبُ الحليبِ الدافئ","emoji":"🥛","value_code":"birr","value_name":"بِرُّ الوالدين","kind":"value","minutes":3,"source":"","min_grade":1,"max_grade":12,"pages":[{"bg":"home","scene":["👧","👩","🏠"],"text":"كانت نور طفلةً لطيفةً تحبُّ أمَّها كثيرًا. كلَّ يومٍ تستيقظُ الأمُّ مبكّرًا، تُعدُّ الفطور، وترتّبُ البيت، وتذهبُ إلى عملِها، ثم تعودُ لتطبخَ الغداءَ وتساعدَ نورَ في دروسِها. وكانت نورُ تلاحظُ أنَّ أمَّها تفعلُ أشياءَ كثيرةً من أجلِها ومن أجلِ إخوتِها."},{"bg":"dusk","scene":["👩","🛋️","😴"],"text":"وفي مساءِ أحدِ الأيّام، جلستِ الأمُّ على الأريكةِ وقد بدا عليها التعب. وضعتْ يدَها على رأسِها وأغمضتْ عينيها قليلًا. نظرتْ نورُ إليها وفكّرتْ: أمّي تتعبُ كثيرًا من أجلنا، ماذا أستطيعُ أنْ أفعلَ لأُسعِدَها؟"},{"bg":"home","scene":["👧","🥛","🍯"],"text":"ذهبتْ نورُ إلى المطبخِ بهدوء، وطلبتْ من أبيها أنْ يساعدَها. سخّنا معًا كوبًا من الحليب، ووضعتْ فيه نورُ ملعقةً صغيرةً من العسل. ثم أخذتْ وسادةً ناعمة، وبطّانيّةً خفيفة، ومشتْ على أطرافِ أصابعِها حتّى لا تُزعجَ أمَّها."},{"bg":"home","scene":["👧","👩","💝"],"text":"وضعتْ نورُ الوسادةَ خلفَ ظهرِ أمِّها، وغطّتْ قدميها بالبطّانيّة، وقدّمتْ لها كوبَ الحليبِ الدافئ، وقالت بصوتٍ رقيق: تفضّلي يا أمّي، أنتِ تتعبين من أجلنا، وأنا أحبُّك كثيرًا. فتحتِ الأمُّ عينيها، وامتلأ وجهُها بالفرح، وقالت: بارك اللهُ فيكِ يا نور، هذا أجملُ كوبِ حليبٍ شربتُه في حياتي."},{"bg":"home","scene":["👧","🧸","✨"],"text":"ولم تتوقّفْ نورُ عند ذلك، بل رتّبتْ ألعابَها في صندوقِها، ووضعتْ حذاءَها في مكانِه، وساعدتْ أخاها الصغيرَ في جمعِ أقلامِه. قال الأبُ مبتسمًا: يا نور، إنَّ برَّ الوالدين من أحبِّ الأعمالِ إلى الله، والبرُّ يكونُ بالكلمةِ الطيّبة، وبالمساعدة، وبالابتسامة."},{"bg":"night","scene":["👧","👩","🌙"],"text":"وفي الليل، جلستِ الأمُّ بجانبِ سريرِ نور، ومسحتْ على شعرِها، ودعتْ لها: اللهمَّ احفظْ نورَ واجعلْها سعيدةً دائمًا. ابتسمتْ نورُ وقبّلتْ يدَ أمِّها، وقالت: وأنا أدعو لكِ يا أمّي كلَّ ليلة: ربِّ ارحمْهما كما ربّياني صغيرًا. ثم نامتْ نورُ وهي تشعرُ بالدفءِ والحبّ. تصبحُ على خير يا صغيري البارّ."}],"question":{"q":"ماذا قدّمتْ نورُ لأمِّها المتعبة؟","options":["كوبَ حليبٍ دافئٍ ووسادة","لعبةً جديدة","قطعةَ حلوى كبيرة"],"answer":0},"activity":"قبلَ النوم، قلْ لأمِّك أو أبيك كلمةً جميلة، وادعُ لهما: ربِّ ارحمْهما كما ربّياني صغيرًا."},
{"id":"s04-kitten-rain","sort":40,"title":"القطّةُ الصغيرةُ والمطر","emoji":"🐱","value_code":"rahma","value_name":"الرحمة","kind":"value","minutes":3,"source":"","min_grade":1,"max_grade":12,"pages":[{"bg":"dusk","scene":["👦","🌧️","🏠"],"text":"في مساءٍ من أيّامِ الشتاء، كان المطرُ ينزلُ رذاذًا خفيفًا على المدينة، وكان يوسفُ يجلسُ قربَ النافذةِ يسمعُ صوتَ القطراتِ وهي تنقرُ الزجاجَ بلطف: تِك، تِك، تِك. كان الجوُّ باردًا، وكان يوسفُ ملفوفًا ببطّانيّتِه الصوفيّةِ الدافئة."},{"bg":"dusk","scene":["🐱","🌧️","🌳"],"text":"وفجأةً سمعَ صوتًا ضعيفًا: مِياو، مِياو. نظرَ من النافذة، فرأى قطّةً صغيرةً رماديّةً تجلسُ تحتَ الشجرةِ، وقد ابتلَّ فروُها وهي ترتجفُ من البرد. شعرَ يوسفُ بقلبِه يرقُّ لها، وقال: مسكينةٌ هذه القطّة، لا بدَّ أنّها جائعةٌ وبردانة."},{"bg":"home","scene":["👦","👨","☂️"],"text":"أسرعَ يوسفُ إلى أبيه وقال: يا أبي، هناك قطّةٌ صغيرةٌ تحتَ المطر، هل نساعدُها؟ ابتسمَ الأبُ وقال: طبعًا يا يوسف، فالرحمةُ بالحيوانِ من الأخلاقِ التي يحبُّها الله. أخذَ الأبُ المظلّة، وأحضرَ يوسفُ صندوقًا صغيرًا ومنشفةً قديمةً ناعمة."},{"bg":"home","scene":["👦","🐱","📦"],"text":"حملَ الأبُ القطّةَ برفق، ووضعَها يوسفُ في الصندوق، وجفّفَ فروَها بالمنشفةِ بهدوءٍ حتّى توقّفتْ عن الارتجاف. ثم وضعَ لها صحنًا صغيرًا فيه ماءٌ نظيف، وقليلًا من الطعام. أكلتِ القطّةُ حتّى شبعتْ، ثم نظرتْ إلى يوسفَ بعينيها الخضراوين، وأغمضتهما ببطءٍ كأنّها تقولُ له: شكرًا."},{"bg":"home","scene":["🐱","🧶","🔥"],"text":"وضعَ يوسفُ الصندوقَ في زاويةٍ دافئةٍ من البيت، فتكوّرتِ القطّةُ على نفسِها، وبدأتْ تُصدرُ صوتًا ناعمًا: خُرْ، خُرْ، خُرْ. ضحكَ يوسفُ وقال: إنّها سعيدة! قالتِ الأمّ: نعم، وفي الصباحِ نبحثُ عن صاحبِها، فإنْ لم نجدْه فسنعتني بها حتّى تكبرَ وتقوى."},{"bg":"night","scene":["👦","🐱","🌙"],"text":"توقّفَ المطرُ، وخرجَ القمرُ من بين الغيوم، ولمعتِ النجوم. استلقى يوسفُ في سريرِه، وقال لأمِّه: يا أمّي، شعرتُ بفرحٍ كبيرٍ حين ساعدتُ القطّة. قالتِ الأمّ: هذه هي الرحمة يا بنيّ، مَن يرحمُ الصغيرَ والضعيفَ يرحمُه الله. أغمضَ يوسفُ عينيه، ونامَ وهو يبتسم، وفي الزاويةِ نامتِ القطّةُ الصغيرةُ في دفءٍ وأمان."}],"question":{"q":"كيف ساعدَ يوسفُ القطّةَ الصغيرة؟","options":["تركَها تحتَ المطر","جفّفَها وأطعمَها ووضعَها في مكانٍ دافئ","أغلقَ النافذة ونام"],"answer":1},"activity":"اسألْ أهلَك: كيف نستطيعُ أنْ نرحمَ الحيوانات؟ مثلًا: نضعُ ماءً للعصافيرِ على الشرفةِ في الأيّامِ الحارّة."},
{"id":"s05-squirrel-bridge","sort":50,"title":"جسرُ السنجاب","emoji":"🐿️","value_code":"help","value_name":"مساعدةُ الآخرين","kind":"value","minutes":3,"source":"","min_grade":1,"max_grade":12,"pages":[{"bg":"forest","scene":["🐿️","🌲","🌰"],"text":"في غابةٍ هادئةٍ تغنّي فيها العصافير، كان يعيشُ سنجابٌ نشيطٌ اسمه بُندُق. كان بندقُ يحبُّ جمعَ الجوزِ والبلّوط، ويقفزُ من شجرةٍ إلى شجرةٍ بخفّة. وفي وسطِ الغابةِ كان يجري جدولٌ صغير، ماؤه صافٍ ولامع، يسمعُ الجميعُ خريرَه الجميل."},{"bg":"forest","scene":["🐢","🦔","🌊"],"text":"وفي صباحِ أحدِ الأيّام، اشتدَّ ماءُ الجدولِ بعد ليلةٍ ممطرة، فصارَ أعرضَ من قبل. وعلى ضفّتِه وقفتِ السلحفاةُ العجوز، والقنفذُ الصغير، والأرنبةُ الأمُّ مع صغارِها، ينظرون إلى الضفّةِ الأخرى حيثُ الأشجارُ المثمرة، ولا يستطيعون العبور."},{"bg":"forest","scene":["🐿️","💡","🪵"],"text":"رآهم بندقُ من فوقِ الشجرة، فنزلَ وسألهم بلطف: ما بكم يا أصدقائي؟ قالتِ السلحفاة: نريدُ أنْ نعبرَ إلى الضفّةِ الأخرى، لكنَّ الماءَ صارَ واسعًا. فكّرَ بندقُ قليلًا، ثم لمعتْ في رأسِه فكرة، وقال: لا تقلقوا، سنصنعُ معًا جسرًا صغيرًا."},{"bg":"forest","scene":["🐿️","🦫","🪵"],"text":"ذهبَ بندقُ إلى صديقِه القُندُس، وطلبَ منه المساعدة، فجاءَ القندسُ مسرورًا. دحرجا معًا جذعًا طويلًا كان ملقًى على الأرض، ووضعاه فوقَ الجدولِ من ضفّةٍ إلى ضفّة، وثبّتاه بالحجارةِ والأغصان. وجمعتِ الأرنبةُ أوراقًا عريضةً وفرشتْها فوقَ الجذعِ حتّى لا يكونَ زلِقًا."},{"bg":"forest","scene":["🐢","🐇","🦔"],"text":"مشى الجميعُ على الجسرِ واحدًا بعد الآخر، ببطءٍ وهدوء. أمسكَ بندقُ بيدِ القنفذِ الصغير، وسارَ بجانبِ السلحفاةِ العجوزِ خطوةً خطوة، حتّى وصلوا جميعًا إلى الضفّةِ الأخرى سالمين. قالتِ السلحفاةُ بصوتٍ دافئ: شكرًا يا بندق، لقد جعلتَ يومَنا جميلًا."},{"bg":"night","scene":["🐿️","🌰","🌙"],"text":"وفي المساء، رجعَ بندقُ إلى بيتِه في جذعِ الشجرةِ العالية، فوجدَ عند بابِه كومةً من الجوزِ والتوت، هديّةً من أصدقائِه. ابتسمَ وقال: عندما نساعدُ غيرَنا، تمتلئُ قلوبُنا بالفرح. ثم تكوّرَ في عشِّه الناعم، ولفَّ ذيلَه الكبيرَ حولَه مثلَ بطّانيّة، ونامَ على صوتِ الجدولِ الهادئ. تصبحُ على خير يا صغيري المساعد."}],"question":{"q":"كيف ساعدَ بندقُ أصدقاءَه على عبورِ الجدول؟","options":["صنعَ معهم جسرًا من جذعِ شجرة","حملَهم على ظهرِه","قالَ لهم: ارجعوا إلى بيوتكم"],"answer":0},"activity":"فكّرْ في شيءٍ صغيرٍ تساعدُ به أحدًا غدًا: أنْ تحملَ شيئًا مع أمِّك، أو تُعيرَ قلمَك لصديقِك."},
{"id":"s06-broken-kite","sort":60,"title":"الطائرةُ الورقيّة","emoji":"🪁","value_code":"afw","value_name":"العفوُ والتسامح","kind":"value","minutes":4,"source":"","min_grade":1,"max_grade":12,"pages":[{"bg":"garden","scene":["👦","🪁","☁️"],"text":"كان عمّارٌ يحبُّ طائرتَه الورقيّةَ الملوّنةَ كثيرًا. صنعَها مع جدِّه من الورقِ الأزرقِ والأصفر، وربطا بها ذيلًا طويلًا من الشرائطِ الحمراء. وفي كلِّ عصرٍ كان يخرجُ إلى الساحةِ الواسعة، فيطيّرُها عاليًا في السماء، وتتراقصُ مع النسيمِ كأنّها عصفورٌ سعيد."},{"bg":"garden","scene":["👦","👦🏽","🪁"],"text":"وفي يومٍ جاءَ صديقُه خالد، وقال: يا عمّار، هل تسمحُ لي أنْ أطيّرَها قليلًا؟ أعطاه عمّارُ الخيط، وقال: انتبهْ، إنّها غالية عليّ. ركضَ خالدٌ فرحًا، لكنَّ قدمَه تعثّرتْ بحجر، فسقطَ، وسقطتِ الطائرةُ على الأرضِ، وانكسرَ عودٌ من أعوادِها، وتمزّقَ طرفُ الورق."},{"bg":"garden","scene":["👦","😢","🪁"],"text":"شعرَ عمّارُ بالحزن، وكادَ أنْ يصرخَ في وجهِ خالد. لكنّه رأى خالدًا ينهضُ ببطء، ووجهُه حزينٌ جدًّا، وعيناه تلمعان، وقال بصوتٍ خافت: أنا آسفٌ يا عمّار، لم أقصدْ ذلك أبدًا. سكتَ عمّارُ قليلًا، وأخذَ نفسًا عميقًا، وتذكّرَ كلامَ جدِّه: العفوُ يجعلُ القلوبَ أقربَ وأجمل."},{"bg":"garden","scene":["👦","🤝","👦🏽"],"text":"اقتربَ عمّارُ من صديقِه، ووضعَ يدَه على كتفِه، وقال: لا بأسَ يا خالد، أنا أسامحُك، المهمُّ أنّك لم تتأذَّ. ابتسمَ خالدٌ ابتسامةً كبيرة، وكأنَّ حِملًا ثقيلًا نزلَ عن قلبِه، وقال: شكرًا يا عمّار، هيّا نصلحُها معًا."},{"bg":"home","scene":["👴","👦","🪁"],"text":"ذهبَ الصديقان إلى الجدّ، فأحضرَ لهما عودًا جديدًا، وقليلًا من الغراء، وورقةً ملوّنة. ألصقا الورقَ بعناية، وربطا العودَ الجديدَ بالخيط. وأضافَ خالدٌ شريطًا أخضرَ جميلًا إلى الذيل. قالَ الجدُّ وهو يبتسم: انظرا، صارتِ الطائرةُ أجملَ من قبل، مثلَ صداقتِكما بعد التسامح."},{"bg":"night","scene":["🪁","⭐","🌙"],"text":"في اليومِ التالي، طيّرَ الصديقان الطائرةَ معًا، وارتفعتْ عاليًا حتّى بدتْ صغيرةً بين الغيوم. وفي الليل، علّقَ عمّارُ طائرتَه على جدارِ غرفتِه، ونظرَ إليها قبلَ النوم، وقال في نفسِه: لو غضبتُ لخسرتُ صديقي، لكنّي سامحتُ فربحتُه. ثم نامَ مرتاحَ القلب. تصبحُ على خير يا صغيري المتسامح."}],"question":{"q":"ماذا قالَ عمّارُ لخالدٍ بعد أنْ انكسرتِ الطائرة؟","options":["لن ألعبَ معك أبدًا","لا بأس، أنا أسامحُك","اذهبْ واشترِ لي طائرةً جديدة"],"answer":1},"activity":"إذا زعّلك أحدٌ اليوم، فكّرْ: هل أستطيعُ أنْ أسامحَه؟ وإنْ أخطأتَ أنت، فقلْ: أنا آسف."},
{"id":"s07-grandpa-seat","sort":70,"title":"مقعدُ الجدّ","emoji":"👴","value_code":"respect","value_name":"احترامُ الكبير","kind":"value","minutes":3,"source":"","min_grade":1,"max_grade":12,"pages":[{"bg":"home","scene":["👧","🚌","🏙️"],"text":"كانت مريمُ تحبُّ ركوبَ الحافلةِ مع أمِّها يومَ الجمعةِ لزيارةِ بيتِ جدّتِها. كانت تجلسُ قربَ النافذة، وتنظرُ إلى الأشجارِ والبيوتِ وهي تمرُّ واحدةً بعد الأخرى، وتعدُّ السيّاراتِ الحمراءَ في الطريق: واحدة، اثنتان، ثلاث."},{"bg":"home","scene":["👴","🦯","🚌"],"text":"وفي إحدى المحطّات، صعدَ إلى الحافلةِ رجلٌ كبيرٌ في السنّ، شعرُه أبيضُ مثلَ القطن، ويمشي ببطءٍ مستندًا إلى عصاه. نظرَ حولَه فلم يجدْ مقعدًا فارغًا، فوقفَ ممسكًا بالعمودِ، والحافلةُ تهتزُّ به قليلًا."},{"bg":"home","scene":["👧","💭","👴"],"text":"رأتْ مريمُ الرجلَ الكبير، وتذكّرتْ ما قالتْه لها معلّمتُها في المدرسة: الكبيرُ له علينا حقُّ الاحترامِ والتقدير، نقدّمُه في الجلوس، ونخفضُ صوتَنا عند الحديثِ معه، ونساعدُه إذا احتاجَ. نظرتْ إلى أمِّها، فهزّتِ الأمُّ رأسَها مبتسمةً كأنّها فهمتْ ما تفكّرُ فيه."},{"bg":"home","scene":["👧","💺","👴"],"text":"قامتْ مريمُ من مقعدِها، واقتربتْ من الرجلِ، وقالت بأدب: تفضّلْ يا عمّي، اجلسْ مكاني. ابتسمَ الرجلُ ابتسامةً واسعة، وجلسَ ببطء، وقال: شكرًا يا ابنتي، بارك اللهُ فيكِ وفي والديكِ اللذين ربّياكِ هذه التربيةَ الجميلة."},{"bg":"home","scene":["👴","🍬","👧"],"text":"وفي الطريق، حكى الرجلُ الكبيرُ لمريمَ عن أيّامِ صغرِه، وكيف كان يزرعُ النخيلَ مع أبيه، ويسقيه من الفلج. استمعتْ مريمُ إليه باهتمام، ولم تقاطعْه. وعندما وصلَ إلى محطّتِه، أعطاها قطعةَ حلوى صغيرة، وقال: أنتِ جعلتِ رحلتي جميلة."},{"bg":"night","scene":["👧","👵","🌙"],"text":"حكتْ مريمُ القصّةَ لجدّتِها، فضمّتْها الجدّةُ وقالت: يا مريم، ليس منّا مَن لا يرحمُ صغيرَنا ويوقّرُ كبيرَنا، هكذا علّمَنا نبيُّنا صلّى اللهُ عليه وسلّم. وفي تلك الليلة، نامتْ مريمُ في بيتِ جدّتِها، وجدّتُها تمسحُ على رأسِها وتدعو لها. تصبحُ على خير يا صغيري المؤدَّب."}],"question":{"q":"ماذا فعلتْ مريمُ عندما رأتِ الرجلَ الكبيرَ واقفًا؟","options":["أعطتْه مقعدَها","نظرتْ من النافذة","ضحكتْ بصوتٍ عالٍ"],"answer":0},"activity":"في المرّةِ القادمةِ التي ترى فيها جدَّك أو جدّتَك، قبّلْ رأسَه أو يدَه، واسألْه عن قصّةٍ من أيّامِ صغرِه."},
{"id":"s08-kind-word","sort":80,"title":"الكلمةُ الطيّبة","emoji":"😊","value_code":"manners","value_name":"حُسنُ التعامل","kind":"value","minutes":3,"source":"","min_grade":1,"max_grade":12,"pages":[{"bg":"home","scene":["👦","🏪","🍞"],"text":"كان حمدٌ يذهبُ كلَّ صباحٍ مع أبيه إلى المخبزِ الصغيرِ في آخرِ الشارع. وكان صاحبُ المخبزِ رجلًا طيّبًا اسمه العمُّ سعيد، يخبزُ الخبزَ الساخنَ منذُ الفجر، فتفوحُ رائحتُه الجميلةُ في الحيِّ كلِّه."},{"bg":"home","scene":["👨‍🍳","😓","🍞"],"text":"وفي أحدِ الأيّام، كان المخبزُ مزدحمًا جدًّا، والعمُّ سعيدٌ يعملُ بسرعة، ووجهُه متعب. ورأى حمدٌ رجلًا يرفعُ صوتَه ويقول: أسرعْ، لقد تأخّرت! وطفلًا آخرَ يأخذُ الخبزَ دون أنْ يقولَ شيئًا. لاحظَ حمدٌ أنَّ العمَّ سعيدًا صارَ حزينًا قليلًا."},{"bg":"home","scene":["👦","💭","😊"],"text":"فكّرَ حمدٌ: ماذا أستطيعُ أنْ أفعلَ لأُفرحَ العمَّ سعيدًا؟ وتذكّرَ أنَّ أباه قال له مرّة: الكلمةُ الطيّبةُ صدقة، والابتسامةُ في وجهِ أخيك صدقة. فقرّرَ أنْ ينتظرَ دورَه بهدوء، وأنْ يستعدَّ بأجملِ كلامٍ يعرفُه."},{"bg":"home","scene":["👦","👨‍🍳","🥖"],"text":"عندما جاءَ دورُه، ابتسمَ حمدٌ وقال: صباحُ الخيرِ يا عمّي سعيد، من فضلك أريدُ خمسَ خبزات. وعندما أعطاه الخبز، قال: شكرًا جزيلًا، خبزُك أطيبُ خبزٍ في العالم، أعانك اللهُ على تعبِك. توقّفَ العمُّ سعيدٌ لحظة، ثم ضحكَ ضحكةً كبيرة، وزالَ التعبُ عن وجهِه."},{"bg":"home","scene":["👨‍🍳","🥐","👦"],"text":"قال العمُّ سعيد: يا حمد، كلماتُك أراحتْ قلبي أكثرَ من فنجانِ قهوة. وأعطاه كعكةً صغيرةً بالسمسم هديّة. ومنذ ذلك اليوم، صارَ الناسُ في المخبزِ يسمعون حمدًا فيقلّدونه: من فضلك، وشكرًا، وجزاك اللهُ خيرًا، حتّى صارَ المخبزُ أهدأَ وأجمل."},{"bg":"night","scene":["👦","📖","🌙"],"text":"وفي الليل، سألَ حمدٌ أباه: هل الكلماتُ الصغيرةُ تغيّرُ الناسَ فعلًا؟ قال الأب: نعم يا بنيّ، حسنُ التعاملِ مثلُ المطرِ الخفيف، يسقي القلوبَ فتُزهر. ابتسمَ حمدٌ وسحبَ الغطاءَ حتّى كتفيه، وقال: غدًا سأقولُ كلمةً طيّبةً لكلِّ مَن أقابلُه. ثم نامَ هادئًا. تصبحُ على خير يا صاحبَ الكلمةِ الطيّبة."}],"question":{"q":"ما الكلماتُ التي قالها حمدٌ للعمِّ سعيد؟","options":["أسرعْ لقد تأخّرت","من فضلك، وشكرًا جزيلًا","لم يقلْ شيئًا"],"answer":1},"activity":"العبْ مع أهلِك لعبةَ الكلماتِ الطيّبة: كلُّ واحدٍ يقولُ كلمةً جميلةً للآخر قبلَ النوم."},
{"id":"s09-thank-you","sort":90,"title":"نِعَمٌ في غرفتي","emoji":"🤲","value_code":"shukr","value_name":"الشكر","kind":"value","minutes":3,"source":"","min_grade":1,"max_grade":12,"pages":[{"bg":"night","scene":["👧","🛏️","🌙"],"text":"في ليلةٍ هادئة، استلقتْ ليلى في سريرِها، لكنّها لم تستطعِ النومَ بسرعة. كانت منزعجةً قليلًا، لأنّها أرادتْ لعبةً جديدةً رأتْها في المتجر، ولم تشترِها لها أمُّها. قالت ليلى بصوتٍ حزين: يا أمّي، ليس عندي أشياءُ جميلة."},{"bg":"night","scene":["👩","👧","🕯️"],"text":"جلستِ الأمُّ بجانبِها، وأضاءتْ مصباحًا صغيرًا بضوءٍ أصفرَ هادئ، وقالت: هيّا نلعبْ لعبةً قبلَ النوم اسمُها: نِعَمٌ في غرفتي. سنبحثُ عن النِّعمِ التي أعطانا اللهُ إيّاها، وكلّما وجدْنا نعمةً قلنا: الحمدُ لله."},{"bg":"night","scene":["👀","👂","🖐️"],"text":"قالتِ الأمّ: انظري إلى عينيكِ، بهما ترينَ القمرَ والزهورَ ووجهَ أبيكِ. قالت ليلى: الحمدُ لله. وأذناكِ، تسمعين بهما صوتَ المطرِ والعصافير. الحمدُ لله. ويداكِ، ترسمين بهما وتعانقين بهما مَن تحبّين. ابتسمتْ ليلى وقالت: الحمدُ لله، هذه نِعَمٌ كثيرة!"},{"bg":"home","scene":["🛏️","💧","🍎"],"text":"ثم نظرتا حولَهما في الغرفة. قالت ليلى: هذا سريرٌ دافئ، الحمدُ لله. وهذا كوبُ ماءٍ نظيفٍ بجانبي، الحمدُ لله. وهذه تفّاحةٌ للصباح، الحمدُ لله. وهذا البيتُ الذي يحمينا من البردِ والمطر، الحمدُ لله. وصارتْ ليلى تجدُ النِّعمَ في كلِّ زاوية."},{"bg":"home","scene":["👨","👩","👧"],"text":"ثم قالت ليلى بفرح: وأنتِ يا أمّي، وأبي، وأخي الصغير، أنتم أجملُ نعمة! الحمدُ لله. ضمّتْها الأمُّ وقالت: أحسنتِ يا ليلى، ومن شكرِ النعمةِ أنْ نقولَ شكرًا لمن يساعدُنا، وأنْ نستعملَ النِّعمَ في الخير. قالت ليلى: شكرًا يا أمّي على كلِّ ما تفعلينه من أجلي."},{"bg":"night","scene":["👧","🤲","✨"],"text":"نسيتْ ليلى اللعبةَ الجديدةَ تمامًا، وشعرتْ أنَّ قلبَها ممتلئٌ بالرضا. رفعتْ يديها الصغيرتين وقالت: الحمدُ للهِ على كلِّ شيء. أطفأتِ الأمُّ المصباح، وبقيَ ضوءُ القمرِ الفضّيُّ يلمعُ على الوسادة. أغمضتْ ليلى عينيها، ونامتْ وهي تبتسم. تصبحُ على خير يا صغيري الشاكر، ولا تنسَ أنْ تقولَ: الحمدُ لله."}],"question":{"q":"ما اسمُ اللعبةِ التي لعبتْها ليلى مع أمِّها؟","options":["نِعَمٌ في غرفتي","الغميضة","سباقُ السيّارات"],"answer":0},"activity":"عُدَّ على أصابعِك خمسَ نِعَمٍ أعطاك اللهُ إيّاها، وقلْ بعد كلِّ واحدة: الحمدُ لله."},
{"id":"s10-suads-seed","sort":100,"title":"بذرةُ سُعاد","emoji":"🌱","value_code":"sabr","value_name":"الصبر","kind":"value","minutes":3,"source":"","min_grade":1,"max_grade":12,"pages":[{"bg":"garden","scene":["👧","🌰","🪴"],"text":"في أوّلِ أيّامِ الربيع، أعطى الجدُّ حفيدتَه سعادَ بذرةً صغيرةً بنّيّة، وقال: يا سعاد، هذه بذرةُ زهرةِ دوّارِ الشمس. ازرعيها، واسقيها، واعتني بها، وسترينَ شيئًا جميلًا. فرحتْ سعادُ كثيرًا، وزرعتِ البذرةَ في أصيصٍ صغيرٍ قربَ النافذة."},{"bg":"home","scene":["👧","🪴","❓"],"text":"في الصباحِ التالي، ركضتْ سعادُ إلى الأصيص، فلم تجدْ شيئًا، التربةُ كما هي. وفي اليومِ الثالثِ لم تجدْ شيئًا أيضًا. قالت بحزن: يا جدّي، البذرةُ لا تكبر! ضحكَ الجدُّ ضحكةً خفيفة وقال: الأشياءُ الجميلةُ تحتاجُ إلى صبرٍ يا صغيرتي. البذرةُ تعملُ الآن تحتَ التراب، حتّى لو لم نرَها."},{"bg":"home","scene":["👧","💧","☀️"],"text":"صبرتْ سعاد. كانت تسقي البذرةَ كلَّ يومٍ قليلًا من الماء، وتضعُ الأصيصَ في ضوءِ الشمس، وتقولُ لها بلطف: كبري ببطءٍ يا بذرتي، أنا أنتظرُك. وكانت كلّما شعرتْ بالملل، تذكّرتْ كلامَ جدِّها: الصبرُ مفتاحُ الفرج."},{"bg":"garden","scene":["🌱","👧","😮"],"text":"وفي صباحِ اليومِ العاشر، صاحتْ سعادُ بفرح: جدّي، جدّي، تعالَ بسرعة! كانت هناك ورقتان خضراوان صغيرتان تخرجان من التراب، مثلَ يدين صغيرتين تلوّحان للشمس. قال الجدُّ: أرأيتِ؟ صبرُكِ بدأَ يُثمر."},{"bg":"garden","scene":["🌻","👧","🐝"],"text":"ومرّتِ الأسابيع، والنبتةُ تطولُ يومًا بعد يوم، حتّى صارتْ أطولَ من سعادَ نفسِها! وفي صباحٍ مشرق، تفتّحتْ زهرةٌ صفراءُ كبيرةٌ تشبهُ الشمس، وجاءتِ النحلاتُ تزورُها وتطنُّ حولَها بسعادة. وقفتْ سعادُ تحتَها مبتسمةً وقالت: كانت تستحقُّ الانتظار."},{"bg":"night","scene":["🌻","🌙","👧"],"text":"في تلك الليلة، قالت سعادُ لجدِّها: تعلّمتُ أنَّ الصبرَ جميل، وأنَّ اللهَ يحبُّ الصابرين. قال الجدّ: نعم يا سعاد، وكلُّ شيءٍ نتعلّمُه يحتاجُ إلى صبر، مثلَ القراءة، والحفظ، وتعلّمِ الكلماتِ الجديدة. نامتْ سعادُ وهي تحلمُ بحديقةٍ مليئةٍ بزهورِ دوّارِ الشمس. تصبحُ على خير يا صغيري الصبور."}],"question":{"q":"ماذا تعلّمتْ سعادُ من بذرتِها؟","options":["أنَّ البذورَ لا تنمو أبدًا","أنَّ الأشياءَ الجميلةَ تحتاجُ إلى صبر","أنْ تتركَ الأصيصَ بلا ماء"],"answer":1},"activity":"ازرعْ مع أهلِك بذرةَ عدسٍ أو فولٍ في قطنٍ مبلول، وراقبْها كلَّ يومٍ بصبر."},
{"id":"h01-thirsty-dog","sort":110,"title":"الرجلُ والكلبُ العطشان","emoji":"🐕","value_code":"rahma","value_name":"الرحمة","kind":"hadith","minutes":3,"source":"صحيح البخاري (2363) وصحيح مسلم (2244)، عن أبي هريرة رضي الله عنه","min_grade":1,"max_grade":12,"pages":[{"bg":"desert","scene":["🌙","✨","📖"],"text":"يا صغيري، هذه الليلةَ سأحكي لك قصّةً حقيقيّة، حكاها نبيُّنا محمّدٌ صلّى اللهُ عليه وسلّم لأصحابِه، ورواها الصحابيُّ الجليلُ أبو هريرة رضي الله عنه. وهي قصّةٌ عن الرحمة، وعن أنَّ اللهَ يحبُّ مَن يرحمُ حتّى الحيوانات."},{"bg":"desert","scene":["🚶","☀️","🏜️"],"text":"أخبرَنا النبيُّ صلّى اللهُ عليه وسلّم أنَّ رجلًا كان يمشي في طريق، فاشتدَّ عليه العطش. تخيّلْ يا صغيري طريقًا طويلًا والشمسُ حارّة، والرجلُ يبحثُ عن ماء. فوجدَ بئرًا، فنزلَ فيها فشربَ حتّى ارتوى، ثم خرجَ منها وهو مرتاح."},{"bg":"desert","scene":["🐕","💧","🕳️"],"text":"وعندما خرجَ من البئر، رأى كلبًا يلهثُ، يأكلُ الترابَ الرطبَ من شدّةِ العطش. نظرَ الرجلُ إليه، وفكّرَ في نفسِه، كما أخبرَنا النبيُّ صلّى اللهُ عليه وسلّم أنّه قال: «لقد بلغَ هذا الكلبَ من العطشِ مثلُ الذي كان بلغَ منّي». لقد شعرَ الرجلُ بالكلب، لأنّه كان عطشانَ مثلَه قبلَ قليل."},{"bg":"desert","scene":["🚶","👞","💧"],"text":"فماذا فعلَ الرجل؟ نزلَ إلى البئرِ مرّةً أخرى، وملأَ خُفَّه ماءً، والخفُّ نوعٌ من الأحذيةِ الجلديّة، ثم أمسكَه بفمِه حتّى يستطيعَ أنْ يصعدَ بيديه، ثم سقى الكلبَ حتّى شرب. عملٌ صغير، لكنّه مليءٌ بالرحمة."},{"bg":"night","scene":["🤲","✨","🌙"],"text":"وأخبرَنا النبيُّ صلّى اللهُ عليه وسلّم أنَّ اللهَ شكرَ لهذا الرجلِ عملَه، فغفرَ له. فتعجّبَ الصحابةُ وسألوا: يا رسولَ الله، وإنَّ لنا في البهائمِ لأجرًا؟ فقال صلّى اللهُ عليه وسلّم: «في كلِّ كبدٍ رطبةٍ أجر». يعني: في الإحسانِ إلى كلِّ مخلوقٍ حيٍّ أجرٌ وثواب."},{"bg":"night","scene":["🐦","💧","💤"],"text":"هل رأيتَ يا صغيري؟ قطرةُ ماءٍ لحيوانٍ عطشان يحبُّها الله. فإذا رأيتَ قطّةً جائعة، أو عصفورًا عطشانَ في يومٍ حارّ، فتذكّرْ هذه القصّة، وكنْ رحيمًا. والآن أغمضْ عينيك، وقلْ: اللهمَّ اجعلْني من الرحماء. تصبحُ على خيرٍ يا صغيري الرحيم."}],"question":{"q":"كيف سقى الرجلُ الكلبَ العطشان؟","options":["ملأَ خفَّه ماءً من البئر","تركَه وذهب","أعطاه طعامًا فقط"],"answer":0},"activity":"ضعْ مع أهلِك صحنًا صغيرًا فيه ماءٌ للعصافيرِ في الشرفةِ أو الحديقة."},
{"id":"h02-anas","sort":120,"title":"أنسٌ والنبيُّ الرحيم","emoji":"🌴","value_code":"manners","value_name":"حُسنُ التعامل","kind":"hadith","minutes":4,"source":"صحيح البخاري (6038، 6911) وصحيح مسلم (2309، 2310)، عن أنس بن مالك رضي الله عنه","min_grade":1,"max_grade":12,"pages":[{"bg":"desert","scene":["🌴","🕌","✨"],"text":"يا صغيري، هل تعرفُ الصحابيَّ أنسَ بنَ مالكٍ رضي الله عنه؟ كان أنسٌ ولدًا صغيرًا حين وصلَ النبيُّ صلّى اللهُ عليه وسلّم إلى المدينةِ المنوّرة. وقد حكى لنا أنسٌ بنفسِه قصصًا جميلةً عن أخلاقِ النبيِّ صلّى اللهُ عليه وسلّم، وهذه واحدةٌ منها."},{"bg":"desert","scene":["👦","🧔","🌴"],"text":"روى أنسٌ أنَّ أبا طلحةَ رضي الله عنه أخذَه بيدِه، وذهبَ به إلى رسولِ اللهِ صلّى اللهُ عليه وسلّم، وقال: يا رسولَ الله، «إنَّ أنسًا غلامٌ كيِّسٌ فليخدمْك». والكيِّسُ يعني الذكيَّ الفطن. فصارَ أنسٌ يخدمُ النبيَّ صلّى اللهُ عليه وسلّم، ويعيشُ قريبًا منه، ويتعلّمُ منه."},{"bg":"desert","scene":["👦","💛","📿"],"text":"وقال أنسٌ رضي الله عنه: «خدمتُ النبيَّ صلّى اللهُ عليه وسلّم عشرَ سنين، فما قال لي: أُفٍّ، ولا: لِمَ صنعتَ؟ ولا: ألا صنعتَ». تخيّلْ يا صغيري، عشرَ سنواتٍ كاملة، ولم يقلْ له النبيُّ صلّى اللهُ عليه وسلّم كلمةً تُحزنُه أبدًا. وقال أنسٌ أيضًا: كان رسولُ اللهِ صلّى اللهُ عليه وسلّم من أحسنِ الناسِ خُلُقًا."},{"bg":"desert","scene":["👦","👦🏽","🏪"],"text":"وحكى أنسٌ أنَّ النبيَّ صلّى اللهُ عليه وسلّم أرسلَه يومًا في حاجة، فخرجَ أنسٌ، فمرَّ على صبيانٍ يلعبون في السوق، فوقفَ عندهم. فإذا برسولِ اللهِ صلّى اللهُ عليه وسلّم قد أمسكَ بقفاه من ورائِه بلطف. قال أنس: فنظرتُ إليه وهو يضحك."},{"bg":"desert","scene":["🧔","😊","👦"],"text":"فقال له النبيُّ صلّى اللهُ عليه وسلّم بلطف: «يا أُنَيْس، أذهبتَ حيثُ أمرتُك؟» وأُنَيْس اسمُ تدليلٍ لأنس، كما نقولُ نحن للصغيرِ كلمةً حنونة. فقال أنس: «نعم، أنا أذهبُ يا رسولَ الله». لم يغضبْ النبيُّ صلّى اللهُ عليه وسلّم، بل ضحكَ وذكّرَه بلطفٍ ومحبّة."},{"bg":"night","scene":["🌙","💛","💤"],"text":"هذا هو حسنُ التعامل يا صغيري: أنْ نتكلّمَ بلطف، وأنْ نبتسم، وأنْ نصبرَ على مَن يخطئ، وأنْ ننصحَ برفق. وقدوتُنا في ذلك نبيُّنا محمّدٌ صلّى اللهُ عليه وسلّم. فغدًا، حاولْ أنْ تكلّمَ إخوتَك وأصدقاءَك بلطفٍ مثلَه. والآن نمْ هادئًا، وقلْ: اللهمَّ صلِّ على محمّد. تصبحُ على خيرٍ يا صغيري اللطيف."}],"question":{"q":"كم سنةً خدمَ أنسٌ النبيَّ صلّى اللهُ عليه وسلّم؟","options":["سنتين","عشرَ سنين","خمسَ سنين"],"answer":1},"activity":"حاولْ غدًا ألّا تقولَ «أُفّ» لأحد، وأنْ تنصحَ أخاك أو صديقَك بلطفٍ وابتسامة."},
{"id":"h03-abdurrahman","sort":130,"title":"الأخوّةُ في المدينة","emoji":"🤝","value_code":"help","value_name":"مساعدةُ الآخرين","kind":"hadith","minutes":3,"source":"صحيح البخاري (2048، 3780)، عن عبد الرحمن بن عوف وأنس بن مالك رضي الله عنهما","min_grade":1,"max_grade":12,"pages":[{"bg":"desert","scene":["🐪","🌴","🏘️"],"text":"يا صغيري، عندما هاجرَ المسلمون من مكّةَ إلى المدينةِ المنوّرة، تركوا بيوتَهم وأموالَهم هناك. وكان أهلُ المدينة، واسمُهم الأنصار، يستقبلونهم بمحبّة. وآخى النبيُّ صلّى اللهُ عليه وسلّم بين المهاجرين والأنصار، يعني جعلَ كلَّ واحدٍ منهم أخًا لصاحبِه."},{"bg":"desert","scene":["🧔","🤝","🧔🏽"],"text":"وكان من هؤلاءِ الإخوة: عبدُ الرحمنِ بنُ عوفٍ من المهاجرين، وسعدُ بنُ الربيعِ من الأنصار، رضي الله عنهما. وكان سعدٌ من أكثرِ الأنصارِ مالًا، فقال لأخيه عبدِ الرحمن: إنّي أكثرُ الأنصارِ مالًا، فأَقسِمُ لك نصفَ مالي. انظرْ يا صغيري كم كان سعدٌ كريمًا، يريدُ أنْ يساعدَ أخاه بنصفِ ما يملك!"},{"bg":"desert","scene":["🧔","💬","🏪"],"text":"فماذا قال عبدُ الرحمن؟ قال له كلامًا جميلًا: «باركَ اللهُ لك في أهلِك ومالِك، أين سوقُكم؟» يعني: شكرًا لك يا أخي، أدعو اللهَ أنْ يباركَ لك، ولكنْ دلَّني على السوقِ لأعملَ وأكسبَ رزقي بنفسي."},{"bg":"desert","scene":["🧀","🫙","🏪"],"text":"فدلّوه على السوق، فذهبَ عبدُ الرحمنِ يبيعُ ويشتري، وتاجرَ في الأَقِطِ والسمن، والأقطُ نوعٌ من اللبنِ المجفّف. ورجعَ في آخرِ اليومِ وقد ربحَ شيئًا منهما. واستمرَّ يعملُ بجدٍّ، وباركَ اللهُ له في تجارتِه حتّى صارَ من الأغنياء."},{"bg":"night","scene":["💛","🤝","🌙"],"text":"في هذه القصّةِ درسان جميلان يا صغيري: سعدٌ علّمَنا أنْ نساعدَ الآخرين ونكرمَهم بما نملك، وعبدُ الرحمنِ علّمَنا أنْ نشكرَ مَن يساعدُنا، وأنْ نعملَ ونجتهد. فكنْ يا صغيري كريمًا مثلَ سعد، ومجتهدًا مثلَ عبدِ الرحمن. والآن نمْ هادئًا، تصبحُ على خيرٍ يا صغيري الكريم."}],"question":{"q":"ماذا طلبَ عبدُ الرحمنِ من أخيه سعد؟","options":["نصفَ مالِه","أنْ يدلَّه على السوق","بيتًا كبيرًا"],"answer":1},"activity":"شاركْ أخاك أو صديقَك شيئًا تحبُّه غدًا، مثلَ لعبةٍ أو قطعةِ حلوى، وقلْ له كلمةً طيّبة."},
{"id":"h04-ibn-abbas","sort":140,"title":"وصيّةٌ لغلامٍ صغير","emoji":"🌟","value_code":"tawakkul","value_name":"الثقةُ بالله","kind":"hadith","minutes":3,"source":"سنن الترمذي (2516) وقال: حديث حسن صحيح، عن عبد الله بن عباس رضي الله عنهما","min_grade":1,"max_grade":12,"pages":[{"bg":"night","scene":["👦","🐪","✨"],"text":"يا صغيري، كان عبدُ اللهِ بنُ عبّاسٍ رضي الله عنهما ابنَ عمِّ النبيِّ صلّى اللهُ عليه وسلّم، وكان غلامًا صغيرًا ذكيًّا يحبُّ العلم. وقد حكى لنا أنّه كان يومًا خلفَ رسولِ اللهِ صلّى اللهُ عليه وسلّم، فقال له النبيُّ صلّى اللهُ عليه وسلّم كلماتٍ جميلة، حفظَها ابنُ عبّاس، وبقيَ الناسُ يحفظونها إلى اليوم."},{"bg":"night","scene":["🧔","💬","👦"],"text":"قال له النبيُّ صلّى اللهُ عليه وسلّم: «يا غلام، إنّي أعلّمُك كلمات». تخيّلْ يا صغيري كم فرحَ ابنُ عبّاس، وكيف أنصتَ باهتمام، لأنَّ النبيَّ صلّى اللهُ عليه وسلّم سيعلّمُه شيئًا خاصًّا. فقال له: «احفظِ اللهَ يحفظْك»."},{"bg":"night","scene":["🛡️","💛","🌙"],"text":"ومعنى «احفظِ اللهَ يحفظْك» يا صغيري: أنْ تطيعَ اللهَ وتفعلَ ما يحبُّ، مثلَ الصلاةِ والصدقِ وبرِّ الوالدين، فيحفظُك اللهُ ويرعاك. ثم قال له: «احفظِ اللهَ تجدْه تُجاهَك»، يعني تجدُ اللهَ معك يعينُك ويساعدُك في كلِّ مكان."},{"bg":"night","scene":["🤲","✨","⭐"],"text":"ثم قال له: «إذا سألتَ فاسألِ الله، وإذا استعنتَ فاستعنْ بالله». يعني يا صغيري: إذا احتجتَ شيئًا فاطلبْه من اللهِ وادعُه، وإذا أردتَ أنْ تفعلَ شيئًا صعبًا، مثلَ امتحانٍ أو حفظِ درس، فقلْ: يا ربِّ أعنّي. فاللهُ قريبٌ يسمعُ دعاءَك."},{"bg":"night","scene":["👦","🛏️","🌙"],"text":"هذه الكلماتُ تجعلُ القلبَ مطمئنًّا وشجاعًا، فأنتَ لستَ وحدَك أبدًا، اللهُ معك يحفظُك في نومِك وفي يقظتِك. والآن، قبلَ أنْ تنام، ارفعْ يديك الصغيرتين وقلْ: يا ربِّ احفظْني واحفظْ أهلي، وأعنّي على كلِّ خير. ثم أغمضْ عينيك مطمئنًّا. تصبحُ على خيرٍ يا صغيري، في حفظِ اللهِ ورعايتِه."}],"question":{"q":"ماذا قال النبيُّ صلّى اللهُ عليه وسلّم لابنِ عبّاس؟","options":["احفظِ اللهَ يحفظْك","العبْ كثيرًا","لا تذهبْ إلى السوق"],"answer":0},"activity":"احفظْ مع أهلِك الجملةَ الأولى: «احفظِ اللهَ يحفظْك»، ورددْها قبلَ النومِ ثلاثَ مرّات."},
{"id":"p01-saleh","sort":150,"title":"سيدنا صالح عليه السلام والناقة","emoji":"🐪","value_code":"obey","value_name":"طاعة الله والرفق بالحيوان","kind":"prophet","minutes":4,"source":"القرآن الكريم: الأعراف 73-79، هود 61-68، الشعراء 141-159، الشمس 11-15","min_grade":1,"max_grade":12,"pages":[{"bg":"desert","scene":["⛰️","🏠","🌴"],"text":"يا صغيري، هذه الليلةَ نتعرّفُ على قصّةٍ من القرآنِ الكريم، قصّةِ نبيِّ اللهِ صالحٍ عليه السلام. كان يعيشُ مع قومٍ اسمُهم ثمود. أعطاهم اللهُ نِعَمًا كثيرة: بساتين وعيونَ ماءٍ ونخيلًا، وكانوا ماهرين جدًّا، كما قال اللهُ تعالى عنهم: «وتنحتون الجبال بيوتا» (الأعراف 74)، أي يصنعون بيوتَهم في الصخر."},{"bg":"desert","scene":["🌴","🌾","💧"],"text":"أرسلَ اللهُ إليهم صالحًا عليه السلام يدعوهم إلى عبادةِ اللهِ وحدَه وشكرِه على نِعَمِه، فقال لهم كما في القرآن: «يا قوم اعبدوا الله ما لكم من إله غيره» (الأعراف 73). فآمنَ به بعضُ الناس، وبقيَ آخرون لا يريدون أنْ يسمعوا النصيحة."},{"bg":"desert","scene":["🐪","✨","⛰️"],"text":"فجعلَ اللهُ لهم آيةً عظيمة، أي علامةً تدلُّ على صدقِ نبيِّه: ناقةً مباركة. قال صالحٌ عليه السلام: «هذه ناقة الله لكم آية فذروها تأكل في أرض الله ولا تمسوها بسوء» (الأعراف 73). أي اتركوها تأكلُ وتشربُ بسلام، ولا تؤذوها أبدًا."},{"bg":"desert","scene":["💧","🐪","📅"],"text":"وكان الماءُ في بلدِهم مقسومًا بالعدل، يومٌ تشربُ فيه الناقة، ويومٌ يشربُ فيه الناس. قال تعالى: «قال هذه ناقة لها شرب ولكم شرب يوم معلوم» (الشعراء 155). وهذا درسٌ جميل يا صغيري: أنْ نتقاسمَ النِّعمَ بالعدل، وأنْ نحترمَ الاتفاقَ ونرفقَ بالحيوان."},{"bg":"dusk","scene":["🌙","🐪","⛰️"],"text":"لكنَّ الذين لم يؤمنوا لم يحفظوا الوصيّة، وآذوا الناقة وعصَوا أمرَ الله، فنزلَ بهم عقابٌ من الله. أمّا صالحٌ عليه السلام والذين آمنوا معه فقد نجّاهم اللهُ برحمتِه، كما قال تعالى: «فلما جاء أمرنا نجينا صالحا والذين آمنوا معه برحمة منا» (هود 66)."},{"bg":"night","scene":["🌙","✨","🐪"],"text":"تعلّمْنا من قصّةِ سيدنا صالحٍ عليه السلام أنْ نطيعَ اللهَ ونشكرَه على نِعَمِه، وأنْ نحافظَ على الوعد، وأنْ نرحمَ الحيواناتِ ولا نؤذيها. والآن أغمضْ عينيك يا صغيري، وقلْ: الحمدُ للهِ على نِعَمِه. تصبحُ على خيرٍ في حفظِ الله."}],"question":{"q":"ما الآيةُ التي جعلَها اللهُ لقومِ صالحٍ عليه السلام؟","options":["ناقةٌ مباركة","سفينةٌ كبيرة","نجمةٌ لامعة"],"answer":0},"activity":"ضعْ مع أهلِك صحنَ ماءٍ للعصافيرِ أو القطط، وتذكّرْ أنَّ الرفقَ بالحيوانِ يحبُّه الله."},
{"id":"p02-nuh","sort":160,"title":"سيدنا نوح عليه السلام والسفينة","emoji":"🚢","value_code":"sabr","value_name":"الصبر","kind":"prophet","minutes":4,"source":"القرآن الكريم: هود 25-48، نوح 1-28، العنكبوت 14، القمر 9-15","min_grade":1,"max_grade":12,"pages":[{"bg":"garden","scene":["🏘️","🌳","☁️"],"text":"يا صغيري، هذه قصّةُ نبيِّ اللهِ نوحٍ عليه السلام كما جاءت في القرآنِ الكريم. أرسلَه اللهُ إلى قومِه يدعوهم إلى عبادةِ اللهِ وحدَه. وكان صبورًا جدًّا، فقد بقيَ يدعوهم زمنًا طويلًا، قال تعالى: «فلبث فيهم ألف سنة إلا خمسين عاما» (العنكبوت 14)."},{"bg":"garden","scene":["🌙","☀️","💬"],"text":"دعاهم في الليلِ والنهار، كما أخبرَنا القرآن: «قال رب إني دعوت قومي ليلا ونهارا» (نوح 5)، وقال لهم: «استغفروا ربكم إنه كان غفارا» (نوح 10). لكنَّ أكثرَهم لم يستجيبوا، قال تعالى: «وما آمن معه إلا قليل» (هود 40). ومع ذلك لم ييأسْ نوحٌ عليه السلام، وبقيَ صابرًا."},{"bg":"garden","scene":["🪵","🔨","🚢"],"text":"فأمرَه اللهُ أنْ يصنعَ سفينةً كبيرة: «واصنع الفلك بأعيننا ووحينا» (هود 37). والفلكُ هو السفينة. فبدأ يصنعُها كما أمرَه الله، وكان بعضُ قومِه يمرّون ويسخرون منه، قال تعالى: «وكلما مر عليه ملأ من قومه سخروا منه» (هود 38). لكنّه استمرَّ في عملِه بصبرٍ وثقةٍ بالله."},{"bg":"sea","scene":["🦁","🐘","🕊️"],"text":"ولمّا جاءَ أمرُ الله، قال تعالى لنوحٍ عليه السلام: «احمل فيها من كل زوجين اثنين» (هود 40)، أي من كلِّ نوعٍ من الحيواناتِ ذكرًا وأنثى، ومعه أهلُه والذين آمنوا. فقال لهم نوحٌ عليه السلام: «اركبوا فيها بسم الله مجراها ومرساها إن ربي لغفور رحيم» (هود 41)."},{"bg":"sea","scene":["🌧️","🌊","🚢"],"text":"ثمَّ نزلَ المطرُ من السماء، وتفجّرتِ العيونُ من الأرض، وارتفعَ الماءُ كثيرًا، والسفينةُ تجري بأمرِ اللهِ وحفظِه، ومَن فيها في أمانٍ. ثمَّ قال اللهُ: «يا أرض ابلعي ماءك ويا سماء أقلعي» (هود 44)، فهدأَ الماء، ورستِ السفينةُ على جبلٍ اسمُه الجوديّ: «واستوت على الجودي» (هود 44)."},{"bg":"night","scene":["⛰️","🚢","🕊️"],"text":"ونزلَ نوحٌ عليه السلام ومَن معه إلى الأرضِ بسلام، قال تعالى: «قيل يا نوح اهبط بسلام منا وبركات عليك» (هود 48). تعلّمْنا يا صغيري من سيدنا نوحٍ عليه السلام الصبرَ، وألّا نيأسَ أبدًا، وأنْ نثقَ بأنَّ اللهَ يحفظُ عبادَه المؤمنين. تصبحُ على خيرٍ في أمانِ الله."}],"question":{"q":"ماذا صنعَ نوحٌ عليه السلام بأمرِ الله؟","options":["بيتًا من الصخر","سفينةً كبيرة","حديقةً جميلة"],"answer":1},"activity":"ارسمْ مع أهلِك سفينةً وحولَها أزواجٌ من الحيوانات، وتحدّثوا عن معنى الصبر."},
{"id":"p03-ibrahim","sort":170,"title":"سيدنا إبراهيم عليه السلام والنار","emoji":"🔥","value_code":"tawakkul","value_name":"الثقةُ بالله","kind":"prophet","minutes":4,"source":"القرآن الكريم: الأنبياء 51-71، الصافات 83-98","min_grade":1,"max_grade":12,"pages":[{"bg":"night","scene":["⭐","🌙","☀️"],"text":"يا صغيري، هذه قصّةُ نبيِّ اللهِ إبراهيمَ عليه السلام من القرآنِ الكريم. كان إبراهيمُ منذُ صغرِه ذكيًّا يفكّرُ ويتأمّل، قال تعالى: «ولقد آتينا إبراهيم رشده من قبل» (الأنبياء 51)، أي أعطاه اللهُ الفهمَ والهدايةَ وهو صغير، فعرفَ أنَّ اللهَ وحدَه هو الخالقُ المستحقُّ للعبادة."},{"bg":"desert","scene":["🗿","🗿","🗿"],"text":"وكان قومُه يعبدون تماثيلَ صنعوها بأيديهم، لا تسمعُ ولا تتكلّم. فسألهم إبراهيمُ عليه السلام: «ما هذه التماثيل التي أنتم لها عاكفون» (الأنبياء 52)؟ فقالوا: «وجدنا آباءنا لها عابدين» (الأنبياء 53). فأخبرَهم أنَّ هذا خطأ، وأنَّ العبادةَ لا تكونُ إلّا لله."},{"bg":"desert","scene":["🪓","🗿","💭"],"text":"وأرادَ أنْ يُفهمَهم بطريقةٍ ذكيّة أنَّ التماثيلَ لا تنفعُ شيئًا، فكسّرَها إلّا الكبيرَ منها، قال تعالى: «فجعلهم جذاذا إلا كبيرا لهم لعلهم إليه يرجعون» (الأنبياء 58). ولمّا سألوه، قال: «بل فعله كبيرهم هذا فاسألوهم إن كانوا ينطقون» (الأنبياء 63)، ليعرفوا بأنفسِهم أنَّها لا تتكلّمُ ولا تدافعُ عن نفسِها."},{"bg":"dusk","scene":["🔥","🪵","🌫️"],"text":"فقال لهم: «أفتعبدون من دون الله ما لا ينفعكم شيئا ولا يضركم» (الأنبياء 66). لكنّهم بدلَ أنْ يفكّروا، غضبوا وقرّروا أنْ يلقوه في نارٍ عظيمة. وكان إبراهيمُ عليه السلام واثقًا بربِّه تمامًا، يعلمُ أنَّ اللهَ معه ولن يتركَه."},{"bg":"garden","scene":["🔥","❄️","🌸"],"text":"وهنا جاءتْ رحمةُ الله، فقال اللهُ تعالى: «قلنا يا نار كوني بردا وسلاما على إبراهيم» (الأنبياء 69). فأطاعتِ النارُ أمرَ ربِّها، وصارتْ بردًا وسلامًا عليه، ولم تؤذِه أبدًا. سبحانَ اللهِ القادرِ على كلِّ شيء! وقال تعالى: «وأرادوا به كيدا فجعلناهم الأخسرين» (الأنبياء 70)."},{"bg":"night","scene":["🌙","✨","🌸"],"text":"تعلّمْنا يا صغيري من سيدنا إبراهيمَ عليه السلام أنْ نعبدَ اللهَ وحدَه، وأنْ نقولَ الحقَّ بأدبٍ وحكمة، وأنْ نثقَ بأنَّ اللهَ يحفظُ مَن يتوكّلُ عليه. والآن أغمضْ عينيك وقلْ: حسبيَ اللهُ ونعمَ الوكيل. تصبحُ على خيرٍ في حفظِ الله ورعايتِه."}],"question":{"q":"ماذا قالَ اللهُ تعالى للنار؟","options":["اشتعلي أكثر","كوني بردا وسلاما على إبراهيم","انطفئي غدًا"],"answer":1},"activity":"احفظْ مع أهلِك الآية: «يا نار كوني بردا وسلاما على إبراهيم»، واسألْهم عن معنى التوكّل على الله."}]$json$;
begin
  update public.bedtime_stories set published = false;
  for st in select * from jsonb_array_elements(data) loop
    insert into public.bedtime_stories (id, sort, title, emoji, value_code, value_name, kind, minutes, source,
                                        min_grade, max_grade, pages, question, activity, published)
    values (st->>'id', (st->>'sort')::int, st->>'title', st->>'emoji', st->>'value_code', st->>'value_name',
            st->>'kind', (st->>'minutes')::int, st->>'source', (st->>'min_grade')::int, (st->>'max_grade')::int,
            st->'pages', st->'question', st->>'activity', true)
    on conflict (id) do update set sort = excluded.sort, title = excluded.title, emoji = excluded.emoji,
       value_code = excluded.value_code, value_name = excluded.value_name, kind = excluded.kind,
       minutes = excluded.minutes, source = excluded.source, min_grade = excluded.min_grade,
       max_grade = excluded.max_grade, pages = excluded.pages, question = excluded.question,
       activity = excluded.activity, published = true;
  end loop;
end $$;
