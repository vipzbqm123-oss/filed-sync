#!/usr/bin/env bash
# path: supabase/tests/70_concurrency.sh
# 실제 동시 트랜잭션(별도 DB 연결)으로 중복 방지 검증. run.sh가 PSQL_CMD를 제공.
# 이 테스트는 커밋하므로 반드시 마지막에 실행(run.sh는 매번 새 클러스터 사용).
set -uo pipefail
: "${PSQL_CMD:?run.sh에서 실행하세요}"
TMP="$(mktemp -d)"; chmod 777 "$TMP"; trap 'rm -rf "$TMP"' EXIT
fails=0
sqlf() { $PSQL_CMD -tA -f - 2>&1; }            # stdin의 SQL 실행
check() {                                       # check <실제> <기대> <이름>
  if [ "$1" = "$2" ]; then echo "PASS: $3"; else echo "FAIL: $3 (expected '$2', got '$1')"; fails=$((fails + 1)); fi
}

# ── C1: A가 현장을 잡은 채 2초 머무는 동안 B가 같은 현장 요청 → B는 A 커밋까지 대기 후 SITE_OCCUPIED
sqlf >"$TMP/a" <<'SQL' &
begin;
select test.login(test.id('W1'));
select 'A:' || test.code(public.claim_site(test.id('S1'), gen_random_uuid()));
select pg_sleep(2);
commit;
SQL
pid=$!
sleep 0.5
sqlf >"$TMP/b" <<'SQL'
begin;
select test.login(test.id('W2'));
select 'B:' || test.code(public.claim_site(test.id('S1'), gen_random_uuid()));
select 'WAIT:' || (extract(epoch from clock_timestamp() - now()) * 1000)::int;
commit;
SQL
wait "$pid"
check "$(grep -o 'A:.*' "$TMP/a")" "A:OK" "C1 먼저 도착한 A 성공"
check "$(grep -o 'B:.*' "$TMP/b")" "B:SITE_OCCUPIED" "C1 동시 요청 B는 SITE_OCCUPIED"
waited="$(grep -o 'WAIT:[0-9]*' "$TMP/b" | cut -d: -f2)"
if [ "${waited:-0}" -ge 1000 ]; then echo "PASS: C1 B는 A 커밋까지 잠금 대기(${waited}ms)"; else echo "FAIL: C1 대기 ${waited:-?}ms"; fails=$((fails + 1)); fi

# ── C2: 20명이 같은 번지를 동시에 맡기 (advisory lock 장벽으로 동시 출발) → 정확히 1명 성공
echo "insert into auth.users (id, email, raw_user_meta_data)
      select ('00000000-0000-0000-0001-' || lpad(i::text, 12, '0'))::uuid, 'user' || i || '@staff.fieldsync.local',
             jsonb_build_object('name', '동시' || i) from generate_series(1, 20) i;" | sqlf >/dev/null
sqlf >/dev/null <<'SQL' &
select pg_advisory_lock(4242);
select pg_sleep(1.5);
SQL
holder=$!
sleep 0.3
for i in $(seq 1 20); do
  uid="$(printf '00000000-0000-0000-0001-%012d' "$i")"
  sqlf >"$TMP/c$i" <<SQL &
begin;
select test.login('$uid');
select pg_advisory_xact_lock_shared(4242);
select 'R:' || test.code(public.claim_site(test.id('S2'), gen_random_uuid()));
commit;
SQL
done
wait
okn="$(cat "$TMP"/c* | grep -c '^R:OK$')"
occ="$(cat "$TMP"/c* | grep -c '^R:SITE_OCCUPIED$')"
check "$okn" "1" "C2 동시 20건 중 성공 정확히 1건"
check "$occ" "19" "C2 나머지 19건 SITE_OCCUPIED"
check "$(echo "select count(*) from public.work_sessions where site_id = test.id('S2') and status in ('en_route','working','paused');" | sqlf)" \
      "1" "C2 DB 점유 세션 1건"
check "$(echo "select count(*) from public.work_logs where site_id = test.id('S2') and action = 'claim' and not ok;" | sqlf)" \
      "19" "C2 거절 로그 19건(중복 시도 통계)"

# ── C3: 최후 방어선 — 앱·RPC를 우회해 DB에 직접 두 번째 점유 세션 삽입 → 유니크 인덱스가 차단
out="$(echo "insert into public.work_sessions (site_id, user_id, status) values (test.id('S2'), test.id('W1'), 'working');" | sqlf)"
if grep -q 'work_sessions_one_active_uq' <<<"$out"; then echo "PASS: C3 부분 유니크 인덱스가 이중 점유 차단"; else echo "FAIL: C3 $out"; fails=$((fails + 1)); fi

# ── C4: 같은 op_id 동시 재전송(응답 유실 후 재시도 상황) → 1회만 적용, 나머지는 replayed
sqlf >/dev/null <<'SQL' &
select pg_advisory_lock(4343);
select pg_sleep(1);
SQL
sleep 0.3
for i in 1 2; do
  sqlf >"$TMP/d$i" <<'SQL' &
begin;
select test.login(test.id('W3'));
select pg_advisory_xact_lock_shared(4343);
select 'R:' || (public.claim_site(test.id('S6'), '33333333-3333-3333-3333-333333333333') ->> 'replayed');
commit;
SQL
done
wait
check "$(cat "$TMP"/d* | grep '^R:' | sort | tr '\n' ' ')" "R:false R:true " "C4 동시 재전송 → 최초 1건 + replayed 1건"
check "$(echo "select count(*) from public.work_sessions where site_id = test.id('S6');" | sqlf)" "1" "C4 세션 1건만 생성"

# ── C5: 서로 다른 현장 동시 처리 — 교착 없이 전원 성공 (현장 단위 잠금이라 병렬)
for i in 1 2 3; do
  site="S$((i + 2))"; uid="W$i"; [ "$i" = 3 ] && uid="W5"
  sqlf >"$TMP/e$i" <<SQL &
begin;
select test.login(test.id('$uid'));
select 'R:' || test.code(public.start_work(test.id('$site'), gen_random_uuid()));
commit;
SQL
done
wait
check "$(cat "$TMP"/e* | grep -c '^R:OK$')" "3" "C5 다른 현장 3건 동시 성공"

# ── C6: 푸시 선점 동시 호출(push 함수 중복 실행 상황) → 알림이 겹치지 않게 나뉨
echo "insert into public.notifications (user_id, kind, title, body)
      select test.id('W1'), 'urgent', 't', 'b' || i from generate_series(1, 50) i;" | sqlf >/dev/null
sqlf >/dev/null <<'SQL' &
select pg_advisory_lock(4444);
select pg_sleep(1);
SQL
sleep 0.3
for i in 1 2; do
  sqlf >"$TMP/f$i" <<'SQL' &
begin;
set local role service_role;
select pg_advisory_xact_lock_shared(4444);
select 'N:' || id from public.claim_push_batch(40);
commit;
SQL
done
wait
check "$(cat "$TMP"/f* | grep -c '^N:')" "50" "C6 두 호출 합계 = 전체 50건"
check "$(cat "$TMP"/f* | grep '^N:' | sort -u | wc -l | tr -d ' ')" "50" "C6 중복 선점 0건"

[ "$fails" = 0 ]
