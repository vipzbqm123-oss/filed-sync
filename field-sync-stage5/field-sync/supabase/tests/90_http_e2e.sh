#!/usr/bin/env bash
# path: supabase/tests/90_http_e2e.sh
# HTTP 통합 테스트: 실제 PostgREST(Supabase REST 계층) → 로컬 PG. 앱(api.dart)·Edge Function이 보내는 요청 형태를 그대로 재현.
#   ① 90_http_e2e.py  : 앱 요청(RPC 인자·임베드 조회·컬럼 권한·RLS·멱등 재전송)
#   ② _tests/e2e.integration.ts : Edge Function 핸들러(geocode·admin-users·push) → 실제 PostgREST (카카오·FCM·Auth만 가짜)
# 요구: postgrest 12+ (POSTGREST=경로 또는 PATH), python3, node 22.18+(②, 없으면 ②만 SKIP)
# run.sh가 PSQL_CMD·TEST_PGHOST·TEST_PGPORT를 넘겨 호출. 테스트 전용 역할(authenticator)·데이터만 추가.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PGRST="${POSTGREST:-$(command -v postgrest || true)}"
if [ -z "$PGRST" ]; then echo "SKIP: postgrest 없음 — POSTGREST=/path/to/postgrest 로 지정하면 실행"; exit 0; fi

$PSQL_CMD <<'SQL'
-- PostgREST 접속 역할(Supabase의 authenticator와 동일 구조: 로그인 후 JWT role로 전환)
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    create role authenticator login noinherit;
  end if;
end $$;
grant anon, authenticated, service_role to authenticator;

-- 앞선 테스트가 바꾼 전역 설정을 기본값으로 복원(결정적 실행)
update public.settings set remind_working_first_min = 90, remind_working_repeat_min = 30, remind_max = 8, escalate_at = 3,
  remind_en_route_after_min = 45, remind_paused_after_min = 240, max_claims_per_user = 3, arrive_radius_m = 50,
  undo_complete_window_min = 5, min_app_version = '1.0.0';
delete from public.role_permissions where role = 'worker';
insert into public.role_permissions (role, perm) values
  ('leader', 'site.create'), ('leader', 'site.edit'), ('leader', 'work.force_release'), ('leader', 'work.reopen'),
  ('leader', 'urgent.send'), ('leader', 'log.view_team'), ('leader', 'stats.view_team')
on conflict do nothing;

insert into public.teams (id, name) values
  ('00000000-0000-4000-8000-e2e0000000a1', 'E2E팀'), ('00000000-0000-4000-8000-e2e0000000a2', 'E2E타팀');
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data) values
  ('00000000-0000-4000-8000-e2e000000001', 'e2e_admin@staff.fieldsync.local', '{"name":"E2E관리자"}', '{"role":"admin"}'),
  ('00000000-0000-4000-8000-e2e000000002', 'e2e_lead@staff.fieldsync.local', '{"name":"E2E팀장"}',
   '{"role":"leader","team_id":"00000000-0000-4000-8000-e2e0000000a1"}'),
  ('00000000-0000-4000-8000-e2e000000003', 'e2e_w1@staff.fieldsync.local', '{"name":"E2E작업1"}',
   '{"team_id":"00000000-0000-4000-8000-e2e0000000a1"}'),
  ('00000000-0000-4000-8000-e2e000000004', 'e2e_w2@staff.fieldsync.local', '{"name":"E2E작업2"}',
   '{"team_id":"00000000-0000-4000-8000-e2e0000000a1"}'),
  ('00000000-0000-4000-8000-e2e000000005', 'e2e_w3@staff.fieldsync.local', '{"name":"E2E타팀원"}',
   '{"team_id":"00000000-0000-4000-8000-e2e0000000a2"}'),
  ('00000000-0000-4000-8000-e2e000000006', 'e2e_new@staff.fieldsync.local', '{"name":"E2E신규"}', '{}'),
  ('00000000-0000-4000-8000-e2e000000007', 'e2e_w4@staff.fieldsync.local', '{"name":"E2E작업4"}',
   '{"team_id":"00000000-0000-4000-8000-e2e0000000a1"}');
insert into public.check_templates (id, name, require_photo, items) values ('00000000-0000-4000-8000-e2e0000000e1', 'E2E 템플릿', 1,
  '[{"key":"w_meter","section":"상수도","label":"계량기 확인","type":"bool","required":true},
    {"key":"s_hole","section":"하수도","label":"맨홀 상태","type":"select","options":["양호","파손"],"required":true}]');
insert into public.site_groups (id, name, team_id, template_id, published, published_at) values
  ('00000000-0000-4000-8000-e2e0000000d1', 'E2E 배포 동선', null, '00000000-0000-4000-8000-e2e0000000e1', true, now()),
  ('00000000-0000-4000-8000-e2e0000000d2', 'E2E 타팀 동선', '00000000-0000-4000-8000-e2e0000000a2',
   '00000000-0000-4000-8000-e2e0000000e1', true, now()),
  ('00000000-0000-4000-8000-e2e0000000d3', 'E2E 초안', null, '00000000-0000-4000-8000-e2e0000000e1', false, null);
insert into public.sites (id, group_id, seq, bunji, jibun, lat, lng, b_code, jibun_key) values
  ('00000000-0000-4000-8000-e2e0000000f1', '00000000-0000-4000-8000-e2e0000000d1', 1, '테스트동 1', '서울 테스트구 테스트동 1',
   37.6001, 127.1001, '9999900000', '9999900000|0|1|0'),
  ('00000000-0000-4000-8000-e2e0000000f2', '00000000-0000-4000-8000-e2e0000000d1', 2, '테스트동 2', '서울 테스트구 테스트동 2',
   37.6002, 127.1002, '9999900000', '9999900000|0|2|0'),
  ('00000000-0000-4000-8000-e2e0000000f3', '00000000-0000-4000-8000-e2e0000000d2', 1, '테스트동 3', '서울 테스트구 테스트동 3',
   37.6003, 127.1003, '9999900000', '9999900000|0|3|0');
SQL

SECRET="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
PORT=$((TEST_PGPORT + 1))
LOG="$(mktemp)"
PGRST_DB_URI="postgres://authenticator@/postgres?host=$TEST_PGHOST&port=$TEST_PGPORT" PGRST_DB_SCHEMAS=public \
PGRST_DB_ANON_ROLE=anon PGRST_JWT_SECRET="$SECRET" PGRST_SERVER_HOST=127.0.0.1 PGRST_SERVER_PORT="$PORT" \
PGRST_DB_POOL=5 PGRST_LOG_LEVEL=crit "$PGRST" >"$LOG" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; rm -f "$LOG"' EXIT
export E2E_BASE="http://127.0.0.1:$PORT" E2E_SECRET="$SECRET"
python3 - <<'PY' || { echo "FAIL: PostgREST 기동 실패"; cat "$LOG"; exit 1; }
import os, time, urllib.request
for _ in range(100):
    try:
        urllib.request.urlopen(os.environ['E2E_BASE'] + '/', timeout=1); break
    except Exception: time.sleep(0.1)
else: raise SystemExit(1)
PY

rc=0
python3 "$HERE/90_http_e2e.py" || rc=1   # 실패해도 ②는 실행(결과를 모두 보고)
if command -v node >/dev/null && node -e 'process.exit(+process.versions.node.split(".")[0] >= 22 ? 0 : 1)'; then
  node --test --test-reporter=tap "$HERE/../functions/_tests/e2e.integration.ts" 2>&1 \
    | sed -n -e 's/^ok [0-9]* - /PASS: /p' -e 's/^not ok [0-9]* - /FAIL: /p' -e '/^ *error:/p' || rc=1
else
  echo "SKIP: node 22.18+ 없음 — Edge Function 통합(②) 생략"
fi
exit $rc
