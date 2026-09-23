-- path: supabase/migrations/20260923000002_api.sql
-- FieldSync 로직: 헬퍼 · 상태머신 RPC · 관리 RPC · 리마인더 · 통계 · 감사 트리거
-- 규약: 모든 SECURITY DEFINER 함수는 search_path='' + 전체 스키마 한정 이름 사용.
--       업무 결과는 jsonb {ok, code, site, session, occupant, replayed, ...} 로 반환(HTTP 200).

-- ═════════════════════════ 1. 헬퍼 ═════════════════════════
create function private.me() returns public.profiles
language sql stable security definer set search_path = '' as $$
  select * from public.profiles where id = auth.uid()
$$;

create function private.cfg() returns public.settings
language sql stable security definer set search_path = '' as $$
  select * from public.settings where id = 1
$$;

-- RLS 정책용 (쿼리당 1회 평가되도록 정책에서 (select ...)로 감싸 사용)
create function private.is_active() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select active from public.profiles where id = auth.uid()), false)
$$;

create function private.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select role = 'admin' and active from public.profiles where id = auth.uid()), false)
$$;

create function private.my_team() returns uuid
language sql stable security definer set search_path = '' as $$
  select team_id from public.profiles where id = auth.uid() and active
$$;

-- 권한 판정: 비활성 → 거부, 관리자 → 허용, 그 외 role_permissions 조회(위임 불가 권한은 행이 존재할 수 없음)
create function private.can(p_perm text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select case
      when not p.active then false
      when p.role = 'admin' then true
      else exists (select 1 from public.role_permissions rp where rp.role = p.role and rp.perm = p_perm)
    end
    from public.profiles p where p.id = auth.uid()), false)
$$;

-- 결과 객체 생성. 점유 중이거나 완료된 현장은 점유자(완료자) 정보를 포함
create function private.res(p_ok boolean, p_code text, p_site public.sites default null,
                            p_ws public.work_sessions default null, p_extra jsonb default null)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object(
      'ok', p_ok,
      'code', p_code,
      'site', case when (p_site).id is null then null else to_jsonb(p_site) end,
      'session', case when (p_ws).id is null then null else to_jsonb(p_ws) end,
      'occupant', case when (p_site).occupant_id is null then null else jsonb_build_object(
          'user_id', (p_site).occupant_id, 'name', (p_site).occupant_name, 'team', (p_site).occupant_team,
          'status', (p_site).status, 'since', coalesce((p_site).started_at, (p_site).status_at)) end,
      'replayed', false)
    || coalesce(p_extra, '{}')
$$;

-- 멱등: 같은 op_id는 advisory lock으로 직렬화 → 이미 처리됐으면 최초 결과 + 현재 행을 반환
create function private.replay(p_op_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_log  public.work_logs;
  v_site public.sites;
  v_ws   public.work_sessions;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_op_id::text, 0));
  select * into v_log from public.work_logs where op_id = p_op_id;
  if not found then return null; end if;
  if v_log.actor_id is distinct from auth.uid() then
    raise exception 'op_id already used' using errcode = '22023';
  end if;
  select * into v_site from public.sites where id = v_log.site_id;
  select * into v_ws from public.work_sessions where id = v_log.session_id and user_id = auth.uid();
  return (v_log.meta -> 'result')
      || jsonb_build_object('site', case when v_site.id is null then null else to_jsonb(v_site) end,
                            'session', case when v_ws.id is null then null else to_jsonb(v_ws) end,
                            'replayed', true);
end $$;

-- 로그 기록 후 결과 반환. 로그에는 site/session 본문을 빼고 저장(행 크기 절감)
create function private.finish(
  p_op_id uuid, p_action text, p_result jsonb,
  p_site_id uuid default null, p_session_id uuid default null, p_group_id uuid default null,
  p_from text default null, p_to text default null, p_meta jsonb default '{}',
  p_client_at timestamptz default null, p_lat double precision default null, p_lng double precision default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  insert into public.work_logs (actor_id, team_id, site_id, session_id, group_id, action, ok,
                                from_status, to_status, meta, op_id, client_at, lat, lng)
  values (auth.uid(), private.my_team(), p_site_id, p_session_id, p_group_id, p_action,
          coalesce((p_result ->> 'ok')::boolean, true), p_from, p_to,
          coalesce(p_meta, '{}') || jsonb_build_object('result', p_result - 'site' - 'session'),
          p_op_id, p_client_at, p_lat, p_lng);
  return p_result;
end $$;

-- 다국어 푸시 문구 (ko/en/vi). 베트남어는 번역 검수 필요
create function private.msg(p_key text, p_lang text, p_args text[] default '{}') returns text
language sql immutable set search_path = '' as $$
  select format(coalesce(t ->> coalesce(p_lang, 'ko'), t ->> 'ko'), variadic (p_args || array['', '', '']))
  from (select (case p_key
    when 'escalate_title' then '{"ko":"완료 체크 지연","en":"Completion check overdue","vi":"Quá hạn xác nhận hoàn thành"}'
    when 'escalate_body'  then '{"ko":"%s · %s · 작업 %s 경과","en":"%s · %s · working for %s","vi":"%s · %s · đã làm %s"}'
    when 'urgent_title'   then '{"ko":"🚨 긴급 요청","en":"🚨 Urgent request","vi":"🚨 Yêu cầu khẩn cấp"}'
    when 'release_title'  then '{"ko":"현장 점유 해제됨","en":"Site released","vi":"Đã giải phóng điểm làm việc"}'
    when 'release_body'   then '{"ko":"%s — %s님이 해제 (사유: %s)","en":"%s — released by %s (reason: %s)","vi":"%s — %s đã giải phóng (lý do: %s)"}'
    when 'publish_title'  then '{"ko":"새 동선 배포","en":"New route published","vi":"Lộ trình mới"}'
    when 'publish_body'   then '{"ko":"%s · 현장 %s곳","en":"%s · %s sites","vi":"%s · %s điểm"}'
    when 'reopen_title'   then '{"ko":"완료 현장 재오픈","en":"Completed site reopened","vi":"Mở lại điểm đã hoàn thành"}'
    when 'reopen_body'    then '{"ko":"%s — 사유: %s","en":"%s — reason: %s","vi":"%s — lý do: %s"}'
    end)::jsonb as t) m
$$;

create function private.fmt_elapsed(p interval, p_lang text) returns text
language sql immutable set search_path = '' as $$
  select case coalesce(p_lang, 'ko')
           when 'en' then format('%sh %sm', h, m)
           when 'vi' then format('%s giờ %s phút', h, m)
           else format('%s시간 %s분', h, m) end
  from (select floor(e / 3600)::int as h, floor(mod(e, 3600) / 60)::int as m
          from (select extract(epoch from greatest(p, interval '0')) as e) z) y
$$;

-- 체크 값 형식 검증. O(1) (select 옵션은 O(옵션 수))
create function private.valid_check_value(p_item jsonb, p_val jsonb) returns boolean
language sql immutable set search_path = '' as $$
  select case p_item ->> 'type'
    when 'bool'   then jsonb_typeof(p_val) = 'boolean'
    when 'number' then case when jsonb_typeof(p_val) <> 'number' then false   -- 캐스트 전에 타입 확인
                       else (p_item -> 'min' is null or (p_val #>> '{}')::numeric >= (p_item ->> 'min')::numeric)
                        and (p_item -> 'max' is null or (p_val #>> '{}')::numeric <= (p_item ->> 'max')::numeric) end
    when 'select' then jsonb_typeof(p_val) = 'string' and (p_item -> 'options') ? (p_val #>> '{}')
    when 'text'   then jsonb_typeof(p_val) = 'string' and length(p_val #>> '{}') <= 500
    else false end
$$;

-- 필수 누락 또는 형식 오류인 항목 key 목록. O(항목 수)
create function private.missing_checks(p_items jsonb, p_checks jsonb) returns text[]
language sql immutable set search_path = '' as $$
  select coalesce(array_agg(e ->> 'key' order by ord), '{}')
  from jsonb_array_elements(coalesce(p_items, '[]')) with ordinality as t(e, ord)
  where (coalesce((e ->> 'required')::boolean, false)
         and (p_checks -> (e ->> 'key') is null
              or jsonb_typeof(p_checks -> (e ->> 'key')) = 'null'
              or p_checks ->> (e ->> 'key') = ''))
     or (p_checks -> (e ->> 'key') is not null
         and jsonb_typeof(p_checks -> (e ->> 'key')) <> 'null'
         and not private.valid_check_value(e, p_checks -> (e ->> 'key')))
$$;

-- 알림 아웃박스 발송 트리거 (pg_net·vault 있을 때만. 로컬/미설정 환경에서는 무동작)
create function private.kick_push() returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_url    text;
  v_secret text;
begin
  if to_regclass('vault.decrypted_secrets') is null
     or not exists (select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'net' and p.proname = 'http_post') then
    return;
  end if;
  execute $q$select (select decrypted_secret from vault.decrypted_secrets where name = 'project_url'),
                    (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')$q$
    into v_url, v_secret;
  if v_url is null or v_secret is null then return; end if;
  execute $q$select net.http_post(url := $1, body := '{}'::jsonb,
                                  headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', $2))$q$
    using v_url || '/functions/v1/push', v_secret;
end $$;

-- ═════════════════════════ 2. 상태머신 (단일 진입점) ═════════════════════════
-- 모든 작업 전이를 한 함수에서 처리 → 규칙 중복 없음.
-- 동시성: 대상 현장 행 FOR UPDATE(현장 단위 직렬화) + 사용자 행 FOR UPDATE(1인 한도 직렬화, 잠금 순서 site→profile).
-- 복잡도: 인덱스 조회 O(log n) 몇 회.
create function private.transition(
  p_action text, p_site_id uuid, p_op_id uuid,
  p_client_at timestamptz default null, p_lat double precision default null, p_lng double precision default null,
  p_args jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_occupied constant public.site_status[] := '{en_route,working,paused}';
  v_me     public.profiles;
  v_cfg    public.settings;
  v_site   public.sites;
  v_grp    public.site_groups;
  v_tpl    public.check_templates;
  v_ws     public.work_sessions;
  v_prev   jsonb;
  v_from   text;
  v_code   text := 'OK';
  v_extra  jsonb;
  v_meta   jsonb := '{}';
  v_missing text[];
  v_owner  boolean;
  v_admin  boolean;
  v_n      int;
  v_nw     int;
  v_reason text := nullif(btrim(coalesce(p_args ->> 'reason', '')), '');
  v_checks jsonb := p_args -> 'checks';
begin
  if p_op_id is null then raise exception 'p_op_id is required' using errcode = '22023'; end if;
  v_prev := private.replay(p_op_id);
  if v_prev is not null then return v_prev; end if;

  v_me := private.me();
  if v_me.id is null then raise exception 'not authenticated' using errcode = '42501'; end if;

  select * into v_site from public.sites where id = p_site_id for update;           -- ★ 현장 단위 직렬화
  if not found or v_site.archived then
    return private.finish(p_op_id, p_action, private.res(false, 'NOT_FOUND'),
                          p_meta => jsonb_build_object('site_id', p_site_id), p_client_at => p_client_at);
  end if;
  v_from := v_site.status::text;

  <<body>>
  begin
    if not v_me.active then v_code := 'FORBIDDEN'; exit body; end if;
    select * into v_grp from public.site_groups where id = v_site.group_id;
    if not v_grp.published or v_grp.archived then v_code := 'NOT_PUBLISHED'; exit body; end if;

    v_cfg := private.cfg();
    v_admin := v_me.role = 'admin';
    if v_site.session_id is not null then
      select * into v_ws from public.work_sessions where id = v_site.session_id for update;
    end if;
    v_owner := v_ws.id is not null and v_ws.user_id = v_me.id and v_site.status = any (c_occupied);

    if p_action in ('pause', 'resume', 'complete', 'release', 'save_checks', 'snooze') and not v_owner then
      v_code := case when v_site.status = 'done' then 'INVALID_TRANSITION' else 'NOT_OWNER' end;
      exit body;
    end if;
    if p_action in ('claim', 'start', 'resume', 'undo_complete') then
      perform 1 from public.profiles where id = v_me.id for update;                  -- 1인 한도 직렬화
      select count(*), count(*) filter (where status = 'working') into v_n, v_nw
        from public.work_sessions where user_id = v_me.id and status in ('en_route', 'working', 'paused');
    end if;

    case p_action
    -- ── 맡기 / 작업 시작 ──
    when 'claim', 'start' then
      if v_site.status = any (c_occupied) then
        if p_action = 'start' and v_owner and v_site.status = 'en_route' then       -- 내 진행중 → 작업중
          if v_nw > 0 then v_code := 'ALREADY_WORKING'; exit body; end if;
          update public.work_sessions
             set status = 'working', started_at = now(), remind_count = 0,
                 next_remind_at = now() + make_interval(mins => v_cfg.remind_working_first_min)
           where id = v_ws.id returning * into v_ws;
          update public.sites set status = 'working', started_at = now(), status_at = now()
           where id = v_site.id returning * into v_site;
          exit body;
        end if;
        v_code := case when v_owner then 'INVALID_TRANSITION' else 'SITE_OCCUPIED' end;
        exit body;
      end if;
      if v_site.status <> 'pending' then v_code := 'INVALID_TRANSITION'; exit body; end if;
      if v_grp.team_id is not null and v_grp.team_id is distinct from v_me.team_id and not v_admin then
        v_code := 'TEAM_MISMATCH'; exit body;
      end if;
      if v_n >= v_cfg.max_claims_per_user then v_code := 'CLAIM_LIMIT'; exit body; end if;
      if p_action = 'start' and v_nw > 0 then v_code := 'ALREADY_WORKING'; exit body; end if;
      begin
        insert into public.work_sessions (site_id, user_id, team_id, status, claimed_at, started_at,
                                          next_remind_at, client_claimed_at)
        values (v_site.id, v_me.id, v_me.team_id,
                (case when p_action = 'claim' then 'en_route' else 'working' end)::public.session_status,
                now(), case when p_action = 'start' then now() end,
                now() + make_interval(mins => case when p_action = 'claim' then v_cfg.remind_en_route_after_min
                                                   else v_cfg.remind_working_first_min end),
                p_client_at)
        returning * into v_ws;
      exception when unique_violation then                                            -- 최후 방어선
        v_code := 'SITE_OCCUPIED'; exit body;
      end;
      update public.sites
         set status = (case when p_action = 'claim' then 'en_route' else 'working' end)::public.site_status,
             session_id = v_ws.id, occupant_id = v_me.id, occupant_name = v_me.name,
             occupant_team = (select name from public.teams where id = v_me.team_id),
             started_at = v_ws.started_at, status_at = now()
       where id = v_site.id returning * into v_site;

    -- ── 일시중단 ──
    when 'pause' then
      if v_site.status <> 'working' then v_code := 'INVALID_TRANSITION'; exit body; end if;
      if coalesce(p_args ->> 'reason_code', '') not in ('absent', 'material', 'no_access', 'weather', 'other')
         or length(coalesce(p_args ->> 'memo', '')) > 500 then
        v_code := 'INVALID_INPUT'; exit body;
      end if;
      v_meta := jsonb_build_object('reason_code', p_args ->> 'reason_code', 'memo', p_args ->> 'memo');
      update public.work_sessions
         set status = 'paused', paused_at = now(), remind_count = 0,
             pause_reason = (p_args ->> 'reason_code') || coalesce(': ' || nullif(p_args ->> 'memo', ''), ''),
             next_remind_at = now() + make_interval(mins => v_cfg.remind_paused_after_min)
       where id = v_ws.id returning * into v_ws;
      update public.sites set status = 'paused', status_at = now() where id = v_site.id returning * into v_site;

    -- ── 재개 ──
    when 'resume' then
      if v_site.status <> 'paused' then v_code := 'INVALID_TRANSITION'; exit body; end if;
      if v_nw > 0 then v_code := 'ALREADY_WORKING'; exit body; end if;
      update public.work_sessions
         set status = 'working', paused_total = paused_total + (now() - coalesce(paused_at, now())),
             paused_at = null, remind_count = 0,
             next_remind_at = now() + make_interval(mins => v_cfg.remind_working_first_min)
       where id = v_ws.id returning * into v_ws;
      update public.sites set status = 'working', status_at = now() where id = v_site.id returning * into v_site;

    -- ── 작업완료 (필수 체크·증빙 검증) ──
    when 'complete' then
      v_meta := jsonb_build_object('checks', coalesce(v_checks, '{}'), 'note', p_args ->> 'note');  -- 거절돼도 입력 보존
      if v_site.status <> 'working' then v_code := 'INVALID_TRANSITION'; exit body; end if;
      if jsonb_typeof(coalesce(v_checks, '{}')) <> 'object' or length(coalesce(p_args ->> 'note', '')) > 2000 then
        v_code := 'INVALID_INPUT'; exit body;
      end if;
      select * into v_tpl from public.check_templates where id = v_grp.template_id;
      v_missing := private.missing_checks(v_tpl.items, v_ws.checks || coalesce(v_checks, '{}'));
      if cardinality(v_missing) > 0 then
        v_code := 'CHECKS_INCOMPLETE'; v_extra := jsonb_build_object('missing', v_missing); exit body;
      end if;
      v_missing := '{}';
      if coalesce(v_tpl.require_photo, 0) >
         (select count(*) from public.attachments where session_id = v_ws.id and kind = 'photo') then
        v_missing := v_missing || 'photo'::text;
      end if;
      if coalesce(v_tpl.require_signature, false)
         and not exists (select 1 from public.attachments where session_id = v_ws.id and kind = 'signature') then
        v_missing := v_missing || 'signature'::text;
      end if;
      if cardinality(v_missing) > 0 then
        v_code := 'PROOF_REQUIRED'; v_extra := jsonb_build_object('missing', v_missing); exit body;
      end if;
      update public.work_sessions
         set status = 'done', completed_at = now(), next_remind_at = null,
             checks = checks || coalesce(v_checks, '{}'), note = coalesce(p_args ->> 'note', note)
       where id = v_ws.id returning * into v_ws;
      update public.sites set status = 'done', status_at = now() where id = v_site.id returning * into v_site;

    -- ── 완료 취소 (본인·제한 시간 내) ──
    when 'undo_complete' then
      if v_site.status <> 'done' or v_ws.id is null or v_ws.status <> 'done' then
        v_code := 'INVALID_TRANSITION'; exit body;
      end if;
      if v_ws.user_id <> v_me.id then v_code := 'NOT_OWNER'; exit body; end if;
      if now() - v_ws.completed_at > make_interval(mins => v_cfg.undo_complete_window_min) then
        v_code := 'UNDO_EXPIRED'; exit body;
      end if;
      if v_nw > 0 then v_code := 'ALREADY_WORKING'; exit body; end if;
      begin
        update public.sites set status = 'working', status_at = now() where id = v_site.id returning * into v_site;
      exception when unique_violation then
        v_code := 'DUPLICATE_SITE'; exit body;
      end;
      update public.work_sessions
         set status = 'working', completed_at = null, remind_count = 0,
             next_remind_at = now() + make_interval(mins => v_cfg.remind_working_repeat_min)
       where id = v_ws.id returning * into v_ws;

    -- ── 반납 (본인) / 강제 해제 (권한자) ──
    when 'release', 'force_release' then
      if p_action = 'force_release' then
        if not (v_admin or (private.can('work.force_release') and v_ws.team_id = v_me.team_id)) then
          v_code := 'FORBIDDEN'; exit body;
        end if;
        if not (v_site.status = any (c_occupied)) then v_code := 'INVALID_TRANSITION'; exit body; end if;
      end if;
      if v_reason is null or length(v_reason) > 500 then v_code := 'INVALID_INPUT'; exit body; end if;
      v_meta := jsonb_build_object('reason', v_reason, 'occupant_id', v_ws.user_id);
      update public.work_sessions
         set status = 'released', released_at = now(), release_reason = v_reason, released_by = v_me.id,
             next_remind_at = null,
             paused_total = paused_total + coalesce(now() - paused_at, interval '0'), paused_at = null
       where id = v_ws.id returning * into v_ws;
      update public.sites
         set status = 'pending', session_id = null, occupant_id = null, occupant_name = null,
             occupant_team = null, started_at = null, status_at = now()
       where id = v_site.id returning * into v_site;
      if p_action = 'force_release' and v_ws.user_id <> v_me.id then
        insert into public.notifications (user_id, kind, title, body, data, collapse_key)
        select p.id, 'force_release', private.msg('release_title', p.lang),
               private.msg('release_body', p.lang, array[v_site.bunji, v_me.name, v_reason]),
               jsonb_build_object('site_id', v_site.id, 'session_id', v_ws.id), 'release:' || v_ws.id
          from public.profiles p where p.id = v_ws.user_id;
        perform private.kick_push();
      end if;

    -- ── 재오픈 (권한자) ──
    when 'reopen' then
      if not (v_admin or (private.can('work.reopen') and v_ws.team_id = v_me.team_id)) then
        v_code := 'FORBIDDEN'; exit body;
      end if;
      if v_site.status <> 'done' then v_code := 'INVALID_TRANSITION'; exit body; end if;
      if v_reason is null or length(v_reason) > 500 then v_code := 'INVALID_INPUT'; exit body; end if;
      v_meta := jsonb_build_object('reason', v_reason, 'prev_session_id', v_ws.id);
      begin
        update public.sites
           set status = 'pending', session_id = null, occupant_id = null, occupant_name = null,
               occupant_team = null, started_at = null, status_at = now()
         where id = v_site.id returning * into v_site;
      exception when unique_violation then
        v_code := 'DUPLICATE_SITE'; exit body;
      end;
      insert into public.notifications (user_id, kind, title, body, data, collapse_key)
      select p.id, 'reopen', private.msg('reopen_title', p.lang),
             private.msg('reopen_body', p.lang, array[v_site.bunji, v_reason]),
             jsonb_build_object('site_id', v_site.id), 'reopen:' || v_site.id
        from public.profiles p where p.id = v_ws.user_id and p.id <> v_me.id and p.active;
      perform private.kick_push();

    -- ── 체크 중간 저장 ──
    when 'save_checks' then
      if v_site.status not in ('working', 'paused') then v_code := 'INVALID_TRANSITION'; exit body; end if;
      if jsonb_typeof(v_checks) is distinct from 'object' then v_code := 'INVALID_INPUT'; exit body; end if;
      update public.work_sessions set checks = checks || v_checks where id = v_ws.id returning * into v_ws;

    -- ── 리마인더 연기 ──
    when 'snooze' then
      if coalesce(p_args ->> 'minutes', '') !~ '^\d{1,4}$'
         or (p_args ->> 'minutes')::int not between 5 and 480 then
        v_code := 'INVALID_INPUT'; exit body;
      end if;
      v_meta := jsonb_build_object('minutes', (p_args ->> 'minutes')::int);
      update public.work_sessions
         set next_remind_at = now() + make_interval(mins => (p_args ->> 'minutes')::int)
       where id = v_ws.id returning * into v_ws;

    else
      raise exception 'unknown action %', p_action using errcode = '22023';
    end case;
  end body;

  if v_code <> 'OK' then
    return private.finish(p_op_id, p_action, private.res(false, v_code, v_site, null, v_extra),
                          v_site.id, v_ws.id, v_site.group_id, v_from, v_from, v_meta, p_client_at, p_lat, p_lng);
  end if;
  return private.finish(p_op_id, p_action, private.res(true, 'OK', v_site, v_ws, v_extra),
                        v_site.id, v_ws.id, v_site.group_id, v_from, v_site.status::text, v_meta, p_client_at, p_lat, p_lng);
end $$;

-- ═════════════════════════ 3. 작업 RPC (PostgREST 노출용 얇은 래퍼) ═════════════════════════
create function public.claim_site(p_site_id uuid, p_op_id uuid, p_client_at timestamptz default null,
                                  p_lat double precision default null, p_lng double precision default null)
returns jsonb language sql security definer set search_path = '' as $$
  select private.transition('claim', p_site_id, p_op_id, p_client_at, p_lat, p_lng)
$$;

create function public.start_work(p_site_id uuid, p_op_id uuid, p_client_at timestamptz default null,
                                  p_lat double precision default null, p_lng double precision default null)
returns jsonb language sql security definer set search_path = '' as $$
  select private.transition('start', p_site_id, p_op_id, p_client_at, p_lat, p_lng)
$$;

create function public.pause_work(p_site_id uuid, p_op_id uuid, p_reason_code text, p_memo text default null,
                                  p_client_at timestamptz default null,
                                  p_lat double precision default null, p_lng double precision default null)
returns jsonb language sql security definer set search_path = '' as $$
  select private.transition('pause', p_site_id, p_op_id, p_client_at, p_lat, p_lng,
                            jsonb_build_object('reason_code', p_reason_code, 'memo', p_memo))
$$;

create function public.resume_work(p_site_id uuid, p_op_id uuid, p_client_at timestamptz default null,
                                   p_lat double precision default null, p_lng double precision default null)
returns jsonb language sql security definer set search_path = '' as $$
  select private.transition('resume', p_site_id, p_op_id, p_client_at, p_lat, p_lng)
$$;

create function public.complete_work(p_site_id uuid, p_op_id uuid, p_checks jsonb default '{}', p_note text default null,
                                     p_client_at timestamptz default null,
                                     p_lat double precision default null, p_lng double precision default null)
returns jsonb language sql security definer set search_path = '' as $$
  select private.transition('complete', p_site_id, p_op_id, p_client_at, p_lat, p_lng,
                            jsonb_build_object('checks', coalesce(p_checks, '{}'), 'note', p_note))
$$;

create function public.undo_complete(p_site_id uuid, p_op_id uuid, p_client_at timestamptz default null,
                                     p_lat double precision default null, p_lng double precision default null)
returns jsonb language sql security definer set search_path = '' as $$
  select private.transition('undo_complete', p_site_id, p_op_id, p_client_at, p_lat, p_lng)
$$;

create function public.release_site(p_site_id uuid, p_op_id uuid, p_reason text, p_client_at timestamptz default null,
                                    p_lat double precision default null, p_lng double precision default null)
returns jsonb language sql security definer set search_path = '' as $$
  select private.transition('release', p_site_id, p_op_id, p_client_at, p_lat, p_lng,
                            jsonb_build_object('reason', p_reason))
$$;

create function public.force_release(p_site_id uuid, p_op_id uuid, p_reason text, p_client_at timestamptz default null,
                                     p_lat double precision default null, p_lng double precision default null)
returns jsonb language sql security definer set search_path = '' as $$
  select private.transition('force_release', p_site_id, p_op_id, p_client_at, p_lat, p_lng,
                            jsonb_build_object('reason', p_reason))
$$;

create function public.reopen_site(p_site_id uuid, p_op_id uuid, p_reason text, p_client_at timestamptz default null,
                                   p_lat double precision default null, p_lng double precision default null)
returns jsonb language sql security definer set search_path = '' as $$
  select private.transition('reopen', p_site_id, p_op_id, p_client_at, p_lat, p_lng,
                            jsonb_build_object('reason', p_reason))
$$;

create function public.save_checks(p_site_id uuid, p_op_id uuid, p_checks jsonb, p_client_at timestamptz default null,
                                   p_lat double precision default null, p_lng double precision default null)
returns jsonb language sql security definer set search_path = '' as $$
  select private.transition('save_checks', p_site_id, p_op_id, p_client_at, p_lat, p_lng,
                            jsonb_build_object('checks', p_checks))
$$;

create function public.snooze_reminder(p_site_id uuid, p_op_id uuid, p_minutes int, p_client_at timestamptz default null,
                                       p_lat double precision default null, p_lng double precision default null)
returns jsonb language sql security definer set search_path = '' as $$
  select private.transition('snooze', p_site_id, p_op_id, p_client_at, p_lat, p_lng,
                            jsonb_build_object('minutes', p_minutes))
$$;

-- ═════════════════════════ 4. 긴급 요청 ═════════════════════════
create function public.send_urgent(p_message text, p_op_id uuid, p_site_id uuid default null, p_group_id uuid default null,
                                   p_client_at timestamptz default null,
                                   p_lat double precision default null, p_lng double precision default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_prev jsonb;
  v_me   public.profiles;
  v_site public.sites;
  v_id   uuid;
  v_code text := 'OK';
  v_msg  text := btrim(coalesce(p_message, ''));
begin
  if p_op_id is null then raise exception 'p_op_id is required' using errcode = '22023'; end if;
  v_prev := private.replay(p_op_id);
  if v_prev is not null then return v_prev; end if;
  v_me := private.me();
  if v_me.id is null then raise exception 'not authenticated' using errcode = '42501'; end if;

  <<body>>
  begin
    if not private.can('urgent.send') then v_code := 'FORBIDDEN'; exit body; end if;
    if length(v_msg) not between 1 and 300 then v_code := 'INVALID_INPUT'; exit body; end if;
    if p_site_id is not null then
      select * into v_site from public.sites where id = p_site_id and not archived for update;
      if not found then v_code := 'NOT_FOUND'; exit body; end if;
    elsif p_group_id is not null and not exists (select 1 from public.site_groups where id = p_group_id) then
      v_code := 'NOT_FOUND'; exit body;
    end if;
    insert into public.urgent_requests (site_id, group_id, message, created_by)
    values (v_site.id, coalesce(v_site.group_id, p_group_id), v_msg, v_me.id) returning id into v_id;
    if v_site.id is not null then
      update public.sites set urgent = true where id = v_site.id returning * into v_site;
    end if;
    insert into public.notifications (user_id, kind, title, body, data, collapse_key)
    select p.id, 'urgent', private.msg('urgent_title', p.lang),
           coalesce(v_site.bunji || ' · ', '') || v_msg,
           jsonb_build_object('urgent_id', v_id, 'site_id', v_site.id), 'urgent:' || v_id
      from public.profiles p where p.active and p.id <> v_me.id;
    perform private.kick_push();
  end body;

  return private.finish(p_op_id, 'urgent', private.res(v_code = 'OK', v_code, v_site, null,
                        case when v_id is null then null else jsonb_build_object('urgent_id', v_id) end),
                        v_site.id, null, coalesce(v_site.group_id, p_group_id), null, null,
                        jsonb_build_object('message', v_msg), p_client_at, p_lat, p_lng);
end $$;

create function public.resolve_urgent(p_urgent_id uuid, p_op_id uuid, p_client_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_prev jsonb;
  v_u    public.urgent_requests;
  v_site public.sites;
  v_code text := 'OK';
begin
  if p_op_id is null then raise exception 'p_op_id is required' using errcode = '22023'; end if;
  v_prev := private.replay(p_op_id);
  if v_prev is not null then return v_prev; end if;
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '42501'; end if;

  <<body>>
  begin
    if not private.can('urgent.send') then v_code := 'FORBIDDEN'; exit body; end if;
    select * into v_u from public.urgent_requests where id = p_urgent_id for update;
    if not found then v_code := 'NOT_FOUND'; exit body; end if;
    if v_u.resolved_at is not null then v_code := 'INVALID_TRANSITION'; exit body; end if;
    update public.urgent_requests set resolved_at = now(), resolved_by = auth.uid() where id = v_u.id;
    if v_u.site_id is not null then
      update public.sites s
         set urgent = exists (select 1 from public.urgent_requests u
                              where u.site_id = s.id and u.resolved_at is null)
       where s.id = v_u.site_id returning * into v_site;
    end if;
  end body;

  return private.finish(p_op_id, 'urgent_resolve', private.res(v_code = 'OK', v_code, v_site),
                        v_u.site_id, null, v_u.group_id, null, null,
                        jsonb_build_object('urgent_id', p_urgent_id), p_client_at);
end $$;

-- ═════════════════════════ 5. 관리 RPC (관리자 고정) ═════════════════════════
create function public.publish_group(p_group_id uuid, p_published boolean, p_op_id uuid,
                                     p_client_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_prev jsonb;
  v_me   public.profiles;
  v_grp  public.site_groups;
  v_n    int;
  v_code text := 'OK';
begin
  if p_op_id is null then raise exception 'p_op_id is required' using errcode = '22023'; end if;
  v_prev := private.replay(p_op_id);
  if v_prev is not null then return v_prev; end if;
  v_me := private.me();
  if v_me.id is null then raise exception 'not authenticated' using errcode = '42501'; end if;

  <<body>>
  begin
    if not (v_me.active and v_me.role = 'admin') then v_code := 'FORBIDDEN'; exit body; end if;
    if p_published is null then v_code := 'INVALID_INPUT'; exit body; end if;
    select * into v_grp from public.site_groups where id = p_group_id for update;
    if not found then v_code := 'NOT_FOUND'; exit body; end if;
    if not p_published and exists (
         select 1 from public.sites s where s.group_id = v_grp.id and s.status in ('en_route', 'working', 'paused')) then
      v_code := 'HAS_ACTIVE_CLAIMS'; exit body;
    end if;
    update public.site_groups
       set published = p_published, published_at = case when p_published then now() else published_at end
     where id = v_grp.id returning * into v_grp;
    select count(*) into v_n from public.sites where group_id = v_grp.id and not archived;
    if p_published then
      insert into public.notifications (user_id, kind, title, body, data, collapse_key)
      select p.id, 'publish', private.msg('publish_title', p.lang),
             private.msg('publish_body', p.lang, array[v_grp.name, v_n::text]),
             jsonb_build_object('group_id', v_grp.id), 'publish:' || v_grp.id
        from public.profiles p
       where p.active and p.id <> v_me.id and (v_grp.team_id is null or p.team_id = v_grp.team_id);
      perform private.kick_push();
    end if;
  end body;

  return private.finish(p_op_id, case when p_published then 'publish' else 'unpublish' end,
                        private.res(v_code = 'OK', v_code, null, null,
                                    jsonb_build_object('group', to_jsonb(v_grp), 'site_count', v_n)),
                        null, null, v_grp.id, null, null, '{}', p_client_at);
end $$;

create function public.set_user_role(p_user_id uuid, p_role public.user_role, p_op_id uuid,
                                     p_team_id uuid default null, p_client_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_prev jsonb;
  v_me   public.profiles;
  v_t    public.profiles;
  v_code text := 'OK';
begin
  if p_op_id is null then raise exception 'p_op_id is required' using errcode = '22023'; end if;
  v_prev := private.replay(p_op_id);
  if v_prev is not null then return v_prev; end if;
  v_me := private.me();
  if v_me.id is null then raise exception 'not authenticated' using errcode = '42501'; end if;

  <<body>>
  begin
    if not (v_me.active and v_me.role = 'admin') then v_code := 'FORBIDDEN'; exit body; end if;
    if p_role is null or (p_team_id is not null and not exists (select 1 from public.teams where id = p_team_id)) then
      v_code := 'INVALID_INPUT'; exit body;
    end if;
    perform 1 from public.profiles where role = 'admin' for update;                 -- 관리자 수 판단 직렬화
    select * into v_t from public.profiles where id = p_user_id for update;
    if not found then v_code := 'NOT_FOUND'; exit body; end if;
    if v_t.role = 'admin' and p_role <> 'admin'
       and (select count(*) from public.profiles where role = 'admin' and active) <= 1 then
      v_code := 'LAST_ADMIN'; exit body;
    end if;
    update public.profiles set role = p_role, team_id = p_team_id where id = v_t.id;
  end body;

  return private.finish(p_op_id, 'role_change', private.res(v_code = 'OK', v_code), null, null, null, null, null,
                        jsonb_build_object('user_id', p_user_id, 'from_role', v_t.role, 'to_role', p_role,
                                           'from_team', v_t.team_id, 'to_team', p_team_id), p_client_at);
end $$;

create function public.set_user_active(p_user_id uuid, p_active boolean, p_op_id uuid,
                                       p_client_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_prev jsonb;
  v_me   public.profiles;
  v_t    public.profiles;
  v_code text := 'OK';
begin
  if p_op_id is null then raise exception 'p_op_id is required' using errcode = '22023'; end if;
  v_prev := private.replay(p_op_id);
  if v_prev is not null then return v_prev; end if;
  v_me := private.me();
  if v_me.id is null then raise exception 'not authenticated' using errcode = '42501'; end if;

  <<body>>
  begin
    if not (v_me.active and v_me.role = 'admin') then v_code := 'FORBIDDEN'; exit body; end if;
    if p_active is null then v_code := 'INVALID_INPUT'; exit body; end if;
    perform 1 from public.profiles where role = 'admin' for update;
    select * into v_t from public.profiles where id = p_user_id for update;
    if not found then v_code := 'NOT_FOUND'; exit body; end if;
    if not p_active and v_t.role = 'admin'
       and (select count(*) from public.profiles where role = 'admin' and active) <= 1 then
      v_code := 'LAST_ADMIN'; exit body;
    end if;
    if not p_active and exists (select 1 from public.work_sessions
                                where user_id = v_t.id and status in ('en_route', 'working', 'paused')) then
      v_code := 'HAS_ACTIVE_CLAIMS'; exit body;
    end if;
    update public.profiles set active = p_active where id = v_t.id;
  end body;

  return private.finish(p_op_id, 'role_change', private.res(v_code = 'OK', v_code), null, null, null, null, null,
                        jsonb_build_object('user_id', p_user_id, 'active', p_active), p_client_at);
end $$;

create function public.set_role_permission(p_role public.user_role, p_perm text, p_granted boolean, p_op_id uuid,
                                           p_client_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_prev jsonb;
  v_code text := 'OK';
begin
  if p_op_id is null then raise exception 'p_op_id is required' using errcode = '22023'; end if;
  v_prev := private.replay(p_op_id);
  if v_prev is not null then return v_prev; end if;
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '42501'; end if;

  <<body>>
  begin
    if not private.is_admin() then v_code := 'FORBIDDEN'; exit body; end if;
    if p_role is null or p_role = 'admin' or p_granted is null
       or not (coalesce(p_perm, '') = any (private.delegable_perms())) then
      v_code := 'INVALID_INPUT'; exit body;
    end if;
    if p_granted then
      insert into public.role_permissions (role, perm) values (p_role, p_perm) on conflict do nothing;
    else
      delete from public.role_permissions where role = p_role and perm = p_perm;
    end if;
  end body;

  return private.finish(p_op_id, 'perm_change', private.res(v_code = 'OK', v_code), null, null, null, null, null,
                        jsonb_build_object('role', p_role, 'perm', p_perm, 'granted', p_granted), p_client_at);
end $$;

create function public.update_settings(p_settings jsonb, p_op_id uuid, p_client_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_prev jsonb;
  v_cur  public.settings;
  v_new  public.settings;
  v_code text := 'OK';
begin
  if p_op_id is null then raise exception 'p_op_id is required' using errcode = '22023'; end if;
  v_prev := private.replay(p_op_id);
  if v_prev is not null then return v_prev; end if;
  if auth.uid() is null then raise exception 'not authenticated' using errcode = '42501'; end if;

  <<body>>
  begin
    if not private.is_admin() then v_code := 'FORBIDDEN'; exit body; end if;
    select * into v_cur from public.settings where id = 1 for update;
    if jsonb_typeof(p_settings) is distinct from 'object'
       or exists (select 1 from jsonb_object_keys(p_settings) k
                  where k not in (select jsonb_object_keys(to_jsonb(v_cur) - 'id' - 'updated_at'))) then
      v_code := 'INVALID_INPUT'; exit body;
    end if;
    begin
      v_new := jsonb_populate_record(v_cur, p_settings);                              -- 형변환 포함
      update public.settings
         set remind_working_first_min  = v_new.remind_working_first_min,
             remind_working_repeat_min = v_new.remind_working_repeat_min,
             remind_max                = v_new.remind_max,
             escalate_at               = v_new.escalate_at,
             remind_en_route_after_min = v_new.remind_en_route_after_min,
             remind_paused_after_min   = v_new.remind_paused_after_min,
             max_claims_per_user       = v_new.max_claims_per_user,
             arrive_radius_m           = v_new.arrive_radius_m,
             undo_complete_window_min  = v_new.undo_complete_window_min,
             min_app_version           = v_new.min_app_version
       where id = 1;
    exception when check_violation or not_null_violation or invalid_text_representation
                   or numeric_value_out_of_range then
      v_code := 'INVALID_INPUT'; exit body;
    end;
  end body;

  return private.finish(p_op_id, 'settings_change',
                        private.res(v_code = 'OK', v_code, null, null,
                                    jsonb_build_object('settings', (select to_jsonb(s) from public.settings s where id = 1))),
                        null, null, null, null, null, jsonb_build_object('input', p_settings), p_client_at);
end $$;

-- ═════════════════════════ 6. 기기 등록 (멱등 upsert, 로그 없음) ═════════════════════════
create function public.register_device(p_token text, p_platform text, p_notif_permission boolean default true)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not private.is_active() then
    raise exception 'not authenticated' using errcode = '42501';
  end if;
  if coalesce(p_platform, '') not in ('ios', 'android') or length(coalesce(p_token, '')) not between 10 and 4096 then
    return private.res(false, 'INVALID_INPUT');
  end if;
  insert into public.device_tokens (token, user_id, platform, notif_permission, updated_at)
  values (p_token, auth.uid(), p_platform, coalesce(p_notif_permission, true), now())
  on conflict (token) do update
     set user_id = excluded.user_id, platform = excluded.platform,
         notif_permission = excluded.notif_permission, updated_at = now();   -- 계정 전환된 기기 재할당
  return private.res(true, 'OK');
end $$;

-- ═════════════════════════ 7. 통계 ═════════════════════════
-- 기간은 Asia/Seoul 날짜 기준 [p_from, p_to]. 관리자=전체, stats.view_team=자기 팀.
-- 완료율 = completed / claimed. 소요 = completed_at − started_at − 일시중단 합계.
-- 복잡도: claimed_at·at 인덱스 범위 스캔 O(k log n), k = 기간 내 세션·로그 수
create function public.get_stats(p_from date, p_to date, p_by text default 'team')
returns table (key uuid, name text, claimed int, completed int, released int, rejected_duplicates int,
               completion_rate numeric, avg_work_min numeric, p50_work_min numeric, long_running int)
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_column
declare
  v_me   public.profiles := private.me();
  v_cfg  public.settings := private.cfg();
  v_all  boolean;
  v_from timestamptz;
  v_to   timestamptz;
begin
  if v_me.id is null or not v_me.active then raise exception 'forbidden' using errcode = '42501'; end if;
  v_all := v_me.role = 'admin';
  if not v_all and not private.can('stats.view_team') then raise exception 'forbidden' using errcode = '42501'; end if;
  if coalesce(p_by, '') not in ('team', 'user') or p_from is null or p_to is null
     or p_to < p_from or p_to - p_from > 366 then
    raise exception 'invalid range or p_by' using errcode = '22023';
  end if;
  v_from := p_from::timestamp at time zone 'Asia/Seoul';
  v_to   := (p_to + 1)::timestamp at time zone 'Asia/Seoul';

  return query
  with s as (
    select case when p_by = 'team' then ws.team_id else ws.user_id end as k, ws.*
      from public.work_sessions ws
     where ws.claimed_at >= v_from and ws.claimed_at < v_to
       and (v_all or ws.team_id = v_me.team_id)
  ), agg as (
    select s.k,
           count(*)::int as claimed,
           count(*) filter (where s.status = 'done')::int as completed,
           count(*) filter (where s.status = 'released')::int as released,
           round((avg(extract(epoch from (s.completed_at - s.started_at - s.paused_total)) / 60)
                  filter (where s.status = 'done' and s.started_at is not null))::numeric, 1) as avg_min,
           round((percentile_cont(0.5) within group
                  (order by extract(epoch from (s.completed_at - s.started_at - s.paused_total)) / 60)
                  filter (where s.status = 'done' and s.started_at is not null))::numeric, 1) as p50_min,
           count(*) filter (where s.status in ('en_route', 'working', 'paused')
                              and s.remind_count >= v_cfg.remind_max)::int as long_running
      from s group by s.k
  ), rej as (
    select case when p_by = 'team' then l.team_id else l.actor_id end as k, count(*)::int as n
      from public.work_logs l
     where l.at >= v_from and l.at < v_to and not l.ok
       and l.meta -> 'result' ->> 'code' = 'SITE_OCCUPIED'
       and (v_all or l.team_id = v_me.team_id)
     group by 1
  ), keys as (
    select agg.k from agg union select rej.k from rej
  )
  select keys.k,
         coalesce(t.name, p.name, '(미지정)'),
         coalesce(a.claimed, 0), coalesce(a.completed, 0), coalesce(a.released, 0), coalesce(r.n, 0),
         case when coalesce(a.claimed, 0) = 0 then 0::numeric else round(a.completed::numeric / a.claimed, 3) end,
         a.avg_min, a.p50_min, coalesce(a.long_running, 0)
    from keys
    left join agg a on a.k is not distinct from keys.k
    left join rej r on r.k is not distinct from keys.k
    left join public.teams t on p_by = 'team' and t.id = keys.k
    left join public.profiles p on p_by = 'user' and p.id = keys.k
   order by 3 desc, 2;
end $$;

-- ═════════════════════════ 8. 리마인더 (pg_cron 1분 주기) ═════════════════════════
-- 작업자에게는 푸시하지 않음(앱 로컬 알림이 같은 스케줄로 울림 → 중복 방지).
-- escalate_at 회차에 팀장(팀장 없으면 관리자)에게 푸시. SKIP LOCKED → 겹쳐 실행돼도 중복 처리 없음.
-- 복잡도: next_remind_at 부분 인덱스 → O(도래 건수 · log n)
create function private.run_reminders() returns int
language plpgsql security definer set search_path = '' as $$
declare
  v_cfg public.settings := private.cfg();
  v     record;
  v_k   int;
  v_n   int := 0;
begin
  for v in
    select ws.id, ws.site_id, ws.team_id, ws.status, ws.remind_count, ws.started_at, ws.paused_total,
           s.bunji, s.group_id, p.name as worker_name
      from public.work_sessions ws
      join public.sites s on s.id = ws.site_id
      join public.profiles p on p.id = ws.user_id
     where ws.next_remind_at <= now() and ws.status in ('en_route', 'working', 'paused')
     order by ws.next_remind_at
     for update of ws skip locked
  loop
    v_k := v.remind_count + 1;
    if v.status = 'working' and v_k = v_cfg.escalate_at then
      insert into public.notifications (user_id, kind, title, body, data, collapse_key)
      select r.id, 'escalate', private.msg('escalate_title', r.lang),
             private.msg('escalate_body', r.lang,
                         array[v.worker_name, v.bunji,
                               private.fmt_elapsed(now() - coalesce(v.started_at, now()) - v.paused_total, r.lang)]),
             jsonb_build_object('site_id', v.site_id, 'session_id', v.id), 'escalate:' || v.id
        from public.profiles r
       where r.active
         and ((r.role = 'leader' and r.team_id = v.team_id)
              or (r.role = 'admin' and not exists (select 1 from public.profiles l
                                                   where l.role = 'leader' and l.active and l.team_id = v.team_id)));
      insert into public.work_logs (team_id, site_id, session_id, group_id, action, meta)
      values (v.team_id, v.site_id, v.id, v.group_id, 'escalate', jsonb_build_object('count', v_k));
    end if;
    update public.work_sessions
       set remind_count = v_k,
           next_remind_at = case when v_k >= v_cfg.remind_max then null
                                 else now() + make_interval(mins => case v.status
                                        when 'working'  then v_cfg.remind_working_repeat_min
                                        when 'en_route' then v_cfg.remind_en_route_after_min
                                        else v_cfg.remind_paused_after_min end) end
     where id = v.id;
    insert into public.work_logs (team_id, site_id, session_id, group_id, action, meta)
    values (v.team_id, v.site_id, v.id, v.group_id, 'remind', jsonb_build_object('count', v_k, 'status', v.status));
    v_n := v_n + 1;
  end loop;
  if v_n > 0 then perform private.kick_push(); end if;
  return v_n;
end $$;

-- ═════════════════════════ 8-1. 푸시 발송 선점 (Edge Function push 전용, service_role만 실행) ═════════════════════════
-- 미발송·5회 미만·임대 만료 알림을 잠그고 attempts+1. SKIP LOCKED로 동시 호출 간 중복 없음. O(k log n)
create function public.claim_push_batch(p_limit int default 500) returns setof public.notifications
language sql security definer set search_path = '' as $$
  update public.notifications n
     set locked_at = now(), attempts = n.attempts + 1
   where n.id in (select id from public.notifications
                   where sent_at is null and attempts < 5
                     and (locked_at is null or locked_at < now() - interval '2 min')
                   order by id
                   limit least(greatest(coalesce(p_limit, 500), 1), 1000)
                   for update skip locked)
  returning n.*
$$;

-- ═════════════════════════ 9. 감사·보호 트리거 ═════════════════════════
-- 현장 내용 변경(등록·수정·보관) 기록. 상태 변경은 RPC가 기록하므로 제외
create function private.audit_sites() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    insert into public.work_logs (actor_id, team_id, site_id, group_id, action, meta)
    values (auth.uid(), private.my_team(), new.id, new.group_id, 'site_create',
            jsonb_build_object('bunji', new.bunji, 'unit', new.unit));
  elsif new.archived and not old.archived then
    insert into public.work_logs (actor_id, team_id, site_id, group_id, action)
    values (auth.uid(), private.my_team(), new.id, new.group_id, 'site_archive');
  elsif (new.group_id, new.seq, new.label, new.bunji, new.jibun, new.road, new.unit, new.note, new.lat, new.lng)
        is distinct from
        (old.group_id, old.seq, old.label, old.bunji, old.jibun, old.road, old.unit, old.note, old.lat, old.lng) then
    insert into public.work_logs (actor_id, team_id, site_id, group_id, action, meta)
    values (auth.uid(), private.my_team(), new.id, new.group_id, 'site_update',
            jsonb_build_object('bunji', new.bunji, 'seq', new.seq));
  end if;
  return null;
end $$;
create trigger sites_audit after insert or update on public.sites
  for each row execute function private.audit_sites();

-- 점유 중인 현장은 보관 불가 / 배포된 묶음으로의 이동은 관리자만(= 주소 전달은 관리자 고정)
create function private.guard_sites() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.archived and not old.archived and old.status in ('en_route', 'working', 'paused') then
    raise exception 'SITE_OCCUPIED: cannot archive an occupied site' using errcode = 'P0001';
  end if;
  if new.group_id <> old.group_id and not private.is_admin()
     and exists (select 1 from public.site_groups g where g.id = new.group_id and g.published) then
    raise exception 'FORBIDDEN: only admin can move sites into a published group' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger sites_guard before update on public.sites
  for each row execute function private.guard_sites();

create function private.audit_attach() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.work_logs (actor_id, team_id, site_id, session_id, action, meta)
  values (new.created_by, private.my_team(), new.site_id, new.session_id, 'attach',
          jsonb_build_object('kind', new.kind, 'path', new.path));
  return null;
end $$;
create trigger attachments_audit after insert on public.attachments
  for each row execute function private.audit_attach();
