// path: supabase/functions/_tests/fake.ts
// deno-lint-ignore-file no-explicit-any -- 테스트: 외부 JSON 응답 형태를 느슨하게 검사
// 테스트용 가짜 fetch(라우팅 + 호출 기록)와 가짜 Supabase(인증·프로필·권한). 외부 의존성 없음.
import type { Env } from '../_shared/core.ts';

export interface Call {
  method: string;
  url: string;
  headers: Record<string, string>;
  body: any;
}
type Reply = Response | { status: number; body?: unknown };
export interface Route {
  method?: string;
  match: RegExp;
  reply: (url: string, call: Call) => Reply | Promise<Reply>;
}

export function fakeFetch(routes: Route[]) {
  const calls: Call[] = [];
  const f = async (url: string, init: RequestInit = {}): Promise<Response> => {
    const method = init.method ?? 'GET';
    const headers = Object.fromEntries(new Headers(init.headers).entries());
    let body: any = init.body ?? null;
    if (typeof body === 'string') {
      try {
        body = JSON.parse(body);
      } catch { /* 폼 인코딩 등은 문자열 그대로 */ }
    }
    const call = { method, url, headers, body };
    calls.push(call);
    const route = routes.find((r) => (!r.method || r.method === method) && r.match.test(url));
    if (!route) return new Response(JSON.stringify({ message: `no route ${method} ${url}` }), { status: 599 });
    const out = await route.reply(url, call);
    if (out instanceof Response) return out;
    return new Response(out.body === undefined ? null : JSON.stringify(out.body), { status: out.status }); // 204는 본문 null
  };
  return { f, calls };
}

export const SB = 'https://sb.test';
export const ID = {
  admin: '00000000-0000-0000-0000-0000000000aa',
  leader: '00000000-0000-0000-0000-0000000000b1',
  worker: '00000000-0000-0000-0000-0000000000c1',
  group: '00000000-0000-0000-0000-0000000000d1',
  team: '00000000-0000-0000-0000-0000000000a1',
};

export const baseEnv = (extra: Env = {}): Env => ({
  SUPABASE_URL: SB,
  SUPABASE_PUBLISHABLE_KEYS: JSON.stringify({ default: 'sb_publishable_test' }),
  SUPABASE_SECRET_KEYS: JSON.stringify({ default: 'sb_secret_test' }),
  ...extra,
});

// JWT "tok-admin" | "tok-leader" | "tok-worker" | "tok-inactive" → 사용자. 그 외는 401
const USERS: Record<string, { id: string; role: string; active: boolean; perms: string[] }> = {
  'tok-admin': { id: ID.admin, role: 'admin', active: true, perms: [] },
  'tok-leader': { id: ID.leader, role: 'leader', active: true, perms: ['site.create', 'site.edit'] },
  'tok-worker': { id: ID.worker, role: 'worker', active: true, perms: [] },
  'tok-inactive': { id: '00000000-0000-0000-0000-0000000000c4', role: 'worker', active: false, perms: [] },
};

export function supabaseAuthRoutes(): Route[] {
  const byToken = (c: Call) => USERS[(c.headers.authorization ?? '').replace('Bearer ', '')];
  return [
    {
      method: 'GET',
      match: /\/auth\/v1\/user$/,
      reply: (
        _u,
        c,
      ) => (byToken(c) ? { status: 200, body: { id: byToken(c).id } } : { status: 401, body: { msg: 'invalid JWT' } }),
    },
    {
      method: 'GET',
      match: /\/rest\/v1\/profiles\?/,
      reply: (_u, c) => ({
        status: 200,
        body: byToken(c) ? [{ role: byToken(c).role, active: byToken(c).active }] : [],
      }),
    },
    {
      method: 'GET',
      match: /\/rest\/v1\/role_permissions\?/,
      reply: (_u, c) => ({ status: 200, body: (byToken(c)?.perms ?? []).map((perm) => ({ perm })) }),
    },
  ];
}

export const req = (body: unknown, token: string | null = 'tok-admin', extra: Record<string, string> = {}): Request =>
  new Request('http://fn.test/', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}), ...extra },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
