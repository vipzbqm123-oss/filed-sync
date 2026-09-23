// path: supabase/functions/geocode/handler.ts
// POST /functions/v1/geocode
//   {mode:"search", query}          → {candidates}                      (관리자 주소 검색)
//   {mode:"import", group_id, csv}  → {inserted, duplicates, failed}    (CSV 일괄 등록)
// 카카오 REST 키는 서버에만 존재. 삽입은 호출자 JWT로 수행 → RLS가 최종 권한 판정.
import {
  AppError,
  bearer,
  call,
  callerOf,
  can,
  type Env,
  errorResponse,
  type Fetch,
  inList,
  isUuid,
  json,
  mapPool,
  readJson,
  requireEnv,
  supaCfg,
  userHeaders,
} from '../_shared/core.ts';
import { type Candidate, parseSiteRows, type RowIssue, searchAddress, type SiteRow } from './lib.ts';

export interface Deps {
  fetch: Fetch;
  env: Env;
  sleep?: (ms: number) => Promise<void>;
}

const KAKAO_CONCURRENCY = 5; // 카카오 초당 호출 제한 대비 보수적 동시 수(추정)
const IN_CHUNK = 100; // URL 길이 제한 대비 in.() 묶음 크기

export async function handle(req: Request, d: Deps): Promise<Response> {
  try {
    const cfg = supaCfg(d.env);
    const kakao = { fetch: d.fetch, key: requireEnv(d.env, 'KAKAO_REST_KEY'), sleep: d.sleep };
    const jwt = bearer(req);
    const body = await readJson(req, 1_000_000);
    const caller = await callerOf(d.fetch, cfg, jwt);
    if (!can(caller, 'site.create') && !can(caller, 'site.edit')) {
      throw new AppError(403, 'FORBIDDEN', '현장 등록 권한이 없습니다'); // 카카오 쿼터 낭비 방지용 사전 차단
    }

    if (body.mode === 'search') {
      const q = typeof body.query === 'string' ? body.query.trim() : '';
      if (q.length < 2 || q.length > 100) throw new AppError(400, 'INVALID_INPUT', '검색어는 2~100자');
      return json(200, { candidates: (await searchAddress(kakao, q, false)).slice(0, 10) });
    }
    if (body.mode !== 'import') throw new AppError(400, 'INVALID_INPUT', 'mode는 search 또는 import');
    if (!isUuid(body.group_id) || typeof body.csv !== 'string') {
      throw new AppError(400, 'INVALID_INPUT', 'group_id(uuid)와 csv(문자열)가 필요합니다');
    }
    if (!can(caller, 'site.create')) throw new AppError(403, 'FORBIDDEN', '현장 등록 권한이 없습니다');

    const h = userHeaders(cfg, jwt);
    const g = await call(d.fetch, `${cfg.url}/rest/v1/site_groups?id=eq.${body.group_id}&select=id,published`, {
      headers: h,
    });
    const group = Array.isArray(g.data) ? g.data[0] : null;
    if (!group) throw new AppError(404, 'NOT_FOUND', '묶음을 찾을 수 없습니다');
    if (group.published && caller.role !== 'admin') {
      throw new AppError(403, 'FORBIDDEN', '배포된 묶음에는 관리자만 추가할 수 있습니다');
    }

    const { rows, errors } = parseSiteRows(body.csv);
    const failed: RowIssue[] = [...errors];
    const duplicates: RowIssue[] = [];

    // 1) 좌표 변환 (정확 일치, 후보가 2개 이상이면 모호로 실패 처리)
    const geo = await mapPool(rows, KAKAO_CONCURRENCY, async (r): Promise<[SiteRow, Candidate] | null> => {
      try {
        const c = await searchAddress(kakao, r.address, true);
        if (c.length === 0) failed.push({ row: r.row, reason: '주소를 찾을 수 없습니다' });
        else if (c.length > 1) failed.push({ row: r.row, reason: `후보 ${c.length}개 — 번지까지 정확히 입력하세요` });
        else return [r, c[0]];
      } catch (e) {
        if (e instanceof AppError && e.code === 'KAKAO_AUTH') throw e; // 설정 오류 → 전체 중단
        failed.push({ row: r.row, reason: e instanceof AppError ? e.message : '좌표 변환 실패' });
      }
      return null;
    });

    // 2) 파일 내 중복 제거 (같은 지번+세부)
    const seen = new Map<string, number>();
    const ready: [SiteRow, Candidate][] = [];
    for (const item of geo) {
      if (!item) continue;
      const [r, c] = item;
      const k = `${c.jibun_key ?? c.jibun}|${r.unit}`;
      const first = seen.get(k);
      if (first !== undefined) duplicates.push({ row: r.row, reason: `파일 ${first}행과 같은 현장` });
      else {
        seen.set(k, r.row);
        ready.push(item);
      }
    }

    // 3) DB 활성 현장과 중복 확인 (편집 권한자는 RLS상 전체 조회 가능). O(n/100) 요청
    const active = new Set<string>();
    const keys = [...new Set(ready.map(([, c]) => c.jibun_key).filter((k): k is string => !!k))];
    for (let i = 0; i < keys.length; i += IN_CHUNK) {
      const q = `jibun_key=${
        encodeURIComponent(inList(keys.slice(i, i + IN_CHUNK)))
      }&archived=is.false&status=neq.done&select=jibun_key,unit`;
      const r = await call(d.fetch, `${cfg.url}/rest/v1/sites?${q}`, { headers: h });
      for (const s of Array.isArray(r.data) ? r.data : []) active.add(`${s.jibun_key}|${s.unit}`);
    }
    const toInsert = ready.filter(([r, c]) => {
      if (c.jibun_key && active.has(`${c.jibun_key}|${r.unit}`)) {
        duplicates.push({ row: r.row, reason: '이미 등록된 활성 현장' });
        return false;
      }
      return true;
    });

    // 4) 순서(seq)는 묶음의 마지막 다음부터, CSV 순서 유지
    const last = await call(
      d.fetch,
      `${cfg.url}/rest/v1/sites?group_id=eq.${group.id}&select=seq&order=seq.desc&limit=1`,
      { headers: h },
    );
    const base = (Array.isArray(last.data) && last.data[0]?.seq) || 0;
    const records = toInsert.map(([r, c], i) => ({
      group_id: group.id,
      seq: base + i + 1,
      label: r.label,
      bunji: c.bunji,
      jibun: c.jibun,
      road: c.road,
      unit: r.unit,
      note: r.memo,
      lat: c.lat,
      lng: c.lng,
      b_code: c.b_code,
      jibun_key: c.jibun_key,
    }));

    // 5) 일괄 삽입 → 경합으로 중복(409) 발생 시에만 행 단위 재시도
    let inserted = 0;
    if (records.length > 0) {
      const ins = { method: 'POST', headers: { ...h, Prefer: 'return=minimal' } };
      const bulk = await call(d.fetch, `${cfg.url}/rest/v1/sites`, { ...ins, body: JSON.stringify(records) });
      if (bulk.status === 201) inserted = records.length;
      else if (bulk.status === 403) throw new AppError(403, 'FORBIDDEN', '등록 권한이 없습니다');
      else if (bulk.status === 409) {
        for (let i = 0; i < records.length; i++) {
          const one = await call(d.fetch, `${cfg.url}/rest/v1/sites`, { ...ins, body: JSON.stringify(records[i]) });
          if (one.status === 201) inserted++;
          else if (one.status === 409) duplicates.push({ row: toInsert[i][0].row, reason: '이미 등록된 활성 현장' });
          else failed.push({ row: toInsert[i][0].row, reason: `저장 실패(${one.status})` });
        }
      } else throw new AppError(502, 'DB_ERROR', `저장 실패(${bulk.status})`);
    }

    const byRow = (a: RowIssue, b: RowIssue) => a.row - b.row;
    return json(200, { inserted, duplicates: duplicates.sort(byRow), failed: failed.sort(byRow) });
  } catch (e) {
    return errorResponse(e);
  }
}
