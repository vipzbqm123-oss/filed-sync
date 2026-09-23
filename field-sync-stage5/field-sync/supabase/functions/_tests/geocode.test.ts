// path: supabase/functions/_tests/geocode.test.ts
// deno-lint-ignore-file no-explicit-any -- 테스트: 외부 JSON 응답 형태를 느슨하게 검사
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AppError } from '../_shared/core.ts';
import { parseCsv, parseSiteRows, searchAddress, toCandidate } from '../geocode/lib.ts';
import { handle } from '../geocode/handler.ts';
import { baseEnv, fakeFetch, ID, req, type Route, SB, supabaseAuthRoutes } from './fake.ts';

// 카카오 document 생성기 (응답 명세의 필드명 그대로)
const kdoc = (
  o: {
    dong?: string;
    main: string;
    sub?: string;
    m?: 'Y' | 'N';
    b?: string;
    lat?: number;
    lng?: number;
    road?: string;
  },
) => ({
  address_name: `서울 성동구 ${o.dong ?? '성수동1가'} ${o.m === 'Y' ? '산' : ''}${o.main}${o.sub ? '-' + o.sub : ''}`,
  address_type: 'REGION_ADDR',
  x: String(o.lng ?? 127.0557),
  y: String(o.lat ?? 37.5446),
  address: {
    address_name: `서울 성동구 ${o.dong ?? '성수동1가'} ${o.m === 'Y' ? '산' : ''}${o.main}${o.sub ? '-' + o.sub : ''}`,
    region_3depth_name: o.dong ?? '성수동1가',
    b_code: o.b ?? '1120011400',
    mountain_yn: o.m ?? 'N',
    main_address_no: o.main,
    sub_address_no: o.sub ?? '',
  },
  road_address: o.road ? { address_name: o.road } : null,
});
const kakaoOk = (docs: unknown[]) => ({ status: 200, body: { meta: { total_count: docs.length }, documents: docs } });

// ───────── CSV ─────────
test('parseCsv: 따옴표 안 쉼표·줄바꿈·"" 이스케이프·CRLF·BOM', () => {
  const t = '﻿a,b\r\n"x, y","say ""hi"""\n"multi\nline",z\n';
  assert.deepEqual(parseCsv(t), [['a', 'b'], ['x, y', 'say "hi"'], ['multi\nline', 'z']]);
  assert.deepEqual(parseCsv('a,b'), [['a', 'b']]); // 마지막 줄바꿈 없음
  assert.deepEqual(parseCsv('a,,c\n'), [['a', '', 'c']]); // 빈 칸
  assert.deepEqual(parseCsv(''), []);
  assert.throws(() => parseCsv('"open,x\n'), (e: AppError) => e.code === 'INVALID_CSV');
});

test('parseSiteRows: 한글 헤더·빈 줄 무시·행 번호·길이 제한', () => {
  const { rows, errors } = parseSiteRows(
    '구분,주소,세부,메모\nA-01, 서울 성동구 성수동1가 685-12 ,B동,비번 1234\n\n,,,\nA-02,,x,\nA-03,서울 성동구 아차산로 17,' +
      'u'.repeat(101) + ',\n',
  );
  assert.deepEqual(rows, [{
    row: 2,
    label: 'A-01',
    address: '서울 성동구 성수동1가 685-12',
    unit: 'B동',
    memo: '비번 1234',
  }]);
  assert.deepEqual(errors, [{ row: 5, reason: '주소가 비어 있습니다' }, { row: 6, reason: 'unit는 100자 이하' }]);
});

test('parseSiteRows: 주소 열 없음·빈 파일·행 수 초과 → INVALID_CSV', () => {
  assert.throws(() => parseSiteRows('label,unit\na,b'), /주소/);
  assert.throws(() => parseSiteRows('\n\n'), /빈 파일/);
  assert.throws(() => parseSiteRows('address\n' + 'x\n'.repeat(4), 3), /최대 3행/);
  assert.equal(parseSiteRows('address\n' + 'x\n'.repeat(3), 3).rows.length, 3); // 경계: 정확히 한도
});

// ───────── 카카오 응답 변환 ─────────
test('toCandidate: 번지 표기·jibun_key·산 번지·부번 없음', () => {
  assert.deepEqual(toCandidate(kdoc({ main: '685', sub: '12', road: '서울 성동구 아차산로 17' })), {
    bunji: '성수동1가 685-12',
    jibun: '서울 성동구 성수동1가 685-12',
    road: '서울 성동구 아차산로 17',
    lat: 37.5446,
    lng: 127.0557,
    b_code: '1120011400',
    jibun_key: '1120011400|0|685|12',
  });
  const m = toCandidate(kdoc({ main: '3', m: 'Y' }))!;
  assert.equal(m.bunji, '성수동1가 산3');
  assert.equal(m.jibun_key, '1120011400|1|3|0');
  assert.equal(toCandidate(kdoc({ main: '700', sub: '0' }))!.bunji, '성수동1가 700');
});

test('toCandidate: 지역 단위(본번 없음)·국외 좌표·b_code 없음', () => {
  assert.equal(toCandidate(kdoc({ main: '' })), null);
  assert.equal(toCandidate(kdoc({ main: '1', lat: 10 })), null);
  assert.equal(toCandidate({ x: '127', y: '37' }), null);
  assert.equal(toCandidate(kdoc({ main: '1', b: '' }))!.jibun_key, null);
});

test('searchAddress: 헤더·인코딩·중복 제거', async () => {
  const { f, calls } = fakeFetch([{
    match: /dapi\.kakao\.com/,
    reply: () => kakaoOk([kdoc({ main: '685', sub: '12' }), kdoc({ main: '685', sub: '12' }), kdoc({ main: '' })]),
  }]);
  const c = await searchAddress({ fetch: f, key: 'K' }, '성수동 685-12', true);
  assert.equal(c.length, 1);
  assert.equal(calls[0].headers.authorization, 'KakaoAK K');
  assert.match(calls[0].url, /query=%EC%84%B1%EC%88%98%EB%8F%99%20685-12&size=10&analyze_type=exact$/);
});

test('searchAddress: 429 → 백오프 재시도 후 성공 / 3회 연속이면 KAKAO_QUOTA / 401 → KAKAO_AUTH', async () => {
  let n = 0;
  const waits: number[] = [];
  const sleep = (ms: number) => {
    waits.push(ms);
    return Promise.resolve();
  };
  const flaky = fakeFetch([{
    match: /kakao/,
    reply: () => (++n < 3 ? { status: 429, body: { code: -10 } } : kakaoOk([kdoc({ main: '1' })])),
  }]);
  assert.equal((await searchAddress({ fetch: flaky.f, key: 'K', sleep }, 'q1', false)).length, 1);
  assert.deepEqual(waits, [200, 400]);
  const quota = fakeFetch([{ match: /kakao/, reply: () => ({ status: 429, body: { code: -10 } }) }]);
  await assert.rejects(
    searchAddress({ fetch: quota.f, key: 'K', sleep }, 'q', false),
    (e: AppError) => e.code === 'KAKAO_QUOTA',
  );
  assert.equal(quota.calls.length, 3);
  const auth = fakeFetch([{ match: /kakao/, reply: () => ({ status: 401, body: { code: -401 } }) }]);
  await assert.rejects(
    searchAddress({ fetch: auth.f, key: 'K', sleep }, 'q', false),
    (e: AppError) => e.code === 'KAKAO_AUTH',
  );
});

// ───────── 핸들러 통합 흐름 ─────────
const env = baseEnv({ KAKAO_REST_KEY: 'kakao-key' });

// 주소별 카카오 응답: "없음" → 0건, "모호" → 2건, 그 외 번지 숫자로 1건
function kakaoByQuery(): Route {
  return {
    match: /dapi\.kakao\.com/,
    reply: (u) => {
      const q = decodeURIComponent(new URL(u).searchParams.get('query') ?? '');
      if (q.includes('없음')) return kakaoOk([]);
      if (q.includes('모호')) return kakaoOk([kdoc({ main: '1' }), kdoc({ main: '2' })]);
      const [main, sub] = (q.match(/(\d+)(?:-(\d+))?\s*$/) ?? []).slice(1);
      return kakaoOk([kdoc({ main, sub })]);
    },
  };
}

function importRoutes(
  opts: { published?: boolean; existing?: string[]; insertStatus?: number; oneStatus?: (b: any) => number } = {},
): Route[] {
  return [
    ...supabaseAuthRoutes(),
    kakaoByQuery(),
    {
      method: 'GET',
      match: /\/rest\/v1\/site_groups\?id=eq\./,
      reply: (u) => ({
        status: 200,
        body: u.includes(ID.group) ? [{ id: ID.group, published: !!opts.published }] : [],
      }),
    },
    {
      method: 'GET',
      match: /\/rest\/v1\/sites\?jibun_key=/,
      reply: () => ({ status: 200, body: (opts.existing ?? []).map((k) => ({ jibun_key: k, unit: '' })) }),
    },
    { method: 'GET', match: /\/rest\/v1\/sites\?group_id=/, reply: () => ({ status: 200, body: [{ seq: 7 }] }) },
    {
      method: 'POST',
      match: /\/rest\/v1\/sites$/,
      reply: (_u, c) => ({
        status: Array.isArray(c.body) ? (opts.insertStatus ?? 201) : (opts.oneStatus?.(c.body) ?? 201),
      }),
    },
  ];
}

test('geocode 인증: 토큰 없음 401 / 만료 401 / 권한 없는 작업자 403(카카오 미호출)', async () => {
  const { f, calls } = fakeFetch(importRoutes());
  assert.equal((await handle(req({ mode: 'search', query: '성수동' }, null), { fetch: f, env })).status, 401);
  assert.equal((await handle(req({ mode: 'search', query: '성수동' }, 'tok-expired'), { fetch: f, env })).status, 401);
  const r = await handle(req({ mode: 'search', query: '성수동' }, 'tok-worker'), { fetch: f, env });
  assert.equal(r.status, 403);
  assert.equal(calls.filter((c) => c.url.includes('kakao')).length, 0);
  assert.equal((await handle(req({ mode: 'search', query: '성수동' }, 'tok-inactive'), { fetch: f, env })).status, 403);
});

test('geocode 설정 누락 → 500 CONFIG (키 값은 응답에 노출 안 함)', async () => {
  const { f } = fakeFetch(importRoutes());
  const r = await handle(req({ mode: 'search', query: '성수동' }), { fetch: f, env: baseEnv() });
  assert.equal(r.status, 500);
  assert.deepEqual(await r.json(), { code: 'CONFIG', message: 'KAKAO_REST_KEY 미설정' });
});

test('geocode search: 후보 반환 / 검색어 검증', async () => {
  const { f } = fakeFetch(importRoutes());
  const r = await handle(req({ mode: 'search', query: '성수동1가 685-12' }, 'tok-leader'), { fetch: f, env });
  assert.equal(r.status, 200);
  assert.equal((await r.json()).candidates[0].bunji, '성수동1가 685-12');
  assert.equal((await handle(req({ mode: 'search', query: 'a' }), { fetch: f, env })).status, 400);
  assert.equal((await handle(req({ mode: 'nope' }), { fetch: f, env })).status, 400);
});

test('geocode import: 성공·실패·파일 내 중복·DB 중복 분류 + seq 이어붙이기 + 사용자 JWT로 삽입', async () => {
  const csv = [
    'label,address,unit,memo',
    'A1,서울 성동구 성수동1가 685-12,,', // 2행 삽입
    'A2,없음 동 1,,', // 3행 실패: 없음
    'A3,모호 동,,', // 4행 실패: 모호
    'A4,서울 성동구 성수동1가 685-12,,', // 5행 파일 내 중복(2행)
    'A5,서울 성동구 성수동1가 686-3,,', // 6행 DB 활성 중복
    'A6,서울 성동구 성수동1가 690-1,B동,', // 7행 삽입
    'A7,,,', // 8행 주소 없음
  ].join('\n');
  const { f, calls } = fakeFetch(importRoutes({ existing: ['1120011400|0|686|3'] }));
  const r = await handle(req({ mode: 'import', group_id: ID.group, csv }, 'tok-leader'), { fetch: f, env });
  assert.equal(r.status, 200);
  const body = await r.json();
  assert.equal(body.inserted, 2);
  assert.deepEqual(body.duplicates.map((d: any) => d.row), [5, 6]);
  assert.deepEqual(body.failed.map((d: any) => [d.row, d.reason]), [
    [3, '주소를 찾을 수 없습니다'],
    [4, '후보 2개 — 번지까지 정확히 입력하세요'],
    [8, '주소가 비어 있습니다'],
  ]);
  const ins = calls.find((c) => c.method === 'POST' && c.url.endsWith('/rest/v1/sites'))!;
  assert.equal(ins.headers.authorization, 'Bearer tok-leader'); // RLS 적용되는 사용자 권한
  assert.equal(ins.headers.apikey, 'sb_publishable_test');
  assert.deepEqual(ins.body.map((x: any) => [x.seq, x.bunji, x.unit, x.label]), [[8, '성수동1가 685-12', '', 'A1'], [
    9,
    '성수동1가 690-1',
    'B동',
    'A6',
  ]]);
  assert.deepEqual(Object.keys(ins.body[0]).sort(), [
    'b_code',
    'bunji',
    'group_id',
    'jibun',
    'jibun_key',
    'label',
    'lat',
    'lng',
    'note',
    'road',
    'seq',
    'unit',
  ]);
});

test('geocode import: 경합으로 일괄 삽입 409 → 행 단위 재시도', async () => {
  const csv = 'address\n서울 성수동1가 1\n서울 성수동1가 2\n';
  const { f } = fakeFetch(importRoutes({ insertStatus: 409, oneStatus: (b) => (b.bunji.endsWith(' 2') ? 409 : 201) }));
  const body = await (await handle(req({ mode: 'import', group_id: ID.group, csv }, 'tok-admin'), { fetch: f, env }))
    .json();
  assert.equal(body.inserted, 1);
  assert.deepEqual(body.duplicates, [{ row: 3, reason: '이미 등록된 활성 현장' }]);
});

test('geocode import: 배포 묶음(비관리자) 403 / 없는 묶음 404 / 잘못된 입력 400 / CSV 오류 400', async () => {
  const pub = fakeFetch(importRoutes({ published: true }));
  assert.equal(
    (await handle(req({ mode: 'import', group_id: ID.group, csv: 'address\nx 1' }, 'tok-leader'), {
      fetch: pub.f,
      env,
    })).status,
    403,
  );
  assert.equal(pub.calls.filter((c) => c.url.includes('kakao')).length, 0); // 사전 차단 → 쿼터 미사용
  assert.equal(
    (await handle(req({ mode: 'import', group_id: ID.group, csv: 'address\nx 1' }, 'tok-admin'), { fetch: pub.f, env }))
      .status,
    200,
  );
  const { f } = fakeFetch(importRoutes());
  assert.equal(
    (await handle(req({ mode: 'import', group_id: '00000000-0000-0000-0000-000000000999', csv: 'address\nx 1' }), {
      fetch: f,
      env,
    })).status,
    404,
  );
  assert.equal((await handle(req({ mode: 'import', group_id: 'not-uuid', csv: 'x' }), { fetch: f, env })).status, 400);
  const bad = await handle(req({ mode: 'import', group_id: ID.group, csv: 'label\nx' }), { fetch: f, env });
  assert.equal(bad.status, 400);
  assert.equal((await bad.json()).code, 'INVALID_CSV');
});

test('geocode import: 카카오 키 오류는 전체 중단 502 / 한도 초과는 해당 행만 실패', async () => {
  const authFail = fakeFetch([...importRoutes().filter((r) => !String(r.match).includes('kakao')), {
    match: /kakao/,
    reply: () => ({ status: 401 }),
  }]);
  const r = await handle(req({ mode: 'import', group_id: ID.group, csv: 'address\nx 1\nx 2' }), {
    fetch: authFail.f,
    env,
  });
  assert.equal(r.status, 502);
  assert.equal((await r.json()).code, 'KAKAO_AUTH');
  const quota = fakeFetch([...importRoutes().filter((r) => !String(r.match).includes('kakao')), {
    match: /kakao/,
    reply: () => ({ status: 429 }),
  }]);
  const q = await (await handle(req({ mode: 'import', group_id: ID.group, csv: 'address\nx 1' }), {
    fetch: quota.f,
    env,
    sleep: async () => {},
  })).json();
  assert.deepEqual(q, { inserted: 0, duplicates: [], failed: [{ row: 2, reason: '카카오 호출 한도 초과' }] });
});

test('geocode import: 빈 결과(모두 실패)면 DB 삽입 호출 없음', async () => {
  const { f, calls } = fakeFetch(importRoutes());
  const body =
    await (await handle(req({ mode: 'import', group_id: ID.group, csv: 'address\n없음 1' }), { fetch: f, env })).json();
  assert.equal(body.inserted, 0);
  assert.equal(calls.filter((c) => c.method === 'POST' && c.url.startsWith(SB)).length, 0);
});
