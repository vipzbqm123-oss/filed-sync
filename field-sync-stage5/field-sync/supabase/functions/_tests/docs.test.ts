// path: supabase/functions/_tests/docs.test.ts
// 문서 예시 = 실제 동작(C9): USER_GUIDE.md의 CSV 예시를 실제 파서(parseSiteRows)로 읽어 설명과 같은지 확인
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseSiteRows } from '../geocode/lib.ts';

const guide = readFileSync(new URL('../../../USER_GUIDE.md', import.meta.url), 'utf8');

test('USER_GUIDE CSV 예시: 3곳 · 행 번호 2~4 · 구분 없는 행 · 따옴표 안 쉼표 유지 · 오류 없음', () => {
  const m = /```csv\n([\s\S]*?)```/.exec(guide);
  assert.ok(m, 'USER_GUIDE.md에 ```csv 예시가 있어야 함');
  const { rows, errors } = parseSiteRows(m[1]);
  assert.deepEqual(errors, []);
  assert.deepEqual(rows.map((r) => [r.row, r.label, r.unit, r.memo]), [
    [2, 'A-1', '', '정문 옆 계량기'],
    [3, 'A-2', 'B동 계량기#2', null],
    [4, null, '', '주차장 안쪽, 경비실 문의'],
  ]);
  assert.equal(rows[0].address, '서울 성동구 성수동1가 685-12');
});

test('USER_GUIDE 열 제목 표의 별칭이 모두 설명대로 해석됨(주소·구분·세부·메모)', () => {
  const table = guide.slice(guide.indexOf('| 열 제목'), guide.indexOf('예시(3곳'));
  const fields = ['address', 'label', 'unit', 'memo'] as const; // 표의 행 순서
  const lines = table.split('\n').filter((l) => l.startsWith('| `'));
  assert.equal(lines.length, 4);
  let n = 0;
  lines.forEach((line, i) => {
    for (const [, alias] of line.split('|')[1].matchAll(/`([^`]+)`/g)) {
      const csv = fields[i] === 'address' ? `${alias}\n서울 테스트구 1\n` : `주소,${alias}\n서울 테스트구 1,X\n`;
      const { rows } = parseSiteRows(csv);
      assert.equal(rows.length, 1, alias);
      assert.equal(
        fields[i] === 'address' ? rows[0].address : rows[0][fields[i]],
        fields[i] === 'address' ? '서울 테스트구 1' : 'X',
        alias,
      );
      n++;
    }
  });
  assert.equal(n, 13);
  assert.throws(() => parseSiteRows('번지\n1\n'), /address/); // 주소 열이 없으면 거절
});
