// path: supabase/functions/_tests/core.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AppError, bearer, inList, mapPool, readJson, safeEqual, serviceHeaders, supaCfg } from '../_shared/core.ts';

test('supaCfg: 새 키(JSON default) 우선, 없으면 레거시 키', () => {
  const n = supaCfg({
    SUPABASE_URL: 'https://x.co/',
    SUPABASE_PUBLISHABLE_KEYS: '{"default":"pub"}',
    SUPABASE_SECRET_KEYS: '{"default":"sec"}',
    SUPABASE_ANON_KEY: 'old',
  });
  assert.deepEqual(n, { url: 'https://x.co', publishable: 'pub', secret: 'sec' });
  const l = supaCfg({
    SUPABASE_URL: 'https://x.co',
    SUPABASE_ANON_KEY: 'eyJanon',
    SUPABASE_SERVICE_ROLE_KEY: 'eyJsvc',
  });
  assert.equal(l.secret, 'eyJsvc');
});

test('supaCfg: 누락·깨진 JSON → CONFIG(500)', () => {
  assert.throws(
    () => supaCfg({ SUPABASE_URL: 'https://x.co' }),
    (e: AppError) => e.code === 'CONFIG' && e.status === 500,
  );
  assert.throws(
    () => supaCfg({ SUPABASE_URL: 'https://x.co', SUPABASE_PUBLISHABLE_KEYS: '{bad', SUPABASE_SECRET_KEYS: '{bad' }),
    /누락/,
  );
});

test('serviceHeaders: 새 secret 키는 apikey만, 레거시 JWT 키는 Bearer도', () => {
  assert.equal(serviceHeaders({ url: '', publishable: '', secret: 'sb_secret_x' }).Authorization, undefined);
  assert.equal(serviceHeaders({ url: '', publishable: '', secret: 'eyJabc' }).Authorization, 'Bearer eyJabc');
});

test('inList: 따옴표·역슬래시 인용', () => {
  assert.equal(inList(['a', 'b"c', 'd\\e']), 'in.("a","b\\"c","d\\\\e")');
});

test('safeEqual: 길이·내용 비교', () => {
  assert.ok(safeEqual('s3cret', 's3cret'));
  assert.ok(!safeEqual('s3cret', 's3creT'));
  assert.ok(!safeEqual('s3cret', 's3cre'));
  assert.ok(!safeEqual('', 'x'));
});

test('mapPool: 순서 보존 + 동시 실행 수 제한', async () => {
  let active = 0;
  let peak = 0;
  const out = await mapPool([5, 1, 4, 2, 3], 2, async (x) => {
    active++;
    peak = Math.max(peak, active);
    await new Promise((r) => setTimeout(r, x));
    active--;
    return x * 10;
  });
  assert.deepEqual(out, [50, 10, 40, 20, 30]);
  assert.equal(peak, 2);
  assert.deepEqual(await mapPool([], 5, (x) => Promise.resolve(x)), []);
});

test('readJson: 메서드·크기·형식 검증', async () => {
  const mk = (body: string, method = 'POST') =>
    new Request('http://x/', { method, body: method === 'GET' ? undefined : body });
  assert.deepEqual(await readJson(mk('{"a":1}'), 100), { a: 1 });
  await assert.rejects(readJson(mk('', 'GET'), 100), (e: AppError) => e.status === 405);
  await assert.rejects(readJson(mk('{"a":"' + 'x'.repeat(200) + '"}'), 100), (e: AppError) => e.status === 413);
  await assert.rejects(readJson(mk('[1,2]'), 100), (e: AppError) => e.code === 'INVALID_INPUT');
  await assert.rejects(readJson(mk('{oops'), 100), (e: AppError) => e.code === 'INVALID_INPUT');
  await assert.rejects(readJson(mk('"' + '가'.repeat(10) + '"'), 30), (e: AppError) => e.status === 413); // 12자지만 32바이트 → 바이트 기준 제한
});

test('bearer: Authorization 헤더 파싱', () => {
  assert.equal(bearer(new Request('http://x/', { headers: { Authorization: 'Bearer abc.def' } })), 'abc.def');
  assert.throws(() => bearer(new Request('http://x/')), (e: AppError) => e.status === 401);
  assert.throws(
    () => bearer(new Request('http://x/', { headers: { Authorization: 'Basic abc' } })),
    (e: AppError) => e.status === 401,
  );
});
