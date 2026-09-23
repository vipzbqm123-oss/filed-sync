// path: supabase/functions/_tests/admin-users.test.ts
// deno-lint-ignore-file no-explicit-any -- 테스트: 외부 JSON 응답 형태를 느슨하게 검사
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AppError } from '../_shared/core.ts';
import { handle, validate } from '../admin-users/handler.ts';
import { baseEnv, fakeFetch, ID, req, type Route, SB, supabaseAuthRoutes } from './fake.ts';

const NEW_ID = '00000000-0000-0000-0000-0000000000f9';
const env = baseEnv();

test('validate: 정상 입력 정규화(소문자·기본값)', () => {
  assert.deepEqual(validate({ action: 'create', login_id: ' Kim.CS ', password: 'pw123456', name: ' 김철수 ' }), {
    action: 'create',
    login_id: 'kim.cs',
    password: 'pw123456',
    name: '김철수',
    role: 'worker',
    team_id: null,
    lang: 'ko',
  });
  assert.deepEqual(validate({ action: 'deactivate', user_id: ID.worker }), {
    action: 'deactivate',
    user_id: ID.worker,
  });
});

test('validate: 경계·오류 입력 → 400', () => {
  const bad = (b: Record<string, unknown>, re: RegExp) =>
    assert.throws(() => validate(b), (e: AppError) => e.status === 400 && re.test(e.message));
  bad({ action: 'create', login_id: 'ab', password: 'pw123456', name: 'x' }, /로그인 ID/); // 2자
  bad({ action: 'create', login_id: 'a b', password: 'pw123456', name: 'x' }, /로그인 ID/);
  bad({ action: 'create', login_id: 'abc', password: '1234567', name: 'x' }, /비밀번호/); // 7자
  bad({ action: 'create', login_id: 'abc', password: '가'.repeat(25), name: 'x' }, /비밀번호/); // 75바이트
  bad({ action: 'create', login_id: 'abc', password: 'pw123456', name: '' }, /이름/);
  bad({ action: 'create', login_id: 'abc', password: 'pw123456', name: 'x', role: 'root' }, /role/);
  bad({ action: 'create', login_id: 'abc', password: 'pw123456', name: 'x', team_id: 'nope' }, /team_id/);
  bad({ action: 'create', login_id: 'abc', password: 'pw123456', name: 'x', lang: 'jp' }, /lang/);
  bad({ action: 'reset_password', user_id: 'x', password: 'pw123456' }, /user_id/);
  bad({ action: 'drop' }, /action/);
  assert.equal(
    (validate({ action: 'create', login_id: 'a'.repeat(32), password: 'p'.repeat(72), name: 'x'.repeat(50) }) as any)
      .login_id.length,
    32,
  ); // 상한 경계
});

function routes(
  o: {
    authCreate?: { status: number; body?: unknown };
    authUpdate?: number;
    rpc?: (fn: string, b: any) => unknown;
    teams?: boolean;
  } = {},
): Route[] {
  return [
    ...supabaseAuthRoutes(),
    {
      method: 'GET',
      match: /\/rest\/v1\/teams\?/,
      reply: () => ({ status: 200, body: o.teams === false ? [] : [{ id: ID.team }] }),
    },
    {
      method: 'POST',
      match: /\/auth\/v1\/admin\/users$/,
      reply: () => o.authCreate ?? { status: 200, body: { id: NEW_ID } },
    },
    { method: 'PUT', match: /\/auth\/v1\/admin\/users\//, reply: () => ({ status: o.authUpdate ?? 200, body: {} }) },
    {
      method: 'POST',
      match: /\/rest\/v1\/rpc\//,
      reply: (u, c) => ({ status: 200, body: o.rpc?.(u.split('/rpc/')[1], c.body) ?? { ok: true, code: 'OK' } }),
    },
  ];
}

test('admin-users 권한: 토큰 없음 401 / 팀장·작업자 403 / 비활성 403', async () => {
  const { f, calls } = fakeFetch(routes());
  const body = { action: 'deactivate', user_id: ID.worker };
  assert.equal((await handle(req(body, null), { fetch: f, env })).status, 401);
  assert.equal((await handle(req(body, 'tok-leader'), { fetch: f, env })).status, 403);
  assert.equal((await handle(req(body, 'tok-worker'), { fetch: f, env })).status, 403);
  assert.equal((await handle(req(body, 'tok-inactive'), { fetch: f, env })).status, 403);
  assert.equal(calls.filter((c) => c.url.includes('/admin/')).length, 0); // 관리 API 미호출
});

test('admin-users create: 가상 이메일·app_metadata 등급·서버 키 사용·감사 로그 RPC(호출자 JWT)', async () => {
  const { f, calls } = fakeFetch(routes());
  const r = await handle(
    req({
      action: 'create',
      login_id: 'Kim',
      password: 'pw123456',
      name: '김철수',
      role: 'leader',
      team_id: ID.team,
      lang: 'vi',
    }),
    { fetch: f, env },
  );
  assert.deepEqual(await r.json(), { ok: true, user_id: NEW_ID });
  const c = calls.find((x) => x.url === `${SB}/auth/v1/admin/users`)!;
  assert.equal(c.headers.apikey, 'sb_secret_test');
  assert.deepEqual(c.body, {
    email: 'kim@staff.fieldsync.local',
    password: 'pw123456',
    email_confirm: true,
    user_metadata: { login_id: 'kim', name: '김철수', lang: 'vi' },
    app_metadata: { role: 'leader', team_id: ID.team },
  });
  const audit = calls.find((x) => x.url.endsWith('/rpc/set_user_role'))!;
  assert.equal(audit.headers.authorization, 'Bearer tok-admin');
  assert.equal(audit.body.p_user_id, NEW_ID);
  assert.match(audit.body.p_op_id, /^[0-9a-f-]{36}$/);
});

test('admin-users create: 중복 ID → LOGIN_ID_TAKEN / 없는 팀 → 400 / Auth 오류 → 502', async () => {
  const dup = fakeFetch(
    routes({
      authCreate: {
        status: 422,
        body: {
          code: 422,
          error_code: 'email_exists',
          msg: 'A user with this email address has already been registered',
        },
      },
    }),
  );
  assert.deepEqual(
    await (await handle(req({ action: 'create', login_id: 'kim', password: 'pw123456', name: 'x' }), {
      fetch: dup.f,
      env,
    })).json(),
    { ok: false, code: 'LOGIN_ID_TAKEN' },
  );
  const noTeam = fakeFetch(routes({ teams: false }));
  assert.equal(
    (await handle(req({ action: 'create', login_id: 'kim', password: 'pw123456', name: 'x', team_id: ID.team }), {
      fetch: noTeam.f,
      env,
    })).status,
    400,
  );
  const down = fakeFetch(routes({ authCreate: { status: 500, body: {} } }));
  assert.equal(
    (await handle(req({ action: 'create', login_id: 'kim', password: 'pw123456', name: 'x' }), { fetch: down.f, env }))
      .status,
    502,
  );
});

test('admin-users reset_password: 성공 / 없는 사용자', async () => {
  const { f, calls } = fakeFetch(routes());
  assert.deepEqual(
    await (await handle(req({ action: 'reset_password', user_id: ID.worker, password: 'newpass12' }), {
      fetch: f,
      env,
    })).json(),
    { ok: true, user_id: ID.worker },
  );
  assert.deepEqual(calls.find((c) => c.method === 'PUT')!.body, { password: 'newpass12' });
  const nf = fakeFetch(routes({ authUpdate: 404 }));
  assert.deepEqual(
    await (await handle(req({ action: 'reset_password', user_id: ID.worker, password: 'newpass12' }), {
      fetch: nf.f,
      env,
    })).json(),
    { ok: false, code: 'NOT_FOUND' },
  );
});

test('admin-users 비활성: DB 규칙 거절(LAST_ADMIN)이면 로그인 차단 안 함 / 통과 시 876000h 차단 / 활성화 시 해제', async () => {
  const last = fakeFetch(routes({ rpc: () => ({ ok: false, code: 'LAST_ADMIN' }) }));
  assert.deepEqual(
    await (await handle(req({ action: 'deactivate', user_id: ID.admin }), { fetch: last.f, env })).json(),
    { ok: false, code: 'LAST_ADMIN' },
  );
  assert.equal(last.calls.filter((c) => c.method === 'PUT').length, 0);
  const ok = fakeFetch(routes());
  await handle(req({ action: 'deactivate', user_id: ID.worker }), { fetch: ok.f, env });
  assert.deepEqual(ok.calls.find((c) => c.url.endsWith('/rpc/set_user_active'))!.body.p_active, false);
  assert.deepEqual(ok.calls.find((c) => c.method === 'PUT')!.body, { ban_duration: '876000h' });
  const on = fakeFetch(routes());
  await handle(req({ action: 'activate', user_id: ID.worker }), { fetch: on.f, env });
  assert.deepEqual(on.calls.find((c) => c.method === 'PUT')!.body, { ban_duration: 'none' });
  const banFail = fakeFetch(routes({ authUpdate: 500 }));
  assert.deepEqual(
    await (await handle(req({ action: 'deactivate', user_id: ID.worker }), { fetch: banFail.f, env })).json(),
    { ok: true, user_id: ID.worker, code: 'AUTH_BAN_PENDING' },
  );
});

test('admin-users: 잘못된 JSON 400 / 큰 본문 413', async () => {
  const { f } = fakeFetch(routes());
  assert.equal((await handle(req('{bad'), { fetch: f, env })).status, 400);
  assert.equal((await handle(req({ action: 'create', name: 'x'.repeat(20000) }), { fetch: f, env })).status, 413);
});
