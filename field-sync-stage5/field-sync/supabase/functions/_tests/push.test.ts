// path: supabase/functions/_tests/push.test.ts
// deno-lint-ignore-file no-explicit-any -- 테스트: 외부 JSON 응답 형태를 느슨하게 검사
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  accessToken,
  b64url,
  buildMessage,
  classify,
  type Notif,
  pemToDer,
  signJwt,
  type TokenCache,
} from '../push/lib.ts';
import { handle } from '../push/handler.ts';
import { baseEnv, fakeFetch, type Route, SB } from './fake.ts';

// 테스트용 RSA 키 (실제 서비스 계정 키와 같은 PKCS#8 PEM 형식)
const pair = await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
  true,
  ['sign', 'verify'],
);
const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey));
const PEM = `-----BEGIN PRIVATE KEY-----\n${
  btoa(String.fromCharCode(...der)).replace(/(.{64})/g, '$1\n')
}\n-----END PRIVATE KEY-----\n`;
const SA = {
  project_id: 'fieldsync-test',
  client_email: 'push@fieldsync-test.iam.gserviceaccount.com',
  private_key: PEM,
  private_key_id: 'kid1',
};
const fromB64url = (s: string) =>
  Uint8Array.from(
    atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4)),
    (c) => c.charCodeAt(0),
  );

test('b64url·pemToDer: 패딩 제거·URL 안전 문자·PEM 왕복', () => {
  assert.equal(b64url('hi?>'), 'aGk_Pg');
  assert.equal(b64url(new Uint8Array([251, 255])), '-_8');
  assert.deepEqual(new Uint8Array(pemToDer(PEM)), der);
});

test('signJwt: RS256 서명이 공개키로 검증되고 헤더·클레임이 정확', async () => {
  const jwt = await signJwt({ iss: 'a', exp: 1 }, PEM, 'kid1');
  const [h, c, s] = jwt.split('.');
  assert.deepEqual(JSON.parse(new TextDecoder().decode(fromB64url(h))), { alg: 'RS256', typ: 'JWT', kid: 'kid1' });
  assert.deepEqual(JSON.parse(new TextDecoder().decode(fromB64url(c))), { iss: 'a', exp: 1 });
  const ok = await crypto.subtle.verify(
    'RSASSA-PKCS1-v1_5',
    pair.publicKey,
    fromB64url(s),
    new TextEncoder().encode(`${h}.${c}`),
  );
  assert.ok(ok);
});

test('accessToken: 교환 1회 후 캐시 재사용, 만료 60초 전 갱신, 실패 시 FCM_AUTH', async () => {
  let n = 0;
  const { f, calls } = fakeFetch([{
    method: 'POST',
    match: /oauth2\.googleapis\.com\/token/,
    reply: () => ({ status: 200, body: { access_token: `at${++n}`, expires_in: 3600 } }),
  }]);
  const cache: TokenCache = {};
  assert.equal(await accessToken(f, SA, 1000, cache), 'at1');
  assert.equal(await accessToken(f, SA, 1000 + 3000, cache), 'at1'); // 아직 유효
  assert.equal(await accessToken(f, SA, 1000 + 3541, cache), 'at2'); // 만료 59초 전 → 갱신
  assert.equal(calls.length, 2);
  const form = new URLSearchParams(calls[0].body);
  assert.equal(form.get('grant_type'), 'urn:ietf:params:oauth:grant-type:jwt-bearer');
  const claims = JSON.parse(new TextDecoder().decode(fromB64url(form.get('assertion')!.split('.')[1])));
  assert.deepEqual(claims, {
    iss: SA.client_email,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token',
    iat: 1000,
    exp: 4600,
  });
  const bad = fakeFetch([{ match: /oauth2/, reply: () => ({ status: 400, body: { error: 'invalid_grant' } }) }]);
  await assert.rejects(accessToken(bad.f, SA, 1, {}), (e: any) => e.code === 'FCM_AUTH');
});

const N = (o: Partial<Notif> = {}): Notif => ({
  id: 1,
  user_id: 'u1',
  kind: 'escalate',
  title: 'T',
  body: 'B',
  data: { site_id: 's1', n: 3, x: null },
  collapse_key: 'escalate:abc',
  ...o,
});

test('buildMessage: data는 문자열만, 긴급류 high 우선순위, collapse 64바이트 제한, 채널', () => {
  const m: any = buildMessage(N(), 'tok').message;
  assert.deepEqual(m.data, { kind: 'escalate', notification_id: '1', site_id: 's1', n: '3' });
  assert.equal(m.android.priority, 'high');
  assert.equal(m.apns.headers['apns-priority'], '10');
  assert.equal(m.android.notification.channel_id, 'default');
  const u: any = buildMessage(N({ kind: 'urgent', collapse_key: 'x'.repeat(80) }), 't').message;
  assert.equal(u.android.notification.channel_id, 'urgent');
  assert.equal(u.apns.headers['apns-collapse-id'].length, 64);
  const p: any = buildMessage(N({ kind: 'publish', collapse_key: null, data: null }), 't').message;
  assert.equal(p.android.priority, 'normal');
  assert.equal(p.apns.headers['apns-collapse-id'], undefined);
});

test('classify: FCM 오류 → 조치', () => {
  const err = (status: number, errorCode?: string, message = '') => ({
    error: {
      code: status,
      message,
      details: errorCode ? [{ '@type': 'type.googleapis.com/google.firebase.fcm.v1.FcmError', errorCode }] : [],
    },
  });
  assert.equal(classify(200, {}), 'ok');
  assert.equal(classify(404, err(404, 'UNREGISTERED')), 'invalid_token');
  assert.equal(classify(403, err(403, 'SENDER_ID_MISMATCH')), 'invalid_token');
  assert.equal(
    classify(400, err(400, 'INVALID_ARGUMENT', 'The registration token is not a valid FCM registration token')),
    'invalid_token',
  );
  assert.equal(classify(400, err(400, 'INVALID_ARGUMENT', 'Message payload too big')), 'fatal');
  assert.equal(classify(429, err(429, 'QUOTA_EXCEEDED')), 'retry');
  assert.equal(classify(503, err(503, 'UNAVAILABLE')), 'retry');
  assert.equal(classify(401, err(401, 'THIRD_PARTY_AUTH_ERROR')), 'retry');
  assert.equal(classify(500, 'not json'), 'retry');
});

// ───────── 핸들러 통합 흐름 ─────────
const env = baseEnv({ CRON_SECRET: 'cron-s3cret', FCM_SERVICE_ACCOUNT: JSON.stringify(SA) });
const cronReq = (secret = 'cron-s3cret') =>
  new Request('http://fn.test/', { method: 'POST', headers: { 'x-cron-secret': secret } });

function pushRoutes(
  notifs: Notif[],
  tokens: { token: string; user_id: string }[],
  fcm: (token: string) => { status: number; body?: unknown },
): Route[] {
  return [
    { method: 'POST', match: /\/rest\/v1\/rpc\/claim_push_batch$/, reply: () => ({ status: 200, body: notifs }) },
    { method: 'GET', match: /\/rest\/v1\/device_tokens\?/, reply: () => ({ status: 200, body: tokens }) },
    {
      method: 'POST',
      match: /oauth2\.googleapis\.com\/token/,
      reply: () => ({ status: 200, body: { access_token: 'AT', expires_in: 3600 } }),
    },
    {
      method: 'POST',
      match: /fcm\.googleapis\.com\/v1\/projects\/fieldsync-test\/messages:send/,
      reply: (_u, c) => fcm(c.body.message.token),
    },
    { method: 'PATCH', match: /\/rest\/v1\/notifications\?/, reply: () => ({ status: 204 }) },
    { method: 'DELETE', match: /\/rest\/v1\/device_tokens\?/, reply: () => ({ status: 204 }) },
  ];
}

test('push 인증: 비밀값 불일치 401 / GET 405 / 설정 누락 500', async () => {
  const { f, calls } = fakeFetch([]);
  assert.equal((await handle(cronReq('wrong'), { fetch: f, env, cache: {} })).status, 401);
  assert.equal((await handle(new Request('http://fn.test/'), { fetch: f, env, cache: {} })).status, 405);
  assert.equal(
    (await handle(cronReq(), { fetch: f, env: baseEnv({ CRON_SECRET: 'cron-s3cret' }), cache: {} })).status,
    500,
  );
  assert.equal(calls.length, 0);
});

test('push: 보낼 알림 없음 → 0건, FCM·토큰 조회 없음', async () => {
  const { f, calls } = fakeFetch(pushRoutes([], [], () => ({ status: 200 })));
  const r = await handle(cronReq(), { fetch: f, env, cache: {} });
  assert.deepEqual(await r.json(), { sent: 0, failed: 0, removed_tokens: 0 });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].headers.apikey, 'sb_secret_test'); // 서버 권한 호출
  assert.equal(calls[0].headers.authorization, undefined); // 새 secret 키는 Bearer 금지
});

test('push: 성공·무효 토큰 삭제·기기 없음 종료·일시 오류 재시도·요청 오류 종료', async () => {
  const notifs = [
    N({ id: 1, user_id: 'u1', kind: 'urgent' }), // 기기 2대: 1대 성공, 1대 UNREGISTERED → 발송 + 토큰 삭제
    N({ id: 2, user_id: 'u2' }), // 기기 없음 → NO_DEVICE 종료
    N({ id: 3, user_id: 'u3' }), // 503 → 재시도 대기
    N({ id: 4, user_id: 'u4' }), // 기기 1대 UNREGISTERED → NO_DEVICE 종료 + 삭제
    N({ id: 5, user_id: 'u5' }), // 페이로드 오류 → FATAL 종료
  ];
  const tokens = [
    { token: 't1a', user_id: 'u1' },
    { token: 't1b:dead', user_id: 'u1' },
    { token: 't3', user_id: 'u3' },
    { token: 't4', user_id: 'u4' },
    { token: 't5', user_id: 'u5' },
  ];
  const fcm = (t: string) => {
    if (t === 't1a') return { status: 200, body: { name: 'projects/x/messages/1' } };
    if (t === 't3') {
      return { status: 503, body: { error: { status: 'UNAVAILABLE', details: [{ errorCode: 'UNAVAILABLE' }] } } };
    }
    if (t === 't5') {
      return {
        status: 400,
        body: { error: { message: 'payload too big', details: [{ errorCode: 'INVALID_ARGUMENT' }] } },
      };
    }
    return { status: 404, body: { error: { details: [{ errorCode: 'UNREGISTERED' }] } } };
  };
  const { f, calls } = fakeFetch(pushRoutes(notifs, tokens, fcm));
  const r = await handle(cronReq(), { fetch: f, env, cache: {}, now: () => Date.UTC(2026, 8, 23, 1, 0, 0) });
  assert.deepEqual(await r.json(), { sent: 1, failed: 1, closed: 3, removed_tokens: 2 });

  const sends = calls.filter((c) => c.url.includes('messages:send'));
  assert.equal(sends.length, 5);
  assert.equal(sends[0].headers.authorization, 'Bearer AT');
  const patches = calls.filter((c) => c.method === 'PATCH').map((
    c,
  ) => [decodeURIComponent(c.url.split('id=')[1]), c.body]);
  assert.deepEqual(patches, [
    ['in.(1)', { sent_at: '2026-09-23T01:00:00.000Z', last_error: null }],
    ['in.(2,4)', { sent_at: '2026-09-23T01:00:00.000Z', last_error: 'NO_DEVICE' }],
    ['in.(5)', { sent_at: '2026-09-23T01:00:00.000Z', last_error: 'FATAL' }],
    ['in.(3)', { last_error: 'RETRY:503' }],
  ]);
  const del = calls.find((c) => c.method === 'DELETE')!;
  assert.equal(decodeURIComponent(del.url.split('token=')[1]), 'in.("t1b:dead","t4")');
});

test('push: 네트워크 오류는 재시도, Google 토큰 실패는 502', async () => {
  const routes = pushRoutes([N({ id: 9, user_id: 'u1' })], [{ token: 't', user_id: 'u1' }], () => ({ status: 200 }));
  const netFail = fakeFetch(routes.map((r) => (String(r.match).includes('fcm')
    ? {
      ...r,
      reply: () => {
        throw new Error('ECONNRESET');
      },
    }
    : r)
  ));
  assert.deepEqual(await (await handle(cronReq(), { fetch: netFail.f, env, cache: {} })).json(), {
    sent: 0,
    failed: 1,
    closed: 0,
    removed_tokens: 0,
  });
  const authFail = fakeFetch(
    routes.map((r) => (String(r.match).includes('oauth2') ? { ...r, reply: () => ({ status: 401 }) } : r)),
  );
  const res = await handle(cronReq(), { fetch: authFail.f, env, cache: {} });
  assert.equal(res.status, 502);
  assert.equal(authFail.calls.filter((c) => c.url.startsWith(SB) && c.method === 'PATCH').length, 0); // 임대 만료 후 자동 재시도
});
