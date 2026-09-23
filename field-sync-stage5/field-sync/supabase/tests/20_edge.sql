-- path: supabase/tests/20_edge.sql
-- 경계 조건 (edge cases)
\o /dev/null

-- E1: 1인 점유 한도(기본 3) → 4번째 CLAIM_LIMIT
begin;
select test.login(test.id('W1'));
select public.claim_site(test.id('S1'), test.op()), public.claim_site(test.id('S2'), test.op()), public.claim_site(test.id('S3'), test.op());
select test.eq(test.code(public.claim_site(test.id('S4'), test.op())), 'CLAIM_LIMIT', 'E1 점유 3곳 초과 → CLAIM_LIMIT');
select test.eq(test.code(public.release_site(test.id('S3'), test.op(), '변경')), 'OK', 'E1 하나 반납');
select test.eq(test.code(public.claim_site(test.id('S4'), test.op())), 'OK', 'E1 반납 후 다시 점유 가능');
rollback;

-- E2: 작업중은 1곳만 (진행중 추가 점유는 허용)
begin;
select test.login(test.id('W1'));
select public.start_work(test.id('S1'), test.op());
select test.eq(test.code(public.start_work(test.id('S2'), test.op())), 'ALREADY_WORKING', 'E2 두 번째 바로 시작 → ALREADY_WORKING');
select test.eq(test.code(public.claim_site(test.id('S2'), test.op())), 'OK', 'E2 진행중 점유는 허용');
select test.eq(test.code(public.start_work(test.id('S2'), test.op())), 'ALREADY_WORKING', 'E2 진행중→작업중도 차단');
select public.pause_work(test.id('S1'), test.op(), 'material');
select test.eq(test.code(public.start_work(test.id('S2'), test.op())), 'OK', 'E2 첫 현장 중단 후 시작 가능');
select test.eq(test.code(public.resume_work(test.id('S1'), test.op())), 'ALREADY_WORKING', 'E2 재개도 1곳 규칙 적용');
rollback;

-- E3: 완료 취소 시간 경계 (정확히 5분 = 허용, 5분 1초 = 만료)
begin;
select test.login(test.id('W1'));
select public.start_work(test.id('S1'), test.op());
select test.photo(test.id('S1'));
select public.complete_work(test.id('S1'), test.op(), test.good());
reset role;
update public.work_sessions set completed_at = now() - interval '5 min' where site_id = test.id('S1');
select test.login(test.id('W1'));
select test.eq(test.code(public.undo_complete(test.id('S1'), test.op())), 'OK', 'E3 정확히 5분 → 취소 허용');
select public.complete_work(test.id('S1'), test.op(), '{}');
reset role;
update public.work_sessions set completed_at = now() - interval '5 min 1 sec' where site_id = test.id('S1');
select test.login(test.id('W1'));
select test.eq(test.code(public.undo_complete(test.id('S1'), test.op())), 'UNDO_EXPIRED', 'E3 5분 1초 → UNDO_EXPIRED');
rollback;

-- E4: 등록 단계 중복 — 같은 지번+세부 활성 중복 금지, 세부가 다르면 허용, 완료 후 재등록 허용
begin;
select test.login(test.id('A'));
select test.raises($$insert into public.sites (group_id, bunji, jibun, lat, lng, jibun_key)
                     values (test.id('G3'), '성수동1가 685-12', '서울 성동구 성수동1가 685-12', 37.5, 127.0, '1120011400|0|685|12')$$,
                   'E4 같은 지번 중복 등록 차단', '23505');
select test.ok((select count(*) = 0 from public.sites where group_id = test.id('G3') and bunji = '성수동1가 685-12'), 'E4 중복 행 미생성');
insert into public.sites (group_id, bunji, jibun, unit, lat, lng, jibun_key)
values (test.id('G3'), '성수동1가 685-12', '서울 성동구 성수동1가 685-12', 'B동 계량기#2', 37.5, 127.0, '1120011400|0|685|12');
select test.ok(true, 'E4 세부(unit)가 다르면 등록 허용');
rollback;
begin;
select test.login(test.id('W1'));
select public.start_work(test.id('S1'), test.op());
select test.photo(test.id('S1'));
select public.complete_work(test.id('S1'), test.op(), test.good());
select test.login(test.id('A'));
insert into public.sites (group_id, bunji, jibun, lat, lng, jibun_key)
values (test.id('G3'), '성수동1가 685-12', '서울 성동구 성수동1가 685-12', 37.5, 127.0, '1120011400|0|685|12');
select test.ok(true, 'E4 완료된 번지는 새 묶음에 재등록 허용');
select test.eq(test.code(public.reopen_site(test.id('S1'), test.op(), '재작업')), 'DUPLICATE_SITE', 'E4 재오픈 시 활성 중복이면 DUPLICATE_SITE');
rollback;

-- E5: 팀 배정 묶음
begin;
select test.login(test.id('W1'));
select test.eq(test.code(public.claim_site(test.id('S6'), test.op())), 'TEAM_MISMATCH', 'E5 타 팀 묶음 → TEAM_MISMATCH');
select test.login(test.id('W3'));
select test.eq(test.code(public.claim_site(test.id('S6'), test.op())), 'OK', 'E5 배정 팀원 점유 가능');
rollback;
begin;
select test.login(test.id('A'));
select test.eq(test.code(public.claim_site(test.id('S6'), test.op())), 'OK', 'E5 관리자는 팀 제한 없음');
rollback;

-- E6: 스누즈 범위 경계 (5~480분)
begin;
select test.login(test.id('W1'));
select public.claim_site(test.id('S1'), test.op());
select test.eq(test.code(public.snooze_reminder(test.id('S1'), test.op(), 4)), 'INVALID_INPUT', 'E6 4분 → INVALID_INPUT');
select test.eq(test.code(public.snooze_reminder(test.id('S1'), test.op(), 481)), 'INVALID_INPUT', 'E6 481분 → INVALID_INPUT');
select test.eq(test.code(public.snooze_reminder(test.id('S1'), test.op(), 5)), 'OK', 'E6 5분 허용');
select test.eq(test.code(public.snooze_reminder(test.id('S1'), test.op(), 480)), 'OK', 'E6 480분 허용');
select test.ok((select next_remind_at = now() + interval '480 min' from public.work_sessions where site_id = test.id('S1')), 'E6 다음 알림 = now+480분');
rollback;

-- E7: 일시중단 누적 시간 → 소요 시간 계산 반영
begin;
select test.login(test.id('W1'));
select public.start_work(test.id('S1'), test.op());
select public.pause_work(test.id('S1'), test.op(), 'weather');
reset role;
update public.work_sessions set paused_at = now() - interval '10 min' where site_id = test.id('S1');
select test.login(test.id('W1'));
select public.resume_work(test.id('S1'), test.op());
select test.eq((select paused_total from public.work_sessions where site_id = test.id('S1')), interval '10 min', 'E7 중단 10분 누적');
rollback;

-- E8: 체크 중간 저장 + 완료 시 병합
begin;
select test.login(test.id('W1'));
select public.start_work(test.id('S1'), test.op());
select test.photo(test.id('S1'));
select test.eq(test.code(public.save_checks(test.id('S1'), test.op(), '{"w_meter": true, "w_read": 1234}')), 'OK', 'E8 중간 저장');
select test.eq(test.code(public.complete_work(test.id('S1'), test.op(), '{"w_leak":"없음","s_hole":"양호","s_back":false}')), 'OK', 'E8 저장분+입력분 병합으로 완료');
select test.eq((select checks ->> 'w_read' from public.work_sessions where site_id = test.id('S1')), '1234', 'E8 병합 결과 보존');
rollback;

-- E9: 체크 값 형식 검증 (최솟값·선택지·타입)
begin;
select test.login(test.id('W1'));
select public.start_work(test.id('S1'), test.op());
select test.photo(test.id('S1'));
select test.eq(public.complete_work(test.id('S1'), test.op(), test.good() || '{"w_read": -1}') -> 'missing', '["w_read"]'::jsonb, 'E9 최솟값 미만 → 오류 항목');
select test.eq(public.complete_work(test.id('S1'), test.op(), test.good() || '{"w_leak": "모름"}') -> 'missing', '["w_leak"]'::jsonb, 'E9 선택지 외 값 → 오류 항목');
select test.eq(public.complete_work(test.id('S1'), test.op(), test.good() || '{"w_meter": "yes"}') -> 'missing', '["w_meter"]'::jsonb, 'E9 bool에 문자열 → 오류 항목');
select test.eq(test.code(public.complete_work(test.id('S1'), test.op(), test.good() || '{"w_read": 0}')), 'OK', 'E9 최솟값 경계(0) 허용');
rollback;

-- E10: 정책 변경 즉시 반영 (점유 한도 1)
begin;
select test.login(test.id('A'));
select public.update_settings('{"max_claims_per_user": 1}', test.op());
select test.login(test.id('W1'));
select public.claim_site(test.id('S1'), test.op());
select test.eq(test.code(public.claim_site(test.id('S2'), test.op())), 'CLAIM_LIMIT', 'E10 한도 1로 변경 즉시 적용');
rollback;

-- E11: 템플릿 형식 검증(CHECK) — 잘못된 항목 거부
begin;
select test.raises($$insert into public.check_templates (name, items) values ('bad', '[{"key":"A B","label":"x","type":"bool"}]')$$, 'E11 잘못된 key 형식 거부', '23514');
select test.raises($$insert into public.check_templates (name, items) values ('bad2', '[{"key":"a","label":"x","type":"select"}]')$$, 'E11 select에 options 없음 거부', '23514');
select test.raises($$insert into public.check_templates (name, items) values ('bad3', '[{"key":"a","label":"x","type":"bool"},{"key":"a","label":"y","type":"bool"}]')$$, 'E11 key 중복 거부', '23514');
rollback;

-- E12: 증빙 요구 — 사진 수 + 서명 필수 템플릿
begin;
update public.check_templates set require_photo = 2, require_signature = true where id = test.id('TPL');
select test.login(test.id('W1'));
select public.start_work(test.id('S1'), test.op());
select test.photo(test.id('S1'));
select test.eq(test.code(public.complete_work(test.id('S1'), test.op(), test.good())), 'PROOF_REQUIRED', 'E12 증빙 부족 → PROOF_REQUIRED');
select test.eq(public.complete_work(test.id('S1'), test.op(), test.good()) -> 'missing', '["photo","signature"]'::jsonb, 'E12 사진 2장 중 1장·서명 누락 표시');
select test.photo(test.id('S1'));
insert into public.attachments (session_id, site_id, kind, path)
select session_id, id, 'signature', session_id || '/sign.png' from public.sites where id = test.id('S1');
select test.eq(test.code(public.complete_work(test.id('S1'), test.op(), test.good())), 'OK', 'E12 사진 2장+서명 → 완료');
rollback;
