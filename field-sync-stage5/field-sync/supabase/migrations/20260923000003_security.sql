-- path: supabase/migrations/20260923000003_security.sql
-- 권한 최소화 + RLS.
-- Supabase는 public 신규 객체를 anon/authenticated에 자동 부여하므로 먼저 전부 회수한 뒤 필요한 것만 부여한다.
-- 정책의 헬퍼 호출은 (select private.x()) 로 감싸 쿼리당 1회만 평가(initPlan)되게 한다.

-- ───────── 1. 일괄 회수 ─────────
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public  from public, anon, authenticated;
revoke all on schema private from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;
alter default privileges in schema public  revoke execute on functions from public;
alter default privileges in schema private revoke execute on functions from public;

-- ───────── 2. 최소 부여 ─────────
grant usage on schema private to authenticated;                                -- 정책 헬퍼 4개만 실행 가능
grant execute on function private.is_active(), private.is_admin(), private.my_team(), private.can(text)
  to authenticated;
grant execute on all functions in schema public to authenticated;              -- public 함수 = RPC 전용(트리거는 private)
revoke execute on function public.claim_push_batch(int) from authenticated;     -- 서버(push 함수) 전용

grant select on public.teams, public.profiles, public.role_permissions, public.settings, public.check_templates,
                public.site_groups, public.sites, public.work_sessions, public.work_logs, public.attachments,
                public.urgent_requests, public.notifications, public.device_tokens
  to authenticated;
grant insert, update, delete on public.teams, public.check_templates to authenticated;          -- RLS로 제한
grant update (lang) on public.profiles to authenticated;
grant insert (name, work_date, team_id, template_id, kakao_folder_url) on public.site_groups to authenticated;
grant update (name, work_date, team_id, template_id, kakao_folder_url, archived) on public.site_groups to authenticated;
grant insert (group_id, seq, label, bunji, jibun, road, unit, note, lat, lng, b_code, jibun_key)
  on public.sites to authenticated;                                            -- 상태·점유 컬럼 제외
grant update (group_id, seq, label, bunji, jibun, road, unit, note, lat, lng, b_code, jibun_key, archived)
  on public.sites to authenticated;
grant insert (session_id, site_id, kind, path, taken_at, lat, lng) on public.attachments to authenticated;
grant update (read_at) on public.notifications to authenticated;
-- work_sessions · work_logs · urgent_requests · role_permissions · settings · device_tokens 쓰기 = RPC 전용

-- service_role(Edge Function 서버 키): Supabase 기본값과 동일하게 명시
grant usage on schema public to service_role;
grant all on all tables in schema public to service_role;
grant execute on all functions in schema public to service_role;

-- ───────── 3. RLS ─────────
alter table public.teams           enable row level security;
alter table public.profiles        enable row level security;
alter table public.role_permissions enable row level security;
alter table public.settings        enable row level security;
alter table public.check_templates enable row level security;
alter table public.site_groups     enable row level security;
alter table public.sites           enable row level security;
alter table public.work_sessions   enable row level security;
alter table public.work_logs       enable row level security;
alter table public.attachments     enable row level security;
alter table public.urgent_requests enable row level security;
alter table public.notifications   enable row level security;
alter table public.device_tokens   enable row level security;

-- 공통 참조 데이터: 활성 사용자 조회
create policy teams_read    on public.teams            for select to authenticated using ((select private.is_active()));
create policy perms_read    on public.role_permissions for select to authenticated using ((select private.is_active()));
create policy settings_read on public.settings         for select to authenticated using ((select private.is_active()));
create policy tpl_read      on public.check_templates  for select to authenticated using ((select private.is_active()));
create policy urgent_read   on public.urgent_requests  for select to authenticated using ((select private.is_active()));

create policy teams_write on public.teams for all to authenticated
  using ((select private.is_admin())) with check ((select private.is_admin()));
create policy tpl_write on public.check_templates for all to authenticated
  using ((select private.can('template.edit'))) with check ((select private.can('template.edit')));

-- 프로필: 활성 사용자는 전체 조회(점유자 이름 표시), 본인 행은 비활성이어도 조회(차단 안내용), 본인 언어만 수정
create policy profiles_read on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select private.is_active()));
create policy profiles_self_update on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- 동선(묶음): 배포분 + 한 번이라도 배포됐던 묶음(회수 이벤트를 Realtime으로 받기 위함). 편집 권한자는 초안 포함
create policy groups_read on public.site_groups for select to authenticated
  using ((select private.is_active())
         and (published_at is not null
              or (select private.can('site.create')) or (select private.can('site.edit'))));
create policy groups_insert on public.site_groups for insert to authenticated
  with check ((select private.can('site.create')));
-- 수정: site.edit + (관리자 또는 미배포 묶음). 배포된 동선의 팀·템플릿·보관 변경 = 전달 변경 → 관리자 고정
create policy groups_update on public.site_groups for update to authenticated
  using ((select private.can('site.edit')) and ((select private.is_admin()) or not published))
  with check ((select private.can('site.edit')) and ((select private.is_admin()) or not published));

-- 현장: 배포된 묶음의 현장(보관 포함 — 보관 이벤트 전달용, 앱에서 숨김). 편집 권한자는 전체
create policy sites_read on public.sites for select to authenticated
  using ((select private.is_active())
         and ((select private.can('site.create')) or (select private.can('site.edit'))
              or exists (select 1 from public.site_groups g where g.id = group_id and g.published and not g.archived)));
-- 등록: site.create + (관리자 또는 미배포 묶음) → 배포된 동선에 주소를 넣는 것 = 전달 = 관리자 고정
create policy sites_insert on public.sites for insert to authenticated
  with check ((select private.can('site.create'))
              and ((select private.is_admin())
                   or not exists (select 1 from public.site_groups g where g.id = group_id and g.published)));
create policy sites_update on public.sites for update to authenticated
  using ((select private.can('site.edit'))
         and ((select private.is_admin())
              or not exists (select 1 from public.site_groups g where g.id = group_id and g.published)))
  with check ((select private.can('site.edit'))
              and ((select private.is_admin())
                   or not exists (select 1 from public.site_groups g where g.id = group_id and g.published)));

-- 세션·로그: 본인 / 관리자 / 팀 조회 권한자(자기 팀)
create policy sessions_read on public.work_sessions for select to authenticated
  using (user_id = (select auth.uid()) or (select private.is_admin())
         or ((select private.can('log.view_team')) and team_id = (select private.my_team())));
create policy logs_read on public.work_logs for select to authenticated
  using (actor_id = (select auth.uid()) or (select private.is_admin())
         or ((select private.can('log.view_team')) and team_id = (select private.my_team())));

-- 증빙: 조회는 세션과 동일, 등록은 본인 작업중/일시중단 세션 + 경로가 세션 폴더일 때만
create policy attach_read on public.attachments for select to authenticated
  using (created_by = (select auth.uid()) or (select private.is_admin())
         or ((select private.can('log.view_team'))
             and exists (select 1 from public.work_sessions s
                         where s.id = session_id and s.team_id = (select private.my_team()))));
create policy attach_insert on public.attachments for insert to authenticated
  with check (created_by = (select auth.uid())
              and split_part(path, '/', 1) = session_id::text
              and exists (select 1 from public.work_sessions s
                          where s.id = session_id and s.site_id = attachments.site_id
                            and s.user_id = (select auth.uid()) and s.status in ('working', 'paused')));

-- 알림·기기: 본인만
create policy notif_read on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));
create policy notif_mark_read on public.notifications for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy device_read on public.device_tokens for select to authenticated
  using (user_id = (select auth.uid()));
