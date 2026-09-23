#!/usr/bin/env bash
# path: supabase/tests/80_check_parity.sh
# 앱↔서버 체크 검증 규칙 일치: app/test/fixtures/check_parity.json 의 기대값을 서버 private.missing_checks로 재확인.
# 같은 파일을 앱 테스트(app/test/models_test.dart)가 Template.missing으로 검증 → 양쪽이 같은 표를 통과해야 함.
# run.sh가 PSQL_CMD를 넘겨 호출. O(사례 수)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
FIX="$HERE/../../app/test/fixtures/check_parity.json"
$PSQL_CMD -At -v fx="$(cat "$FIX")" <<'SQL'
select case when got = want then 'PASS: ' || name
            else 'FAIL: ' || name || ' got=' || got::text || ' want=' || want::text end
  from (select c ->> 'name' as name, c -> 'missing' as want,
               to_jsonb(private.missing_checks(:'fx'::jsonb -> 'items', c -> 'checks')) as got
          from jsonb_array_elements(:'fx'::jsonb -> 'cases') as c) t;
SQL
