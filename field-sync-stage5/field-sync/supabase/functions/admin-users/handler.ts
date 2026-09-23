// path: supabase/functions/admin-users/handler.ts
// POST /functions/v1/admin-users — 관리자 전용 계정 관리
//   {action:"create", login_id, password, name, role?, team_id?, lang?}
//   {action:"reset_password", user_id, password}
//   {action:"deactivate"|"activate", user_id}
// 응답: {ok, user_id?, code?}  (업무 거절은 200 + ok=false, 인증·권한·입력 오류는 4xx)
import {
  AppError,
  bearer,
  call,
  callerOf,
  type Env,
  errorResponse,
  type Fetch,
  isUuid,
  json,
  readJson,
  serviceHeaders,
  supaCfg,
  userHeaders,
} from '../_shared/core.ts';

export interface Deps {
  fetch: Fetch;
  env: Env;
}

export const EMAIL_DOMAIN = 'staff.fieldsync.local'; // 로그인 ID → 가상 이메일 (Supabase Auth는 이메일 필수)
const BAN_FOREVER = '876000h'; // 100년

export type AdminReq =
  | {
    action: 'create';
    login_id: string;
    password: string;
    name: string;
    role: 'admin' | 'leader' | 'worker';
    team_id: string | null;
    lang: 'ko' | 'en' | 'vi';
  }
  | { action: 'reset_password'; user_id: string; password: string }
  | { action: 'deactivate' | 'activate'; user_id: string };

// 입력 검증(DB 제약과 동일 규칙). 실패 시 400
export function validate(b: Record<string, unknown>): AdminReq {
  const bad = (m: string): never => {
    throw new AppError(400, 'INVALID_INPUT', m);
  };
  const password = (): string => {
    const p = b.password;
    if (typeof p !== 'string' || p.length < 8 || new TextEncoder().encode(p).length > 72) {
      bad('비밀번호는 8자 이상(72바이트 이하)');
    }
    return p as string;
  };
  const userId = (): string => (isUuid(b.user_id) ? b.user_id : bad('user_id(uuid)가 필요합니다'));
  switch (b.action) {
    case 'create': {
      const login = typeof b.login_id === 'string' ? b.login_id.trim().toLowerCase() : '';
      if (!/^[a-z0-9_.-]{3,32}$/.test(login)) bad('로그인 ID는 영문 소문자·숫자·_.- 3~32자');
      const name = typeof b.name === 'string' ? b.name.trim() : '';
      if (name.length < 1 || name.length > 50) bad('이름은 1~50자');
      const role = b.role ?? 'worker';
      if (role !== 'admin' && role !== 'leader' && role !== 'worker') bad('role은 admin/leader/worker');
      const team = b.team_id ?? null;
      if (team !== null && !isUuid(team)) bad('team_id는 uuid 또는 null');
      const lang = b.lang ?? 'ko';
      if (lang !== 'ko' && lang !== 'en' && lang !== 'vi') bad('lang은 ko/en/vi');
      return { action: 'create', login_id: login, password: password(), name, role, team_id: team, lang } as AdminReq;
    }
    case 'reset_password':
      return { action: 'reset_password', user_id: userId(), password: password() };
    case 'deactivate':
    case 'activate':
      return { action: b.action, user_id: userId() };
    default:
      return bad('action은 create/reset_password/deactivate/activate');
  }
}

export async function handle(req: Request, d: Deps): Promise<Response> {
  try {
    const cfg = supaCfg(d.env);
    const jwt = bearer(req);
    const body = await readJson(req, 10_000);
    const caller = await callerOf(d.fetch, cfg, jwt);
    if (caller.role !== 'admin') throw new AppError(403, 'FORBIDDEN', '관리자 전용');
    const r = validate(body);
    const admin = `${cfg.url}/auth/v1/admin/users`;
    const sh = serviceHeaders(cfg);
    const rpc = (fn: string, args: Record<string, unknown>) =>
      call(d.fetch, `${cfg.url}/rest/v1/rpc/${fn}`, {
        method: 'POST',
        headers: userHeaders(cfg, jwt),
        body: JSON.stringify({ ...args, p_op_id: crypto.randomUUID() }),
      });

    if (r.action === 'create') {
      if (r.team_id) {
        const t = await call(d.fetch, `${cfg.url}/rest/v1/teams?id=eq.${r.team_id}&select=id`, {
          headers: userHeaders(cfg, jwt),
        });
        if (!Array.isArray(t.data) || t.data.length === 0) throw new AppError(400, 'INVALID_INPUT', '존재하지 않는 팀');
      }
      const c = await call(d.fetch, admin, {
        method: 'POST',
        headers: sh,
        body: JSON.stringify({
          email: `${r.login_id}@${EMAIL_DOMAIN}`,
          password: r.password,
          email_confirm: true,
          user_metadata: { login_id: r.login_id, name: r.name, lang: r.lang },
          app_metadata: { role: r.role, team_id: r.team_id }, // 등급은 app_metadata(서비스 키 전용)로만 전달
        }),
      });
      if (c.status === 422 && (c.data?.error_code === 'email_exists' || /already/i.test(JSON.stringify(c.data)))) {
        return json(200, { ok: false, code: 'LOGIN_ID_TAKEN' });
      }
      if ((c.status !== 200 && c.status !== 201) || !isUuid(c.data?.id)) {
        throw new AppError(502, 'AUTH_UPSTREAM', `계정 생성 실패(${c.status})`);
      }
      // 감사 로그: 누가 어떤 등급으로 만들었는지 role_change로 기록 (트리거가 이미 같은 등급으로 생성)
      await rpc('set_user_role', { p_user_id: c.data.id, p_role: r.role, p_team_id: r.team_id });
      return json(200, { ok: true, user_id: c.data.id });
    }

    if (r.action === 'reset_password') {
      const u = await call(d.fetch, `${admin}/${r.user_id}`, {
        method: 'PUT',
        headers: sh,
        body: JSON.stringify({ password: r.password }),
      });
      if (u.status === 404) return json(200, { ok: false, code: 'NOT_FOUND' });
      if (u.status !== 200) throw new AppError(502, 'AUTH_UPSTREAM', `비밀번호 변경 실패(${u.status})`);
      return json(200, { ok: true, user_id: r.user_id });
    }

    // 활성/비활성: DB 규칙(마지막 관리자·점유 중)을 먼저 적용하고, 통과 시 로그인 차단/해제
    const a = await rpc('set_user_active', { p_user_id: r.user_id, p_active: r.action === 'activate' });
    if (a.status !== 200) throw new AppError(502, 'DB_ERROR', `상태 변경 실패(${a.status})`);
    if (!a.data?.ok) return json(200, { ok: false, code: a.data?.code ?? 'UNKNOWN' });
    const ban = await call(d.fetch, `${admin}/${r.user_id}`, {
      method: 'PUT',
      headers: sh,
      body: JSON.stringify({ ban_duration: r.action === 'activate' ? 'none' : BAN_FOREVER }),
    });
    if (ban.status !== 200) return json(200, { ok: true, user_id: r.user_id, code: 'AUTH_BAN_PENDING' }); // DB상 차단은 이미 적용
    return json(200, { ok: true, user_id: r.user_id });
  } catch (e) {
    return errorResponse(e);
  }
}
