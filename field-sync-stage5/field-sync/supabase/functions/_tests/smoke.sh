#!/usr/bin/env bash
# path: supabase/functions/_tests/smoke.sh
# 선택 실행: 실제 Deno 런타임에서 진입점(index.ts, Deno.serve)을 띄워 HTTP로 호출하는 스모크 테스트.
# Supabase(Auth·PostgREST)는 Node로 만든 가짜 서버로 대체. 요구: deno, node, curl
# 사용: DENO=/path/to/deno bash supabase/functions/_tests/smoke.sh
set -uo pipefail
cd "$(dirname "$0")/.."
DENO="${DENO:-deno}"
UP=54400; FN=8000; fails=0

node -e '
const http = require("http");
const users = { "tok-admin": ["00000000-0000-0000-0000-0000000000aa", "admin"], "tok-worker": ["00000000-0000-0000-0000-0000000000c1", "worker"] };
http.createServer((q, s) => {
  const u = users[(q.headers.authorization || "").replace("Bearer ", "")];
  const send = (st, b) => { s.writeHead(st, { "Content-Type": "application/json" }); s.end(b === undefined ? "" : JSON.stringify(b)); };
  if (q.url === "/auth/v1/user") return u ? send(200, { id: u[0] }) : send(401, {});
  if (q.url.startsWith("/rest/v1/profiles")) return send(200, u ? [{ role: u[1], active: true }] : []);
  if (q.url.startsWith("/rest/v1/role_permissions")) return send(200, []);
  if (q.url === "/rest/v1/rpc/claim_push_batch") return q.headers.apikey === "sb_secret_smoke" ? send(200, []) : send(401, {});
  if (q.url === "/rest/v1/rpc/set_user_active") return send(200, { ok: true, code: "OK" });
  if (q.url.startsWith("/auth/v1/admin/users/")) return send(200, {});
  send(404, { url: q.url });
}).listen('"$UP"', "127.0.0.1");
' &
UPPID=$!
export SUPABASE_URL="http://127.0.0.1:$UP" SUPABASE_PUBLISHABLE_KEYS='{"default":"sb_publishable_smoke"}' \
       SUPABASE_SECRET_KEYS='{"default":"sb_secret_smoke"}' KAKAO_REST_KEY=k CRON_SECRET=cron-smoke \
       FCM_SERVICE_ACCOUNT='{"project_id":"p","client_email":"e","private_key":"-----BEGIN PRIVATE KEY-----\nAA\n-----END PRIVATE KEY-----"}'

expect() {  # expect <이름> <기대 HTTP> <curl 인자...>
  local name="$1" want="$2"; shift 2
  local got; got="$(curl -s -o /tmp/smoke_body -w '%{http_code}' "$@" "http://127.0.0.1:$FN/")"
  if [ "$got" = "$want" ]; then echo "PASS: $name ($got $(head -c 80 /tmp/smoke_body))"; else echo "FAIL: $name (expected $want, got $got $(cat /tmp/smoke_body))"; fails=$((fails + 1)); fi
}
serve() {  # serve <함수> → Deno로 index.ts 실행(포트 8000) 후 준비될 때까지 대기
  "$DENO" run --quiet --allow-net --allow-env "$1/index.ts" & FNPID=$!
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$FN/" && return; sleep 0.1; done
}
stop() { kill "$FNPID" 2>/dev/null; wait "$FNPID" 2>/dev/null; }

serve geocode
expect "geocode 토큰 없음 → 401" 401 -X POST -d '{}'
expect "geocode 권한 없는 작업자 → 403" 403 -X POST -H 'Authorization: Bearer tok-worker' -d '{"mode":"search","query":"성수동"}'
expect "geocode 잘못된 JSON → 400" 400 -X POST -H 'Authorization: Bearer tok-admin' -d '{bad'
stop

serve push
expect "push 비밀값 불일치 → 401" 401 -X POST -H 'x-cron-secret: nope'
expect "push 보낼 알림 없음 → 200(secret 키는 apikey로 전달)" 200 -X POST -H 'x-cron-secret: cron-smoke'
expect "push GET → 405" 405
stop

serve admin-users
expect "admin-users 작업자 → 403" 403 -X POST -H 'Authorization: Bearer tok-worker' -d '{"action":"activate","user_id":"00000000-0000-0000-0000-0000000000c1"}'
expect "admin-users 관리자 활성화 → 200" 200 -X POST -H 'Authorization: Bearer tok-admin' -d '{"action":"activate","user_id":"00000000-0000-0000-0000-0000000000c1"}'
stop

kill "$UPPID" 2>/dev/null
[ "$fails" = 0 ]
