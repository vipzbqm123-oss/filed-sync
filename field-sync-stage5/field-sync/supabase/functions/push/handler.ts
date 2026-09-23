// path: supabase/functions/push/handler.ts
// POST /functions/v1/push (내부 전용: pg_cron/pg_net이 x-cron-secret 헤더로 호출, verify_jwt=false 배포)
// 알림 아웃박스를 원자적으로 선점(claim_push_batch) → 기기 토큰별 FCM 발송 → 결과 반영·무효 토큰 삭제.
import {
  AppError,
  call,
  type Env,
  errorResponse,
  type Fetch,
  inList,
  json,
  mapPool,
  requireEnv,
  safeEqual,
  serviceHeaders,
  supaCfg,
} from '../_shared/core.ts';
import {
  accessToken,
  buildMessage,
  classify,
  fcmSendUrl,
  type Notif,
  parseServiceAccount,
  type SendOutcome,
  type TokenCache,
} from './lib.ts';

export interface Deps {
  fetch: Fetch;
  env: Env;
  now?: () => number; // epoch ms (테스트 주입)
  cache?: TokenCache;
}

const moduleCache: TokenCache = {}; // 같은 isolate 재사용 시 토큰 재발급 생략
const BATCH = 500;
const FCM_CONCURRENCY = 10;

export async function handle(req: Request, d: Deps): Promise<Response> {
  try {
    if (req.method !== 'POST') throw new AppError(405, 'METHOD_NOT_ALLOWED');
    if (!safeEqual(req.headers.get('x-cron-secret') ?? '', requireEnv(d.env, 'CRON_SECRET'))) {
      throw new AppError(401, 'UNAUTHORIZED');
    }
    const cfg = supaCfg(d.env);
    const sa = parseServiceAccount(d.env.FCM_SERVICE_ACCOUNT);
    const now = d.now ?? Date.now;
    const h = serviceHeaders(cfg);

    // 1) 선점: 동시 실행돼도 같은 알림을 두 번 보내지 않음 (FOR UPDATE SKIP LOCKED + 2분 임대)
    const claim = await call(d.fetch, `${cfg.url}/rest/v1/rpc/claim_push_batch`, {
      method: 'POST',
      headers: h,
      body: JSON.stringify({ p_limit: BATCH }),
    });
    if (claim.status !== 200) throw new AppError(502, 'DB_ERROR', `선점 실패(${claim.status})`);
    const notifs: Notif[] = claim.data ?? [];
    if (notifs.length === 0) return json(200, { sent: 0, failed: 0, removed_tokens: 0 });

    // 2) 수신자 기기 토큰
    const users = [...new Set(notifs.map((n) => n.user_id))];
    const t = await call(
      d.fetch,
      `${cfg.url}/rest/v1/device_tokens?user_id=${
        encodeURIComponent(inList(users))
      }&notif_permission=is.true&select=token,user_id`,
      { headers: h },
    );
    const tokensOf = new Map<string, string[]>();
    for (const r of Array.isArray(t.data) ? t.data : []) {
      tokensOf.set(r.user_id, [...(tokensOf.get(r.user_id) ?? []), r.token]);
    }

    // 3) 발송 (알림×토큰, 동시 10). 복잡도 O(알림 × 기기)
    const bearerToken = await accessToken(d.fetch, sa, Math.floor(now() / 1000), d.cache ?? moduleCache);
    const jobs = notifs.flatMap((n) => (tokensOf.get(n.user_id) ?? []).map((token) => ({ n, token })));
    const outcomes = await mapPool(jobs, FCM_CONCURRENCY, async ({ n, token }) => {
      try {
        const r = await call(d.fetch, fcmSendUrl(sa.project_id), {
          method: 'POST',
          headers: { Authorization: `Bearer ${bearerToken}`, 'Content-Type': 'application/json' },
          body: JSON.stringify(buildMessage(n, token)),
        });
        return { n, token, o: classify(r.status, r.data), status: r.status };
      } catch {
        return { n, token, o: 'retry' as SendOutcome, status: 0 }; // 네트워크 오류
      }
    });

    // 4) 알림별 판정: 1대라도 성공=발송 / 재시도 대상 있음=대기 / 전부 무효·오류=종료(재시도 무의미)
    const byNotif = new Map<number, { o: SendOutcome; status: number }[]>();
    for (const x of outcomes) byNotif.set(x.n.id, [...(byNotif.get(x.n.id) ?? []), { o: x.o, status: x.status }]);
    const sentIds: number[] = [];
    const closed: { id: number; err: string }[] = [];
    const retry: { id: number; err: string }[] = [];
    for (const n of notifs) {
      const res = byNotif.get(n.id) ?? [];
      const firstRetry = res.find((r) => r.o === 'retry');
      if (res.some((r) => r.o === 'ok')) sentIds.push(n.id);
      else if (firstRetry) retry.push({ id: n.id, err: `RETRY:${firstRetry.status}` });
      else {
        const noDevice = res.length === 0 || res.every((r) => r.o === 'invalid_token');
        closed.push({ id: n.id, err: noDevice ? 'NO_DEVICE' : 'FATAL' });
      }
    }

    // 5) 결과 반영 (선점 시 attempts는 이미 +1, locked_at은 재시도 백오프 역할)
    const nowIso = new Date(now()).toISOString();
    const patch = (ids: number[], body: Record<string, unknown>) =>
      call(d.fetch, `${cfg.url}/rest/v1/notifications?id=in.(${ids.join(',')})`, {
        method: 'PATCH',
        headers: { ...h, Prefer: 'return=minimal' },
        body: JSON.stringify(body),
      });
    if (sentIds.length) await patch(sentIds, { sent_at: nowIso, last_error: null });
    for (const err of new Set(closed.map((c) => c.err))) {
      await patch(closed.filter((c) => c.err === err).map((c) => c.id), { sent_at: nowIso, last_error: err });
    }
    for (const err of new Set(retry.map((r) => r.err))) {
      await patch(retry.filter((r) => r.err === err).map((r) => r.id), { last_error: err });
    }
    const invalid = [...new Set(outcomes.filter((x) => x.o === 'invalid_token').map((x) => x.token))];
    if (invalid.length) {
      await call(d.fetch, `${cfg.url}/rest/v1/device_tokens?token=${encodeURIComponent(inList(invalid))}`, {
        method: 'DELETE',
        headers: { ...h, Prefer: 'return=minimal' },
      });
    }
    return json(200, {
      sent: sentIds.length,
      failed: retry.length,
      closed: closed.length,
      removed_tokens: invalid.length,
    });
  } catch (e) {
    return errorResponse(e);
  }
}
