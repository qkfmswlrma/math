-- 수학질문방 · 데이터베이스 전체
--
-- 빈 Supabase 프로젝트에 이 파일을 통째로 실행하면 사이트가 돕니다.
-- 이미 돌아가는 프로젝트에 실행해도 됩니다. 있는 것은 건드리지 않고 없는 것만 만듭니다.
--
-- 준비: Authentication > Providers > Email 에서 "Confirm email" 을 끕니다.
--       아이디로 로그인하는 구조라 확인 메일을 받을 주소가 없습니다.
--
-- 이 파일에 없는 것 = 아무 데서도 안 쓰는 것입니다. 2026.8.7 에 실제 DB 를 뽑아
-- 앱(_source.html)과 미들웨어(functions/_middleware.js)를 하나씩 맞대어 정리했습니다.
--
-- 맨 아래 [확인] 을 실행해서 다 만들어졌는지 보세요.


-- ══════════════════════════════════════════════════════════
-- 1. 회원
-- ══════════════════════════════════════════════════════════
-- is_admin  글을 쓰고 시험을 낼 수 있음
-- is_super  root. 남이 낸 시험도 고치고 회원 권한을 바꿀 수 있음
--           앱 화면 어디에도 root 라는 말이 나오면 안 됩니다
-- tamgu1/2  모의고사에서 탐구로 무슨 과목을 보는지

create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  username   text not null unique,
  kakao_id   text default '',
  is_admin   boolean not null default false,
  is_super   boolean not null default false,
  tamgu1     text,
  tamgu2     text,
  created_at timestamptz not null default now()
);

alter table public.profiles add column if not exists tamgu1 text;
alter table public.profiles add column if not exists tamgu2 text;

-- 채팅방 닉네임은 겹치면 안 됩니다. 대소문자와 앞뒤 공백은 같은 것으로 봅니다.
-- 비어 있는 값은 여럿이어도 됩니다.
create unique index if not exists profiles_kakao_id_unique
  on public.profiles (lower(btrim(kakao_id)))
  where kakao_id is not null and btrim(kakao_id) <> '';

alter table public.profiles enable row level security;


-- ── 권한을 보는 두 함수 ────────────────────────────────────
-- 정책 안에서 씁니다. security definer 라 profiles 를 못 읽는 사람도 판정은 됩니다.
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path to 'public'
as $function$
  select coalesce((select is_admin from profiles where id = auth.uid()), false);
$function$;

create or replace function public.is_root()
returns boolean language sql security definer set search_path to 'public'
as $function$
  select exists (select 1 from public.profiles where id = auth.uid() and is_super = true);
$function$;


drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles
  for select to authenticated using ((id = auth.uid()) or is_admin());

drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self on public.profiles
  for insert to authenticated with check (id = auth.uid());

drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles
  for update to authenticated using ((id = auth.uid()) or is_admin());

drop policy if exists profiles_delete on public.profiles;
create policy profiles_delete on public.profiles
  for delete to authenticated using (is_admin());


-- 가입하면 profiles 행을 자동으로 만듭니다.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path to 'public'
as $function$
begin
  insert into public.profiles (id, username, kakao_id, is_admin)
  values (new.id,
          new.raw_user_meta_data->>'username',
          coalesce(new.raw_user_meta_data->>'kakao_id', ''),
          false);
  return new;
end;
$function$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- 화면에서 버튼을 숨기는 것과 실제로 막는 것은 다릅니다.
-- 브라우저 콘솔로 API 를 직접 부르면 정책만으로는 등급을 올릴 수 있어서, 트리거로 막습니다.
create or replace function public.guard_profile_roles()
returns trigger language plpgsql security definer
as $function$
begin
  if new.is_super is not distinct from old.is_super
     and new.is_admin is not distinct from old.is_admin then
    return new;
  end if;

  -- is_super 는 앱에서 절대 못 바꿉니다.
  -- 나중에 손볼 일이 있으면 이 트리거를 잠시 끄고 하세요.
  if new.is_super is distinct from old.is_super then
    raise exception 'root 등급은 앱에서 변경할 수 없습니다.';
  end if;

  if old.is_super and new.is_admin = false then
    raise exception 'root의 관리자 권한은 해제할 수 없습니다.';
  end if;

  if not exists (select 1 from profiles where id = auth.uid() and is_super = true) then
    raise exception 'root만 관리자 권한을 변경할 수 있습니다.';
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_guard_profile_roles on public.profiles;
create trigger trg_guard_profile_roles
  before update on public.profiles
  for each row execute function public.guard_profile_roles();


-- ══════════════════════════════════════════════════════════
-- 2. 칼럼과 공지
-- ══════════════════════════════════════════════════════════
-- 한 표를 씁니다. category = 'notice' 인 것이 공지사항입니다.
-- 그래서 읽기 권한을 조건으로 가릅니다. 공지는 누구나, 칼럼은 회원만.

create table if not exists public.columns (
  id         uuid primary key default gen_random_uuid(),
  title      text not null,
  body       text default '',
  author     text default '',
  author_id  uuid,
  category   text not null default 'elem',   -- elem mid high notice
  is_draft   boolean not null default false,
  is_rule    boolean not null default false, -- 채팅방 규칙 글. 목록 맨 위로 옵니다
  sort_order integer not null default 0,
  no         bigint unique,
  prev_nos   bigint[] default '{}',
  created_at timestamptz not null default now()
);

-- 규칙 글은 하나뿐입니다.
create unique index if not exists columns_one_rule on public.columns ((true)) where is_rule;

alter table public.columns enable row level security;

drop policy if exists columns_read on public.columns;
create policy columns_read on public.columns
  for select to public using ((category = 'notice') or (auth.uid() is not null));

drop policy if exists columns_insert on public.columns;
create policy columns_insert on public.columns
  for insert to authenticated with check (is_admin());

-- 남이 쓴 글은 root 만 고칩니다. 글쓴이가 없는 옛 글은 관리자면 됩니다.
drop policy if exists columns_update on public.columns;
create policy columns_update on public.columns
  for update to public
  using (is_admin() and (is_root() or (author_id = auth.uid()) or (author_id is null)));

drop policy if exists columns_delete on public.columns;
create policy columns_delete on public.columns
  for delete to public
  using (is_admin() and (is_root() or (author_id = auth.uid()) or (author_id is null)));


-- ══════════════════════════════════════════════════════════
-- 3. 시험
-- ══════════════════════════════════════════════════════════

create table if not exists public.exams (
  id         uuid primary key default gen_random_uuid(),
  title      text not null,
  questions  jsonb not null default '[]'::jsonb,
  author     text default '',
  author_id  uuid,
  exam_type  text not null default 'level',  -- level today
  publish_at timestamptz,                    -- 비어 있으면 바로 공개
  no         bigint unique,
  prev_nos   bigint[] default '{}',
  created_at timestamptz not null default now()
);

alter table public.exams enable row level security;

drop policy if exists exams_read on public.exams;
create policy exams_read on public.exams
  for select to public using ((publish_at is null) or (publish_at <= now()) or is_admin());

drop policy if exists exams_insert on public.exams;
create policy exams_insert on public.exams
  for insert to authenticated with check (is_admin());

drop policy if exists exams_update on public.exams;
create policy exams_update on public.exams
  for update to public
  using (is_admin() and (is_root() or (author_id = auth.uid()) or (author_id is null)));

drop policy if exists exams_delete on public.exams;
create policy exams_delete on public.exams
  for delete to public
  using (is_admin() and (is_root() or (author_id = auth.uid()) or (author_id is null)));


-- 아직 안 푼 사람에게는 정답과 해설을 빼고 내려줍니다.
-- 표를 직접 읽으면 정답이 딸려 오므로 앱은 이 뷰를 먼저 씁니다.
create or replace function public.strip_answers(p_questions jsonb)
returns jsonb language sql immutable
as $function$
  select coalesce(
    (select jsonb_agg(q - 'answer' - 'accept' - 'explain' order by ord)
     from jsonb_array_elements(coalesce(p_questions,'[]'::jsonb)) with ordinality t(q, ord)),
    '[]'::jsonb);
$function$;

create or replace view public.exams_view as
  select id, no, prev_nos, title, exam_type, author, author_id, publish_at, created_at,
    case
      when (is_admin() or exists (select 1 from submissions s
                                  where s.exam_id = e.id and s.student_id = auth.uid()))
      then questions
      else strip_answers(questions)
    end as questions
  from exams e
  where (publish_at is null) or (publish_at <= now()) or is_admin();


-- ══════════════════════════════════════════════════════════
-- 4. 글번호 자동 부여
-- ══════════════════════════════════════════════════════════
-- [종류1][대상1][예비1][순번3] 여섯 자리입니다.
--   11 12 13 칼럼 초등/중학/고등    20 공지    31 32 레벨테스트/오늘의 문제
-- 분류를 바꾸면 새 번호를 받고 옛 번호는 prev_nos 에 남아 옛 링크가 계속 열립니다.
-- 앱은 자릿수를 해석하지 않습니다. 나중에 자리를 늘려도 옛 링크가 삽니다.

create or replace function public.column_no_prefix(p_category text)
returns bigint language sql immutable
as $function$
  select case p_category
           when 'notice' then 200000
           when 'elem'   then 110000
           when 'mid'    then 120000
           when 'high'   then 130000
           else               190000   -- 알 수 없는 분류
         end;
$function$;

create or replace function public.exam_no_prefix(p_type text)
returns bigint language sql immutable
as $function$
  select case p_type when 'today' then 320000 else 310000 end;
$function$;

-- prev_nos 까지 훑어야 옛 번호를 다시 내주지 않습니다.
create or replace function public.next_column_no(p_category text)
returns bigint language plpgsql
as $function$
declare
  v_prefix bigint := public.column_no_prefix(p_category);
  v_max    bigint;
begin
  select coalesce(max(n), v_prefix) into v_max
  from (select no as n from public.columns
        union all
        select unnest(prev_nos) from public.columns) t
  where n >= v_prefix and n < v_prefix + 1000;

  return greatest(v_max + 1, v_prefix + 1);
end;
$function$;

create or replace function public.next_exam_no(p_type text)
returns bigint language plpgsql
as $function$
declare
  v_prefix bigint := public.exam_no_prefix(p_type);
  v_max    bigint;
begin
  select coalesce(max(n), v_prefix) into v_max
  from (select no as n from public.exams
        union all
        select unnest(prev_nos) from public.exams) t
  where n >= v_prefix and n < v_prefix + 1000;

  return greatest(v_max + 1, v_prefix + 1);
end;
$function$;

create or replace function public.set_column_no()
returns trigger language plpgsql
as $function$
begin
  if TG_OP = 'INSERT' then
    if new.no is null then
      new.no := public.next_column_no(new.category);
    end if;
  elsif TG_OP = 'UPDATE' then
    if new.category is distinct from old.category and old.no is not null then
      new.prev_nos := array_append(coalesce(old.prev_nos, '{}'), old.no);
      new.no := public.next_column_no(new.category);
    end if;
  end if;
  return new;
end;
$function$;

create or replace function public.set_exam_no()
returns trigger language plpgsql
as $function$
begin
  if TG_OP = 'INSERT' then
    if new.no is null then
      new.no := public.next_exam_no(new.exam_type);
    end if;
  elsif TG_OP = 'UPDATE' then
    if new.exam_type is distinct from old.exam_type and old.no is not null then
      new.prev_nos := array_append(coalesce(old.prev_nos, '{}'), old.no);
      new.no := public.next_exam_no(new.exam_type);
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_set_column_no on public.columns;
create trigger trg_set_column_no
  before insert or update on public.columns
  for each row execute function public.set_column_no();

drop trigger if exists trg_set_exam_no on public.exams;
create trigger trg_set_exam_no
  before insert or update on public.exams
  for each row execute function public.set_exam_no();


-- ══════════════════════════════════════════════════════════
-- 5. 제출
-- ══════════════════════════════════════════════════════════

create table if not exists public.submissions (
  id            uuid primary key default gen_random_uuid(),
  exam_id       uuid,
  student       text not null,
  student_id    uuid,
  answers       jsonb not null default '{}'::jsonb,
  manual_scores jsonb not null default '{}'::jsonb,  -- 서술형을 사람이 매긴 점수
  graded        boolean not null default false,
  submitted_at  timestamptz not null default now()
);

alter table public.submissions enable row level security;

drop policy if exists subs_read on public.submissions;
create policy subs_read on public.submissions
  for select to authenticated using ((student_id = auth.uid()) or is_admin());

drop policy if exists subs_insert on public.submissions;
create policy subs_insert on public.submissions
  for insert to authenticated with check (student_id = auth.uid());

drop policy if exists subs_update on public.submissions;
create policy subs_update on public.submissions
  for update to authenticated using (is_admin());

drop policy if exists subs_delete on public.submissions;
create policy subs_delete on public.submissions
  for delete to authenticated using (is_admin());


-- ── 비회원 제출 ────────────────────────────────────────────
-- 비회원은 이 표를 직접 못 씁니다. 아래 함수로만 들어옵니다.
-- ip_hash 로 같은 시험을 하루에 한 번만 풀게 합니다.
create table if not exists public.guest_submissions (
  id         uuid primary key default gen_random_uuid(),
  exam_id    uuid,
  answers    jsonb not null default '{}'::jsonb,
  ip_hash    text,
  created_at timestamptz not null default now()
);

create index if not exists guest_sub_exam_idx on public.guest_submissions (exam_id);

alter table public.guest_submissions enable row level security;

drop policy if exists guest_sub_read on public.guest_submissions;
create policy guest_sub_read on public.guest_submissions
  for select to authenticated using (is_admin());

-- 넣기 정책이 없는 것이 맞습니다. security definer 인 아래 함수가 대신 넣습니다.
create or replace function public.submit_guest_attempt(p_exam_id uuid, p_answers jsonb)
returns jsonb language plpgsql security definer set search_path to 'public'
as $function$
declare v_ip text; v_hash text; v_ok boolean := true; v_qs jsonb;
begin
  v_ip := btrim(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1));
  if v_ip <> '' then
    v_hash := md5(v_ip);
    if exists (select 1 from guest_submissions
               where exam_id = p_exam_id and ip_hash = v_hash
                 and created_at > now() - interval '24 hours') then
      v_ok := false;
    end if;
  end if;
  if v_ok then
    insert into guest_submissions (exam_id, answers, ip_hash)
    values (p_exam_id, coalesce(p_answers, '{}'::jsonb), v_hash);
  end if;
  -- 내고 나면 정답을 함께 돌려줍니다. 비회원은 뷰로 정답을 볼 수 없기 때문입니다.
  select questions into v_qs from exams where id = p_exam_id;
  return jsonb_build_object('ok', v_ok, 'questions', coalesce(v_qs, '[]'::jsonb));
end;
$function$;


-- ══════════════════════════════════════════════════════════
-- 6. 정답률
-- ══════════════════════════════════════════════════════════
-- 집계는 반드시 서버에서 합니다. 학생은 남의 제출을 읽을 수 없어서
-- 앱에서 세면 자기 것만 반영된 값이 나옵니다.
-- 회원과 비회원을 합쳐서 냅니다. 목록 카드, 응시 화면, 채점 결과, 관리자 통계가
-- 모두 같은 숫자를 보여야 합니다. 화면마다 다른 방식으로 계산하지 마세요.

create or replace function public.exam_question_stats(p_exam_id uuid)
returns table(qid text, total integer, correct integer, gtotal integer, gcorrect integer)
language sql security definer set search_path to 'public'
as $function$
  with q as (
    select (elem->>'id') as qid, (elem->>'type') as qtype, (elem->>'answer') as qanswer,
           btrim(coalesce(elem->>'accept','')) as qaccept
    from public.exams e, jsonb_array_elements(e.questions) as elem
    where e.id = p_exam_id
  ),
  s as (select answers from public.submissions       where exam_id = p_exam_id),
  g as (select answers from public.guest_submissions where exam_id = p_exam_id)
  select q.qid,
    (select count(*) from s)::int,
    (select count(*) from s
       where (q.qtype = 'mc'    and (s.answers->>q.qid) = q.qanswer)
          or (q.qtype = 'short' and q.qaccept <> '' and btrim(coalesce(s.answers->>q.qid,'')) = q.qaccept))::int,
    (select count(*) from g)::int,
    (select count(*) from g
       where (q.qtype = 'mc'    and (g.answers->>q.qid) = q.qanswer)
          or (q.qtype = 'short' and q.qaccept <> '' and btrim(coalesce(g.answers->>q.qid,'')) = q.qaccept))::int
  from q;
$function$;

-- 목록에서 시험마다 한 번씩 부르면 느려서, 한 번에 다 받아옵니다.
create or replace function public.exam_stats_all()
returns table(exam_id uuid, total bigint, correct bigint, gtotal bigint, gcorrect bigint)
language sql stable security definer set search_path to 'public'
as $function$
  select e.id,
         coalesce(sum(s.total), 0)::bigint,
         coalesce(sum(s.correct), 0)::bigint,
         coalesce(sum(s.gtotal), 0)::bigint,
         coalesce(sum(s.gcorrect), 0)::bigint
  from public.exams e
  cross join lateral public.exam_question_stats(e.id) s
  group by e.id;
$function$;


-- ══════════════════════════════════════════════════════════
-- 7. 안 읽음 표시
-- ══════════════════════════════════════════════════════════

create table if not exists public.column_reads (
  user_id   uuid not null,
  column_id uuid not null,
  read_at   timestamptz not null default now(),
  primary key (user_id, column_id)
);

create table if not exists public.exam_reads (
  user_id uuid not null,
  exam_id uuid not null,
  read_at timestamptz not null default now(),
  primary key (user_id, exam_id)
);

alter table public.column_reads enable row level security;
alter table public.exam_reads   enable row level security;

drop policy if exists column_reads_select on public.column_reads;
create policy column_reads_select on public.column_reads
  for select to authenticated using (user_id = auth.uid());

drop policy if exists column_reads_insert on public.column_reads;
create policy column_reads_insert on public.column_reads
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists exam_reads_select on public.exam_reads;
create policy exam_reads_select on public.exam_reads
  for select to authenticated using (user_id = auth.uid());

drop policy if exists exam_reads_insert on public.exam_reads;
create policy exam_reads_insert on public.exam_reads
  for insert to authenticated with check (user_id = auth.uid());


-- ══════════════════════════════════════════════════════════
-- 8. 활동 기록
-- ══════════════════════════════════════════════════════════

create table if not exists public.audit_log (
  id         uuid primary key default gen_random_uuid(),
  actor      text,
  actor_id   uuid,
  action     text,
  target     text,
  created_at timestamptz not null default now()
);

create index if not exists audit_log_created_idx on public.audit_log (created_at desc);

alter table public.audit_log enable row level security;

drop policy if exists audit_read on public.audit_log;
create policy audit_read on public.audit_log
  for select to authenticated using (is_admin());

drop policy if exists audit_insert on public.audit_log;
create policy audit_insert on public.audit_log
  for insert to authenticated with check (actor_id = auth.uid());


-- ══════════════════════════════════════════════════════════
-- 9. 스피드 연산 랭킹
-- ══════════════════════════════════════════════════════════
-- 점수는 앱이 직접 못 씁니다. 아래 함수가 검산하고 넣습니다.

create table if not exists public.speed_scores (
  user_id    uuid primary key,
  nickname   text not null,
  best_score integer not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.speed_scores enable row level security;

drop policy if exists speed_scores_read on public.speed_scores;
create policy speed_scores_read on public.speed_scores
  for select to authenticated using (true);

create or replace function public.speed_ranking(p_limit integer default 50)
returns table(nickname text, best_score integer)
language sql security definer set search_path to 'public'
as $function$
  select nickname, best_score
  from public.speed_scores
  order by best_score desc, updated_at asc
  limit greatest(1, least(p_limit, 200));
$function$;

-- 랭킹 화면의 "내 순위" 한 줄.
create or replace function public.my_speed_rank()
returns table(my_rank bigint, best_score integer, total bigint)
language sql security definer set search_path to 'public'
as $function$
  with ranked as (
    select user_id, s.best_score,
           rank() over (order by s.best_score desc, s.updated_at asc) as r
    from public.speed_scores s
  )
  select r.r, r.best_score, (select count(*) from public.speed_scores)
  from ranked r
  where r.user_id = auth.uid();
$function$;

grant execute on function public.my_speed_rank() to authenticated;

-- 브라우저 콘솔로 아무 점수나 넣지 못하게 서버에서 검산합니다.
create or replace function public.submit_speed_score(
  p_score integer, p_correct integer default null,
  p_combo integer default null, p_seconds numeric default null)
returns void language plpgsql security definer set search_path to 'public', 'auth'
as $function$
declare
  v_id uuid := auth.uid();
  v_nick text;
  v_max numeric := 0;
  k integer;
begin
  if v_id is null then raise exception 'not signed in'; end if;

  select nullif(trim(kakao_id), '') into v_nick from public.profiles where id = v_id;
  if v_nick is null then raise exception 'no nickname'; end if;

  if p_score is null or p_score < 0 then raise exception 'invalid score'; end if;

  -- 검산에 필요한 값이 없으면(옛 버전 등) 거부합니다.
  if p_correct is null or p_combo is null or p_seconds is null then
    raise exception 'verification data required';
  end if;

  if p_combo < 0 or p_combo > p_correct then
    raise exception 'combo exceeds correct count';
  end if;

  -- 한 문제당 최소 0.3초. 시간0에 정답이 폭증하는 위조를 거릅니다.
  if p_seconds < 0 or p_correct > ceil(p_seconds / 0.3) + 10 then
    raise exception 'too many answers for elapsed time';
  end if;

  -- 정답수로 낼 수 있는 이론상 최대 점수를 넘으면 위조로 봅니다.
  if p_correct > 0 then
    for k in 1..least(p_correct, 1000) loop
      v_max := v_max + round(10 * power(1.15, k));
    end loop;
  end if;
  if p_score > v_max then raise exception 'score exceeds theoretical maximum'; end if;

  insert into public.speed_scores (user_id, nickname, best_score, updated_at)
  values (v_id, v_nick, p_score, now())
  on conflict (user_id) do update
    set best_score = greatest(public.speed_scores.best_score, excluded.best_score),
        nickname   = excluded.nickname,
        updated_at = now();
end;
$function$;


-- ══════════════════════════════════════════════════════════
-- 10. 모의고사
-- ══════════════════════════════════════════════════════════
-- 남의 성적을 볼 이유가 없습니다. 전부 본인 것만 허용합니다.

create table if not exists public.exam_records (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  exam_name    text not null,
  exam_date    date not null,
  subject      text not null,   -- korean math english history tamgu1 tamgu2 lang2
  detail       text default '', -- 미적분, 생명과학Ⅰ 처럼 세부 과목
  raw_score    numeric,
  std_score    numeric,
  percentile   numeric,
  grade        integer check (grade is null or (grade between 1 and 9)),
  wrong_nos    integer[] not null default '{}',
  grade_cuts   integer[],       -- 1등급컷부터 8등급컷까지의 원점수
  duration_sec integer,
  memo         text default '',
  created_at   timestamptz not null default now()
);

create index if not exists exam_records_user_date
  on public.exam_records (user_id, exam_date desc);

alter table public.exam_records enable row level security;

drop policy if exists exam_records_select on public.exam_records;
create policy exam_records_select on public.exam_records
  for select to authenticated using (user_id = auth.uid());

drop policy if exists exam_records_insert on public.exam_records;
create policy exam_records_insert on public.exam_records
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists exam_records_update on public.exam_records;
create policy exam_records_update on public.exam_records
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists exam_records_delete on public.exam_records;
create policy exam_records_delete on public.exam_records
  for delete to authenticated using (user_id = auth.uid());


-- 평가원·교육청 시험은 앱에 박혀 있고, 사설처럼 사람마다 다른 것만 여기 쌓입니다.
-- subject 가 비어 있으면 전 과목, 값이 있으면 그 과목에서만 보입니다.
create table if not exists public.exam_categories (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  name       text not null,
  subject    text,
  created_at timestamptz not null default now()
);

-- 같은 이름이라도 과목이 다르면 따로 둘 수 있습니다.
-- coalesce 는 괄호로 한 번 더 감싸야 합니다. 그냥 쓰면 문법 오류가 납니다.
create unique index if not exists exam_categories_uniq
  on public.exam_categories (user_id, name, (coalesce(subject, '')));

alter table public.exam_categories enable row level security;

drop policy if exists exam_categories_select on public.exam_categories;
create policy exam_categories_select on public.exam_categories
  for select to authenticated using (user_id = auth.uid());

drop policy if exists exam_categories_insert on public.exam_categories;
create policy exam_categories_insert on public.exam_categories
  for insert to authenticated with check (user_id = auth.uid());

drop policy if exists exam_categories_update on public.exam_categories;
create policy exam_categories_update on public.exam_categories
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists exam_categories_delete on public.exam_categories;
create policy exam_categories_delete on public.exam_categories
  for delete to authenticated using (user_id = auth.uid());


-- ══════════════════════════════════════════════════════════
-- 11. 계정 관리
-- ══════════════════════════════════════════════════════════
-- 회원 권한, 삭제, 비번 초기화는 root 만 할 수 있습니다.
-- 화면에서 숨기는 것으로는 부족해서 함수 안에서도 검사합니다.

create or replace function public.admin_delete_user(p_username text)
returns boolean language plpgsql security definer set search_path to 'public', 'auth'
as $function$
declare v_id uuid;
begin
  if not public.is_root() then raise exception 'forbidden: root only'; end if;
  if exists (select 1 from public.profiles where username = p_username and is_super = true) then
    raise exception 'forbidden: cannot delete root account';
  end if;
  select id into v_id from public.profiles where username = p_username;
  delete from public.profiles where username = p_username;
  if v_id is not null then delete from auth.users where id = v_id; end if;
  return true;
end;
$function$;

create or replace function public.admin_reset_password(p_username text)
returns boolean language plpgsql security definer set search_path to 'public', 'extensions', 'auth'
as $function$
declare v_id uuid;
begin
  if not public.is_root() then raise exception 'forbidden: root only'; end if;
  if exists (select 1 from public.profiles where username = p_username and is_super = true) then
    raise exception 'forbidden: cannot reset root password';
  end if;
  select id into v_id from public.profiles where username = p_username;
  if v_id is null then return false; end if;
  update auth.users
  set encrypted_password = crypt('0000__mr__', gen_salt('bf')), updated_at = now()
  where id = v_id;
  return true;
end;
$function$;

-- 본인이 스스로 탈퇴하는 것은 누구나 할 수 있습니다.
create or replace function public.delete_my_account()
returns boolean language plpgsql security definer set search_path to 'public', 'auth'
as $function$
declare v_id uuid := auth.uid();
begin
  if v_id is null then raise exception 'not signed in'; end if;
  delete from public.profiles where id = v_id;
  delete from auth.users where id = v_id;
  return true;
end;
$function$;


-- ══════════════════════════════════════════════════════════
-- 12. 카톡 링크 미리보기
-- ══════════════════════════════════════════════════════════
-- functions/_middleware.js 가 씁니다. 앱은 부르지 않습니다. 지우지 마세요.
-- 공지는 본문까지, 칼럼은 회원 전용이라 제목만 내줍니다.

create or replace function public.post_preview(p_no integer)
returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select jsonb_build_object(
    'title', c.title, 'category', c.category, 'author', c.author,
    'body', case when c.category = 'notice' then c.body else null end)
  from public.columns c
  where c.is_draft = false and (c.no = p_no or p_no = any(c.prev_nos))
  limit 1;
$function$;


-- ══════════════════════════════════════════════════════════
-- 13. 문제 사진
-- ══════════════════════════════════════════════════════════
-- 사진은 누구나 보고, 올리는 것은 로그인한 사람만.

insert into storage.buckets (id, name, public)
values ('exam-images', 'exam-images', true)
on conflict (id) do nothing;

drop policy if exists exam_images_read on storage.objects;
create policy exam_images_read on storage.objects
  for select to public using (bucket_id = 'exam-images');

drop policy if exists exam_images_insert on storage.objects;
create policy exam_images_insert on storage.objects
  for insert to authenticated with check (bucket_id = 'exam-images');


-- ══════════════════════════════════════════════════════════
-- [확인]
-- ══════════════════════════════════════════════════════════
-- 네 줄 모두 OK 여야 합니다.

with c as (
  select
    (select count(*) from information_schema.tables
      where table_schema = 'public' and table_type = 'BASE TABLE'
        and table_name in ('profiles','columns','exams','submissions','guest_submissions',
                           'column_reads','exam_reads','audit_log','speed_scores',
                           'exam_records','exam_categories'))                        as tbl,
    (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.prokind = 'f'
        and p.proname in ('is_admin','is_root','handle_new_user','guard_profile_roles',
                          'strip_answers','column_no_prefix','exam_no_prefix',
                          'next_column_no','next_exam_no','set_column_no','set_exam_no',
                          'submit_guest_attempt','exam_question_stats','exam_stats_all',
                          'speed_ranking','my_speed_rank','submit_speed_score',
                          'admin_delete_user','admin_reset_password','delete_my_account',
                          'post_preview'))                                           as fn,
    (select count(*) from pg_class cl join pg_namespace n on n.oid = cl.relnamespace
      where n.nspname = 'public' and cl.relkind = 'r' and cl.relrowsecurity
        and cl.relname in ('profiles','columns','exams','submissions','guest_submissions',
                           'column_reads','exam_reads','audit_log','speed_scores',
                           'exam_records','exam_categories'))                        as rls,
    (select count(*) from pg_policies where schemaname = 'public'
       and 'public' = any(roles) and tablename in ('exam_records','exam_categories',
                           'profiles','submissions','speed_scores','audit_log'))     as leak
)
select '표 11개'          as 항목, tbl::text as 값, case when tbl  = 11 then 'OK' else '모자람' end as 결과 from c
union all select '함수 21개',  fn::text,  case when fn   = 21 then 'OK' else '모자람' end from c
union all select 'RLS 11개',   rls::text, case when rls  = 11 then 'OK' else '안 켜진 표 있음' end from c
union all select '새는 정책',  leak::text, case when leak = 0  then 'OK' else '개인 자료 표에 public 정책 있음' end from c;
