-- path: supabase/tests/40_empty.sql
-- 빈 입력·빈 데이터 (empty cases)
\o /dev/null

begin;
select test.login(test.id('A'));
select test.eq((select count(*) from public.get_stats('2020-01-01', '2020-01-02', 'team')), 0::bigint, 'M1 데이터 없는 기간 통계 → 0행');
reset role;
select test.eq(private.run_reminders(), 0, 'M2 도래한 리마인더 없음 → 0건');
select test.login(test.id('W1'));
select test.eq(test.code(public.claim_site('99999999-9999-9999-9999-999999999999', test.op())), 'NOT_FOUND', 'M3 없는 현장 → NOT_FOUND');
select test.eq((select meta ->> 'site_id' from public.work_logs where actor_id = test.id('W1') and action = 'claim' and not ok),
               '99999999-9999-9999-9999-999999999999', 'M3 없는 현장도 로그(meta.site_id)');
select public.start_work(test.id('S1'), test.op());
select test.eq(test.code(public.pause_work(test.id('S1'), test.op(), '')), 'INVALID_INPUT', 'M4 빈 중단 사유 → INVALID_INPUT');
select test.eq(test.code(public.pause_work(test.id('S1'), test.op(), null)), 'INVALID_INPUT', 'M4 NULL 중단 사유 → INVALID_INPUT');
select test.eq(test.code(public.release_site(test.id('S1'), test.op(), '   ')), 'INVALID_INPUT', 'M4 공백 반납 사유 → INVALID_INPUT');
select test.eq(test.code(public.complete_work(test.id('S1'), test.op(), null)), 'CHECKS_INCOMPLETE', 'M5 체크 NULL → 빈 객체로 처리');
select test.eq(test.code(public.save_checks(test.id('S1'), test.op(), null)), 'INVALID_INPUT', 'M5 체크 저장 NULL → INVALID_INPUT');
select test.eq(test.code(public.snooze_reminder(test.id('S1'), test.op(), null)), 'INVALID_INPUT', 'M5 스누즈 NULL → INVALID_INPUT');
select test.eq(test.code(public.register_device('', 'android')), 'INVALID_INPUT', 'M6 빈 토큰 → INVALID_INPUT');
select test.eq(test.code(public.register_device('fcm-token-abcdef', 'windows')), 'INVALID_INPUT', 'M6 잘못된 플랫폼 → INVALID_INPUT');
select test.login(test.id('L1'));
select test.eq(test.code(public.send_urgent('', test.op())), 'INVALID_INPUT', 'M7 빈 긴급 메시지 → INVALID_INPUT');
select test.eq(test.code(public.send_urgent(repeat('가', 301), test.op())), 'INVALID_INPUT', 'M7 301자 긴급 메시지 → INVALID_INPUT');
select test.eq(test.code(public.resolve_urgent('99999999-9999-9999-9999-999999999999', test.op())), 'NOT_FOUND', 'M7 없는 긴급 해제 → NOT_FOUND');
select test.login(test.id('A'));
select test.eq(test.code(public.publish_group('99999999-9999-9999-9999-999999999999', true, test.op())), 'NOT_FOUND', 'M8 없는 묶음 배포 → NOT_FOUND');
select test.eq(test.code(public.set_user_role('99999999-9999-9999-9999-999999999999', 'worker', test.op())), 'NOT_FOUND', 'M8 없는 사용자 → NOT_FOUND');
select test.eq(test.code(public.update_settings('{}', test.op())), 'OK', 'M8 빈 정책 변경 → 변화 없이 OK');
reset role;
select test.eq(private.missing_checks(null, '{}'), '{}'::text[], 'M9 템플릿 없음 → 누락 없음');
select test.eq(private.missing_checks('[]', null), '{}'::text[], 'M9 빈 템플릿·NULL 체크 → 누락 없음');
rollback;

-- M10: 템플릿이 없는 묶음 + 사진 요구 0 → 체크 없이 완료 가능
begin;
update public.site_groups set template_id = null where id = test.id('G1');
select test.login(test.id('W1'));
select public.start_work(test.id('S1'), test.op());
select test.eq(test.code(public.complete_work(test.id('S1'), test.op())), 'OK', 'M10 템플릿 없는 현장은 체크·증빙 없이 완료');
rollback;
