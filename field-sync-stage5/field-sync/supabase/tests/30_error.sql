-- path: supabase/tests/30_error.sql
-- 오류·거절 경로 (error cases)
\o /dev/null

-- X1: 타인 점유 현장 → SITE_OCCUPIED + 점유자 정보 + 거절 로그(ok=false)
begin;
select test.login(test.id('W1'));
select public.start_work(test.id('S1'), test.op());
select test.login(test.id('W2'));
select test.eq(test.code(public.claim_site(test.id('S1'), test.op())), 'SITE_OCCUPIED', 'X1 맡기 → SITE_OCCUPIED');
select test.eq(public.start_work(test.id('S1'), test.op()) -> 'occupant' ->> 'name', '김철수', 'X1 점유자 이름 반환');
select test.eq((select count(*) from public.work_logs where actor_id = test.id('W2') and not ok
                  and meta -> 'result' ->> 'code' = 'SITE_OCCUPIED'), 2::bigint, 'X1 거절 시도 2건 로그');
select test.eq(public.claim_site(test.id('S1'), test.op()) -> 'session', 'null'::jsonb, 'X1 타인 세션 비노출');
rollback;

-- X2: 점유자가 아닌 사용자의 조작 → NOT_OWNER
begin;
select test.login(test.id('W1'));
select public.start_work(test.id('S1'), test.op());
select test.login(test.id('W2'));
select test.eq(test.code(public.pause_work(test.id('S1'), test.op(), 'absent')), 'NOT_OWNER', 'X2 타인 일시중단 → NOT_OWNER');
select test.eq(test.code(public.complete_work(test.id('S1'), test.op(), test.good())), 'NOT_OWNER', 'X2 타인 완료 → NOT_OWNER');
select test.eq(test.code(public.release_site(test.id('S1'), test.op(), 'x')), 'NOT_OWNER', 'X2 타인 반납 → NOT_OWNER');
select test.eq(test.code(public.save_checks(test.id('S1'), test.op(), '{}')), 'NOT_OWNER', 'X2 타인 체크 저장 → NOT_OWNER');
rollback;

-- X3: 필수 체크 누락 → CHECKS_INCOMPLETE + 누락 목록
begin;
select test.login(test.id('W1'));
select public.start_work(test.id('S2'), test.op());
select test.eq(public.complete_work(test.id('S2'), test.op(), '{}') -> 'missing',
               '["w_meter","w_leak","s_hole","s_back"]'::jsonb, 'X3 누락 항목 4개 반환');
select test.eq((select meta -> 'checks' from public.work_logs where actor_id = test.id('W1') and action = 'complete' and not ok),
               '{}'::jsonb, 'X3 거절돼도 입력값 로그 보존');
rollback;

-- X4: 강제 해제 권한·팀 범위
begin;
select test.login(test.id('W1'));
select public.start_work(test.id('S1'), test.op());
select test.login(test.id('W2'));
select test.eq(test.code(public.force_release(test.id('S1'), test.op(), 'x')), 'FORBIDDEN', 'X4 작업자 강제 해제 → FORBIDDEN');
select test.login(test.id('L2'));
select test.eq(test.code(public.force_release(test.id('S1'), test.op(), 'x')), 'FORBIDDEN', 'X4 타 팀 팀장 → FORBIDDEN');
select test.login(test.id('A'));
select test.eq(test.code(public.force_release(test.id('S1'), test.op(), '')), 'INVALID_INPUT', 'X4 사유 없음 → INVALID_INPUT');
select test.eq(test.code(public.force_release(test.id('S1'), test.op(), '관리자 해제')), 'OK', 'X4 관리자는 팀 무관 허용');
rollback;
begin;
select test.login(test.id('A'));
select public.set_role_permission('leader', 'work.force_release', false, test.op());
select test.login(test.id('W1'));
select public.claim_site(test.id('S1'), test.op());
select test.login(test.id('L1'));
select test.eq(test.code(public.force_release(test.id('S1'), test.op(), 'x')), 'FORBIDDEN', 'X4 권한 회수 즉시 반영');
rollback;

-- X5: 배포는 관리자 고정 (팀장·작업자 거부, 위임 불가)
begin;
select test.login(test.id('L1'));
select test.eq(test.code(public.publish_group(test.id('G3'), true, test.op())), 'FORBIDDEN', 'X5 팀장 배포 → FORBIDDEN');
select test.login(test.id('W1'));
select test.eq(test.code(public.publish_group(test.id('G3'), true, test.op())), 'FORBIDDEN', 'X5 작업자 배포 → FORBIDDEN');
select test.login(test.id('A'));
select test.eq(test.code(public.set_role_permission('leader', 'site.publish', true, test.op())), 'INVALID_INPUT', 'X5 배포 권한 위임 시도 → INVALID_INPUT');
select test.eq(test.code(public.set_role_permission('admin', 'site.edit', true, test.op())), 'INVALID_INPUT', 'X5 관리자 등급 대상 → INVALID_INPUT');
reset role;
select test.raises($$insert into public.role_permissions values ('leader', 'site.publish')$$, 'X5 DB 제약으로도 위임 불가 권한 차단', '23514');
rollback;

-- X6: 미배포 묶음 현장
begin;
select test.login(test.id('W1'));
select test.eq(test.code(public.claim_site(test.id('S7'), test.op())), 'NOT_PUBLISHED', 'X6 미배포 → NOT_PUBLISHED');
rollback;

-- X7: 비활성 사용자
begin;
select test.login(test.id('W4'));
select test.eq(test.code(public.claim_site(test.id('S1'), test.op())), 'FORBIDDEN', 'X7 비활성 → FORBIDDEN');
select test.raises($$select public.register_device('tok-1234567890', 'ios')$$, 'X7 비활성 기기 등록 거부', '42501');
rollback;

-- X8: 상태 컬럼 직접 수정·세션 직접 생성 차단 (RPC 우회 불가)
begin;
select test.login(test.id('L1'));
select test.raises($$update public.sites set status = 'done' where id = test.id('S1')$$, 'X8 편집권자도 status 직접 수정 불가', '42501');
select test.raises($$update public.sites set occupant_id = auth.uid() where id = test.id('S1')$$, 'X8 occupant 직접 수정 불가', '42501');
select test.raises($$insert into public.work_sessions (site_id, user_id, status) values (test.id('S1'), auth.uid(), 'working')$$, 'X8 세션 직접 생성 불가', '42501');
select test.raises($$insert into public.work_logs (action) values ('claim')$$, 'X8 로그 직접 기록 불가', '42501');
select test.raises($$update public.settings set remind_max = 1$$, 'X8 정책 직접 수정 불가', '42501');
rollback;

-- X9: 감사 로그 불변 (관리자·DB 소유자도 수정·삭제 불가)
begin;
select test.login(test.id('W1'));
select public.claim_site(test.id('S1'), test.op());
reset role;
select test.raises($$update public.work_logs set action = 'start'$$, 'X9 로그 UPDATE 차단', '42501');
select test.raises($$delete from public.work_logs$$, 'X9 로그 DELETE 차단', '42501');
select test.raises($$truncate public.work_logs cascade$$, 'X9 로그 TRUNCATE 차단', '42501');
rollback;

-- X10: 마지막 관리자 보호
begin;
select test.login(test.id('A'));
select test.eq(test.code(public.set_user_role(test.id('A'), 'worker', test.op())), 'LAST_ADMIN', 'X10 마지막 관리자 강등 → LAST_ADMIN');
select test.eq(test.code(public.set_user_active(test.id('A'), false, test.op())), 'LAST_ADMIN', 'X10 마지막 관리자 비활성 → LAST_ADMIN');
rollback;

-- X11: 허용되지 않은 전이
begin;
select test.login(test.id('W1'));
select public.claim_site(test.id('S1'), test.op());
select test.eq(test.code(public.complete_work(test.id('S1'), test.op(), test.good())), 'INVALID_TRANSITION', 'X11 진행중에서 완료 → INVALID_TRANSITION');
select test.eq(test.code(public.resume_work(test.id('S1'), test.op())), 'INVALID_TRANSITION', 'X11 진행중에서 재개 → INVALID_TRANSITION');
select test.eq(test.code(public.claim_site(test.id('S1'), test.op())), 'INVALID_TRANSITION', 'X11 내 현장 재맡기 → INVALID_TRANSITION');
select test.eq(test.code(public.undo_complete(test.id('S1'), test.op())), 'INVALID_TRANSITION', 'X11 미완료 현장 완료취소 → INVALID_TRANSITION');
rollback;

-- X12: 입력 오류(HTTP 400 대상) — op_id 누락, 다른 사용자의 op_id 재사용
begin;
select test.login(test.id('W1'));
select test.raises($$select public.claim_site(test.id('S1'), null)$$, 'X12 op_id 누락 → 22023', '22023');
select public.claim_site(test.id('S1'), '22222222-2222-2222-2222-222222222222');
select test.login(test.id('W2'));
select test.raises($$select public.claim_site(test.id('S2'), '22222222-2222-2222-2222-222222222222')$$, 'X12 타인 op_id 재사용 → 22023', '22023');
rollback;

-- X13: 비로그인(anon) 차단
begin;
set local role anon;
select test.raises($$select public.claim_site(test.id('S1'), gen_random_uuid())$$, 'X13 anon RPC 실행 불가', '42501');
select test.raises($$select * from public.sites$$, 'X13 anon 테이블 조회 불가', '42501');
rollback;

-- X14: 현장 등록 권한 — 배포된 동선에 추가는 관리자만(= 주소 전달 관리자 고정)
begin;
select test.login(test.id('L1'));
select test.raises($$insert into public.sites (group_id, bunji, jibun, lat, lng) values (test.id('G1'), '새 번지 1', '서울 새 번지 1', 37.5, 127.0)$$,
                   'X14 팀장이 배포된 묶음에 추가 → RLS 거부', '42501');
insert into public.sites (group_id, bunji, jibun, lat, lng) values (test.id('G3'), '새 번지 2', '서울 새 번지 2', 37.5, 127.0);
select test.ok(true, 'X14 팀장은 미배포 묶음에 등록 가능');
select test.raises($$update public.sites set group_id = test.id('G1') where bunji = '새 번지 2'$$, 'X14 팀장이 배포 묶음으로 이동 → 거부', '42501');
select test.login(test.id('W1'));
select test.raises($$insert into public.sites (group_id, bunji, jibun, lat, lng) values (test.id('G3'), '새 번지 3', '서울 새 번지 3', 37.5, 127.0)$$,
                   'X14 작업자 등록 → RLS 거부', '42501');
select test.raises($$insert into public.sites (group_id, bunji, jibun, lat, lng) values (test.id('G3'), '범위 밖', '해외', 10, 10)$$,
                   'X14 좌표 범위 밖 거부', '42501');
rollback;
begin;
select test.login(test.id('A'));
select test.raises($$insert into public.sites (group_id, bunji, jibun, lat, lng) values (test.id('G3'), '범위 밖', '해외', 10, 10)$$,
                   'X14 대한민국 좌표 범위 밖 → CHECK 위반', '23514');
rollback;

-- X15: 점유 중 현장 보관 불가, 활성 점유 있는 묶음 회수 불가
begin;
select test.login(test.id('W1'));
select public.claim_site(test.id('S1'), test.op());
select test.login(test.id('A'));
select test.raises($$update public.sites set archived = true where id = test.id('S1')$$, 'X15 점유 중 현장 보관 차단', 'P0001');
select test.eq(test.code(public.publish_group(test.id('G1'), false, test.op())), 'HAS_ACTIVE_CLAIMS', 'X15 활성 점유 묶음 회수 → HAS_ACTIVE_CLAIMS');
select test.eq(test.code(public.set_user_active(test.id('W1'), false, test.op())), 'HAS_ACTIVE_CLAIMS', 'X15 점유 중 사용자 비활성 → HAS_ACTIVE_CLAIMS');
rollback;

-- X16: 정책 입력 검증
begin;
select test.login(test.id('A'));
select test.eq(test.code(public.update_settings('{"remind_max": 0}', test.op())), 'INVALID_INPUT', 'X16 범위 밖 값 → INVALID_INPUT');
select test.eq(test.code(public.update_settings('{"unknown_key": 1}', test.op())), 'INVALID_INPUT', 'X16 알 수 없는 키 → INVALID_INPUT');
select test.eq(test.code(public.update_settings('{"remind_max": "abc"}', test.op())), 'INVALID_INPUT', 'X16 숫자 아님 → INVALID_INPUT');
select test.eq(test.code(public.update_settings('[1]', test.op())), 'INVALID_INPUT', 'X16 객체 아님 → INVALID_INPUT');
select test.login(test.id('L1'));
select test.eq(test.code(public.update_settings('{"remind_max": 5}', test.op())), 'FORBIDDEN', 'X16 팀장 정책 변경 → FORBIDDEN');
rollback;

-- X17: 증빙 위조 차단 — 타인 세션·다른 경로로 첨부 불가
begin;
select test.login(test.id('W1'));
select public.start_work(test.id('S1'), test.op());
select test.login(test.id('W2'));
select test.raises($$select test.photo(test.id('S1'))$$, 'X17 타인 세션에 사진 첨부 → RLS 거부', '42501');
select test.login(test.id('W1'));
select test.raises($$insert into public.attachments (session_id, site_id, kind, path)
                     select session_id, id, 'photo', gen_random_uuid() || '/x.jpg' from public.sites where id = test.id('S1')$$,
                   'X17 세션 폴더가 아닌 경로 → RLS 거부', '42501');
rollback;
