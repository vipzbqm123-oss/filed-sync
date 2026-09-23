-- path: supabase/migrations/20260923000001_schema.sql
-- FieldSync 스키마: 타입 · 테이블 · 인덱스 · 트리거 · 기본 데이터
-- 원칙: 상태 컬럼은 RPC(20260923000002)로만 변경, 권한은 20260923000003에서 최소 부여.

create schema if not exists private;  -- PostgREST 비노출 헬퍼 전용

-- ───────────────────────── 타입 ─────────────────────────
create type public.site_status    as enum ('pending', 'en_route', 'working', 'paused', 'done');
create type public.session_status as enum ('en_route', 'working', 'paused', 'done', 'released');
create type public.user_role      as enum ('admin', 'leader', 'worker');

-- ───────────────────────── 공통 트리거 함수 ─────────────────────────
create function private.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := clock_timestamp();  -- 델타 동기화 기준: 커밋 시각에 가깝게
  return new;
end $$;

-- 체크 템플릿 항목 형식 검증 (CHECK 제약용). O(항목 수)
create function private.valid_template_items(p jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select jsonb_typeof(p) = 'array'
     and not exists (
       select 1 from jsonb_array_elements(p) e
       where jsonb_typeof(e) <> 'object'
          or coalesce(e ->> 'key', '') !~ '^[a-z][a-z0-9_]{0,31}$'
          or coalesce(e ->> 'label', '') = ''
          or coalesce(e ->> 'type', '') not in ('bool', 'number', 'select', 'text')
          or (e ->> 'type' = 'select' and jsonb_typeof(e -> 'options') is distinct from 'array')
          or (e ? 'required' and jsonb_typeof(e -> 'required') <> 'boolean')
          or (e ? 'min' and jsonb_typeof(e -> 'min') <> 'number')
          or (e ? 'max' and jsonb_typeof(e -> 'max') <> 'number'))
     and (select count(distinct e ->> 'key') = count(*) from jsonb_array_elements(p) e)
$$;

-- 위임 가능 권한 목록 (단일 원본). 배포·등급·권한·정책은 목록에 없음 = 관리자 고정
create function private.delegable_perms() returns text[]
language sql immutable set search_path = '' as $$
  select array['site.create', 'site.edit', 'work.force_release', 'work.reopen',
               'urgent.send', 'log.view_team', 'stats.view_team', 'template.edit']
$$;

-- ───────────────────────── 조직 ─────────────────────────
create table public.teams (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique check (length(name) between 1 and 50),
  created_at timestamptz not null default now()
);

create table public.profiles (
  id         uuid primary key references auth.users (id) on delete cascade,
  login_id   text not null unique check (login_id ~ '^[a-z0-9_.-]{3,32}$'),
  name       text not null check (length(name) between 1 and 50),
  role       public.user_role not null default 'worker',
  team_id    uuid references public.teams (id) on delete set null,
  lang       text not null default 'ko' check (lang in ('ko', 'en', 'vi')),
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index profiles_team_idx on public.profiles (team_id);
create trigger profiles_touch before update on public.profiles
  for each row execute function private.touch_updated_at();

-- 등급별 위임 권한 (관리자는 암묵적 전체 → 행 없음)
create table public.role_permissions (
  role public.user_role not null check (role <> 'admin'),
  perm text not null check (perm = any (private.delegable_perms())),
  primary key (role, perm)
);

-- 단일 행 정책 (분 단위)
create table public.settings (
  id                        int primary key default 1 check (id = 1),
  remind_working_first_min  int  not null default 90  check (remind_working_first_min between 5 and 1440),
  remind_working_repeat_min int  not null default 30  check (remind_working_repeat_min between 5 and 1440),
  remind_max                int  not null default 8   check (remind_max between 1 and 20),
  escalate_at               int  not null default 3   check (escalate_at between 1 and 20),
  remind_en_route_after_min int  not null default 45  check (remind_en_route_after_min between 5 and 1440),
  remind_paused_after_min   int  not null default 240 check (remind_paused_after_min between 5 and 2880),
  max_claims_per_user       int  not null default 3   check (max_claims_per_user between 1 and 20),
  arrive_radius_m           int  not null default 50  check (arrive_radius_m between 10 and 500),
  undo_complete_window_min  int  not null default 5   check (undo_complete_window_min between 0 and 60),
  min_app_version           text not null default '1.0.0' check (min_app_version ~ '^\d+\.\d+\.\d+$'),
  updated_at                timestamptz not null default now()
);
create trigger settings_touch before update on public.settings
  for each row execute function private.touch_updated_at();

-- ───────────────────────── 현장 ─────────────────────────
create table public.check_templates (
  id                uuid primary key default gen_random_uuid(),
  name              text not null unique check (length(name) between 1 and 100),
  items             jsonb not null default '[]' check (private.valid_template_items(items)),
  require_photo     int not null default 0 check (require_photo between 0 and 10),
  require_signature boolean not null default false,
  updated_at        timestamptz not null default now()
);
create trigger check_templates_touch before update on public.check_templates
  for each row execute function private.touch_updated_at();

-- 현장 묶음 = 동선 = 배포 단위 (카카오맵 즐겨찾기 폴더에 대응)
create table public.site_groups (
  id               uuid primary key default gen_random_uuid(),
  name             text not null check (length(name) between 1 and 100),
  work_date        date,
  team_id          uuid references public.teams (id) on delete set null,          -- null = 전체 팀
  template_id      uuid references public.check_templates (id) on delete set null,
  kakao_folder_url text check (kakao_folder_url is null or kakao_folder_url ~ '^https://\S+$'),
  published        boolean not null default false,
  published_at     timestamptz,
  archived         boolean not null default false,
  created_by       uuid references public.profiles (id) default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index site_groups_pub_idx on public.site_groups (published, archived);
create trigger site_groups_touch before update on public.site_groups
  for each row execute function private.touch_updated_at();

create table public.sites (
  id             uuid primary key default gen_random_uuid(),
  group_id       uuid not null references public.site_groups (id),
  seq            int not null default 0,
  label          text check (length(label) <= 50),
  bunji          text not null check (length(bunji) between 1 and 100),   -- "성수동1가 685-12"
  jibun          text not null check (length(jibun) between 1 and 200),   -- 지번 전체
  road           text check (length(road) <= 200),
  unit           text not null default '' check (length(unit) <= 100),    -- 세부(동·계량기)
  note           text check (length(note) <= 500),
  lat            double precision not null check (lat between 33 and 39),   -- 대한민국 범위
  lng            double precision not null check (lng between 124 and 132),
  b_code         text,
  jibun_key      text,                                                      -- b_code|산|본번|부번
  -- 아래는 RPC 전용(컬럼 권한으로 직접 수정 차단). occupant_* 는 Realtime 페이로드 자급용 비정규화
  status         public.site_status not null default 'pending',
  session_id     uuid,
  occupant_id    uuid references public.profiles (id),
  occupant_name  text,
  occupant_team  text,
  started_at     timestamptz,
  status_at      timestamptz,
  urgent         boolean not null default false,
  archived       boolean not null default false,
  created_by     uuid references public.profiles (id) default auth.uid(),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
-- 등록 단계 중복 방지: 같은 지번+세부는 동시에 1건만 활성
create unique index sites_active_address_uq on public.sites (jibun_key, unit)
  where not archived and status <> 'done' and jibun_key is not null;
create index sites_group_seq_idx on public.sites (group_id, seq);
create index sites_updated_idx   on public.sites (updated_at);
create trigger sites_touch before update on public.sites
  for each row execute function private.touch_updated_at();

-- ───────────────────────── 작업 ─────────────────────────
create table public.work_sessions (
  id                uuid primary key default gen_random_uuid(),
  site_id           uuid not null references public.sites (id),
  user_id           uuid not null references public.profiles (id),
  team_id           uuid references public.teams (id) on delete set null,   -- 점유 시점 팀 스냅샷
  status            public.session_status not null,
  claimed_at        timestamptz not null default now(),
  started_at        timestamptz,
  paused_at         timestamptz,
  pause_reason      text,
  paused_total      interval not null default '0',
  completed_at      timestamptz,
  released_at       timestamptz,
  release_reason    text,
  released_by       uuid references public.profiles (id),
  checks            jsonb not null default '{}' check (jsonb_typeof(checks) = 'object'),
  note              text check (length(note) <= 2000),
  next_remind_at    timestamptz,
  remind_count      int not null default 0,
  client_claimed_at timestamptz,
  updated_at        timestamptz not null default now()
);
-- ★ 중복 방지 최후 방어선: 현장당 점유 세션 0 또는 1개
create unique index work_sessions_one_active_uq on public.work_sessions (site_id)
  where status in ('en_route', 'working', 'paused');
create index work_sessions_user_status_idx on public.work_sessions (user_id, status);
create index work_sessions_remind_idx      on public.work_sessions (next_remind_at) where next_remind_at is not null;
create index work_sessions_claimed_idx     on public.work_sessions (claimed_at);
create trigger work_sessions_touch before update on public.work_sessions
  for each row execute function private.touch_updated_at();

alter table public.sites add constraint sites_session_fk
  foreign key (session_id) references public.work_sessions (id);

create table public.attachments (
  id         uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.work_sessions (id),
  site_id    uuid not null references public.sites (id),
  kind       text not null check (kind in ('photo', 'signature')),
  path       text not null unique check (path ~ '^[0-9a-f-]{36}/[A-Za-z0-9._-]{1,100}$'),  -- Storage 'evidence' 버킷 객체명 {session_id}/{파일}
  taken_at   timestamptz,
  lat        double precision,
  lng        double precision,
  created_by uuid not null references public.profiles (id) default auth.uid(),
  created_at timestamptz not null default now()
);
create index attachments_session_idx on public.attachments (session_id);

-- 감사 로그: 추가 전용. 결과 객체(meta.result)를 저장해 op_id 재전송 시 그대로 반환(멱등)
create table public.work_logs (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  actor_id   uuid references public.profiles (id),
  team_id    uuid,                                   -- 행위자 팀 스냅샷(팀 로그 RLS용)
  site_id    uuid references public.sites (id),
  session_id uuid references public.work_sessions (id),
  group_id   uuid references public.site_groups (id),
  action     text not null check (action in (
               'claim', 'start', 'pause', 'resume', 'complete', 'undo_complete', 'release',
               'force_release', 'reopen', 'save_checks', 'snooze', 'attach', 'remind', 'escalate',
               'urgent', 'urgent_resolve', 'publish', 'unpublish', 'site_create', 'site_update',
               'site_archive', 'role_change', 'perm_change', 'settings_change')),
  ok         boolean not null default true,          -- false = 거절된 시도(중복 시도 통계 등)
  from_status text,
  to_status   text,
  meta       jsonb not null default '{}',
  op_id      uuid unique,
  client_at  timestamptz,
  lat        double precision,
  lng        double precision
);
create index work_logs_at_idx      on public.work_logs (at desc);
create index work_logs_site_idx    on public.work_logs (site_id, at desc);
create index work_logs_actor_idx   on public.work_logs (actor_id, at desc);
create index work_logs_team_idx    on public.work_logs (team_id, at desc);

create function private.forbid_log_change() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'work_logs is append-only' using errcode = '42501';
end $$;
create trigger work_logs_no_update before update or delete on public.work_logs
  for each row execute function private.forbid_log_change();
create trigger work_logs_no_truncate before truncate on public.work_logs
  for each statement execute function private.forbid_log_change();

create table public.urgent_requests (
  id          uuid primary key default gen_random_uuid(),
  site_id     uuid references public.sites (id),
  group_id    uuid references public.site_groups (id),
  message     text not null check (length(message) between 1 and 300),
  created_by  uuid not null references public.profiles (id),
  created_at  timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references public.profiles (id)
);
create index urgent_open_idx on public.urgent_requests (created_at desc) where resolved_at is null;

-- 푸시 아웃박스 (Edge Function push가 드레인)
create table public.notifications (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles (id) on delete cascade,
  kind         text not null check (kind in ('remind', 'escalate', 'urgent', 'force_release', 'publish', 'reopen')),
  title        text not null,
  body         text not null,
  data         jsonb not null default '{}',
  collapse_key text,
  created_at   timestamptz not null default now(),
  sent_at      timestamptz,
  read_at      timestamptz,
  attempts     int not null default 0,     -- 발송 시도 횟수(선점 시 +1, 5회까지)
  locked_at    timestamptz,                -- 발송 선점 시각(2분 임대 → 동시 실행 중복 발송 방지·재시도 백오프)
  last_error   text
);
create index notifications_unsent_idx on public.notifications (created_at) where sent_at is null;
create index notifications_user_idx   on public.notifications (user_id, created_at desc);

create table public.device_tokens (
  token            text primary key check (length(token) between 10 and 4096),
  user_id          uuid not null references public.profiles (id) on delete cascade,
  platform         text not null check (platform in ('ios', 'android')),
  notif_permission boolean not null default true,
  updated_at       timestamptz not null default now()
);
create index device_tokens_user_idx on public.device_tokens (user_id);

-- ───────────────────────── 신규 사용자 → profiles ─────────────────────────
-- 등급·팀은 app_metadata(서비스 키로만 설정 가능)에서만 읽음 → 자가 권한 상승 차단
create function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  -- 자가 가입 방어(2중): Auth 가입 API로 생긴 계정은 app_metadata에 provider만 있고 role이 없음 → 비활성으로 생성.
  -- 관리자 발급(admin-users 함수)은 항상 role 포함 → 활성. 1차 방어는 Auth 설정의 가입 비활성화(RUNBOOK)
  insert into public.profiles (id, login_id, name, role, team_id, lang, active)
  values (
    new.id,
    lower(coalesce(new.raw_user_meta_data ->> 'login_id', split_part(new.email, '@', 1))),
    coalesce(nullif(new.raw_user_meta_data ->> 'name', ''), split_part(new.email, '@', 1)),
    coalesce((new.raw_app_meta_data ->> 'role')::public.user_role, 'worker'),
    nullif(new.raw_app_meta_data ->> 'team_id', '')::uuid,
    coalesce(new.raw_user_meta_data ->> 'lang', 'ko'),
    not (new.raw_app_meta_data ? 'provider' and not new.raw_app_meta_data ? 'role'));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

-- ───────────────────────── 기본 데이터 ─────────────────────────
insert into public.settings default values;

insert into public.role_permissions (role, perm) values
  ('leader', 'site.create'), ('leader', 'site.edit'), ('leader', 'work.force_release'),
  ('leader', 'work.reopen'), ('leader', 'urgent.send'), ('leader', 'log.view_team'),
  ('leader', 'stats.view_team');

insert into public.check_templates (name, require_photo, require_signature, items) values (
  '상하수도 기본 (예시)', 1, false,
  '[{"key":"w_meter","section":"상수도","label":"계량기 확인","type":"bool","required":true},
    {"key":"w_leak","section":"상수도","label":"누수 여부","type":"select","options":["없음","있음"],"required":true},
    {"key":"w_read","section":"상수도","label":"지침","type":"number","unit":"m³","min":0,"required":false},
    {"key":"s_hole","section":"하수도","label":"맨홀 상태","type":"select","options":["양호","파손","막힘"],"required":true},
    {"key":"s_back","section":"하수도","label":"역류 여부","type":"bool","required":true}]');
