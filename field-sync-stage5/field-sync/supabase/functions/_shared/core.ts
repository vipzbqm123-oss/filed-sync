// path: supabase/functions/_shared/core.ts
// Edge Function 공용 모듈: 환경설정 · HTTP 응답 · Supabase REST/Auth 최소 클라이언트 · 동시성 풀.
// 외부 패키지 없이 Web 표준 API(fetch, Response, crypto)만 사용 → Deno(Supabase)와 Node(테스트) 양쪽에서 실행.

export type Env = Record<string, string | undefined>;
export type Fetch = (input: string, init?: RequestInit) => Promise<Response>;

export class AppError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message = code) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

// ───────── 환경설정 ─────────
export interface SupaCfg {
  url: string;
  publishable: string; // 사용자 대리 호출용(apikey)
  secret: string; // 서버 권한(service_role) 호출용
}

// 새 키(SUPABASE_*_KEYS JSON의 default) 우선, 없으면 레거시 키 사용
export function supaCfg(env: Env): SupaCfg {
  const pick = (json?: string): string | undefined => {
    if (!json) return undefined;
    try {
      return JSON.parse(json).default;
    } catch {
      return undefined;
    }
  };
  const url = env.SUPABASE_URL?.replace(/\/+$/, '');
  const publishable = pick(env.SUPABASE_PUBLISHABLE_KEYS) ?? env.SUPABASE_ANON_KEY;
  const secret = pick(env.SUPABASE_SECRET_KEYS) ?? env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !publishable || !secret) throw new AppError(500, 'CONFIG', 'Supabase 환경변수 누락');
  return { url, publishable, secret };
}

export function requireEnv(env: Env, name: string): string {
  const v = env[name];
  if (!v) throw new AppError(500, 'CONFIG', `${name} 미설정`);
  return v;
}

// ───────── HTTP ─────────
export const json = (status: number, body: unknown): Response =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json; charset=utf-8' } });

export const errorResponse = (e: unknown): Response =>
  e instanceof AppError
    ? json(e.status, { code: e.code, message: e.message })
    : (console.error('[internal]', e), json(500, { code: 'INTERNAL', message: '서버 오류' })); // 상세는 서버 로그에만(응답 비노출)

export function bearer(req: Request): string {
  const m = /^Bearer\s+(\S+)$/i.exec(req.headers.get('Authorization') ?? '');
  if (!m) throw new AppError(401, 'UNAUTHORIZED', '로그인이 필요합니다');
  return m[1];
}

// 본문 크기 제한 후 JSON 파싱. O(본문 길이)
export async function readJson(req: Request, maxBytes: number): Promise<Record<string, unknown>> {
  if (req.method !== 'POST') throw new AppError(405, 'METHOD_NOT_ALLOWED');
  const text = await req.text();
  if (new TextEncoder().encode(text).length > maxBytes) {
    throw new AppError(413, 'TOO_LARGE', `요청은 ${maxBytes}바이트 이하`);
  }
  try {
    const v = JSON.parse(text);
    if (v && typeof v === 'object' && !Array.isArray(v)) return v as Record<string, unknown>;
  } catch { /* 아래에서 처리 */ }
  throw new AppError(400, 'INVALID_INPUT', 'JSON 객체 본문이 필요합니다');
}

export const isUuid = (v: unknown): v is string =>
  typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);

// 비밀값 비교: 내용과 무관하게 같은 시간(타이밍 공격 완화). 길이가 다르면 즉시 false. O(n)
export function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// ───────── Supabase REST / Auth ─────────
export const userHeaders = (cfg: SupaCfg, jwt: string): Record<string, string> => ({
  apikey: cfg.publishable,
  Authorization: `Bearer ${jwt}`,
  'Content-Type': 'application/json',
});

// 새 secret 키는 apikey 헤더로만 전달(Bearer로 보내면 JWT로 파싱돼 거부됨). 레거시 JWT 키는 둘 다.
export function serviceHeaders(cfg: SupaCfg): Record<string, string> {
  const h: Record<string, string> = { apikey: cfg.secret, 'Content-Type': 'application/json' };
  if (cfg.secret.startsWith('eyJ')) h.Authorization = `Bearer ${cfg.secret}`;
  return h;
}

export interface HttpResult {
  status: number;
  // deno-lint-ignore no-explicit-any -- 외부(PostgREST·Auth) JSON: 호출부에서 필드 존재를 검사
  data: any;
}

export async function call(f: Fetch, url: string, init: RequestInit): Promise<HttpResult> {
  const r = await f(url, init);
  const text = await r.text();
  let data: unknown = null;
  if (text) {
    try {
      data = JSON.parse(text);
    } catch {
      data = text;
    }
  }
  return { status: r.status, data };
}

// PostgREST in.() 필터용 값 인용
export const inList = (vals: string[]): string =>
  `in.(${vals.map((v) => `"${v.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`).join(',')})`;

// JWT를 Auth 서버에 검증 요청 → 사용자 id (무효·만료면 401)
export async function authUser(f: Fetch, cfg: SupaCfg, jwt: string): Promise<string> {
  const r = await call(f, `${cfg.url}/auth/v1/user`, { headers: userHeaders(cfg, jwt) });
  if (r.status !== 200 || !isUuid(r.data?.id)) throw new AppError(401, 'UNAUTHORIZED', '세션이 만료되었습니다');
  return r.data.id;
}

export interface Caller {
  id: string;
  role: 'admin' | 'leader' | 'worker';
  perms: Set<string>;
}

// 호출자 등급·권한 조회(사용자 JWT로 → RLS 적용). 비활성이면 403
export async function callerOf(f: Fetch, cfg: SupaCfg, jwt: string): Promise<Caller> {
  const id = await authUser(f, cfg, jwt);
  const h = userHeaders(cfg, jwt);
  const p = await call(f, `${cfg.url}/rest/v1/profiles?id=eq.${id}&select=role,active`, { headers: h });
  const prof = Array.isArray(p.data) ? p.data[0] : null;
  if (!prof || !prof.active) throw new AppError(403, 'FORBIDDEN', '비활성 계정');
  const perms = new Set<string>();
  if (prof.role !== 'admin') {
    const rp = await call(f, `${cfg.url}/rest/v1/role_permissions?role=eq.${prof.role}&select=perm`, { headers: h });
    for (const r of Array.isArray(rp.data) ? rp.data : []) perms.add(r.perm);
  }
  return { id, role: prof.role, perms };
}

export const can = (c: Caller, perm: string): boolean => c.role === 'admin' || c.perms.has(perm);

// ───────── 동시성 풀 ─────────
// 입력 순서를 보존하며 최대 limit개씩 병렬 실행. 호출 O(n), 동시 실행 ≤ limit
export async function mapPool<T, R>(items: T[], limit: number, fn: (x: T, i: number) => Promise<R>): Promise<R[]> {
  const out = new Array<R>(items.length);
  let next = 0;
  const worker = async (): Promise<void> => {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i], i);
    }
  };
  await Promise.all(Array.from({ length: Math.min(Math.max(1, limit), items.length) }, worker));
  return out;
}

export const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
