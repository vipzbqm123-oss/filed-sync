-- path: supabase/tests/bench.sql
-- 선택 실행 벤치마크(기본 테스트에 미포함): 현장 10,000곳·사용자 500명 규모에서 RPC 지연 측정. 전부 롤백.
-- 실행: KEEP=1 bash supabase/tests/run.sh 후 출력된 psql 명령에 -f supabase/tests/bench.sql
\timing off
begin;
insert into public.site_groups (id, name, published, published_at)
values ('00000000-0000-0000-0000-00000000bbbb', 'bench', true, now());
insert into public.sites (group_id, seq, bunji, jibun, lat, lng, jibun_key)
select '00000000-0000-0000-0000-00000000bbbb', i, 'B-' || i, 'bench ' || i,
       37 + (i % 1000) / 10000.0, 127 + (i / 1000) / 1000.0, 'bench|' || i
  from generate_series(1, 10000) i;
insert into auth.users (id, email)
select ('00000000-0000-0000-0002-' || lpad(i::text, 12, '0'))::uuid, 'bench' || i || '@staff.fieldsync.local'
  from generate_series(1, 500) i;
analyze;

do $$
declare
  t0 timestamptz; i int; v_site uuid; v_ms numeric; v_n int;
begin
  -- 1) 맡기 500건 (각기 다른 사용자·현장)
  t0 := clock_timestamp();
  for i in 1..500 loop
    select id into v_site from public.sites where jibun_key = 'bench|' || i;
    perform set_config('request.jwt.claims', json_build_object('sub', ('00000000-0000-0000-0002-' || lpad(i::text, 12, '0')))::text, true);
    if public.claim_site(v_site, gen_random_uuid()) ->> 'code' <> 'OK' then raise exception 'claim failed'; end if;
  end loop;
  v_ms := extract(epoch from clock_timestamp() - t0) * 1000;
  raise notice 'BENCH claim_site: 500건 % ms (평균 % ms/건)', round(v_ms, 1), round(v_ms / 500, 2);

  -- 2) 같은 현장 중복 시도 500건 (거절 경로)
  t0 := clock_timestamp();
  for i in 1..500 loop
    perform set_config('request.jwt.claims', json_build_object('sub', ('00000000-0000-0000-0002-' || lpad((501 - i)::text, 12, '0')))::text, true);
    perform public.claim_site((select id from public.sites where jibun_key = 'bench|1'), gen_random_uuid());
  end loop;
  v_ms := extract(epoch from clock_timestamp() - t0) * 1000;
  raise notice 'BENCH 중복 거절: 500건 % ms (평균 % ms/건)', round(v_ms, 1), round(v_ms / 500, 2);

  -- 3) 리마인더 500건 동시 도래
  update public.work_sessions set next_remind_at = now() - interval '1 sec';
  t0 := clock_timestamp();
  v_n := private.run_reminders();
  v_ms := extract(epoch from clock_timestamp() - t0) * 1000;
  raise notice 'BENCH run_reminders: %건 % ms', v_n, round(v_ms, 1);

  -- 4) 통계(관리자, 사용자별)
  perform set_config('request.jwt.claims', json_build_object('sub', '00000000-0000-0000-0000-0000000000aa')::text, true);
  t0 := clock_timestamp();
  perform count(*) from public.get_stats((now() at time zone 'Asia/Seoul')::date, (now() at time zone 'Asia/Seoul')::date, 'user');
  raise notice 'BENCH get_stats(user): % ms', round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
end $$;
rollback;
