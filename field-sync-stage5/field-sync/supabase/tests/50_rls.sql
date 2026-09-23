-- path: supabase/tests/50_rls.sql
-- 행 수준 보안(RLS)·권한 부여 검증
\o /dev/null

-- R0: Supabase 자동 부여 회수 확인 + SECURITY DEFINER 함수 search_path 고정 확인
select test.eq((select count(*) from information_schema.role_table_grants
                 where grantee = 'anon' and table_schema = 'public'), 0::bigint, 'R0 anon 테이블 권한 0');
select test.eq((select count(*) from information_schema.role_routine_grants
                 where grantee in ('anon', 'PUBLIC') and routine_schema in ('public', 'private')), 0::bigint, 'R0 anon/PUBLIC 함수 실행권 0');
select test.eq((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                 where n.nspname in ('public', 'private') and p.prosecdef
                   and not coalesce(p.proconfig @> array['search_path=""'], false)), 0::bigint, 'R0 모든 DEFINER 함수 search_path 고정');
select test.eq((select count(*) from pg_tables where schemaname = 'public' and not rowsecurity), 0::bigint, 'R0 public 전 테이블 RLS 활성');

-- R1: 현장 조회 범위
begin;
select test.login(test.id('W1'));
select test.eq((select count(*) from public.sites), 6::bigint, 'R1 작업자: 배포 묶음 현장 6곳만');
select test.eq((select count(*) from public.sites where id = test.id('S7')), 0::bigint, 'R1 작업자: 미배포 현장 비노출');
select test.login(test.id('L1'));
select test.eq((select count(*) from public.sites), 7::bigint, 'R1 편집권자(팀장): 초안 포함 7곳');
select test.login(test.id('W4'));
select test.eq((select count(*) from public.sites), 0::bigint, 'R1 비활성 사용자: 0곳');
select test.eq((select count(*) from public.profiles), 1::bigint, 'R1 비활성 사용자: 본인 프로필만');
rollback;

-- R2: 로그 조회 범위 (본인 / 팀장=자기 팀 / 관리자=전체)
begin;
select test.login(test.id('W1')); select public.claim_site(test.id('S1'), test.op());
select test.login(test.id('W2')); select public.claim_site(test.id('S2'), test.op());
select test.login(test.id('W3')); select public.claim_site(test.id('S6'), test.op());
select test.login(test.id('W1'));
select test.eq((select count(*) from public.work_logs where actor_id is distinct from test.id('W1')), 0::bigint, 'R2 작업자: 본인 로그만');
select test.login(test.id('L1'));
select test.eq((select count(*) from public.work_logs where actor_id in (test.id('W1'), test.id('W2'))), 2::bigint, 'R2 팀장: 팀원 로그 조회');
select test.eq((select count(*) from public.work_logs where actor_id = test.id('W3')), 0::bigint, 'R2 팀장: 타 팀 로그 비노출');
select test.login(test.id('A'));
select test.eq((select count(*) from public.work_logs where action = 'claim'), 3::bigint, 'R2 관리자: 전체 로그');
-- 팀 로그 권한 회수 → 팀장도 본인 것만
select public.set_role_permission('leader', 'log.view_team', false, test.op());
select test.login(test.id('L1'));
select test.eq((select count(*) from public.work_logs where actor_id in (test.id('W1'), test.id('W2'))), 0::bigint, 'R2 권한 회수 즉시 비노출');
rollback;

-- R3: 세션 상세 조회 범위
begin;
select test.login(test.id('W1')); select public.claim_site(test.id('S1'), test.op());
select test.login(test.id('W2'));
select test.eq((select count(*) from public.work_sessions), 0::bigint, 'R3 작업자: 타인 세션 비노출');
select test.eq((select occupant_name from public.sites where id = test.id('S1')), '김철수', 'R3 단, 현장 점유자 이름은 전원 조회(중복 방지)');
select test.login(test.id('L1'));
select test.eq((select count(*) from public.work_sessions), 1::bigint, 'R3 팀장: 팀원 세션 조회');
select test.login(test.id('L2'));
select test.eq((select count(*) from public.work_sessions), 0::bigint, 'R3 타 팀 팀장: 비노출');
rollback;

-- R4: 알림은 본인 것만, 읽음 표시만 수정 가능
begin;
select test.login(test.id('L1'));
select public.send_urgent('테스트', test.op());
select test.login(test.id('W1'));
select test.eq((select count(*) from public.notifications), 1::bigint, 'R4 본인 알림만 조회');
update public.notifications set read_at = now();
select test.eq((select count(*) from public.notifications where read_at is not null), 1::bigint, 'R4 읽음 표시 가능');
select test.raises($$update public.notifications set body = 'x'$$, 'R4 본문 수정 불가', '42501');
reset role;
select test.eq((select count(*) from public.notifications where read_at is not null), 1::bigint, 'R4 타인 알림은 영향 없음');
rollback;

-- R5: 동선(묶음) 조회 — 초안 비노출, 회수된 묶음은 published=false로 노출(Realtime 회수 이벤트 전달)
begin;
select test.login(test.id('W1'));
select test.eq((select count(*) from public.site_groups), 2::bigint, 'R5 배포 묶음 2개만');
select test.login(test.id('A'));
select public.publish_group(test.id('G3'), true, test.op());
select public.publish_group(test.id('G3'), false, test.op());
select test.login(test.id('W1'));
select test.eq((select published from public.site_groups where id = test.id('G3')), false, 'R5 회수된 묶음은 published=false로 보임');
select test.eq((select count(*) from public.sites where group_id = test.id('G3')), 0::bigint, 'R5 회수된 묶음의 현장은 비노출');
rollback;

-- R6: 프로필 — 본인 언어만 수정, 등급 자가 변경 불가
begin;
select test.login(test.id('W1'));
update public.profiles set lang = 'en' where id = auth.uid();
select test.eq((select lang from public.profiles where id = test.id('W1')), 'en', 'R6 본인 언어 변경');
update public.profiles set lang = 'en' where id = test.id('W2');
select test.eq((select lang from public.profiles where id = test.id('W2')), 'vi', 'R6 타인 프로필 수정 무효(RLS)');
select test.raises($$update public.profiles set role = 'admin' where id = auth.uid()$$, 'R6 등급 자가 변경 불가', '42501');
rollback;

-- R7: 팀·템플릿 쓰기 권한
begin;
select test.login(test.id('L1'));
select test.raises($$insert into public.teams (name) values ('3팀')$$, 'R7 팀장 팀 생성 불가', '42501');
select test.raises($$insert into public.check_templates (name) values ('t')$$, 'R7 template.edit 없으면 템플릿 생성 불가', '42501');
select test.login(test.id('A'));
insert into public.teams (name) values ('3팀');
select test.ok(true, 'R7 관리자 팀 생성 가능');
rollback;

-- R8: 자가 가입 방어 — Auth 가입 API 형태(app_metadata에 provider만)는 비활성, 관리자 발급 형태(role 포함)는 활성
begin;
insert into auth.users (id, email, raw_app_meta_data) values
  ('00000000-0000-0000-0000-00000000fe01', 'self@staff.fieldsync.local', '{"provider":"email","providers":["email"]}'),
  ('00000000-0000-0000-0000-00000000fe02', 'issued@staff.fieldsync.local', '{"provider":"email","providers":["email"],"role":"worker"}');
select test.eq((select active from public.profiles where id = '00000000-0000-0000-0000-00000000fe01'), false, 'R8 자가 가입 계정은 비활성 생성');
select test.eq((select active from public.profiles where id = '00000000-0000-0000-0000-00000000fe02'), true, 'R8 관리자 발급 계정은 활성 생성');
select test.login('00000000-0000-0000-0000-00000000fe01');
select test.eq((select count(*) from public.sites), 0::bigint, 'R8 자가 가입 계정은 현장 조회 불가');
rollback;

-- R9: 배포된 동선·현장 수정은 관리자만(팀장 site.edit은 초안에서만) — 배포 후 팀·템플릿·보관·주소 변경 = 전달 변경
begin;
select test.login(test.id('L1'));
update public.site_groups set name = '팀장수정' where id = test.id('G1');
update public.site_groups set name = '초안수정' where id = test.id('G3');
update public.sites set note = '팀장메모' where id = test.id('S2');
update public.sites set note = '초안메모' where id = test.id('S7');
reset role;
select test.eq((select name from public.site_groups where id = test.id('G1')), '9/23 성수 1구역', 'R9 팀장은 배포된 동선 수정 불가');
select test.eq((select name from public.site_groups where id = test.id('G3')), '초안수정', 'R9 팀장은 초안 동선 수정 가능');
select test.eq((select note from public.sites where id = test.id('S2')), null, 'R9 팀장은 배포된 동선의 현장 수정 불가');
select test.eq((select note from public.sites where id = test.id('S7')), '초안메모', 'R9 팀장은 초안 동선의 현장 수정 가능');
select test.login(test.id('A'));
update public.site_groups set name = '관리자수정' where id = test.id('G1');
reset role;
select test.eq((select name from public.site_groups where id = test.id('G1')), '관리자수정', 'R9 관리자는 배포된 동선 수정 가능');
rollback;
