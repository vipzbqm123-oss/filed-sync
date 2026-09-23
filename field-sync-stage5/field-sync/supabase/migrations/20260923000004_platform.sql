-- path: supabase/migrations/20260923000004_platform.sql
-- Supabase 플랫폼 연동: Realtime 발행 · Storage 버킷/정책 · pg_cron 작업.
-- 확장이 없는 환경(로컬 테스트)에서도 실패하지 않도록 존재 여부를 확인한다.

-- ───────── Realtime: 변경을 구독자에게 전달할 테이블 ─────────
do $$
declare t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['sites', 'site_groups', 'urgent_requests', 'notifications'] loop
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- ───────── Storage: 증빙 사진·서명 (비공개, 5MB, JPEG/PNG) ─────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('evidence', 'evidence', false, 5242880, array['image/jpeg', 'image/png'])
on conflict (id) do nothing;

-- 객체명 = {session_id}/{파일}. 업로드: 본인 작업중/일시중단 세션, 조회: 본인·관리자·팀 조회 권한자
create policy evidence_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'evidence' and exists (
    select 1 from public.work_sessions s
     where s.id::text = (storage.foldername(name))[1]
       and s.user_id = (select auth.uid()) and s.status in ('working', 'paused')));
create policy evidence_read on storage.objects for select to authenticated
  using (bucket_id = 'evidence' and exists (
    select 1 from public.work_sessions s
     where s.id::text = (storage.foldername(name))[1]
       and (s.user_id = (select auth.uid()) or (select private.is_admin())
            or ((select private.can('log.view_team')) and s.team_id = (select private.my_team())))));

-- ───────── pg_cron: 리마인더(1분) · 푸시 재시도(5분) ─────────
-- 푸시 호출에는 Vault 비밀 'project_url', 'cron_secret' 필요(RUNBOOK 참고). 없으면 kick_push()는 무동작.
do $$
begin
  -- 이미 활성화(스키마 존재)됐거나 설치 불가한 환경이면 건너뜀
  if not exists (select 1 from pg_namespace where nspname = 'cron')
     and exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension pg_cron;
  end if;
  if not exists (select 1 from pg_namespace where nspname = 'net')
     and exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension pg_net;
  end if;
end $$;

select cron.schedule('fieldsync-reminders', '* * * * *', 'select private.run_reminders()');
select cron.schedule('fieldsync-push-retry', '*/5 * * * *', 'select private.kick_push()');
