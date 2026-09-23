#!/usr/bin/env bash
# path: supabase/tests/run.sh
# 로컬 임시 Postgres 클러스터에서 마이그레이션 + 통합 테스트 실행 (Docker·외부 패키지 불필요).
# 사용: bash supabase/tests/run.sh            # 전체
#       KEEP=1 bash supabase/tests/run.sh     # 종료 후 클러스터 유지(디버깅)
# 요구: PostgreSQL 14+ 서버 바이너리(initdb, pg_ctl, psql). PGBIN으로 경로 지정 가능.
set -euo pipefail
shopt -s nullglob

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PGBIN="${PGBIN:-$(pg_config --bindir 2>/dev/null || ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
[ -x "$PGBIN/initdb" ] || { echo "initdb를 찾을 수 없음: PGBIN=/path/to/postgres/bin 지정" >&2; exit 2; }
PORT="${PGPORT_TEST:-54329}"
WORK="$(mktemp -d)"
AS=()
if [ "$(id -u)" = 0 ]; then chown postgres "$WORK"; AS=(runuser -u postgres --); fi   # initdb는 root 실행 불가

cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then echo "클러스터 유지: psql -h $WORK -p $PORT -U postgres"; return; fi
  "${AS[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

"${AS[@]}" "$PGBIN/initdb" -D "$WORK/data" -U postgres -A trust -E UTF8 --no-locale >/dev/null
"${AS[@]}" "$PGBIN/pg_ctl" -D "$WORK/data" -l "$WORK/server.log" -w \
  -o "-p $PORT -k $WORK -c listen_addresses= -c max_connections=60" start >/dev/null

export TEST_PGHOST="$WORK" TEST_PGPORT="$PORT"   # 90_http_e2e.sh(PostgREST 접속)용
export PSQL_CMD="${AS[*]:+${AS[*]} }$PGBIN/psql -X -q -v ON_ERROR_STOP=1 -h $WORK -p $PORT -U postgres -d postgres"
psql_f() { $PSQL_CMD -f "$1" 2>&1; }

pass=0; fail=0
run_file() {  # $1 = 파일, 출력의 PASS/FAIL 집계
  local out
  if out="$(psql_f "$1")"; then :; else fail=$((fail + 1)); fi
  local p f
  p="$(grep -c 'PASS:' <<<"$out" || true)"; f="$(grep -c 'FAIL:\|ERROR:' <<<"$out" || true)"
  pass=$((pass + p))
  printf '%-34s PASS %3d  FAIL %d\n' "$(basename "$1")" "$p" "$f"
  if [ "$f" != 0 ]; then grep 'FAIL:\|ERROR:' <<<"$out" | sed 's/^/    /'; fi
}

echo "▶ 스텁 + 마이그레이션 적용"
for f in "$HERE/00_supabase_stub.sql" "$ROOT"/migrations/*.sql "$HERE/01_helpers_fixtures.sql"; do
  if ! out="$(psql_f "$f")"; then echo "적용 실패: $(basename "$f")"; echo "$out"; exit 1; fi
  printf '  ✓ %s\n' "$(basename "$f")"
done

echo "▶ 테스트"
for f in "$HERE"/[1-6]*.sql; do run_file "$f"; done
for sh in "$HERE"/[7-9]*.sh; do   # 70 동시성 · 80 앱↔서버 체크 규칙 · 90 HTTP 통합(PostgREST)
  if out="$(bash "$sh" 2>&1)"; then :; else fail=$((fail + 1)); fi
  p="$(grep -c 'PASS:' <<<"$out" || true)"; f="$(grep -c 'FAIL:\|ERROR:' <<<"$out" || true)"; pass=$((pass + p))
  printf '%-34s PASS %3d  FAIL %d\n' "$(basename "$sh")" "$p" "$f"
  if [ "$f" != 0 ]; then fail=$((fail + 1)); grep 'FAIL:\|ERROR:' <<<"$out" | sed 's/^/    /'; fi
done

echo "────────────────────────────────"
echo "합계: PASS $pass · 실패 파일 $fail"
[ "$fail" = 0 ]
