-- path: supabase/tests/60_reminders_stats.sql
-- 리마인더 스케줄·에스컬레이션·푸시 트리거·통계·다국어 문구
\o /dev/null

-- T1: 작업중 리마인더 8회 → 3회째 팀장 에스컬레이션 → 8회 후 중단
begin;
select test.login(test.id('W1'));
select public.start_work(test.id('S1'), test.op());
reset role;
do $$
declare i int;
begin
  for i in 1..8 loop
    update public.work_sessions set next_remind_at = now() - interval '1 sec' where site_id = test.id('S1') and status = 'working';
    perform test.eq(private.run_reminders(), 1, format('T1 리마인더 %s회차 처리', i));
  end loop;
end $$;
select test.ok((select remind_count = 8 and next_remind_at is null from public.work_sessions where site_id = test.id('S1')), 'T1 8회 후 다음 알림 없음');
select test.eq((select count(*) from public.notifications where kind = 'escalate'), 1::bigint, 'T1 에스컬레이션 정확히 1회');
select test.eq((select user_id from public.notifications where kind = 'escalate'), test.id('L1'), 'T1 수신자 = 같은 팀 팀장');
select test.ok((select body like '김철수 · 성수동1가 685-12 · 작업 %시간 %분 경과' from public.notifications where kind = 'escalate'), 'T1 문구(이름·번지·경과)');
select test.eq((select count(*) from public.work_logs where action = 'remind'), 8::bigint, 'T1 remind 로그 8건');
select test.eq((select count(*) from public.work_logs where action = 'escalate'), 1::bigint, 'T1 escalate 로그 1건');
select test.eq(private.run_reminders(), 0, 'T1 추가 실행해도 0건(중복 없음)');
rollback;

-- T2: 반복 간격 = 상태별 정책 (작업중 30분 / 진행중 45분 / 일시중단 240분)
begin;
select test.login(test.id('W1'));
select public.claim_site(test.id('S1'), test.op());
select public.start_work(test.id('S2'), test.op());
select public.pause_work(test.id('S2'), test.op(), 'other');
select public.start_work(test.id('S1'), test.op());
select public.claim_site(test.id('S3'), test.op());
reset role;
update public.work_sessions set next_remind_at = now() - interval '1 sec' where user_id = test.id('W1');
select test.eq(private.run_reminders(), 3, 'T2 3건 동시 처리');
select test.eq((select next_remind_at - now() from public.work_sessions where site_id = test.id('S1')), interval '30 min', 'T2 작업중 반복 30분');
select test.eq((select next_remind_at - now() from public.work_sessions where site_id = test.id('S2')), interval '240 min', 'T2 일시중단 반복 240분');
select test.eq((select next_remind_at - now() from public.work_sessions where site_id = test.id('S3')), interval '45 min', 'T2 진행중 반복 45분');
rollback;

-- T3: 팀장이 없는 팀(무소속) → 관리자에게 에스컬레이션
begin;
select test.login(test.id('W5'));
select public.start_work(test.id('S1'), test.op());
reset role;
update public.work_sessions set remind_count = 2, next_remind_at = now() - interval '1 sec' where site_id = test.id('S1');
select private.run_reminders();
select test.eq((select array_agg(user_id) from public.notifications where kind = 'escalate'), array[test.id('A')], 'T3 팀장 없으면 관리자 수신');
rollback;

-- T4: 스누즈는 에스컬레이션 회차를 초기화하지 않음(회피 방지)
begin;
select test.login(test.id('W1'));
select public.start_work(test.id('S1'), test.op());
reset role;
update public.work_sessions set remind_count = 2 where site_id = test.id('S1');
select test.login(test.id('W1'));
select public.snooze_reminder(test.id('S1'), test.op(), 60);
reset role;
select test.eq((select remind_count from public.work_sessions where site_id = test.id('S1')), 2, 'T4 스누즈 후에도 회차 유지');
rollback;

-- T5: 푸시 트리거 — Vault 설정 시 pg_net으로 push 함수 호출, 미설정 시 무동작
begin;
select test.login(test.id('L1'));
select public.send_urgent('미설정', test.op());
reset role;
select test.eq((select count(*) from net.requests), 0::bigint, 'T5 Vault 미설정 → 호출 안 함');
insert into vault.secrets values ('project_url', 'https://demo.supabase.co'), ('cron_secret', 's3cret');
select test.login(test.id('L1'));
select public.send_urgent('설정됨', test.op());
reset role;
select test.ok((select url = 'https://demo.supabase.co/functions/v1/push' and headers ->> 'x-cron-secret' = 's3cret'
                  from net.requests order by id desc limit 1), 'T5 Vault 설정 → push 함수 호출');
rollback;

-- T5b: 재오픈 알림도 즉시 발송 호출(강제 해제·긴급·배포와 동일)
begin;
insert into vault.secrets values ('project_url', 'https://demo.supabase.co'), ('cron_secret', 's3cret');
select test.login(test.id('W1'));
select public.start_work(test.id('S1'), test.op());
select test.photo(test.id('S1'));
select public.complete_work(test.id('S1'), test.op(), test.good());
reset role;
delete from net.requests;
select test.login(test.id('L1'));
select test.eq(test.code(public.reopen_site(test.id('S1'), test.op(), '재작업')), 'OK', 'T5b 팀장 재오픈');
reset role;
select test.eq((select count(*) from net.requests), 1::bigint, 'T5b 재오픈 알림 → push 즉시 호출');
rollback;

-- T6: 통계 — 완료율·반납·차단된 중복 시도·범위 제한 (기준일 = 서울 날짜)
begin;
create function pg_temp.today() returns date language sql as $$ select (now() at time zone 'Asia/Seoul')::date $$;
select test.login(test.id('W1'));
select public.start_work(test.id('S1'), test.op());
select test.photo(test.id('S1'));
select public.complete_work(test.id('S1'), test.op(), test.good());
select test.login(test.id('W2'));
select public.claim_site(test.id('S2'), test.op());
select public.release_site(test.id('S2'), test.op(), '변경');
select public.claim_site(test.id('S1'), test.op());       -- 완료 현장(INVALID_TRANSITION, 중복 아님)
select public.start_work(test.id('S3'), test.op());
select test.login(test.id('W1'));
select public.claim_site(test.id('S3'), test.op());       -- SITE_OCCUPIED → 차단된 중복 1
select test.login(test.id('A'));
select test.eq((select row(claimed, completed, released, rejected_duplicates, completion_rate)::text
                  from public.get_stats(pg_temp.today(), pg_temp.today(), 'user') where key = test.id('W1')),
               '(1,1,0,1,1.000)', 'T6 개인: W1 맡음1·완료1·차단1·완료율 1');
select test.eq((select row(claimed, completed, released, rejected_duplicates)::text
                  from public.get_stats(pg_temp.today(), pg_temp.today(), 'user') where key = test.id('W2')),
               '(2,0,1,0)', 'T6 개인: W2 맡음2·반납1');
select test.eq((select row(name, claimed, completed, completion_rate)::text
                  from public.get_stats(pg_temp.today(), pg_temp.today(), 'team') where key = test.id('T1')),
               '(1팀,3,1,0.333)', 'T6 팀: 1팀 완료율 0.333');
select test.ok((select avg_work_min is not null from public.get_stats(pg_temp.today(), pg_temp.today(), 'user') where key = test.id('W1')), 'T6 평균 소요 계산');
select test.login(test.id('L2'));
select test.eq((select count(*) from public.get_stats(pg_temp.today(), pg_temp.today(), 'team')), 0::bigint, 'T6 타 팀 팀장: 자기 팀(데이터 없음)만');
select test.login(test.id('W1'));
select test.raises($$select * from public.get_stats(pg_temp.today(), pg_temp.today(), 'team')$$, 'T6 작업자 통계 조회 불가', '42501');
select test.login(test.id('A'));
select test.raises($$select * from public.get_stats(pg_temp.today(), pg_temp.today(), 'x')$$, 'T6 잘못된 기준 → 22023', '22023');
select test.raises($$select * from public.get_stats(pg_temp.today(), pg_temp.today() - 1, 'team')$$, 'T6 역순 기간 → 22023', '22023');
select test.raises($$select * from public.get_stats('2024-01-01', '2025-06-01', 'team')$$, 'T6 366일 초과 → 22023', '22023');
rollback;

-- T7: 다국어 문구·경과 시간 형식
select test.eq(private.msg('escalate_body', 'en', array['Kim', '685-12', '1h 2m']), 'Kim · 685-12 · working for 1h 2m', 'T7 영어 문구');
select test.eq(private.msg('urgent_title', 'xx'), '🚨 긴급 요청', 'T7 미지원 언어 → 한국어 대체');
select test.eq(private.msg('publish_body', 'ko', array['9/23 성수']), '9/23 성수 · 현장 곳', 'T7 인자 부족해도 오류 없음');
select test.eq(private.fmt_elapsed(interval '2 hours 5 min 59 sec', 'ko'), '2시간 5분', 'T7 경과 한국어');
select test.eq(private.fmt_elapsed(interval '-5 min', 'vi'), '0 giờ 0 phút', 'T7 음수 경과 → 0');

-- T8: 푸시 발송 선점 — 서버 전용, limit·임대(2분)·최대 5회
begin;
select test.login(test.id('L1'));
select public.send_urgent('푸시', test.op());                          -- 알림 6건
select test.raises($$select public.claim_push_batch(10)$$, 'T8 일반 사용자는 선점 함수 실행 불가', '42501');
reset role;
set local role service_role;
select test.eq((select count(*) from public.claim_push_batch(4)), 4::bigint, 'T8 limit만큼 선점');
select test.eq((select count(*) from public.claim_push_batch(10)), 2::bigint, 'T8 임대 중인 건 제외하고 나머지만');
select test.eq((select count(*) from public.claim_push_batch(10)), 0::bigint, 'T8 전부 임대 중 → 0');
reset role;
update public.notifications set locked_at = now() - interval '3 min';
set local role service_role;
select test.eq((select count(*) from public.claim_push_batch(10)), 6::bigint, 'T8 임대 만료 → 재선점(재시도)');
reset role;
select test.eq((select max(attempts) from public.notifications), 2, 'T8 선점마다 attempts+1');
update public.notifications set locked_at = null, attempts = 5;
set local role service_role;
select test.eq((select count(*) from public.claim_push_batch(10)), 0::bigint, 'T8 5회 시도 후 중단');
rollback;
