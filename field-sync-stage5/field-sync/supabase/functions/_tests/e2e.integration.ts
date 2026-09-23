// path: supabase/functions/_tests/e2e.integration.ts
// deno-lint-ignore-file no-explicit-any -- 테스트: PostgREST JSON 응답을 느슨하게 검사
// Edge Function 핸들러 → 실제 PostgREST·PG(90_http_e2e.sh가 기동). 외부(카카오·Google·Auth 관리 API)만 가짜.
// Supabase API 게이트웨이 동작(secret 키 → service_role JWT)은 라우터에서 재현. E2E_BASE 없으면 전부 건너뜀.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { createHmac } from 'node:crypto';
import process from 'node:process';
import { handle as geocode } from '../geocode/handler.ts';
import { handle as adminUsers } from '../admin-users/handler.ts';
import { handle as push } from '../push/handler.ts';

const BASE = process.env.E2E_BASE ?? '';
const SECRET = process.env.E2E_SECRET ?? '';
const skip = !BASE;
const SB = 'https://sb.e2e';
const SECRET_KEY = 'sb_secret_e2e';
const U = (n: string) => `00000000-0000-4000-8000-e2e0000000${n}`;
const ADMIN = U('01'), LEAD = U('02'), W1 = U('03'), W2 = U('04'), NEW = U('06'), W4 = U('07');
const G = U('d1'), TEAM = U('a1');

const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url');
function jwt(sub: string | null, role = 'authenticated'): string {
  const body = `${b64({ alg: 'HS256', typ: 'JWT' })}.${
    b64({ ...(sub ? { sub } : {}), role, exp: Math.floor(Date.now() / 1000) + 3600 })
  }`;
  return `${body}.${createHmac('sha256', SECRET).update(body).digest('base64url')}`;
}
const subOf = (auth: string | null) => {
  try {
    return JSON.parse(Buffer.from((auth ?? '').split('.')[1] ?? '', 'base64url').toString()).sub ?? null;
  } catch {
    return null;
  }
};

// 가짜 카카오: "… 테스트동 N" → 지번 1건, "모호동" → 2건, 그 외 0건
function kakaoDocs(query: string): any[] {
  const doc = (n: number) => ({
    x: String(127.1 + n / 10000),
    y: String(37.6 + n / 10000),
    road_address: null,
    address: {
      address_name: `서울 테스트구 테스트동 ${n}`,
      region_3depth_name: '테스트동',
      main_address_no: String(n),
      sub_address_no: '',
      mountain_yn: 'N',
      b_code: '9999900000',
    },
  });
  const m = /테스트동 (\d+)/.exec(query);
  if (m) return [doc(Number(m[1]))];
  if (query.includes('모호동')) return [doc(801), doc(802)];
  return [];
}

const authAdminCalls: { method: string; url: string; body: any }[] = [];
const fcmCalls: any[] = [];
const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status });

// deno-lint-ignore require-await -- 가짜 응답은 동기 생성, 실제 PostgREST 경로만 fetch Promise 반환
async function router(url: string, init: RequestInit = {}): Promise<Response> {
  const method = init.method ?? 'GET';
  const h = new Headers(init.headers);
  if (url.startsWith(`${SB}/rest/v1/`)) {
    if (!h.has('Authorization') && h.get('apikey') === SECRET_KEY) {
      h.set('Authorization', `Bearer ${jwt(null, 'service_role')}`);
    }
    h.delete('apikey');
    return fetch(BASE + url.slice(`${SB}/rest/v1`.length), { ...init, headers: h });
  }
  if (url === `${SB}/auth/v1/user`) {
    const sub = subOf(h.get('Authorization'));
    return sub ? json(200, { id: sub }) : json(401, { msg: 'invalid JWT' });
  }
  if (url.startsWith(`${SB}/auth/v1/admin/users`)) {
    authAdminCalls.push({ method, url, body: init.body ? JSON.parse(String(init.body)) : null });
    return method === 'POST' ? json(200, { id: NEW }) : json(200, {}); // 신규 계정은 미리 만든 auth.users 행으로 대체
  }
  if (url.startsWith('https://dapi.kakao.com/')) {
    return json(200, { documents: kakaoDocs(new URL(url).searchParams.get('query') ?? '') });
  }
  if (url === 'https://oauth2.googleapis.com/token') return json(200, { access_token: 'ya29.e2e', expires_in: 3600 });
  if (url.startsWith('https://fcm.googleapis.com/')) {
    const msg = JSON.parse(String(init.body)).message;
    fcmCalls.push(msg);
    return msg.token.includes('dead')
      ? json(404, { error: { status: 'NOT_FOUND', details: [{ errorCode: 'UNREGISTERED' }] } })
      : json(200, { name: 'projects/e2e/messages/1' });
  }
  return json(599, { message: `no route ${method} ${url}` });
}

// 서비스 계정용 RSA 키(실제 키와 같은 PKCS#8 PEM 형식)
const pair = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
  true,
  ['sign', 'verify'],
);
const der = Buffer.from(await crypto.subtle.exportKey('pkcs8', pair.privateKey)).toString('base64');
const env = {
  SUPABASE_URL: SB,
  SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: 'sb_publishable_e2e' }),
  SUPABASE_SECRET_KEYS: JSON.stringify({ default: SECRET_KEY }),
  KAKAO_REST_KEY: 'kakao-e2e',
  CRON_SECRET: 'cron-e2e',
  FCM_SERVICE_ACCOUNT: JSON.stringify({
    project_id: 'e2e',
    client_email: 'push@e2e.iam.gserviceaccount.com',
    private_key: `-----BEGIN PRIVATE KEY-----\n${der.replace(/(.{64})/g, '$1\n')}\n-----END PRIVATE KEY-----\n`,
  }),
};
const deps = { fetch: router, env, sleep: async () => {} };
const call = (
  h: (r: Request, d: any) => Promise<Response>,
  body: unknown,
  who: string | null,
  extra: Record<string, string> = {},
) =>
  h(
    new Request('http://fn.e2e/', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(who ? { Authorization: `Bearer ${jwt(who)}` } : {}),
        ...extra,
      },
      body: JSON.stringify(body),
    }),
    deps,
  ).then(async (r) => ({ status: r.status, body: await r.json() as any }));
const rest = async (path: string, who: string | null = null) => {
  const r = await fetch(BASE + path, {
    headers: { Authorization: `Bearer ${jwt(who, who ? 'authenticated' : 'service_role')}` },
  });
  return r.json() as Promise<any>;
};

test('geocode search: 팀장(site.create) 주소 검색 → 후보 1건', { skip }, async () => {
  const r = await call(geocode, { mode: 'search', query: '테스트동 21' }, LEAD);
  assert.equal(r.status, 200);
  assert.equal(r.body.candidates.length, 1);
  assert.equal(r.body.candidates[0].jibun_key, '9999900000|0|21|0');
});

test('geocode import: 관리자 CSV → 등록 1 · 파일 중복 · DB 활성 중복 · 주소 없음 · 모호', { skip }, async () => {
  const csv = '주소,세부,메모\n서울 테스트구 테스트동 21,,첫 행\n서울 테스트구 테스트동 21,,같은 파일\n' +
    '서울 테스트구 테스트동 2,,작업중 현장\n없는동 99,,\n모호동 1,,\n';
  const r = await call(geocode, { mode: 'import', group_id: G, csv }, ADMIN);
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(r.body.inserted, 1);
  assert.deepEqual(r.body.duplicates.map((d: any) => d.row), [3, 4]);
  assert.deepEqual(r.body.failed.map((d: any) => d.row), [5, 6]);
  const site =
    (await rest(`/sites?jibun_key=eq.${encodeURIComponent('9999900000|0|21|0')}&select=id,group_id,seq,note`))[0];
  assert.equal(site.group_id, G);
  assert.equal(site.seq, 3); // 기존 seq 1·2 다음
  assert.equal(site.note, '첫 행');
  const logs = await rest(`/work_logs?site_id=eq.${site.id}&select=action,actor_id`);
  assert.deepEqual(logs, [{ action: 'site_create', actor_id: ADMIN }]); // 누가 등록했는지 감사 기록
});

test('geocode import: 팀장은 배포된 동선에 추가 불가(403)', { skip }, async () => {
  const r = await call(geocode, { mode: 'import', group_id: G, csv: '주소\n서울 테스트구 테스트동 22\n' }, LEAD);
  assert.equal(r.status, 403);
  assert.equal(r.body.code, 'FORBIDDEN');
});

test('admin-users: 점유 중인 작업자 비활성화 → HAS_ACTIVE_CLAIMS(로그인 차단 호출 없음)', { skip }, async () => {
  const before = authAdminCalls.length;
  const r = await call(adminUsers, { action: 'deactivate', user_id: W2 }, ADMIN);
  assert.deepEqual(r.body, { ok: false, code: 'HAS_ACTIVE_CLAIMS' });
  assert.equal(authAdminCalls.length, before);
});

test('admin-users: 비활성화 → DB 차단 + 로그인 차단, 재활성화 → 해제', { skip }, async () => {
  let r = await call(adminUsers, { action: 'deactivate', user_id: W4 }, ADMIN);
  assert.deepEqual(r.body, { ok: true, user_id: W4 });
  assert.equal((await rest(`/profiles?id=eq.${W4}&select=active`))[0].active, false);
  assert.deepEqual(await rest(`/sites?select=id&limit=1`, W4), []); // 비활성 계정은 RLS로 조회 불가
  assert.notEqual(authAdminCalls.at(-1)!.body.ban_duration, 'none');
  r = await call(adminUsers, { action: 'activate', user_id: W4 }, ADMIN);
  assert.equal(r.body.ok, true);
  assert.equal(authAdminCalls.at(-1)!.body.ban_duration, 'none');
  assert.equal((await rest(`/profiles?id=eq.${W4}&select=active`))[0].active, true);
});

test('admin-users: 계정 발급 → 등급·팀을 실제 RPC로 반영, 팀장은 호출 불가', { skip }, async () => {
  const r = await call(adminUsers, {
    action: 'create',
    login_id: 'e2e_new',
    name: 'E2E신규',
    password: 'Passw0rd!e2e',
    role: 'leader',
    team_id: TEAM,
  }, ADMIN);
  assert.deepEqual(r.body, { ok: true, user_id: NEW });
  assert.equal(authAdminCalls.at(-1)!.body.app_metadata.role, 'leader');
  assert.deepEqual((await rest(`/profiles?id=eq.${NEW}&select=role,team_id`))[0], { role: 'leader', team_id: TEAM });
  const denied = await call(adminUsers, { action: 'activate', user_id: W4 }, LEAD);
  assert.equal(denied.status, 403);
});

test('push: 아웃박스 선점 → FCM 발송 → 결과 반영 · 무효 토큰 삭제 · 재실행 시 중복 발송 없음', { skip }, async () => {
  const unauth = await call(push, {}, null, { 'x-cron-secret': 'wrong' });
  assert.equal(unauth.status, 401);
  const r = await call(push, {}, null, { 'x-cron-secret': 'cron-e2e' });
  assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.ok(r.body.sent >= 1 && r.body.removed_tokens === 1, JSON.stringify(r.body));
  const toW1 = fcmCalls.find((m) => m.token === 'fcm-token-e2e-w1-ok' && m.data?.kind === 'urgent');
  assert.equal(toW1.android.notification.channel_id, 'urgent'); // 앱이 만든 채널과 일치
  const mine = await rest(`/notifications?user_id=in.(${W1},${W2})&kind=eq.urgent&select=user_id,sent_at,last_error`);
  const w1 = mine.find((n: any) => n.user_id === W1), w2 = mine.find((n: any) => n.user_id === W2);
  assert.ok(w1.sent_at && w1.last_error === null);
  assert.ok(w2.sent_at && w2.last_error === 'NO_DEVICE'); // 유일한 기기 토큰이 무효 → 종료
  assert.deepEqual(await rest(`/device_tokens?user_id=eq.${W2}&select=token`), []);
  assert.equal((await rest(`/device_tokens?user_id=eq.${W1}&select=token`)).length, 1);
  const again = await call(push, {}, null, { 'x-cron-secret': 'cron-e2e' });
  assert.equal(again.body.sent, 0);
});
