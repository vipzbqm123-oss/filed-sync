// path: supabase/functions/geocode/lib.ts
// 순수 로직: CSV 파싱 · 현장 행 검증 · 카카오 주소 검색 응답 → 후보 변환.
import { AppError, type Fetch, sleep as realSleep } from '../_shared/core.ts';

// ───────── CSV (RFC 4180) ─────────
// BOM·CRLF/LF·따옴표 안의 쉼표/줄바꿈·"" 이스케이프 처리. O(문자 수)
export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let quoted = false;
  let i = text.charCodeAt(0) === 0xfeff ? 1 : 0;
  for (; i < text.length; i++) {
    const c = text[i];
    if (quoted) {
      if (c !== '"') field += c;
      else if (text[i + 1] === '"') {
        field += '"';
        i++;
      } else quoted = false;
    } else if (c === '"' && field === '') quoted = true;
    else if (c === ',') {
      row.push(field);
      field = '';
    } else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i++;
      row.push(field);
      rows.push(row);
      row = [];
      field = '';
    } else field += c;
  }
  if (quoted) throw new AppError(400, 'INVALID_CSV', '닫히지 않은 따옴표가 있습니다');
  if (field !== '' || row.length > 0) {
    row.push(field);
    rows.push(row);
  }
  return rows;
}

export interface SiteRow {
  row: number; // CSV 행 번호(헤더 = 1)
  label: string | null;
  address: string;
  unit: string;
  memo: string | null;
}
export interface RowIssue {
  row: number;
  reason: string;
}

const HEADER_ALIASES: Record<string, keyof Omit<SiteRow, 'row'>> = {
  label: 'label',
  '라벨': 'label',
  '이름': 'label',
  '구분': 'label',
  address: 'address',
  '주소': 'address',
  unit: 'unit',
  '세부': 'unit',
  '상세': 'unit',
  memo: 'memo',
  note: 'memo',
  '메모': 'memo',
  '비고': 'memo',
};
const LIMITS = { label: 50, address: 200, unit: 100, memo: 500 } as const;

// 헤더 매핑 + 행 검증(DB 제약과 동일한 길이 제한). 빈 줄은 건너뜀. O(행 수 × 열 수)
export function parseSiteRows(text: string, maxRows = 1000): { rows: SiteRow[]; errors: RowIssue[] } {
  const blank = (r: string[]) => r.every((c) => c.trim() === '');
  const table = parseCsv(text);
  const h = table.findIndex((r) => !blank(r)); // 첫 비어있지 않은 행 = 헤더
  if (h < 0) throw new AppError(400, 'INVALID_CSV', '빈 파일입니다');
  const header = table[h].map((c) => HEADER_ALIASES[c.trim().toLowerCase()]);
  if (!header.includes('address')) throw new AppError(400, 'INVALID_CSV', 'address(주소) 열이 필요합니다');
  if (table.slice(h + 1).filter((r) => !blank(r)).length > maxRows) {
    throw new AppError(400, 'INVALID_CSV', `한 번에 최대 ${maxRows}행까지 올릴 수 있습니다`);
  }

  const rows: SiteRow[] = [];
  const errors: RowIssue[] = [];
  for (let r = h + 1; r < table.length; r++) { // 행 번호는 빈 줄 포함 원본 기준(엑셀과 일치)
    if (blank(table[r])) continue;
    const v: Record<string, string> = { label: '', address: '', unit: '', memo: '' };
    header.forEach((key, c) => {
      if (key) v[key] = (table[r][c] ?? '').trim();
    });
    const row = r + 1;
    const tooLong = (Object.keys(LIMITS) as (keyof typeof LIMITS)[]).find((k) => v[k].length > LIMITS[k]);
    if (!v.address) errors.push({ row, reason: '주소가 비어 있습니다' });
    else if (tooLong) errors.push({ row, reason: `${tooLong}는 ${LIMITS[tooLong]}자 이하` });
    else rows.push({ row, label: v.label || null, address: v.address, unit: v.unit, memo: v.memo || null });
  }
  return { rows, errors };
}

// ───────── 카카오 로컬: 주소 검색 ─────────
export interface Candidate {
  bunji: string; // "성수동1가 685-12"
  jibun: string; // 지번 전체
  road: string | null;
  lat: number;
  lng: number;
  b_code: string | null;
  jibun_key: string | null; // b_code|산(0/1)|본번|부번 → DB 등록 중복 방지 키
}

// 카카오 document → 후보. 지번(본번)이 없는 지역 단위 결과·국외 좌표는 제외
// deno-lint-ignore no-explicit-any -- 카카오 응답 JSON: 필드 존재를 아래에서 검사
export function toCandidate(doc: any): Candidate | null {
  const a = doc?.address;
  if (!a?.main_address_no || !a.address_name) return null;
  const lat = Number(doc.y ?? a.y);
  const lng = Number(doc.x ?? a.x);
  if (!(lat >= 33 && lat <= 39 && lng >= 124 && lng <= 132)) return null;
  const mountain = a.mountain_yn === 'Y';
  const sub = a.sub_address_no && a.sub_address_no !== '0' ? String(a.sub_address_no) : '';
  const lot = `${mountain ? '산' : ''}${a.main_address_no}${sub ? `-${sub}` : ''}`;
  return {
    bunji: [a.region_3depth_name, lot].filter(Boolean).join(' '),
    jibun: a.address_name,
    road: doc.road_address?.address_name || null,
    lat,
    lng,
    b_code: a.b_code || null,
    jibun_key: a.b_code ? `${a.b_code}|${mountain ? 1 : 0}|${a.main_address_no}|${sub || '0'}` : null,
  };
}

export const KAKAO_ADDRESS_URL = 'https://dapi.kakao.com/v2/local/search/address.json';

export interface KakaoDeps {
  fetch: Fetch;
  key: string;
  sleep?: (ms: number) => Promise<void>;
}

// 주소 검색 → 중복 제거된 후보. 429(한도)는 200·400ms 백오프로 2회 재시도
export async function searchAddress(d: KakaoDeps, query: string, exact: boolean): Promise<Candidate[]> {
  const url = `${KAKAO_ADDRESS_URL}?query=${encodeURIComponent(query)}&size=10&analyze_type=${
    exact ? 'exact' : 'similar'
  }`;
  for (let attempt = 0;; attempt++) {
    const r = await d.fetch(url, { headers: { Authorization: `KakaoAK ${d.key}` } });
    if (r.status === 200) {
      const body = await r.json();
      const seen = new Set<string>();
      const out: Candidate[] = [];
      for (const doc of body?.documents ?? []) {
        const c = toCandidate(doc);
        const k = c && (c.jibun_key ?? c.jibun);
        if (c && k && !seen.has(k)) {
          seen.add(k);
          out.push(c);
        }
      }
      return out;
    }
    await r.body?.cancel();
    if (r.status === 429 && attempt < 2) {
      await (d.sleep ?? realSleep)(200 * 2 ** attempt);
      continue;
    }
    if (r.status === 429) throw new AppError(429, 'KAKAO_QUOTA', '카카오 호출 한도 초과');
    if (r.status === 401 || r.status === 403) throw new AppError(502, 'KAKAO_AUTH', '카카오 REST 키 확인 필요');
    throw new AppError(502, 'KAKAO_UPSTREAM', `카카오 응답 오류 ${r.status}`);
  }
}
