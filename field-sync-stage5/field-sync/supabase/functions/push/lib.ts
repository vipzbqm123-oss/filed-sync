// path: supabase/functions/push/lib.ts
// FCM HTTP v1 순수 로직: 서비스 계정 JWT(RS256, WebCrypto) · 액세스 토큰 캐시 · 메시지 생성 · 오류 분류.
import { AppError, type Fetch } from '../_shared/core.ts';

export const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
export const GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token';
export const fcmSendUrl = (projectId: string): string =>
  `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

// ───────── base64url · PEM ─────────
export function b64url(input: string | ArrayBuffer | Uint8Array): string {
  const bytes = typeof input === 'string'
    ? new TextEncoder().encode(input)
    : input instanceof Uint8Array
    ? input
    : new Uint8Array(input);
  let bin = '';
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function pemToDer(pem: string): ArrayBuffer {
  const bin = atob(pem.replace(/-----[^-]+-----/g, '').replace(/\s+/g, ''));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}

// ───────── 서비스 계정 ─────────
export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  private_key_id?: string;
}

export function parseServiceAccount(raw: string | undefined): ServiceAccount {
  try {
    const sa = JSON.parse(raw ?? '');
    if (sa.project_id && sa.client_email && String(sa.private_key).includes('PRIVATE KEY')) return sa;
  } catch { /* 아래에서 처리 */ }
  throw new AppError(500, 'CONFIG', 'FCM_SERVICE_ACCOUNT(JSON) 확인 필요');
}

export async function signJwt(claims: Record<string, unknown>, privateKeyPem: string, kid?: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToDer(privateKeyPem),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const header = kid ? { alg: 'RS256', typ: 'JWT', kid } : { alg: 'RS256', typ: 'JWT' };
  const input = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(claims))}`;
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(input));
  return `${input}.${b64url(sig)}`;
}

export interface TokenCache {
  token?: string;
  exp?: number; // epoch 초
}

// 액세스 토큰(1시간)을 캐시해 호출마다 서명·교환하지 않음. 만료 60초 전 갱신
export async function accessToken(f: Fetch, sa: ServiceAccount, nowSec: number, cache: TokenCache): Promise<string> {
  if (cache.token && (cache.exp ?? 0) - 60 > nowSec) return cache.token;
  const assertion = await signJwt(
    { iss: sa.client_email, scope: FCM_SCOPE, aud: GOOGLE_TOKEN_URL, iat: nowSec, exp: nowSec + 3600 },
    sa.private_key,
    sa.private_key_id,
  );
  const r = await f(GOOGLE_TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=${encodeURIComponent('urn:ietf:params:oauth:grant-type:jwt-bearer')}&assertion=${assertion}`,
  });
  const body = await r.json().catch(() => ({}));
  if (r.status !== 200 || !body.access_token) throw new AppError(502, 'FCM_AUTH', `Google 토큰 발급 실패(${r.status})`);
  cache.token = body.access_token;
  cache.exp = nowSec + Number(body.expires_in ?? 3600);
  return body.access_token;
}

// ───────── 메시지 ─────────
export interface Notif {
  id: number;
  user_id: string;
  kind: string;
  title: string;
  body: string;
  data: Record<string, unknown> | null;
  collapse_key: string | null;
}

const HIGH = new Set(['urgent', 'escalate', 'force_release']);

// FCM v1 message. data 값은 모두 문자열이어야 함. apns-collapse-id는 64바이트 제한
export function buildMessage(n: Notif, token: string): Record<string, unknown> {
  const data: Record<string, string> = { kind: n.kind, notification_id: String(n.id) };
  for (const [k, v] of Object.entries(n.data ?? {})) {
    if (v !== null && v !== undefined) data[k] = typeof v === 'string' ? v : JSON.stringify(v);
  }
  const high = HIGH.has(n.kind);
  const collapse = n.collapse_key ? n.collapse_key.slice(0, 64) : undefined;
  return {
    message: {
      token,
      notification: { title: n.title, body: n.body },
      data,
      android: {
        priority: high ? 'high' : 'normal',
        ...(collapse ? { collapse_key: collapse } : {}),
        notification: {
          channel_id: n.kind === 'urgent' ? 'urgent' : 'default',
          ...(collapse ? { tag: collapse } : {}),
        },
      },
      apns: {
        headers: { 'apns-priority': high ? '10' : '5', ...(collapse ? { 'apns-collapse-id': collapse } : {}) },
        payload: { aps: { sound: 'default' } },
      },
    },
  };
}

export type SendOutcome = 'ok' | 'invalid_token' | 'retry' | 'fatal';

// FCM 오류 → 조치. 토큰 무효(삭제) / 일시 오류(재시도) / 요청 자체 오류(재시도 무의미)
// deno-lint-ignore no-explicit-any -- FCM 오류 JSON: 형태가 달라도 안전하게 분류
export function classify(status: number, body: any): SendOutcome {
  if (status === 200) return 'ok';
  const err = body?.error ?? {};
  const code: string | undefined = (err.details ?? []).find((d: { errorCode?: string }) => d?.errorCode)?.errorCode ??
    err.status;
  if (status === 404 || code === 'UNREGISTERED') return 'invalid_token';
  if (code === 'SENDER_ID_MISMATCH') return 'invalid_token';
  if (status === 400 || code === 'INVALID_ARGUMENT') {
    return /registration token/i.test(String(err.message ?? '')) ? 'invalid_token' : 'fatal';
  }
  return 'retry'; // 401(인증/APNs 설정)·429·500·503 등
}
