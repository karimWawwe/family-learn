-- ============================================================================
--  Family Learn - Speaking game: STAGES
--   * many more stages, easy -> hard (content at the end of this file);
--   * a stage opens when the stage before it is finished AND the child has
--     collected enough stars in total (required_stars);
--   * once a stage is open it stays open (speak_unlocks), it is never locked again;
--   * every stage can be replayed; the BEST stars and BEST points of each stage count.
--
--  Needs 20260930000006_speak_game.sql. Safe to run again: progress is kept.
-- ============================================================================

alter table public.speak_levels add column if not exists required_stars int not null default 0;

-- Stages already open for each child are remembered here.
do $$
begin
  if to_regclass('public.speak_unlocks') is null then
    create table public.speak_unlocks (
      profile_id  uuid not null references public.profiles (id) on delete cascade,
      level_id    text not null references public.speak_levels (id) on delete cascade,
      unlocked_at timestamptz not null default now(),
      primary key (profile_id, level_id)
    );
    alter table public.speak_unlocks enable row level security;
    revoke all on public.speak_unlocks from anon, authenticated;

    -- First install only: keep every stage that was already open under the old
    -- rule (played stages, the stage right after each played one, and the first).
    insert into public.speak_unlocks (profile_id, level_id)
    select distinct x.profile_id, x.level_id from (
      select sp.profile_id, sp.level_id from public.speak_plays sp
      union
      select sp.profile_id, nxt.id
        from public.speak_plays sp
        join public.speak_levels cur on cur.id = sp.level_id
        join lateral (select l.id from public.speak_levels l
                       where l.track = cur.track and l.published and l.sort > cur.sort
                       order by l.sort limit 1) nxt on true
    ) x
    on conflict do nothing;
  end if;
end $$;

-- ---------------------------------------------------------------- helpers
-- Stars of a profile in its track: the best result of every published stage.
create or replace function app.speak_total_stars(p_profile uuid) returns int
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(b.best), 0)::int
    from (select max(sp.stars) best
            from public.speak_plays sp
            join public.speak_levels l on l.id = sp.level_id
           where sp.profile_id = p_profile and l.published and l.track = app.speak_track(p_profile)
           group by sp.level_id) b
$$;

-- Points: the best result of every stage (replaying can only improve it).
create or replace function app.speak_best_points(p_profile uuid) returns int
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(b.best), 0)::int
    from (select max(points) best from public.speak_plays
           where profile_id = p_profile group by level_id) b
$$;

create or replace function app.speak_level_unlocked(p_profile uuid, p_level text) returns boolean
language sql stable security definer set search_path = '' as $$
  with me as (select * from public.speak_levels where id = p_level and published),
       prev as (
         select l.id from public.speak_levels l, me
          where l.track = me.track and l.published and l.sort < me.sort
          order by l.sort desc limit 1)
  select exists (select 1 from me)
     and (
       exists (select 1 from public.speak_unlocks u where u.profile_id = p_profile and u.level_id = p_level)
       or (
         (not exists (select 1 from prev)
          or exists (select 1 from public.speak_plays sp, prev
                      where sp.profile_id = p_profile and sp.level_id = prev.id))
         and app.speak_total_stars(p_profile) >= (select required_stars from me)))
$$;

revoke all on function app.speak_total_stars(uuid) from public, anon;
revoke all on function app.speak_best_points(uuid) from public, anon;
grant execute on function app.speak_total_stars(uuid) to authenticated;
grant execute on function app.speak_best_points(uuid) to authenticated;

-- ---------------------------------------------------------------- API (RPC)

-- Stages (with words) of the profile's track: best stars/points, plays, open or not,
-- stars needed; totals. Newly opened stages are remembered so they stay open.
create or replace function public.speak_game_state(p_profile uuid) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_track text;
  tz      text;
  today   date;
  v_levels jsonb;
  v_streak int := 0;
  v_stars int;
  d       date;
begin
  perform app.require_profile(p_profile);
  v_track := app.speak_track(p_profile);
  tz := app.profile_tz(p_profile);
  today := (now() at time zone tz)::date;
  v_stars := app.speak_total_stars(p_profile);

  -- remember every stage that is open now (it will never be locked again)
  insert into public.speak_unlocks (profile_id, level_id)
  select p_profile, l.id from public.speak_levels l
   where l.track = v_track and l.published and app.speak_level_unlocked(p_profile, l.id)
  on conflict do nothing;

  select coalesce(jsonb_agg(x.j order by x.sort), '[]'::jsonb) into v_levels
    from (
      select l.sort, jsonb_build_object(
               'id', l.id, 'title', l.title, 'title_ar', l.title_ar, 'emoji', l.emoji,
               'strictness', l.strictness, 'source', l.source, 'required_stars', l.required_stars,
               'best_stars', coalesce((select max(stars) from public.speak_plays sp
                                        where sp.profile_id = p_profile and sp.level_id = l.id), 0),
               'best_points', coalesce((select max(points) from public.speak_plays sp
                                         where sp.profile_id = p_profile and sp.level_id = l.id), 0),
               'plays', (select count(*) from public.speak_plays sp
                          where sp.profile_id = p_profile and sp.level_id = l.id),
               'unlocked', exists (select 1 from public.speak_unlocks u
                                    where u.profile_id = p_profile and u.level_id = l.id),
               'words', (select coalesce(jsonb_agg(jsonb_build_object(
                                  'text', w.text, 'emoji', w.emoji, 'meaning_ar', w.meaning_ar,
                                  'hint', w.hint, 'accept', to_jsonb(w.accept)) order by w.sort), '[]'::jsonb)
                           from public.speak_words w where w.level_id = l.id)) j
        from public.speak_levels l
       where l.track = v_track and l.published) x;

  select max((created_at at time zone tz)::date) into d from public.speak_plays where profile_id = p_profile;
  if d is not null and d >= today - 1 then
    while exists (select 1 from public.speak_plays where profile_id = p_profile
                   and (created_at at time zone tz)::date = d) loop
      v_streak := v_streak + 1;
      d := d - 1;
    end loop;
  end if;

  return jsonb_build_object(
    'track', v_track,
    'levels', v_levels,
    'stars', v_stars,
    'points', app.speak_best_points(p_profile),
    'points_today', (select coalesce(sum(points), 0) from public.speak_plays
                      where profile_id = p_profile and (created_at at time zone tz)::date = today),
    'words_mastered', (select count(distinct lower(word)) from public.speak_attempts
                        where profile_id = p_profile and result = 'correct'),
    'day_streak', v_streak,
    'last_played', (select max(created_at) from public.speak_plays where profile_id = p_profile),
    'tricky', (select coalesce(jsonb_agg(jsonb_build_object('word', t.word, 'misses', t.n) order by t.n desc), '[]'::jsonb)
                 from (select word, count(*) n from public.speak_attempts
                        where profile_id = p_profile and result in ('close', 'wrong')
                          and created_at > now() - interval '14 days'
                        group by word order by count(*) desc limit 6) t));
end $$;

-- A stage played to the end (first time or a replay). Returns the new state.
create or replace function public.speak_finish_level(
  p_profile uuid, p_level text, p_points int, p_stars int, p_words int, p_first_try int, p_attempts int
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_words int;
begin
  perform app.require_profile(p_profile);
  if not exists (select 1 from public.speak_levels
                  where id = p_level and published and track = app.speak_track(p_profile)) then
    perform app.fail('not_found');
  end if;
  if not app.speak_level_unlocked(p_profile, p_level) then perform app.fail('lesson_locked'); end if;
  select count(*) into v_words from public.speak_words where level_id = p_level;
  insert into public.speak_plays (profile_id, level_id, points, stars, words, first_try, attempts)
  values (p_profile, p_level,
          least(greatest(coalesce(p_points, 0), 0), v_words * 30 + 50),
          least(greatest(coalesce(p_stars, 1), 1), 3),
          v_words,
          least(greatest(coalesce(p_first_try, 0), 0), v_words),
          greatest(coalesce(p_attempts, 0), 0));
  return public.speak_game_state(p_profile);
end $$;

revoke all on function public.speak_game_state(uuid) from public, anon;
revoke all on function public.speak_finish_level(uuid, text, int, int, int, int, int) from public, anon;
grant execute on function public.speak_game_state(uuid) to authenticated;
grant execute on function public.speak_finish_level(uuid, text, int, int, int, int, int) to authenticated;
do $$
declare
  lv jsonb;
  wd jsonb;
  i  int;
  data jsonb := $json$[{"id":"a1-words","track":"adult","sort":10,"title":"Everyday English words","title_ar":"كلمات الإنجليزية اليومية","emoji":"💼","strictness":0.86,"source":"Everyday English 1","words":[{"text":"formal","emoji":"👔","meaning_ar":"رسمي","hint":"","accept":[]},{"text":"informal","emoji":"👕","meaning_ar":"غير رسمي","hint":"","accept":[]},{"text":"opinion","emoji":"💭","meaning_ar":"رأي","hint":"","accept":[]},{"text":"discussion","emoji":"🗣️","meaning_ar":"نقاش","hint":"","accept":[]},{"text":"paragraph","emoji":"📄","meaning_ar":"فقرة","hint":"","accept":[]},{"text":"punctuation","emoji":"❗","meaning_ar":"علامات الترقيم","hint":"","accept":[]},{"text":"spelling","emoji":"🔤","meaning_ar":"التهجئة","hint":"","accept":[]},{"text":"summary","emoji":"📝","meaning_ar":"ملخص","hint":"","accept":[]}],"required_stars":0},
{"id":"a2-phrases","track":"adult","sort":20,"title":"Useful phrases","title_ar":"عبارات مفيدة","emoji":"🤝","strictness":0.82,"source":"Everyday English 1 - Speaking, Writing","words":[{"text":"Thank you for your email","emoji":"📧","meaning_ar":"شكراً على بريدك","hint":"","accept":[]},{"text":"Could you please send me the details","emoji":"📨","meaning_ar":"هل يمكنك إرسال التفاصيل من فضلك؟","hint":"","accept":[]},{"text":"In my opinion","emoji":"💭","meaning_ar":"في رأيي","hint":"","accept":[]},{"text":"I agree with you","emoji":"👍","meaning_ar":"أتفق معك","hint":"","accept":[]},{"text":"I would like to ask about the price","emoji":"💬","meaning_ar":"أود أن أسأل عن السعر","hint":"","accept":["i'd like to ask about the price"]},{"text":"Best regards","emoji":"✍️","meaning_ar":"مع أطيب التحيات","hint":"","accept":[]}],"required_stars":2},
{"id":"a3-perfume","track":"adult","sort":30,"title":"Perfume shop words","title_ar":"كلمات متجر العطور","emoji":"🧴","strictness":0.86,"source":"Business English","words":[{"text":"fragrance","emoji":"🌸","meaning_ar":"عطر / رائحة","hint":"fra-grance","accept":[]},{"text":"perfume","emoji":"🧴","meaning_ar":"عطر","hint":"per-fume","accept":[]},{"text":"customer","emoji":"🧑","meaning_ar":"زبون","hint":"cus-tom-er","accept":[]},{"text":"discount","emoji":"🏷️","meaning_ar":"خصم","hint":"dis-count","accept":[]},{"text":"delivery","emoji":"🚚","meaning_ar":"توصيل","hint":"de-liv-er-y","accept":[]},{"text":"invoice","emoji":"🧾","meaning_ar":"فاتورة","hint":"in-voice","accept":[]}],"required_stars":4},
{"id":"a4-shop-phrases","track":"adult","sort":40,"title":"Talking to customers","title_ar":"الحديث مع الزبائن","emoji":"💬","strictness":0.82,"source":"Business English","words":[{"text":"How can I help you","emoji":"🙋","meaning_ar":"كيف أستطيع مساعدتك؟","hint":"","accept":[]},{"text":"This fragrance lasts all day","emoji":"⏳","meaning_ar":"هذا العطر يدوم طوال اليوم","hint":"","accept":[]},{"text":"Would you like to try it","emoji":"🧴","meaning_ar":"هل تحب أن تجرّبه؟","hint":"","accept":[]},{"text":"We have a special offer today","emoji":"🏷️","meaning_ar":"لدينا عرض خاص اليوم","hint":"","accept":[]},{"text":"Thank you for shopping with us","emoji":"🛍️","meaning_ar":"شكرًا لتسوّقك معنا","hint":"","accept":[]}],"required_stars":6},
{"id":"a5-meetings","track":"adult","sort":50,"title":"Meeting words","title_ar":"كلمات الاجتماعات","emoji":"📊","strictness":0.86,"source":"Business English","words":[{"text":"agenda","emoji":"📋","meaning_ar":"جدول الأعمال","hint":"a-gen-da","accept":[]},{"text":"target","emoji":"🎯","meaning_ar":"الهدف","hint":"tar-get","accept":[]},{"text":"sales","emoji":"💰","meaning_ar":"المبيعات","hint":"","accept":["sails"]},{"text":"report","emoji":"📈","meaning_ar":"تقرير","hint":"re-port","accept":[]},{"text":"deadline","emoji":"⏰","meaning_ar":"الموعد النهائي","hint":"dead-line","accept":[]},{"text":"budget","emoji":"💵","meaning_ar":"الميزانية","hint":"budg-et","accept":[]}],"required_stars":7},
{"id":"a6-meeting-phrases","track":"adult","sort":60,"title":"In the sales meeting","title_ar":"في اجتماع المبيعات","emoji":"🤝","strictness":0.82,"source":"Business English","words":[{"text":"Let's review the monthly sales","emoji":"📊","meaning_ar":"لنراجع المبيعات الشهرية","hint":"","accept":["let us review the monthly sales"]},{"text":"We exceeded our target","emoji":"🎯","meaning_ar":"تجاوزنا هدفنا","hint":"","accept":[]},{"text":"Could we schedule a meeting","emoji":"📅","meaning_ar":"هل يمكننا تحديد موعد اجتماع؟","hint":"","accept":[]},{"text":"I will send the report today","emoji":"📨","meaning_ar":"سأرسل التقرير اليوم","hint":"","accept":["i'll send the report today"]}],"required_stars":9},
{"id":"o0-warmup","track":"older","sort":5,"title":"Warm up","title_ar":"إحماء","emoji":"🙌","strictness":0.8,"source":"Everyday words","words":[{"text":"school","emoji":"🏫","meaning_ar":"مدرسة","hint":"","accept":[]},{"text":"friend","emoji":"🤝","meaning_ar":"صديق","hint":"","accept":[]},{"text":"family","emoji":"👨‍👩‍👦","meaning_ar":"عائلة","hint":"fam-i-ly","accept":[]},{"text":"teacher","emoji":"👩‍🏫","meaning_ar":"معلم","hint":"tea-cher","accept":[]},{"text":"weekend","emoji":"🎉","meaning_ar":"عطلة نهاية الأسبوع","hint":"week-end","accept":[]},{"text":"homework","emoji":"📝","meaning_ar":"واجب منزلي","hint":"home-work","accept":[]}],"required_stars":0},
{"id":"o0b-days-months","track":"older","sort":7,"title":"Days and months","title_ar":"الأيام والشهور","emoji":"🗓️","strictness":0.82,"source":"Everyday words","words":[{"text":"Monday","emoji":"📅","meaning_ar":"الاثنين","hint":"","accept":[]},{"text":"Wednesday","emoji":"📅","meaning_ar":"الأربعاء","hint":"wens-day","accept":[]},{"text":"Thursday","emoji":"📅","meaning_ar":"الخميس","hint":"thurs-day","accept":[]},{"text":"February","emoji":"❄️","meaning_ar":"فبراير","hint":"feb-ru-ar-y","accept":[]},{"text":"August","emoji":"☀️","meaning_ar":"أغسطس","hint":"au-gust","accept":[]},{"text":"December","emoji":"🎄","meaning_ar":"ديسمبر","hint":"de-cem-ber","accept":[]}],"required_stars":2},
{"id":"o1-art","track":"older","sort":10,"title":"Celebrating creativity","title_ar":"الاحتفاء بالإبداع","emoji":"🎨","strictness":0.84,"source":"English P6 - Unit 1: Celebrating Creativity","words":[{"text":"canvas","emoji":"🖼️","meaning_ar":"قماش الرسم","hint":"can-vas","accept":["canvass"]},{"text":"gallery","emoji":"🏛️","meaning_ar":"معرض","hint":"gal-le-ry","accept":[]},{"text":"sketch","emoji":"✏️","meaning_ar":"رسم تخطيطي","hint":"","accept":[]},{"text":"mural","emoji":"🧱","meaning_ar":"لوحة جدارية","hint":"mu-ral","accept":[]},{"text":"palette","emoji":"🎨","meaning_ar":"لوحة الألوان","hint":"pal-ette","accept":["pallet"]},{"text":"sculpture","emoji":"🗿","meaning_ar":"منحوتة","hint":"sculp-ture","accept":[]},{"text":"sculptor","emoji":"🧑‍🎨","meaning_ar":"نحّات","hint":"sculp-tor","accept":[]},{"text":"masterpiece","emoji":"🌟","meaning_ar":"تحفة فنية","hint":"mas-ter-piece","accept":["master piece"]}],"required_stars":4},
{"id":"o1b-art2","track":"older","sort":13,"title":"Art words 2","title_ar":"كلمات الفن 2","emoji":"🖌️","strictness":0.84,"source":"English P6 - Unit 1","words":[{"text":"artist","emoji":"🧑‍🎨","meaning_ar":"فنان","hint":"art-ist","accept":[]},{"text":"painting","emoji":"🖼️","meaning_ar":"لوحة","hint":"paint-ing","accept":[]},{"text":"colourful","emoji":"🌈","meaning_ar":"ملوّن","hint":"col-our-ful","accept":["colorful"]},{"text":"exhibition","emoji":"🏛️","meaning_ar":"معرض","hint":"ex-hi-bi-tion","accept":[]},{"text":"portrait","emoji":"🖼️","meaning_ar":"صورة شخصية","hint":"por-trait","accept":[]},{"text":"statue","emoji":"🗽","meaning_ar":"تمثال","hint":"stat-ue","accept":[]}],"required_stars":6},
{"id":"o1c-both-either","track":"older","sort":16,"title":"Both, either, neither","title_ar":"كلاهما، إمّا، لا هذا ولا ذاك","emoji":"⚖️","strictness":0.8,"source":"English P6 - Unit 1: grammar","words":[{"text":"Both Omar and Ali like art","emoji":"🎨","meaning_ar":"عمر وعلي كلاهما يحبان الفن","hint":"","accept":[]},{"text":"You can either walk or run","emoji":"🏃","meaning_ar":"يمكنك إمّا أن تمشي أو تجري","hint":"","accept":[]},{"text":"Neither the tea nor the milk is hot","emoji":"☕","meaning_ar":"لا الشاي ولا الحليب ساخن","hint":"","accept":[]},{"text":"I like both drawing and music","emoji":"🎵","meaning_ar":"أحب الرسم والموسيقى كليهما","hint":"","accept":[]},{"text":"Either Sara or Mona will help","emoji":"🤝","meaning_ar":"إمّا سارة أو منى ستساعد","hint":"","accept":[]}],"required_stars":7},
{"id":"o2-inventions","track":"older","sort":20,"title":"Wonderful inventions","title_ar":"اختراعات رائعة","emoji":"💡","strictness":0.84,"source":"English P6 - Unit 2: Wonderful Inventions","words":[{"text":"gadget","emoji":"📟","meaning_ar":"أداة / جهاز صغير","hint":"gad-get","accept":[]},{"text":"fabric","emoji":"🧵","meaning_ar":"قماش","hint":"fab-ric","accept":[]},{"text":"thread","emoji":"🪡","meaning_ar":"خيط","hint":"","accept":[]},{"text":"blueprint","emoji":"📐","meaning_ar":"مخطط","hint":"blue-print","accept":["blue print"]},{"text":"accurate","emoji":"🎯","meaning_ar":"دقيق","hint":"ac-cu-rate","accept":[]},{"text":"assemble","emoji":"🔧","meaning_ar":"يُجمِّع","hint":"as-sem-ble","accept":[]},{"text":"rebuild","emoji":"🏗️","meaning_ar":"يعيد البناء","hint":"re-build","accept":["re build"]},{"text":"unhappy","emoji":"🙁","meaning_ar":"غير سعيد","hint":"un-hap-py","accept":[]}],"required_stars":9},
{"id":"o2b-inventions2","track":"older","sort":23,"title":"Inventors","title_ar":"المخترعون","emoji":"⚙️","strictness":0.84,"source":"English P6 - Unit 2","words":[{"text":"inventor","emoji":"👨‍🔬","meaning_ar":"مخترع","hint":"in-ven-tor","accept":[]},{"text":"invention","emoji":"💡","meaning_ar":"اختراع","hint":"in-ven-tion","accept":[]},{"text":"machine","emoji":"⚙️","meaning_ar":"آلة","hint":"ma-chine","accept":[]},{"text":"electricity","emoji":"⚡","meaning_ar":"كهرباء","hint":"e-lec-tric-i-ty","accept":[]},{"text":"telephone","emoji":"☎️","meaning_ar":"هاتف","hint":"tel-e-phone","accept":[]},{"text":"engine","emoji":"🚂","meaning_ar":"محرك","hint":"en-gine","accept":[]}],"required_stars":11},
{"id":"o2c-prefixes","track":"older","sort":26,"title":"Prefixes re- and un-","title_ar":"البادئات re و un","emoji":"🔁","strictness":0.84,"source":"English P6 - Unit 2: prefixes","words":[{"text":"redo","emoji":"🔁","meaning_ar":"يعيد العمل","hint":"re-do","accept":["re do"]},{"text":"rewrite","emoji":"✍️","meaning_ar":"يعيد الكتابة","hint":"re-write","accept":["re write"]},{"text":"unlock","emoji":"🔓","meaning_ar":"يفتح القفل","hint":"un-lock","accept":[]},{"text":"unkind","emoji":"😠","meaning_ar":"غير لطيف","hint":"un-kind","accept":[]},{"text":"retell","emoji":"🗣️","meaning_ar":"يعيد الحكي","hint":"re-tell","accept":["re tell"]},{"text":"unfair","emoji":"⚖️","meaning_ar":"غير عادل","hint":"un-fair","accept":[]}],"required_stars":13},
{"id":"o3-egypt","track":"older","sort":30,"title":"Hidden gems of Egypt","title_ar":"كنوز مصر الخفية","emoji":"🏺","strictness":0.84,"source":"English P6 - Unit 3: Hidden Gems of Egypt","words":[{"text":"mummy","emoji":"🧟","meaning_ar":"مومياء","hint":"mum-my","accept":[]},{"text":"monument","emoji":"🗿","meaning_ar":"أثر / نُصب","hint":"mon-u-ment","accept":[]},{"text":"chamber","emoji":"🚪","meaning_ar":"حجرة","hint":"cham-ber","accept":[]},{"text":"ruler","emoji":"👑","meaning_ar":"حاكم","hint":"rul-er","accept":[]},{"text":"discover","emoji":"🔍","meaning_ar":"يكتشف","hint":"dis-cov-er","accept":[]},{"text":"restore","emoji":"🛠️","meaning_ar":"يرمّم","hint":"re-store","accept":[]},{"text":"craftsman","emoji":"🔨","meaning_ar":"حِرفي","hint":"crafts-man","accept":["craftsmen"]},{"text":"archaeologist","emoji":"⛏️","meaning_ar":"عالم آثار","hint":"ar-chae-ol-o-gist","accept":["archeologist"]}],"required_stars":14},
{"id":"o3b-egypt2","track":"older","sort":33,"title":"Ancient Egypt","title_ar":"مصر القديمة","emoji":"🔺","strictness":0.84,"source":"English P6 - Unit 3","words":[{"text":"pyramid","emoji":"🔺","meaning_ar":"هرم","hint":"pyr-a-mid","accept":[]},{"text":"temple","emoji":"🏛️","meaning_ar":"معبد","hint":"tem-ple","accept":[]},{"text":"pharaoh","emoji":"👑","meaning_ar":"فرعون","hint":"phar-aoh","accept":["pharoah"]},{"text":"tomb","emoji":"⚱️","meaning_ar":"مقبرة","hint":"toom (b is silent)","accept":[]},{"text":"ancient","emoji":"📜","meaning_ar":"قديم","hint":"an-cient","accept":[]},{"text":"papyrus","emoji":"📜","meaning_ar":"ورق البردي","hint":"pa-py-rus","accept":[]}],"required_stars":16},
{"id":"o3c-present-perfect","track":"older","sort":36,"title":"Have you ever...?","title_ar":"هل سبق لك...؟","emoji":"✅","strictness":0.8,"source":"English P6 - Unit 3: present perfect","words":[{"text":"I have visited Luxor","emoji":"🏛️","meaning_ar":"لقد زرت الأقصر","hint":"","accept":["i've visited luxor"]},{"text":"She has finished her homework","emoji":"📝","meaning_ar":"لقد أنهت واجبها","hint":"","accept":["she's finished her homework"]},{"text":"Have you ever seen the pyramids","emoji":"🔺","meaning_ar":"هل رأيت الأهرامات من قبل؟","hint":"","accept":[]},{"text":"They have discovered a tomb","emoji":"⚱️","meaning_ar":"لقد اكتشفوا مقبرة","hint":"","accept":["they've discovered a tomb"]},{"text":"We have never been to Aswan","emoji":"🏝️","meaning_ar":"لم نذهب إلى أسوان أبدًا","hint":"","accept":["we've never been to aswan"]}],"required_stars":18},
{"id":"o4-industry","track":"older","sort":40,"title":"Egypt on the move","title_ar":"مصر تتحرك","emoji":"🏭","strictness":0.84,"source":"English P6 - Unit 4: Egypt on the Move","words":[{"text":"steel","emoji":"🔩","meaning_ar":"فولاذ","hint":"","accept":["steal"]},{"text":"textile","emoji":"🧶","meaning_ar":"نسيج","hint":"tex-tile","accept":[]},{"text":"highway","emoji":"🛣️","meaning_ar":"طريق سريع","hint":"high-way","accept":["high way"]},{"text":"border","emoji":"🗺️","meaning_ar":"حدود","hint":"bor-der","accept":["boarder"]},{"text":"innovation","emoji":"🚀","meaning_ar":"ابتكار","hint":"in-no-va-tion","accept":[]},{"text":"manufacture","emoji":"🏭","meaning_ar":"يصنّع","hint":"man-u-fac-ture","accept":[]},{"text":"infrastructure","emoji":"🌉","meaning_ar":"البنية التحتية","hint":"in-fra-struc-ture","accept":[]},{"text":"self-reliant","emoji":"💪","meaning_ar":"معتمد على نفسه","hint":"self - re-li-ant","accept":["self reliant"]}],"required_stars":20},
{"id":"o4b-industry2","track":"older","sort":43,"title":"Factories","title_ar":"المصانع","emoji":"🏭","strictness":0.84,"source":"English P6 - Unit 4","words":[{"text":"factory","emoji":"🏭","meaning_ar":"مصنع","hint":"fac-to-ry","accept":[]},{"text":"product","emoji":"📦","meaning_ar":"منتج","hint":"prod-uct","accept":[]},{"text":"export","emoji":"🚢","meaning_ar":"يصدّر","hint":"ex-port","accept":[]},{"text":"cotton","emoji":"☁️","meaning_ar":"قطن","hint":"cot-ton","accept":[]},{"text":"engineer","emoji":"👷","meaning_ar":"مهندس","hint":"en-gi-neer","accept":[]},{"text":"technology","emoji":"🤖","meaning_ar":"تكنولوجيا","hint":"tech-nol-o-gy","accept":[]}],"required_stars":21},
{"id":"o4c-used-to","track":"older","sort":46,"title":"Used to","title_ar":"كان يفعل (used to)","emoji":"⏳","strictness":0.8,"source":"English P6 - Unit 4: used to","words":[{"text":"I used to play in the garden","emoji":"🌳","meaning_ar":"كنت ألعب في الحديقة","hint":"","accept":[]},{"text":"We didn't use to have a car","emoji":"🚗","meaning_ar":"لم تكن لدينا سيارة","hint":"","accept":["we did not use to have a car"]},{"text":"Did you use to live here","emoji":"🏠","meaning_ar":"هل كنت تعيش هنا؟","hint":"","accept":[]},{"text":"My grandfather used to farm","emoji":"👴","meaning_ar":"كان جدي يزرع","hint":"","accept":[]},{"text":"People used to write letters","emoji":"✉️","meaning_ar":"كان الناس يكتبون الرسائل","hint":"","accept":[]}],"required_stars":23},
{"id":"o5-transport","track":"older","sort":50,"title":"Smart transportation","title_ar":"النقل الذكي","emoji":"🚝","strictness":0.84,"source":"English P6 - Unit 5: Smart Transportation","words":[{"text":"monorail","emoji":"🚝","meaning_ar":"قطار أحادي","hint":"mon-o-rail","accept":["mono rail"]},{"text":"escalator","emoji":"🛗","meaning_ar":"سلم متحرك","hint":"es-ca-la-tor","accept":[]},{"text":"ticket machine","emoji":"🎫","meaning_ar":"آلة التذاكر","hint":"tick-et ma-chine","accept":[]},{"text":"pollution","emoji":"🏭","meaning_ar":"تلوث","hint":"pol-lu-tion","accept":[]},{"text":"digital","emoji":"💻","meaning_ar":"رقمي","hint":"dig-i-tal","accept":[]},{"text":"renewable","emoji":"♻️","meaning_ar":"متجدد","hint":"re-new-a-ble","accept":[]},{"text":"eco-friendly","emoji":"🌱","meaning_ar":"صديق للبيئة","hint":"e-co friend-ly","accept":["eco friendly"]},{"text":"self-driving","emoji":"🚘","meaning_ar":"ذاتي القيادة","hint":"self driv-ing","accept":["self driving"]}],"required_stars":25},
{"id":"o5b-transport2","track":"older","sort":53,"title":"Getting around","title_ar":"التنقل","emoji":"🚉","strictness":0.84,"source":"English P6 - Unit 5","words":[{"text":"passenger","emoji":"🧳","meaning_ar":"راكب","hint":"pas-sen-ger","accept":[]},{"text":"platform","emoji":"🚉","meaning_ar":"رصيف القطار","hint":"plat-form","accept":[]},{"text":"traffic","emoji":"🚦","meaning_ar":"حركة المرور","hint":"traf-fic","accept":[]},{"text":"station","emoji":"🚏","meaning_ar":"محطة","hint":"sta-tion","accept":[]},{"text":"electric car","emoji":"🔋","meaning_ar":"سيارة كهربائية","hint":"e-lec-tric car","accept":[]},{"text":"underground","emoji":"🚇","meaning_ar":"مترو الأنفاق","hint":"un-der-ground","accept":[]}],"required_stars":27},
{"id":"o5c-conditional","track":"older","sort":56,"title":"If... will...","title_ar":"إذا... سوف...","emoji":"🔀","strictness":0.8,"source":"English P6 - Unit 5: first conditional","words":[{"text":"If you study you will pass","emoji":"📚","meaning_ar":"إذا ذاكرت ستنجح","hint":"","accept":["if you study you'll pass"]},{"text":"If it is sunny we will swim","emoji":"☀️","meaning_ar":"إذا كان الجو مشمسًا سنسبح","hint":"","accept":["if it's sunny we'll swim"]},{"text":"If I have time I will call you","emoji":"📞","meaning_ar":"إذا كان لدي وقت سأتصل بك","hint":"","accept":["if i have time i'll call you"]},{"text":"You will be late if you don't hurry","emoji":"⏰","meaning_ar":"ستتأخر إذا لم تسرع","hint":"","accept":["you'll be late if you don't hurry"]},{"text":"If we recycle we will save energy","emoji":"♻️","meaning_ar":"إذا أعدنا التدوير سنوفّر الطاقة","hint":"","accept":["if we recycle we'll save energy"]}],"required_stars":28},
{"id":"o6-library","track":"older","sort":60,"title":"The library that time forgot","title_ar":"المكتبة المنسية","emoji":"📚","strictness":0.84,"source":"English P6 - Unit 6: The Library That Time Forgot","words":[{"text":"library","emoji":"📚","meaning_ar":"مكتبة","hint":"li-brar-y","accept":[]},{"text":"treasure","emoji":"💰","meaning_ar":"كنز","hint":"trea-sure","accept":[]},{"text":"fountain","emoji":"⛲","meaning_ar":"نافورة","hint":"foun-tain","accept":[]},{"text":"rusty","emoji":"🔧","meaning_ar":"صدئ","hint":"rust-y","accept":[]},{"text":"clogged","emoji":"🚱","meaning_ar":"مسدود","hint":"","accept":["clogs"]},{"text":"creaked","emoji":"🚪","meaning_ar":"صرّ / أصدر صريراً","hint":"","accept":["creeked"]},{"text":"stacks","emoji":"📚","meaning_ar":"أكوام","hint":"","accept":["stax"]},{"text":"mayor","emoji":"🎩","meaning_ar":"عمدة","hint":"","accept":["mare","mayer"]}],"required_stars":30},
{"id":"o6b-library2","track":"older","sort":63,"title":"In the library","title_ar":"في المكتبة","emoji":"📖","strictness":0.84,"source":"English P6 - Unit 6","words":[{"text":"librarian","emoji":"🧑‍🏫","meaning_ar":"أمين المكتبة","hint":"li-brar-i-an","accept":[]},{"text":"shelf","emoji":"🗄️","meaning_ar":"رف","hint":"","accept":[]},{"text":"novel","emoji":"📕","meaning_ar":"رواية","hint":"nov-el","accept":[]},{"text":"author","emoji":"✍️","meaning_ar":"مؤلف","hint":"au-thor","accept":[]},{"text":"dusty","emoji":"🌫️","meaning_ar":"مغبّر","hint":"dust-y","accept":[]},{"text":"mysterious","emoji":"🕵️","meaning_ar":"غامض","hint":"mys-te-ri-ous","accept":[]}],"required_stars":32},
{"id":"o6c-past-continuous","track":"older","sort":66,"title":"I was doing...","title_ar":"كنت أفعل...","emoji":"🎬","strictness":0.8,"source":"English P6 - Unit 6: past continuous","words":[{"text":"I was reading when the phone rang","emoji":"📞","meaning_ar":"كنت أقرأ عندما رنّ الهاتف","hint":"","accept":[]},{"text":"They were playing football","emoji":"⚽","meaning_ar":"كانوا يلعبون كرة القدم","hint":"","accept":[]},{"text":"What were you doing yesterday","emoji":"❓","meaning_ar":"ماذا كنت تفعل أمس؟","hint":"","accept":[]},{"text":"It was raining all day","emoji":"🌧️","meaning_ar":"كانت تمطر طوال اليوم","hint":"","accept":[]}],"required_stars":34},
{"id":"o7-math","track":"older","sort":70,"title":"Math words","title_ar":"كلمات الرياضيات","emoji":"📐","strictness":0.84,"source":"Math P6 - Units 8-13","words":[{"text":"fraction","emoji":"½","meaning_ar":"كسر","hint":"frac-tion","accept":[]},{"text":"decimal","emoji":"🔢","meaning_ar":"عدد عشري","hint":"dec-i-mal","accept":[]},{"text":"ratio","emoji":"⚖️","meaning_ar":"نسبة","hint":"ra-ti-o","accept":[]},{"text":"percent","emoji":"💯","meaning_ar":"نسبة مئوية","hint":"per-cent","accept":["per cent"]},{"text":"unit rate","emoji":"🏷️","meaning_ar":"معدل الوحدة","hint":"u-nit rate","accept":[]},{"text":"coordinates","emoji":"📍","meaning_ar":"إحداثيات","hint":"co-or-di-nates","accept":["coordinate"]},{"text":"polygon","emoji":"🔷","meaning_ar":"مضلع","hint":"pol-y-gon","accept":[]},{"text":"volume","emoji":"🧊","meaning_ar":"الحجم","hint":"vol-ume","accept":[]}],"required_stars":35},
{"id":"o7b-fractions","track":"older","sort":73,"title":"Fractions","title_ar":"الكسور","emoji":"🍕","strictness":0.84,"source":"Math P6","words":[{"text":"numerator","emoji":"🔝","meaning_ar":"البسط","hint":"nu-mer-a-tor","accept":[]},{"text":"denominator","emoji":"⬇️","meaning_ar":"المقام","hint":"de-nom-i-na-tor","accept":[]},{"text":"equivalent","emoji":"🟰","meaning_ar":"مكافئ","hint":"e-quiv-a-lent","accept":[]},{"text":"divisible","emoji":"➗","meaning_ar":"قابل للقسمة","hint":"di-vis-i-ble","accept":[]},{"text":"perimeter","emoji":"📏","meaning_ar":"المحيط","hint":"pe-rim-e-ter","accept":[]},{"text":"area","emoji":"⬛","meaning_ar":"المساحة","hint":"ar-e-a","accept":[]}],"required_stars":37},
{"id":"o7c-geometry","track":"older","sort":76,"title":"Shapes","title_ar":"الأشكال","emoji":"📐","strictness":0.84,"source":"Math P6 - Geometry","words":[{"text":"triangle","emoji":"🔺","meaning_ar":"مثلث","hint":"tri-an-gle","accept":[]},{"text":"rectangle","emoji":"▭","meaning_ar":"مستطيل","hint":"rec-tan-gle","accept":[]},{"text":"parallelogram","emoji":"▱","meaning_ar":"متوازي أضلاع","hint":"par-al-lel-o-gram","accept":[]},{"text":"angle","emoji":"📐","meaning_ar":"زاوية","hint":"an-gle","accept":[]},{"text":"diagonal","emoji":"⟋","meaning_ar":"قطر","hint":"di-ag-o-nal","accept":[]},{"text":"cube","emoji":"🧊","meaning_ar":"مكعب","hint":"","accept":[]}],"required_stars":39},
{"id":"o8-sentences","track":"older","sort":80,"title":"Grammar sentences","title_ar":"جمل القواعد","emoji":"💬","strictness":0.8,"source":"English P6 - Units 1-6 (grammar)","words":[{"text":"Have you been to Aswan","emoji":"🏝️","meaning_ar":"هل زرت أسوان؟","hint":"","accept":[]},{"text":"We used to travel by train","emoji":"🚆","meaning_ar":"كنا نسافر بالقطار","hint":"","accept":[]},{"text":"If it rains we will stay at home","emoji":"🌧️","meaning_ar":"إذا أمطرت سنبقى في البيت","hint":"","accept":["if it rains we'll stay at home"]},{"text":"She was walking when it started to rain","emoji":"🚶‍♀️","meaning_ar":"كانت تمشي عندما بدأ المطر","hint":"","accept":[]},{"text":"The man who painted this is famous","emoji":"🧑‍🎨","meaning_ar":"الرجل الذي رسم هذه مشهور","hint":"","accept":[]},{"text":"Neither Ali nor Sara was late","emoji":"⏰","meaning_ar":"لا علي ولا سارة تأخرا","hint":"","accept":[]}],"required_stars":41},
{"id":"o9-science","track":"older","sort":83,"title":"Science","title_ar":"العلوم","emoji":"🔬","strictness":0.84,"source":"Science words","words":[{"text":"planet","emoji":"🪐","meaning_ar":"كوكب","hint":"plan-et","accept":[]},{"text":"energy","emoji":"⚡","meaning_ar":"طاقة","hint":"en-er-gy","accept":[]},{"text":"oxygen","emoji":"🫧","meaning_ar":"أكسجين","hint":"ox-y-gen","accept":[]},{"text":"volcano","emoji":"🌋","meaning_ar":"بركان","hint":"vol-ca-no","accept":[]},{"text":"environment","emoji":"🌍","meaning_ar":"البيئة","hint":"en-vi-ron-ment","accept":[]},{"text":"temperature","emoji":"🌡️","meaning_ar":"درجة الحرارة","hint":"tem-per-a-ture","accept":[]}],"required_stars":42},
{"id":"o9b-tricky","track":"older","sort":86,"title":"Tricky spellings","title_ar":"كلمات صعبة النطق","emoji":"🧩","strictness":0.84,"source":"Silent letters","words":[{"text":"vegetable","emoji":"🥦","meaning_ar":"خضار","hint":"veg-ta-ble","accept":["vegetables"]},{"text":"island","emoji":"🏝️","meaning_ar":"جزيرة","hint":"eye-land (s is silent)","accept":[]},{"text":"knowledge","emoji":"🧠","meaning_ar":"معرفة","hint":"nol-edge (k is silent)","accept":[]},{"text":"answer","emoji":"💬","meaning_ar":"إجابة","hint":"an-ser (w is silent)","accept":[]},{"text":"through","emoji":"➡️","meaning_ar":"عبر","hint":"throo","accept":["threw"]},{"text":"enough","emoji":"✋","meaning_ar":"يكفي","hint":"e-nuff","accept":[]}],"required_stars":44},
{"id":"o10-review","track":"older","sort":90,"title":"Big review","title_ar":"مراجعة كبيرة","emoji":"🏆","strictness":0.86,"source":"Review of all stages","words":[{"text":"masterpiece","emoji":"🌟","meaning_ar":"تحفة فنية","hint":"mas-ter-piece","accept":[]},{"text":"archaeologist","emoji":"⛏️","meaning_ar":"عالم آثار","hint":"ar-chae-ol-o-gist","accept":["archeologist"]},{"text":"infrastructure","emoji":"🌉","meaning_ar":"البنية التحتية","hint":"in-fra-struc-ture","accept":[]},{"text":"escalator","emoji":"🛗","meaning_ar":"سلم متحرك","hint":"es-ca-la-tor","accept":[]},{"text":"fraction","emoji":"½","meaning_ar":"كسر","hint":"frac-tion","accept":[]},{"text":"pendulum","emoji":"🕰️","meaning_ar":"بندول","hint":"pen-du-lum","accept":[]}],"required_stars":46},
{"id":"o10b-long-sentences","track":"older","sort":93,"title":"Long sentences","title_ar":"جمل طويلة","emoji":"📜","strictness":0.8,"source":"English P6 - Review","words":[{"text":"Libraries help people learn new things every day","emoji":"📚","meaning_ar":"المكتبات تساعد الناس على تعلّم أشياء جديدة كل يوم","hint":"","accept":[]},{"text":"Clean energy is good for our planet","emoji":"🌍","meaning_ar":"الطاقة النظيفة مفيدة لكوكبنا","hint":"","accept":[]},{"text":"My favourite subject at school is science","emoji":"🔬","meaning_ar":"مادتي المفضلة في المدرسة هي العلوم","hint":"","accept":["my favorite subject at school is science"]},{"text":"I would like to visit the Egyptian Museum","emoji":"🏛️","meaning_ar":"أودّ زيارة المتحف المصري","hint":"","accept":["i'd like to visit the egyptian museum"]}],"required_stars":48},
{"id":"y1-sounds","track":"young","sort":10,"title":"Sounds: st, sl, tr, gr","title_ar":"أصوات: st, sl, tr, gr","emoji":"🚂","strictness":0.8,"source":"English P3 - Unit 1: Sounds sl, st, gr, tr","words":[{"text":"stop","emoji":"🛑","meaning_ar":"قِف","hint":"","accept":[]},{"text":"star","emoji":"⭐","meaning_ar":"نجمة","hint":"","accept":[]},{"text":"step","emoji":"👣","meaning_ar":"خطوة","hint":"","accept":[]},{"text":"slow","emoji":"🐢","meaning_ar":"بطيء","hint":"","accept":[]},{"text":"sleep","emoji":"😴","meaning_ar":"ينام","hint":"","accept":[]},{"text":"train","emoji":"🚆","meaning_ar":"قطار","hint":"","accept":[]},{"text":"truck","emoji":"🚚","meaning_ar":"شاحنة","hint":"","accept":["trucks"]},{"text":"green","emoji":"🟢","meaning_ar":"أخضر","hint":"","accept":[]}],"required_stars":0},
{"id":"y1b-colors","track":"young","sort":13,"title":"Colours","title_ar":"الألوان","emoji":"🎨","strictness":0.78,"source":"Everyday words","words":[{"text":"red","emoji":"🔴","meaning_ar":"أحمر","hint":"","accept":["read"]},{"text":"blue","emoji":"🔵","meaning_ar":"أزرق","hint":"","accept":["blew"]},{"text":"green","emoji":"🟢","meaning_ar":"أخضر","hint":"","accept":[]},{"text":"yellow","emoji":"🟡","meaning_ar":"أصفر","hint":"","accept":[]},{"text":"pink","emoji":"🩷","meaning_ar":"وردي","hint":"","accept":[]},{"text":"orange","emoji":"🟠","meaning_ar":"برتقالي","hint":"","accept":[]}],"required_stars":2},
{"id":"y1c-numbers","track":"young","sort":16,"title":"Numbers 1-6","title_ar":"الأرقام 1-6","emoji":"🔢","strictness":0.78,"source":"Math P3","words":[{"text":"one","emoji":"1️⃣","meaning_ar":"واحد","hint":"","accept":["won","1"]},{"text":"two","emoji":"2️⃣","meaning_ar":"اثنان","hint":"","accept":["to","too","2"]},{"text":"three","emoji":"3️⃣","meaning_ar":"ثلاثة","hint":"","accept":["3"]},{"text":"four","emoji":"4️⃣","meaning_ar":"أربعة","hint":"","accept":["for","fore","4"]},{"text":"five","emoji":"5️⃣","meaning_ar":"خمسة","hint":"","accept":["5"]},{"text":"six","emoji":"6️⃣","meaning_ar":"ستة","hint":"","accept":["6"]}],"required_stars":4},
{"id":"y2-safety","track":"young","sort":20,"title":"Safety","title_ar":"السلامة","emoji":"⛑️","strictness":0.8,"source":"English P3 - Unit 1: Safety","words":[{"text":"helmet","emoji":"⛑️","meaning_ar":"خوذة","hint":"hel-met","accept":[]},{"text":"careful","emoji":"⚠️","meaning_ar":"حذِر","hint":"care-ful","accept":[]},{"text":"sign","emoji":"🪧","meaning_ar":"إشارة","hint":"","accept":["sine"]},{"text":"stranger","emoji":"🧍","meaning_ar":"شخص غريب","hint":"stran-ger","accept":[]},{"text":"ambulance","emoji":"🚑","meaning_ar":"سيارة إسعاف","hint":"am-bu-lance","accept":[]},{"text":"seat belt","emoji":"🚗","meaning_ar":"حزام الأمان","hint":"seat - belt","accept":["seatbelt"]},{"text":"dangerous","emoji":"⚡","meaning_ar":"خطير","hint":"dan-ger-ous","accept":[]},{"text":"emergency","emoji":"🚨","meaning_ar":"طوارئ","hint":"e-mer-gen-cy","accept":[]}],"required_stars":6},
{"id":"y2b-body","track":"young","sort":23,"title":"My body","title_ar":"جسمي","emoji":"🧒","strictness":0.8,"source":"Everyday words","words":[{"text":"head","emoji":"🙆","meaning_ar":"رأس","hint":"","accept":[]},{"text":"hand","emoji":"✋","meaning_ar":"يد","hint":"","accept":[]},{"text":"eye","emoji":"👁️","meaning_ar":"عين","hint":"","accept":["i","aye"]},{"text":"nose","emoji":"👃","meaning_ar":"أنف","hint":"","accept":["knows"]},{"text":"ear","emoji":"👂","meaning_ar":"أذن","hint":"","accept":[]},{"text":"foot","emoji":"🦶","meaning_ar":"قدم","hint":"","accept":[]}],"required_stars":7},
{"id":"y2c-short-a","track":"young","sort":26,"title":"Short a: cat, hat","title_ar":"صوت a القصير","emoji":"🐈","strictness":0.82,"source":"English P3 - Phonics","words":[{"text":"cat","emoji":"🐈","meaning_ar":"قطة","hint":"","accept":[]},{"text":"hat","emoji":"👒","meaning_ar":"قبعة","hint":"","accept":[]},{"text":"bat","emoji":"🦇","meaning_ar":"خفاش","hint":"","accept":[]},{"text":"map","emoji":"🗺️","meaning_ar":"خريطة","hint":"","accept":[]},{"text":"bag","emoji":"👜","meaning_ar":"حقيبة","hint":"","accept":[]},{"text":"jam","emoji":"🍓","meaning_ar":"مربى","hint":"","accept":[]}],"required_stars":9},
{"id":"y3-food","track":"young","sort":30,"title":"Food and health","title_ar":"الطعام والصحة","emoji":"🍎","strictness":0.8,"source":"English P3 - Unit 2: Food and Health","words":[{"text":"apple","emoji":"🍎","meaning_ar":"تفاحة","hint":"ap-ple","accept":[]},{"text":"milk","emoji":"🥛","meaning_ar":"حليب","hint":"","accept":[]},{"text":"rice","emoji":"🍚","meaning_ar":"أرز","hint":"","accept":[]},{"text":"water","emoji":"💧","meaning_ar":"ماء","hint":"wa-ter","accept":[]},{"text":"breakfast","emoji":"🍳","meaning_ar":"الفطور","hint":"break-fast","accept":[]},{"text":"lunch","emoji":"🥪","meaning_ar":"الغداء","hint":"","accept":[]},{"text":"dinner","emoji":"🍽️","meaning_ar":"العشاء","hint":"din-ner","accept":[]},{"text":"vegetables","emoji":"🥦","meaning_ar":"خضروات","hint":"veg-e-ta-bles","accept":["vegetable"]}],"required_stars":11},
{"id":"y3b-healthy","track":"young","sort":33,"title":"Healthy food","title_ar":"طعام صحي","emoji":"🥕","strictness":0.8,"source":"English P3 - Unit 2","words":[{"text":"fruit","emoji":"🍇","meaning_ar":"فاكهة","hint":"","accept":[]},{"text":"juice","emoji":"🧃","meaning_ar":"عصير","hint":"","accept":[]},{"text":"egg","emoji":"🥚","meaning_ar":"بيضة","hint":"","accept":[]},{"text":"bread","emoji":"🍞","meaning_ar":"خبز","hint":"","accept":[]},{"text":"cheese","emoji":"🧀","meaning_ar":"جبن","hint":"","accept":[]},{"text":"carrot","emoji":"🥕","meaning_ar":"جزر","hint":"car-rot","accept":[]}],"required_stars":13},
{"id":"y3c-long-e","track":"young","sort":36,"title":"Long e: ee, ea","title_ar":"صوت e الطويل","emoji":"🐝","strictness":0.84,"source":"English P3 - Unit 2: long e","words":[{"text":"tree","emoji":"🌳","meaning_ar":"شجرة","hint":"","accept":[]},{"text":"bee","emoji":"🐝","meaning_ar":"نحلة","hint":"","accept":["b","be"]},{"text":"sea","emoji":"🌊","meaning_ar":"بحر","hint":"","accept":["see","c"]},{"text":"leaf","emoji":"🍃","meaning_ar":"ورقة شجر","hint":"","accept":[]},{"text":"sheep","emoji":"🐑","meaning_ar":"خروف","hint":"","accept":[]},{"text":"teeth","emoji":"🦷","meaning_ar":"أسنان","hint":"","accept":[]}],"required_stars":14},
{"id":"y4-magic-e","track":"young","sort":40,"title":"Magic e: cap or cape?","title_ar":"حرف e السحري","emoji":"🪄","strictness":0.93,"source":"English P3 - Unit 3: Magic e","words":[{"text":"cap","emoji":"🧢","meaning_ar":"قبعة","hint":"","accept":[]},{"text":"cape","emoji":"🦸","meaning_ar":"عباءة","hint":"c-a-pe (a says its name)","accept":[]},{"text":"hop","emoji":"🐇","meaning_ar":"يقفز","hint":"","accept":[]},{"text":"hope","emoji":"🙏","meaning_ar":"أمل","hint":"h-o-pe (o says its name)","accept":[]},{"text":"kit","emoji":"🧰","meaning_ar":"عُدّة","hint":"","accept":[]},{"text":"kite","emoji":"🪁","meaning_ar":"طائرة ورقية","hint":"k-i-te (i says its name)","accept":[]},{"text":"cub","emoji":"🐻","meaning_ar":"شبل / صغير الدب","hint":"","accept":["cubs"]},{"text":"cube","emoji":"🧊","meaning_ar":"مكعب","hint":"c-u-be (u says its name)","accept":[]}],"required_stars":16},
{"id":"y4b-magic-e2","track":"young","sort":43,"title":"Magic e: tap or tape?","title_ar":"حرف e السحري 2","emoji":"✨","strictness":0.93,"source":"English P3 - Unit 3: Magic e","words":[{"text":"pin","emoji":"📌","meaning_ar":"دبوس","hint":"","accept":[]},{"text":"pine","emoji":"🌲","meaning_ar":"صنوبر","hint":"p-i-ne (i says its name)","accept":[]},{"text":"tap","emoji":"🚰","meaning_ar":"صنبور","hint":"","accept":[]},{"text":"tape","emoji":"📼","meaning_ar":"شريط","hint":"t-a-pe (a says its name)","accept":[]},{"text":"not","emoji":"🚫","meaning_ar":"ليس","hint":"","accept":["knot"]},{"text":"note","emoji":"📝","meaning_ar":"ملاحظة","hint":"n-o-te (o says its name)","accept":[]}],"required_stars":18},
{"id":"y4c-sequence","track":"young","sort":46,"title":"First, then, finally","title_ar":"أولًا ثم أخيرًا","emoji":"🔢","strictness":0.8,"source":"English P3 - Unit 3","words":[{"text":"first","emoji":"1️⃣","meaning_ar":"أولًا","hint":"","accept":[]},{"text":"then","emoji":"➡️","meaning_ar":"ثم","hint":"","accept":[]},{"text":"next","emoji":"⏭️","meaning_ar":"بعد ذلك","hint":"","accept":[]},{"text":"finally","emoji":"🏁","meaning_ar":"أخيرًا","hint":"fi-nal-ly","accept":[]},{"text":"before","emoji":"⬅️","meaning_ar":"قبل","hint":"be-fore","accept":[]},{"text":"after","emoji":"➡️","meaning_ar":"بعد","hint":"af-ter","accept":[]}],"required_stars":20},
{"id":"y5-heroes","track":"young","sort":50,"title":"Heroes around us","title_ar":"أبطال حولنا","emoji":"🚒","strictness":0.8,"source":"English P3 - Unit 3: Heroes Around Us","words":[{"text":"firefighter","emoji":"👩‍🚒","meaning_ar":"رجل إطفاء","hint":"fire-fight-er","accept":["fire fighter","firefighters"]},{"text":"pilot","emoji":"👨‍✈️","meaning_ar":"طيار","hint":"pi-lot","accept":[]},{"text":"teacher","emoji":"👩‍🏫","meaning_ar":"معلم","hint":"tea-cher","accept":[]},{"text":"chef","emoji":"👨‍🍳","meaning_ar":"طاهٍ","hint":"","accept":["shef"]},{"text":"brave","emoji":"🦁","meaning_ar":"شجاع","hint":"","accept":[]},{"text":"ladder","emoji":"🪜","meaning_ar":"سلّم","hint":"lad-der","accept":[]},{"text":"medal","emoji":"🏅","meaning_ar":"ميدالية","hint":"med-al","accept":["metal"]},{"text":"uniform","emoji":"🦺","meaning_ar":"زي موحد","hint":"u-ni-form","accept":[]}],"required_stars":21},
{"id":"y5b-jobs","track":"young","sort":53,"title":"Jobs","title_ar":"المهن","emoji":"👩‍⚕️","strictness":0.8,"source":"English P3 - Unit 3","words":[{"text":"doctor","emoji":"👨‍⚕️","meaning_ar":"طبيب","hint":"doc-tor","accept":[]},{"text":"nurse","emoji":"👩‍⚕️","meaning_ar":"ممرضة","hint":"","accept":[]},{"text":"farmer","emoji":"👨‍🌾","meaning_ar":"مزارع","hint":"farm-er","accept":[]},{"text":"driver","emoji":"🚕","meaning_ar":"سائق","hint":"driv-er","accept":[]},{"text":"dentist","emoji":"🦷","meaning_ar":"طبيب أسنان","hint":"den-tist","accept":[]},{"text":"police officer","emoji":"👮","meaning_ar":"شرطي","hint":"po-lice of-fi-cer","accept":[]}],"required_stars":23},
{"id":"y5c-places","track":"young","sort":56,"title":"Places in town","title_ar":"أماكن في المدينة","emoji":"🏫","strictness":0.8,"source":"Everyday words","words":[{"text":"school","emoji":"🏫","meaning_ar":"مدرسة","hint":"","accept":[]},{"text":"hospital","emoji":"🏥","meaning_ar":"مستشفى","hint":"hos-pi-tal","accept":[]},{"text":"park","emoji":"🏞️","meaning_ar":"حديقة","hint":"","accept":[]},{"text":"shop","emoji":"🏪","meaning_ar":"متجر","hint":"","accept":[]},{"text":"house","emoji":"🏠","meaning_ar":"بيت","hint":"","accept":[]},{"text":"mosque","emoji":"🕌","meaning_ar":"مسجد","hint":"","accept":["mosk"]}],"required_stars":25},
{"id":"y6-tech","track":"young","sort":60,"title":"Technology","title_ar":"التكنولوجيا","emoji":"🤖","strictness":0.8,"source":"English P3 - Unit 4: Living with Technology","words":[{"text":"phone","emoji":"📱","meaning_ar":"هاتف","hint":"","accept":[]},{"text":"robot","emoji":"🤖","meaning_ar":"روبوت","hint":"ro-bot","accept":[]},{"text":"camera","emoji":"📷","meaning_ar":"كاميرا","hint":"cam-er-a","accept":[]},{"text":"tablet","emoji":"📲","meaning_ar":"جهاز لوحي","hint":"tab-let","accept":[]},{"text":"screen","emoji":"🖥️","meaning_ar":"شاشة","hint":"","accept":[]},{"text":"keyboard","emoji":"⌨️","meaning_ar":"لوحة المفاتيح","hint":"key-board","accept":["key board"]},{"text":"button","emoji":"🔘","meaning_ar":"زر","hint":"but-ton","accept":[]},{"text":"password","emoji":"🔑","meaning_ar":"كلمة المرور","hint":"pass-word","accept":["pass word"]}],"required_stars":27},
{"id":"y6b-tech2","track":"young","sort":63,"title":"More technology","title_ar":"تكنولوجيا أكثر","emoji":"💻","strictness":0.8,"source":"English P3 - Unit 4","words":[{"text":"computer","emoji":"💻","meaning_ar":"حاسوب","hint":"com-pu-ter","accept":[]},{"text":"internet","emoji":"🌐","meaning_ar":"الإنترنت","hint":"in-ter-net","accept":[]},{"text":"message","emoji":"💬","meaning_ar":"رسالة","hint":"mes-sage","accept":[]},{"text":"video","emoji":"🎬","meaning_ar":"فيديو","hint":"vid-e-o","accept":[]},{"text":"drone","emoji":"🛸","meaning_ar":"طائرة مسيّرة","hint":"","accept":[]},{"text":"charger","emoji":"🔌","meaning_ar":"شاحن","hint":"char-ger","accept":[]}],"required_stars":28},
{"id":"y6c-short-o-u","track":"young","sort":66,"title":"Short o and u","title_ar":"صوت o و u القصير","emoji":"🐶","strictness":0.82,"source":"English P3 - Phonics","words":[{"text":"dog","emoji":"🐶","meaning_ar":"كلب","hint":"","accept":[]},{"text":"box","emoji":"📦","meaning_ar":"صندوق","hint":"","accept":[]},{"text":"sun","emoji":"☀️","meaning_ar":"شمس","hint":"","accept":["son"]},{"text":"bus","emoji":"🚌","meaning_ar":"حافلة","hint":"","accept":[]},{"text":"cup","emoji":"☕","meaning_ar":"كوب","hint":"","accept":[]},{"text":"duck","emoji":"🦆","meaning_ar":"بطة","hint":"","accept":[]}],"required_stars":30},
{"id":"y7-animals","track":"young","sort":70,"title":"Animals and habitats","title_ar":"الحيوانات وبيئاتها","emoji":"🐪","strictness":0.8,"source":"English P3 - Unit 5: Animals and Habitats","words":[{"text":"camel","emoji":"🐪","meaning_ar":"جمل","hint":"cam-el","accept":[]},{"text":"monkey","emoji":"🐒","meaning_ar":"قرد","hint":"mon-key","accept":[]},{"text":"fish","emoji":"🐟","meaning_ar":"سمكة","hint":"","accept":[]},{"text":"owl","emoji":"🦉","meaning_ar":"بومة","hint":"","accept":[]},{"text":"polar bear","emoji":"🐻‍❄️","meaning_ar":"دب قطبي","hint":"po-lar bear","accept":["polarbear"]},{"text":"feathers","emoji":"🪶","meaning_ar":"ريش","hint":"feath-ers","accept":["feather"]},{"text":"fur","emoji":"🧸","meaning_ar":"فرو","hint":"","accept":["fir"]},{"text":"claws","emoji":"🐾","meaning_ar":"مخالب","hint":"","accept":["claw","clause"]}],"required_stars":32},
{"id":"y7b-habitats","track":"young","sort":73,"title":"Where animals live","title_ar":"أين تعيش الحيوانات","emoji":"🌍","strictness":0.8,"source":"English P3 - Unit 5","words":[{"text":"desert","emoji":"🏜️","meaning_ar":"صحراء","hint":"des-ert","accept":[]},{"text":"ocean","emoji":"🌊","meaning_ar":"محيط","hint":"o-cean","accept":[]},{"text":"forest","emoji":"🌲","meaning_ar":"غابة","hint":"for-est","accept":[]},{"text":"jungle","emoji":"🌴","meaning_ar":"أدغال","hint":"jun-gle","accept":[]},{"text":"river","emoji":"🏞️","meaning_ar":"نهر","hint":"riv-er","accept":[]},{"text":"nest","emoji":"🪺","meaning_ar":"عش","hint":"","accept":[]}],"required_stars":34},
{"id":"y7c-farm","track":"young","sort":76,"title":"On the farm","title_ar":"في المزرعة","emoji":"🐐","strictness":0.8,"source":"Everyday words","words":[{"text":"goat","emoji":"🐐","meaning_ar":"ماعز","hint":"","accept":[]},{"text":"horse","emoji":"🐴","meaning_ar":"حصان","hint":"","accept":[]},{"text":"hen","emoji":"🐔","meaning_ar":"دجاجة","hint":"","accept":[]},{"text":"rabbit","emoji":"🐇","meaning_ar":"أرنب","hint":"rab-bit","accept":[]},{"text":"donkey","emoji":"🫏","meaning_ar":"حمار","hint":"don-key","accept":[]},{"text":"cow","emoji":"🐄","meaning_ar":"بقرة","hint":"","accept":[]}],"required_stars":35},
{"id":"y8-actions","track":"young","sort":80,"title":"I can... (action words)","title_ar":"أستطيع... (أفعال)","emoji":"🤸","strictness":0.8,"source":"English P3 - Unit 5: can / can't","words":[{"text":"fly","emoji":"🕊️","meaning_ar":"يطير","hint":"","accept":[]},{"text":"jump","emoji":"🦘","meaning_ar":"يقفز","hint":"","accept":[]},{"text":"crawl","emoji":"🐛","meaning_ar":"يزحف","hint":"","accept":[]},{"text":"swim","emoji":"🏊","meaning_ar":"يسبح","hint":"","accept":[]},{"text":"climb","emoji":"🧗","meaning_ar":"يتسلق","hint":"","accept":["clime"]},{"text":"run","emoji":"🏃","meaning_ar":"يجري","hint":"","accept":[]}],"required_stars":37},
{"id":"y8b-actions2","track":"young","sort":83,"title":"More action words","title_ar":"أفعال أكثر","emoji":"✏️","strictness":0.8,"source":"Everyday words","words":[{"text":"read","emoji":"📖","meaning_ar":"يقرأ","hint":"","accept":["reed","red"]},{"text":"write","emoji":"✍️","meaning_ar":"يكتب","hint":"","accept":["right","rite"]},{"text":"draw","emoji":"🖍️","meaning_ar":"يرسم","hint":"","accept":[]},{"text":"sing","emoji":"🎤","meaning_ar":"يغني","hint":"","accept":[]},{"text":"dance","emoji":"💃","meaning_ar":"يرقص","hint":"","accept":[]},{"text":"cook","emoji":"🍳","meaning_ar":"يطبخ","hint":"","accept":[]}],"required_stars":39},
{"id":"y8c-can-sentences","track":"young","sort":86,"title":"What can they do?","title_ar":"ماذا يستطيعون؟","emoji":"🐦","strictness":0.8,"source":"English P3 - Unit 5: can / can't","words":[{"text":"I can swim","emoji":"🏊","meaning_ar":"أستطيع السباحة","hint":"","accept":[]},{"text":"A bird can fly","emoji":"🐦","meaning_ar":"الطائر يستطيع الطيران","hint":"","accept":[]},{"text":"A fish can't walk","emoji":"🐟","meaning_ar":"السمكة لا تستطيع المشي","hint":"","accept":["a fish cannot walk"]},{"text":"I can read","emoji":"📖","meaning_ar":"أستطيع القراءة","hint":"","accept":[]},{"text":"A monkey can climb","emoji":"🐒","meaning_ar":"القرد يستطيع التسلق","hint":"","accept":[]}],"required_stars":41},
{"id":"y9-feelings","track":"young","sort":90,"title":"Feelings (story)","title_ar":"المشاعر (القصة)","emoji":"😊","strictness":0.8,"source":"English P3 - Unit 6: The Honest Choice","words":[{"text":"happy","emoji":"😀","meaning_ar":"سعيد","hint":"hap-py","accept":[]},{"text":"angry","emoji":"😠","meaning_ar":"غاضب","hint":"an-gry","accept":[]},{"text":"sleepy","emoji":"😴","meaning_ar":"نعسان","hint":"sleep-y","accept":[]},{"text":"nervous","emoji":"😬","meaning_ar":"متوتر","hint":"ner-vous","accept":[]},{"text":"honest","emoji":"🤝","meaning_ar":"صادق","hint":"hon-est (h is silent)","accept":[]},{"text":"whisper","emoji":"🤫","meaning_ar":"يهمس","hint":"whis-per","accept":[]}],"required_stars":42},
{"id":"y9b-feelings2","track":"young","sort":93,"title":"How do you feel?","title_ar":"كيف تشعر؟","emoji":"🥱","strictness":0.8,"source":"English P3 - Unit 6","words":[{"text":"tired","emoji":"🥱","meaning_ar":"متعب","hint":"","accept":[]},{"text":"hungry","emoji":"😋","meaning_ar":"جائع","hint":"hun-gry","accept":[]},{"text":"excited","emoji":"🤩","meaning_ar":"متحمس","hint":"ex-cit-ed","accept":[]},{"text":"proud","emoji":"😊","meaning_ar":"فخور","hint":"","accept":[]},{"text":"bored","emoji":"😐","meaning_ar":"ملول","hint":"","accept":["board"]},{"text":"scared","emoji":"😨","meaning_ar":"خائف","hint":"","accept":[]}],"required_stars":44},
{"id":"y9c-weather","track":"young","sort":96,"title":"Weather","title_ar":"الطقس","emoji":"🌦️","strictness":0.8,"source":"Everyday words","words":[{"text":"sunny","emoji":"☀️","meaning_ar":"مشمس","hint":"sun-ny","accept":[]},{"text":"rainy","emoji":"🌧️","meaning_ar":"ممطر","hint":"rain-y","accept":[]},{"text":"windy","emoji":"🌬️","meaning_ar":"عاصف","hint":"wind-y","accept":[]},{"text":"cloudy","emoji":"☁️","meaning_ar":"غائم","hint":"cloud-y","accept":[]},{"text":"hot","emoji":"🥵","meaning_ar":"حار","hint":"","accept":[]},{"text":"cold","emoji":"🥶","meaning_ar":"بارد","hint":"","accept":[]}],"required_stars":46},
{"id":"y10-math","track":"young","sort":100,"title":"Math words","title_ar":"كلمات الرياضيات","emoji":"➗","strictness":0.8,"source":"Math P3 - Chapters 1-10","words":[{"text":"multiply","emoji":"✖️","meaning_ar":"يضرب","hint":"mul-ti-ply","accept":[]},{"text":"divide","emoji":"➗","meaning_ar":"يقسم","hint":"di-vide","accept":[]},{"text":"hour","emoji":"⏰","meaning_ar":"ساعة","hint":"our (h is silent)","accept":["our"]},{"text":"minute","emoji":"⏱️","meaning_ar":"دقيقة","hint":"min-ute","accept":["minutes"]},{"text":"remainder","emoji":"🧮","meaning_ar":"الباقي","hint":"re-main-der","accept":[]},{"text":"kilometre","emoji":"🛣️","meaning_ar":"كيلومتر","hint":"ki-lo-me-tre","accept":["kilometer","kilometers","kilometres"]},{"text":"graph","emoji":"📊","meaning_ar":"رسم بياني","hint":"","accept":["graf"]},{"text":"ten thousand","emoji":"🔟","meaning_ar":"عشرة آلاف","hint":"","accept":["10000"]}],"required_stars":48},
{"id":"y10b-math2","track":"young","sort":103,"title":"Math words 2","title_ar":"كلمات الرياضيات 2","emoji":"➕","strictness":0.8,"source":"Math P3","words":[{"text":"plus","emoji":"➕","meaning_ar":"زائد","hint":"","accept":[]},{"text":"minus","emoji":"➖","meaning_ar":"ناقص","hint":"mi-nus","accept":[]},{"text":"equals","emoji":"🟰","meaning_ar":"يساوي","hint":"e-quals","accept":["equal"]},{"text":"twenty","emoji":"2️⃣0️⃣","meaning_ar":"عشرون","hint":"","accept":["20"]},{"text":"hundred","emoji":"💯","meaning_ar":"مئة","hint":"","accept":["100","one hundred"]},{"text":"half","emoji":"🌓","meaning_ar":"نصف","hint":"","accept":[]}],"required_stars":49},
{"id":"y10c-time","track":"young","sort":106,"title":"Telling the time","title_ar":"الوقت","emoji":"⏰","strictness":0.8,"source":"Math P3 - Time","words":[{"text":"o'clock","emoji":"🕒","meaning_ar":"الساعة (تمامًا)","hint":"","accept":["oclock","o clock"]},{"text":"morning","emoji":"🌅","meaning_ar":"صباح","hint":"morn-ing","accept":[]},{"text":"evening","emoji":"🌆","meaning_ar":"مساء","hint":"eve-ning","accept":[]},{"text":"today","emoji":"📅","meaning_ar":"اليوم","hint":"to-day","accept":[]},{"text":"tomorrow","emoji":"🗓️","meaning_ar":"غدًا","hint":"to-mor-row","accept":[]},{"text":"week","emoji":"📆","meaning_ar":"أسبوع","hint":"","accept":["weak"]}],"required_stars":51},
{"id":"y11-sentences","track":"young","sort":110,"title":"Short sentences","title_ar":"جمل قصيرة","emoji":"💬","strictness":0.8,"source":"English P3 - Units 1, 2, 6","words":[{"text":"Be careful","emoji":"⚠️","meaning_ar":"كن حذراً","hint":"","accept":[]},{"text":"Don't run","emoji":"🚫🏃","meaning_ar":"لا تجرِ","hint":"","accept":["do not run"]},{"text":"Wait here","emoji":"✋","meaning_ar":"انتظر هنا","hint":"","accept":[]},{"text":"I did it myself","emoji":"💪","meaning_ar":"فعلتها بنفسي","hint":"","accept":[]},{"text":"I can jump","emoji":"🦘","meaning_ar":"أستطيع أن أقفز","hint":"","accept":[]},{"text":"Always tell the truth","emoji":"🤝","meaning_ar":"قل الحقيقة دائماً","hint":"","accept":[]}],"required_stars":53},
{"id":"y11b-talk","track":"young","sort":113,"title":"Let's talk","title_ar":"لنتحدث","emoji":"🗣️","strictness":0.8,"source":"Everyday English","words":[{"text":"Good morning","emoji":"🌅","meaning_ar":"صباح الخير","hint":"","accept":[]},{"text":"Thank you very much","emoji":"🙏","meaning_ar":"شكرًا جزيلًا","hint":"","accept":[]},{"text":"How are you","emoji":"👋","meaning_ar":"كيف حالك؟","hint":"","accept":[]},{"text":"I am fine","emoji":"😊","meaning_ar":"أنا بخير","hint":"","accept":["i'm fine"]},{"text":"What is your name","emoji":"📛","meaning_ar":"ما اسمك؟","hint":"","accept":["what's your name"]},{"text":"See you tomorrow","emoji":"👋","meaning_ar":"أراك غدًا","hint":"","accept":[]}],"required_stars":55},
{"id":"y11c-future","track":"young","sort":116,"title":"I will...","title_ar":"سوف...","emoji":"🔮","strictness":0.8,"source":"English P3 - Unit 4: will","words":[{"text":"I will help my mom","emoji":"🤝","meaning_ar":"سأساعد أمي","hint":"","accept":["i will help my mum","i'll help my mom"]},{"text":"It will rain tomorrow","emoji":"🌧️","meaning_ar":"ستمطر غدًا","hint":"","accept":[]},{"text":"I will read a book","emoji":"📖","meaning_ar":"سأقرأ كتابًا","hint":"","accept":["i'll read a book"]},{"text":"We will go to the park","emoji":"🏞️","meaning_ar":"سنذهب إلى الحديقة","hint":"","accept":["we'll go to the park"]},{"text":"I will be kind","emoji":"💛","meaning_ar":"سأكون لطيفًا","hint":"","accept":["i'll be kind"]}],"required_stars":56},
{"id":"y12-review","track":"young","sort":120,"title":"Big review","title_ar":"مراجعة كبيرة","emoji":"🏆","strictness":0.84,"source":"Review of all stages","words":[{"text":"helmet","emoji":"⛑️","meaning_ar":"خوذة","hint":"hel-met","accept":[]},{"text":"breakfast","emoji":"🍳","meaning_ar":"الفطور","hint":"break-fast","accept":[]},{"text":"firefighter","emoji":"👩‍🚒","meaning_ar":"رجل إطفاء","hint":"fire-fight-er","accept":["fire fighter"]},{"text":"keyboard","emoji":"⌨️","meaning_ar":"لوحة المفاتيح","hint":"key-board","accept":[]},{"text":"camel","emoji":"🐪","meaning_ar":"جمل","hint":"cam-el","accept":[]},{"text":"remainder","emoji":"🧮","meaning_ar":"الباقي","hint":"re-main-der","accept":[]}],"required_stars":58}]$json$;
begin
  update public.speak_levels set published = false;
  for lv in select * from jsonb_array_elements(data) loop
    insert into public.speak_levels (id, track, sort, title, title_ar, emoji, strictness, source, required_stars, published)
    values (lv->>'id', lv->>'track', (lv->>'sort')::int, lv->>'title', lv->>'title_ar', lv->>'emoji',
            (lv->>'strictness')::numeric, lv->>'source', (lv->>'required_stars')::int, true)
    on conflict (id) do update set track = excluded.track, sort = excluded.sort, title = excluded.title,
       title_ar = excluded.title_ar, emoji = excluded.emoji, strictness = excluded.strictness,
       source = excluded.source, required_stars = excluded.required_stars, published = true;
    delete from public.speak_words where level_id = lv->>'id';
    i := 0;
    for wd in select * from jsonb_array_elements(lv->'words') loop
      i := i + 1;
      insert into public.speak_words (level_id, sort, text, emoji, meaning_ar, hint, accept)
      values (lv->>'id', i, wd->>'text', wd->>'emoji', wd->>'meaning_ar', wd->>'hint',
              array(select jsonb_array_elements_text(wd->'accept')));
    end loop;
  end loop;
end $$;

-- ---------------------------------------------------------------- parent report: speaking points = best result per stage
create or replace function public.parent_follow(p_profile uuid, p_period text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  tz    text;
  today date;
  n     int;
  v_xp  int;
  v_speak_pts int;
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
                 + app.speak_minutes(p_profile, d, d, tz))) order by d)
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
      'points', v_xp + v_speak_pts + 20 * v_stories_done,
      'lesson_xp', v_xp, 'speak_points', v_speak_pts, 'story_points', 20 * v_stories_done,
      'level', 1 + (v_xp + v_speak_pts + 20 * v_stories_done) / 500,
      'into_level', (v_xp + v_speak_pts + 20 * v_stories_done) % 500),
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
