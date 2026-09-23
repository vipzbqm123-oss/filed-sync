-- path: supabase/tests/10_happy.sql
-- 정상 흐름 (happy path). 각 블록은 트랜잭션 후 롤백 → 픽스처 불변.
\o /dev/null

-- H1~H6: 맡기 → 시작 → 중단 → 재개 → (증빙 누락 거절) → 사진 → 완료 → 완료취소 → 재완료
begin;
select test.login(test.id('W1'));
select test.eq(test.code(public.claim_site(test.id('S1'), test.op())), 'OK', 'H1 맡기 성공');
select test.eq((select status::text from public.sites where id = test.id('S1')), 'en_route', 'H1 현장=진행중');
select test.eq((select occupant_name || '/' || occupant_team from public.sites where id = test.id('S1')), '김철수/1팀', 'H1 점유자 비정규화');
select test.ok((select next_remind_at between now() + interval '44 min' and now() + interval '46 min'
                  from public.work_sessions where site_id = test.id('S1') and status = 'en_route'), 'H1 리마인더 +45분');
select test.eq(test.code(public.start_work(test.id('S1'), test.op())), 'OK', 'H2 작업 시작');
select test.ok((select status = 'working' and started_at is not null from public.sites where id = test.id('S1')), 'H2 현장=작업중·시작시각');
select test.ok((select next_remind_at between now() + interval '89 min' and now() + interval '91 min' and remind_count = 0
                  from public.work_sessions where site_id = test.id('S1') and status = 'working'), 'H2 리마인더 +90분');
select test.eq(test.code(public.pause_work(test.id('S1'), test.op(), 'absent', '주민 부재')), 'OK', 'H3 일시중단');
select test.eq((select pause_reason from public.work_sessions where site_id = test.id('S1') and status = 'paused'), 'absent: 주민 부재', 'H3 중단 사유 저장');
select test.eq(test.code(public.resume_work(test.id('S1'), test.op())), 'OK', 'H3 재개');
select test.eq(public.complete_work(test.id('S1'), test.op(), test.good()) -> 'missing', '["photo"]'::jsonb, 'H4 사진 없으면 PROOF_REQUIRED(photo)');
select test.photo(test.id('S1'));
select test.eq(test.code(public.complete_work(test.id('S1'), test.op(), test.good(), '완료')), 'OK', 'H4 작업완료');
select test.ok((select status = 'done' and completed_at is not null and next_remind_at is null and note = '완료'
                  from public.work_sessions where site_id = test.id('S1') and status = 'done'), 'H4 세션 완료·리마인더 해제');
select test.eq((select status::text from public.sites where id = test.id('S1')), 'done', 'H4 현장=작업완료');
select test.eq(test.code(public.undo_complete(test.id('S1'), test.op())), 'OK', 'H5 5분 내 완료 취소');
select test.eq((select status::text from public.sites where id = test.id('S1')), 'working', 'H5 현장=작업중 복귀');
select test.eq(test.code(public.complete_work(test.id('S1'), test.op(), '{}')), 'OK', 'H5 재완료(저장된 체크 재사용)');
select test.eq((select array_agg(action || ':' || ok order by id) from public.work_logs
                 where site_id = test.id('S1') and actor_id = test.id('W1')),
               array['claim:true', 'start:true', 'pause:true', 'resume:true', 'complete:false', 'attach:true',
                     'complete:true', 'undo_complete:true', 'complete:true'], 'H6 감사 로그 순서·성공여부');
rollback;

-- H7: 바로 작업 시작(대기 → 작업중) 후 반납
begin;
select test.login(test.id('W2'));
select test.eq(test.code(public.start_work(test.id('S2'), test.op())), 'OK', 'H7 대기→작업중 바로 시작');
select test.eq(test.code(public.release_site(test.id('S2'), test.op(), '자재 부족')), 'OK', 'H7 반납');
select test.ok((select status = 'pending' and occupant_id is null and session_id is null from public.sites where id = test.id('S2')), 'H7 현장=대기중·점유 해제');
select test.ok((select status = 'released' and release_reason = '자재 부족' from public.work_sessions where site_id = test.id('S2')), 'H7 세션=released');
rollback;

-- H8: 팀장 강제 해제 + 대상자 알림(수신자 언어 vi)
begin;
select test.login(test.id('W2'));
select public.claim_site(test.id('S3'), test.op());
select test.login(test.id('L1'));
select test.eq(test.code(public.force_release(test.id('S3'), test.op(), '퇴근')), 'OK', 'H8 팀장 강제 해제');
select test.login(test.id('W2'));
select test.eq((select body from public.notifications where user_id = test.id('W2') and kind = 'force_release'),
               '성수동1가 690-1 — 팀장1 đã giải phóng (lý do: 퇴근)', 'H8 해제 알림(베트남어)');
rollback;

-- H9: 재오픈 → 이전 완료자에게 알림
begin;
select test.login(test.id('W1'));
select public.start_work(test.id('S4'), test.op());
select test.photo(test.id('S4'));
select public.complete_work(test.id('S4'), test.op(), test.good());
select test.login(test.id('L1'));
select test.eq(test.code(public.reopen_site(test.id('S4'), test.op(), '하자')), 'OK', 'H9 재오픈');
select test.eq((select status::text from public.sites where id = test.id('S4')), 'pending', 'H9 현장=대기중');
select test.login(test.id('W1'));
select test.eq((select count(*) from public.notifications where kind = 'reopen'), 1::bigint, 'H9 완료자에게 재오픈 알림');
rollback;

-- H10: 멱등 재전송 (같은 op_id 2회 → 1회만 적용)
begin;
select test.login(test.id('W1'));
select test.eq(public.claim_site(test.id('S5'), '11111111-1111-1111-1111-111111111111') ->> 'replayed', 'false', 'H10 최초 요청');
select test.eq(public.claim_site(test.id('S5'), '11111111-1111-1111-1111-111111111111') ->> 'replayed', 'true', 'H10 재전송=replayed');
select test.eq((select count(*) from public.work_sessions where site_id = test.id('S5')), 1::bigint, 'H10 세션 1건만 생성');
rollback;

-- H11: 관리자 — 배포·권한 부여·정책 변경·등급 변경
begin;
select test.login(test.id('A'));
select test.eq(public.publish_group(test.id('G3'), true, test.op()) ->> 'site_count', '1', 'H11 배포(현장 1곳)');
reset role;
select test.eq((select count(*) from public.notifications where kind = 'publish'), 6::bigint, 'H11 배포 알림: 활성 사용자 6명(본인·비활성 제외)');
select test.login(test.id('A'));
select test.eq(test.code(public.set_role_permission('worker', 'urgent.send', true, test.op())), 'OK', 'H11 작업자에 긴급발송 권한 부여');
select test.eq(test.code(public.update_settings('{"max_claims_per_user": 5, "remind_working_first_min": "60"}', test.op())), 'OK', 'H11 정책 변경(문자열 숫자 허용)');
select test.eq((select max_claims_per_user * 100 + remind_working_first_min from public.settings), 560, 'H11 정책 반영');
select test.eq(test.code(public.set_user_role(test.id('W2'), 'leader', test.op(), test.id('T1'))), 'OK', 'H11 등급 변경');
select test.login(test.id('W1'));
select test.eq(test.code(public.send_urgent('위임 테스트', test.op())), 'OK', 'H11 위임받은 작업자 긴급 발송');
rollback;

-- H12: 긴급 요청 → 전원 알림 + 현장 표시 → 해제
begin;
select test.login(test.id('L1'));
select test.ok((public.send_urgent('누수 긴급', test.op(), test.id('S5')) -> 'site' ->> 'urgent')::boolean, 'H12 긴급 발송·현장 표시');
reset role;
select test.eq((select count(*) from public.notifications where kind = 'urgent'), 6::bigint, 'H12 활성 사용자 6명에게 알림(발신자 제외)');
select test.login(test.id('L1'));
select test.eq(test.code(public.resolve_urgent((select id from public.urgent_requests limit 1), test.op())), 'OK', 'H12 긴급 해제');
select test.eq((select urgent from public.sites where id = test.id('S5')), false, 'H12 현장 긴급 표시 해제');
rollback;

-- H13: 기기 토큰 등록(upsert) + 계정 전환 시 재할당
begin;
select test.login(test.id('W1'));
select test.eq(test.code(public.register_device('fcm-token-abcdef', 'android')), 'OK', 'H13 토큰 등록');
select test.login(test.id('W2'));
select test.eq(test.code(public.register_device('fcm-token-abcdef', 'android')), 'OK', 'H13 같은 기기 다른 계정');
reset role;
select test.eq((select user_id from public.device_tokens where token = 'fcm-token-abcdef'), test.id('W2'), 'H13 토큰 재할당');
rollback;

-- H14: 신규 사용자 트리거 → profiles 자동 생성(등급은 app_metadata만 신뢰)
select test.eq((select role::text || '/' || name || '/' || login_id from public.profiles where id = test.id('L1')), 'leader/팀장1/lead1', 'H14 프로필 자동 생성');
begin;
insert into auth.users (email, raw_user_meta_data) values ('hacker@staff.fieldsync.local', '{"name":"h","role":"admin"}');
select test.eq((select role::text from public.profiles where login_id = 'hacker'), 'worker', 'H14 user_metadata의 role 무시(권한 상승 차단)');
rollback;
