#!/usr/bin/env python3
# path: app/tool/xref_check.py
# 앱 ↔ 서버 교차 검증(파이썬 표준 라이브러리만). Flutter 없이 실행 가능한 정적 점검 — flutter analyze를 대체하지 않음.
#  1) i18n: 3개 언어 키 동일 · 중복 키 없음(Dart const map 중복 = 컴파일 오류) · {자리표시자} 일치 · '$' 미사용
#  2) tr('키') 사용처가 사전에 존재 · 동적 키 계열(status.* code.* log.* …)이 서버 값 전체를 포함
#  3) RPC 호출: 함수 존재 · 인자명 ⊆ SQL 시그니처 · 기본값 없는 인자 모두 전달
#  4) 테이블 쓰기: 컬럼 ⊆ GRANT 컬럼, 모델 fromJson 키 ⊆ 테이블 컬럼
#  5) import: 상대 경로 파일 존재 · 패키지 ⊆ pubspec · 선언된 의존성은 모두 사용
#  6) Edge Function 호출: 함수 폴더 존재 · 요청 필드명이 핸들러에 존재
#  7) 문서: 화면 이름 [ ]이 앱 문구에 존재 · 정책 기본값·상태 색이 코드와 같음 · 참조 경로 존재
# 사용: python3 app/tool/xref_check.py   (종료 코드 0 = 오류 없음)
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP, SUPA = ROOT / 'app', ROOT / 'supabase'
LIB = APP / 'lib'
errors, notes = [], []


def err(msg):
    errors.append(msg)


def dart_files(*dirs):
    for d in dirs:
        yield from sorted((APP / d).rglob('*.dart'))


SRC = {p: p.read_text(encoding='utf-8') for p in dart_files('lib', 'test')}
LIBSRC = {p: s for p, s in SRC.items() if LIB in p.parents}
SQL = '\n'.join(p.read_text(encoding='utf-8') for p in sorted((SUPA / 'migrations').glob('*.sql')))
STR = r"'((?:[^'\\\n]|\\.)*)'"


def rel(p):
    return p.relative_to(ROOT).as_posix()


def block_after(text, start):
    """text[start]가 '{' 또는 '(' 일 때 짝이 맞는 닫는 괄호까지 반환(문자열 내부 무시). O(길이)"""
    pairs = {'{': '}', '(': ')', '[': ']'}
    stack, i, q = [], start, None
    while i < len(text):
        c = text[i]
        if q:
            if c == '\\':
                i += 2
                continue
            if c == q:
                q = None
        elif c in '\'"':
            q = c
        elif c in pairs:
            stack.append(pairs[c])
        elif stack and c == stack[-1]:
            stack.pop()
            if not stack:
                return text[start:i + 1]
        i += 1
    return text[start:]


# ─────────────── 1) i18n 사전 ───────────────
i18n_src = (LIB / 'core/i18n.dart').read_text(encoding='utf-8')
DICT = {}
for lang in ('ko', 'en', 'vi'):
    m = re.search(r'const _%s = <String, String>\{' % lang, i18n_src)
    body = block_after(i18n_src, m.end() - 1)[1:-1]
    pairs = re.findall(STR + r'\s*:\s*' + STR, body)
    residue = re.sub(STR + r'\s*:\s*' + STR + r'\s*,?', '', body)
    residue = re.sub(r'//[^\n]*', '', residue).strip()
    if residue:
        err(f'i18n[{lang}] 해석 불가 잔여 텍스트: {residue[:80]!r}')
    keys = [k for k, _ in pairs]
    dups = sorted({k for k in keys if keys.count(k) > 1})
    if dups:
        err(f'i18n[{lang}] 중복 키(컴파일 오류): {dups}')
    for k, v in pairs:
        if re.search(r'(?<!\\)\$', v):
            err(f"i18n[{lang}] '{k}' 값에 $ (Dart 보간으로 해석됨)")
    DICT[lang] = dict(pairs)

ko = DICT['ko']
for lang in ('en', 'vi'):
    miss, extra = set(ko) - set(DICT[lang]), set(DICT[lang]) - set(ko)
    if miss:
        err(f'i18n[{lang}] 누락 키 {len(miss)}: {sorted(miss)[:10]}')
    if extra:
        err(f'i18n[{lang}] 여분 키 {len(extra)}: {sorted(extra)[:10]}')
    for k in set(ko) & set(DICT[lang]):
        a, b = set(re.findall(r'\{(\w+)\}', ko[k])), set(re.findall(r'\{(\w+)\}', DICT[lang][k]))
        if a != b:
            err(f"i18n[{lang}] '{k}' 자리표시자 불일치 ko={sorted(a)} {lang}={sorted(b)}")

# ─────────────── 2) 키 사용처 ───────────────
used_static, families = set(), {}
_dp = re.search(r"function private\.delegable_perms\(\).*?array\[(.*?)\]", SQL, re.S)
PERMS = set(re.findall(r"'([^']+)'", _dp.group(1)) if _dp else []) | {'site.publish', 'role.grant', 'user.manage', 'settings.edit'}
for p, s in LIBSRC.items():
    for m in re.finditer(r"\btr\(\s*'([^'$]+)'", s):
        used_static.add(m.group(1))
        if m.group(1) not in ko:
            err(f"{rel(p)}: tr('{m.group(1)}') 사전에 없음")
    for m in re.finditer(r"\btr\(\s*'([a-z_.]+\.)\$", s):
        families.setdefault(m.group(1), set()).add(rel(p))
    # tr() 밖에서 키로 쓰이는 문자열(labelKey·정책 표 등): 사전 키 모양이면 존재해야 함
    for m in re.finditer(r"'((?:status|policy|arrive|remind|channel|perm|role|code|log|pause|theme|tpl\.type)\.[a-z_.]+)'", s):
        if m.group(1) in PERMS:
            continue  # 권한 이름('log.view_team' 등) — tr('perm.$p')로 사용
        used_static.add(m.group(1))
        if m.group(1) not in ko:
            err(f"{rel(p)}: 키 문자열 '{m.group(1)}' 사전에 없음")


def sql_list(pattern):
    m = re.search(pattern, SQL, re.S)
    return re.findall(r"'([^']+)'", m.group(1)) if m else []


def expect_family(prefix, values, why):
    if prefix not in families and not any(f'{prefix}{v}' in used_static for v in values):
        notes.append(f'동적 키 {prefix}* 사용처 없음(정적 사용만)')
    miss = [v for v in values if f'{prefix}{v}' not in ko]
    if miss:
        err(f'동적 키 {prefix}* 누락({why}): {miss}')


site_status = sql_list(r"create type public\.site_status as enum \((.*?)\)")
user_role = sql_list(r"create type public\.user_role as enum \((.*?)\)")
log_actions = sql_list(r"action\s+text not null check \(action in \((.*?)\)\)")
sql_codes = sorted(set(re.findall(r"v_code := (?:case .*? then )?'([A-Z_]+)'", SQL))
                   | set(re.findall(r"'([A-Z_]{4,})'", ' '.join(re.findall(r"v_code := case[^;]*", SQL))))
                   | set(re.findall(r"private\.res\(false, '([A-Z_]+)'", SQL)))
edge_codes = {'LOGIN_ID_TAKEN', 'NOT_FOUND', 'UNKNOWN'}  # admin-users 결과 code(200 응답) + 앱 기본값
delegable = sql_list(r"function private\.delegable_perms\(\).*?array\[(.*?)\]")
pause_codes = sql_list(r"'reason_code', ''\) not in \((.*?)\)")
app_pause = re.search(r"for \(final k in \[([^\]]*)\]\) k: tr\('pause\.", (LIB / 'ui/actions.dart').read_text())
if not app_pause or sorted(re.findall(r"'(\w+)'", app_pause.group(1))) != sorted(pause_codes):
    err(f'일시중단 사유 코드 불일치: 서버 {pause_codes} / 앱 {app_pause and app_pause.group(1)}')
theme_vals = re.search(r'enum ThemeChoice \{([^}]*)\}', (LIB / 'core/theme.dart').read_text()).group(1)

expect_family('status.', site_status, 'site_status enum')
expect_family('role.', user_role, 'user_role enum')
expect_family('log.', log_actions, 'work_logs.action CHECK')
expect_family('code.', sorted(set(sql_codes) | edge_codes), 'RPC/Edge 결과 코드')
expect_family('perm.', delegable + ['site.publish', 'role.grant', 'user.manage', 'settings.edit'], '권한 목록')
expect_family('theme.', [t.strip() for t in theme_vals.split(',') if t.strip()], 'ThemeChoice')
expect_family('tpl.type.', ['bool', 'select', 'number', 'text'], '템플릿 타입')
expect_family('remind.title.', ['working', 'en_route', 'paused'], '리마인더 상태')
expect_family('remind.body.', ['working', 'en_route', 'paused'], '리마인더 상태')
expect_family('pause.', pause_codes, '일시중단 사유 코드')
for fam in families:
    if not any(k.startswith(fam) for k in ko):
        err(f'동적 키 계열 {fam}* 가 사전에 하나도 없음 ({sorted(families[fam])})')

fam_keys = {k for k in ko if any(k.startswith(f) for f in families)}
unused = sorted(set(ko) - used_static - fam_keys)
if unused:
    notes.append(f'사전에 있으나 코드에서 참조 안 됨 {len(unused)}개: {unused[:12]}')

# ─────────────── 3) RPC 계약 ───────────────
SIG = {}
for m in re.finditer(r'create (?:or replace )?function public\.(\w+)\s*\(', SQL):
    args = block_after(SQL, m.end() - 1)[1:-1]
    parts, depth, cur = [], 0, ''
    for c in args:
        depth += c in '(['
        depth -= c in ')]'
        if c == ',' and depth == 0:
            parts.append(cur)
            cur = ''
        else:
            cur += c
    if cur.strip():
        parts.append(cur)
    parts = [re.sub(r'--[^\n]*', '', x).strip() for x in parts]
    SIG[m.group(1)] = {x.split()[0]: ('default' in x.lower() or '=' in x) for x in parts if x}

OP_BASE = ['p_site_id', 'p_op_id', 'p_client_at', 'p_lat', 'p_lng']  # AppState._op 공통 인자
calls = []
for p, s in LIBSRC.items():
    for m in re.finditer(r"\brpc\(\s*'(\w+)',\s*(?:params:\s*)?(?=\{)", s):
        calls.append((p, m.group(1), re.findall(r"'(p_\w+)'\s*:", block_after(s, m.end()))))
    for m in re.finditer(r"\b_act\(\s*'(\w+)'", s):
        tail = s[m.end():s.find(';', m.end())]  # 현재 문장까지만
        ex = re.search(r'extra:\s*(?=\{)', tail)
        keys = re.findall(r"'(p_\w+)'\s*:", block_after(tail, ex.end())) if ex else []
        calls.append((p, m.group(1), OP_BASE + keys))
rpc_names = set()
for p, fn, keys in calls:
    rpc_names.add(fn)
    if fn not in SIG:
        err(f'{rel(p)}: RPC {fn} 없음')
        continue
    bad = [k for k in keys if k not in SIG[fn]]
    need = [a for a, has_def in SIG[fn].items() if not has_def and a not in keys]
    if bad:
        err(f'{rel(p)}: {fn} 알 수 없는 인자 {bad} (PostgREST PGRST202)')
    if need:
        err(f'{rel(p)}: {fn} 필수 인자 누락 {need}')
granted_rpc = set(SIG) - {'claim_push_batch'}
notes.append(f'RPC 호출 {len(calls)}곳 · 함수 {len(rpc_names)}종 / 서버 공개 {len(granted_rpc)}종 '
             f'(앱 미사용: {sorted(granted_rpc - rpc_names)})')

# ─────────────── 4) 테이블·컬럼 ───────────────
TABLES = {}
for m in re.finditer(r'create table public\.(\w+)\s*\(', SQL):
    body = block_after(SQL, m.end() - 1)[1:-1]
    cols = []
    for line in body.split('\n'):
        w = re.match(r'\s*([a-z_]+)\s+(?!key\b)', line)
        if w and w.group(1) not in ('primary', 'unique', 'check', 'constraint', 'foreign', 'exclude'):
            cols.append(w.group(1))
    TABLES[m.group(1)] = set(cols)

GRANT = {}  # (table, op) → set(columns) | None(전체)
for m in re.finditer(r'grant ([a-z, ]+?)(?:\s*\(([^)]*)\))?\s+on\s+((?:public\.\w+\s*,?\s*)+)\s+to authenticated', SQL):
    ops = [o.strip() for o in m.group(1).split(',')]
    cols = {c.strip() for c in m.group(2).split(',')} if m.group(2) else None
    for t in re.findall(r'public\.(\w+)', m.group(3)):
        for o in ops:
            GRANT[(t, o)] = cols

writes = []  # (파일, 테이블, 연산, 키)
for p, s in LIBSRC.items():
    for m in re.finditer(r"\.from\('(\w+)'\)\.(insert|update)\((?=\{)", s):
        writes.append((p, m.group(1), m.group(2), re.findall(r"^\s*'(\w+)'\s*:|[{,]\s*'(\w+)'\s*:", block_after(s, m.end()), re.M)))
WRAP = {'saveGroup': ('site_groups', ['insert', 'update']), 'insertSite': ('sites', ['insert']),
        'updateSite': ('sites', ['update']), 'saveTemplate': ('check_templates', ['insert', 'update'])}
for p, s in LIBSRC.items():
    for name, (t, ops) in WRAP.items():
        for m in re.finditer(r'\.%s\((?:[^,{]*,\s*)?(?=\{)' % name, s):
            for o in ops:
                writes.append((p, t, o, re.findall(r"[{,]\s*'(\w+)'\s*:", block_after(s, m.end()))))
for p, t, o, keys in writes:
    keys = [k if isinstance(k, str) else (k[0] or k[1]) for k in keys]
    keys = sorted(set(k for k in keys if k))
    if t not in TABLES:
        err(f'{rel(p)}: 테이블 {t} 없음')
        continue
    if (t, o) not in GRANT:
        err(f'{rel(p)}: {t} {o} 권한 없음')
        continue
    allowed = GRANT[(t, o)] or TABLES[t]
    bad = [k for k in keys if k not in allowed]
    if bad:
        err(f'{rel(p)}: {t}.{o} 허용되지 않은 컬럼 {bad}')
for p, s in LIBSRC.items():
    for t in re.findall(r"\.from\('(\w+)'\)", s):
        if t not in TABLES and t != 'evidence':
            err(f'{rel(p)}: from({t}) 테이블 없음')
if "values ('evidence'" not in SQL:
    err("Storage 버킷 'evidence' 미생성")

models = (LIB / 'data/models.dart').read_text(encoding='utf-8')
MODEL_TABLE = {'Site': 'sites', 'SiteGroup': 'site_groups', 'Profile': 'profiles', 'Session': 'work_sessions',
               'Template': 'check_templates', 'LogEntry': 'work_logs', 'AppNotif': 'notifications',
               'Urgent': 'urgent_requests', 'Team': 'teams'}
for cls, t in MODEL_TABLE.items():
    m = re.search(r'factory %s\.fromJson\(Map<String, dynamic> j\)\s*(?:=>|\{)' % cls, models)
    body = models[m.end():m.end() + 2500]
    body = body[:body.find('\n  }') if '{' in models[m.end() - 1] else body.find(');\n') + 2]
    keys = set(re.findall(r"\bj\['(\w+)'\]", body)) - {'actor', 'site'}  # 임베드 관계
    bad = sorted(keys - TABLES[t])
    if bad:
        err(f'models.dart {cls}.fromJson: {t}에 없는 컬럼 {bad}')
settings_keys = set(re.findall(r"_v\('(\w+)'", models)) | {'min_app_version'}
policy_keys = set(re.findall(r"'(\w+)': \('policy\.", (LIB / 'ui/admin/policy_page.dart').read_text()))
for k in sorted((settings_keys | policy_keys) - TABLES['settings']):
    err(f'settings 컬럼 없음: {k}')
stats_ret = re.search(r'function public\.get_stats\(.*?returns table\s*\((.*?)\)\s*language', SQL, re.S)
stats_cols = {c.split()[0] for c in stats_ret.group(1).split(',')} if stats_ret else set()
for k in sorted(set(re.findall(r"j\['(\w+)'\]", models[models.find('class StatsRow'):])) - stats_cols):
    err(f'StatsRow 키 {k}: get_stats 반환 컬럼에 없음 {sorted(stats_cols)}')
emb = re.search(r"select\('\*, actor:profiles!(\w+)\((\w+)\), site:sites!(\w+)\(([\w,]+)\)'\)", (LIB / 'data/api.dart').read_text())
if emb:
    fk1, c1, fk2, c2 = emb.groups()
    for fk in (fk1, fk2):
        if fk not in TABLES['work_logs']:
            err(f'work_logs 임베드 FK 컬럼 없음: {fk}')
    if c1 not in TABLES['profiles'] or not set(c2.split(',')) <= TABLES['sites']:
        err('work_logs 임베드 대상 컬럼 없음')

settings_tbl = re.search(r'create table public\.settings \((.*?)\n\);', SQL, re.S).group(1)
for k, dv in re.findall(r"_v\('(\w+)', (\d+)\)", models):
    m = re.search(r'^\s*%s\s+int\s+not null default (\d+)' % k, settings_tbl, re.M)
    if not m or m.group(1) != dv:
        err(f'Settings 기본값 불일치 {k}: 앱 {dv} / 서버 {m and m.group(1)}')

# 앱 설정 키 = env.example.json 키, 알림 채널 id = 서버 push channel_id·매니페스트 기본 채널
env_keys = set(re.findall(r"String\.fromEnvironment\('(\w+)'\)", (LIB / 'config.dart').read_text()))
env_ex = set(re.findall(r'"(\w+)"\s*:', (APP / 'env.example.json').read_text()))
if env_keys != env_ex:
    err(f'env.example.json 키 불일치: 코드 {sorted(env_keys)} / 예시 {sorted(env_ex)}')
channels = set(re.findall(r"AndroidNotificationChannel\('(\w+)'", (LIB / 'services/notif.dart').read_text()))
push_ch = set(re.findall(r"'(\w+)'", ' '.join(re.findall(r'channel_id:[^\n]*', (SUPA / 'functions/push/lib.ts').read_text()))))
man = (APP / 'platform/android/AndroidManifest.additions.xml').read_text()
man_ch = set(re.findall(r'default_notification_channel_id"\s+android:value="(\w+)"', man))
if not (push_ch | man_ch) <= channels:
    err(f'알림 채널 불일치: 앱 생성 {sorted(channels)} / 서버·매니페스트 {sorted(push_ch | man_ch)}')

# ─────────────── 5) import · pubspec ───────────────
pub = (APP / 'pubspec.yaml').read_text(encoding='utf-8')
dep_sec = re.search(r'^dependencies:\n((?:  .*\n|\n)*)', pub, re.M).group(1)
deps = set(re.findall(r'^  (\w+):', dep_sec, re.M)) - {'flutter'}
dev_sec = re.search(r'^dev_dependencies:\n((?:  .*\n|\n)*)', pub, re.M).group(1)
dev_deps = set(re.findall(r'^  (\w+):', dev_sec, re.M))
PKG = re.search(r'^name: (\w+)$', pub, re.M).group(1)
used_pkgs = set()
for p, s in SRC.items():
    for imp in re.findall(r"^import '([^']+)'", s, re.M):
        if imp.startswith('package:'):
            pkg = imp[8:].split('/')[0]
            used_pkgs.add(pkg)
            is_test = APP / 'test' in p.parents
            ok = pkg in ('flutter', PKG) or pkg in deps or (is_test and pkg in dev_deps)
            if not ok:
                err(f'{rel(p)}: 미선언 패키지 {pkg}')
        elif not imp.startswith('dart:') and not (p.parent / imp).resolve().exists():
            err(f'{rel(p)}: import 대상 없음 {imp}')
    header = s.split('\n', 1)[0]
    if header != f'// path: {rel(p)}':
        err(f'{rel(p)}: 첫 줄 경로 주석 불일치 ({header[:60]})')
    # supabase_flutter(gotrue)가 Session을 export → models.dart의 Session과 함께 import 시 ambiguous_import 컴파일 오류
    if re.search(r"^import '(?:\.\./)*(?:data/)?models\.dart'", s, re.M) and \
            re.search(r"^import 'package:supabase_flutter/supabase_flutter\.dart'(?! hide Session)", s, re.M):
        err(f'{rel(p)}: supabase_flutter import에 hide Session 필요(모델 Session과 충돌)')
for d in sorted(deps - used_pkgs):
    err(f'pubspec 의존성 미사용: {d}')

# ─────────────── 6) Edge Function 호출 ───────────────
for p, s in LIBSRC.items():
    for m in re.finditer(r"invoke\(\s*'([\w-]+)',\s*(?=\{)", s):
        fn = m.group(1)
        h = SUPA / 'functions' / fn / 'handler.ts'
        if not h.exists():
            err(f'{rel(p)}: Edge Function {fn} 없음')
            continue
        hs = h.read_text(encoding='utf-8') + (h.parent / 'lib.ts').read_text(encoding='utf-8') if (h.parent / 'lib.ts').exists() else h.read_text(encoding='utf-8')
        blk = block_after(s, m.end())
        for k in re.findall(r"'(\w+)'\s*:", blk):
            if not re.search(r'\b%s\b' % k, hs):
                err(f'{rel(p)}: {fn} 요청 필드 {k}가 핸들러에 없음')
        for v in re.findall(r"'(?:action|mode)'\s*:\s*'(\w+)'", blk):
            if f"'{v}'" not in hs:
                err(f'{rel(p)}: {fn} 동작 {v}가 핸들러에 없음')

# ─────────────── 7) 문서 = 동작 (DEVELOPMENT·RUNBOOK·USER_GUIDE) ───────────────
GENERATED = {'supabase/config.toml'}  # `supabase init`이 생성(RUNBOOK 2.3)
docs = {n: (ROOT / n).read_text(encoding='utf-8') for n in ('USER_GUIDE.md', 'RUNBOOK.md', 'DEVELOPMENT.md') if (ROOT / n).exists()}
ko_pat = [re.compile('^' + re.sub(r'\\\{\w+\\\}', '.+', re.escape(v)) + '$') for v in ko.values()]
for name in ('USER_GUIDE.md', 'RUNBOOK.md'):
    body = re.sub(r'```.*?```', '', docs.get(name, ''), flags=re.S)
    for label in re.findall(r'\[([^\]\n]+)\](?!\()', body):  # [화면 이름] (마크다운 링크 제외)
        if label.strip() and not any(pt.match(label) for pt in ko_pat):
            err(f'{name}: 화면 이름 [{label}]이 앱 문구(ko)에 없음')
ug = docs.get('USER_GUIDE.md', '')
documented = {}
for key, val in re.findall(r'\|\s*`(\w+)`\s*\|\s*([^|]+)\|', ug):
    m = re.search(r'^\s*%s\s+\w+\s+not null default (\S+)' % key, settings_tbl, re.M)
    if m:
        documented[key] = True
        want, got = m.group(1).strip("'"), re.search(r'\d+(?:\.\d+)*', val)
        if not got or got.group(0) != want:
            err(f'USER_GUIDE 정책 기본값 불일치 {key}: 문서 {val.strip()} / 서버 {want}')
for col in sorted(TABLES['settings'] - {'id', 'updated_at'} - set(documented)):
    err(f'USER_GUIDE 정책 표에 없는 설정: {col}')
theme_src = (LIB / 'core/theme.dart').read_text(encoding='utf-8')
theme_hex = {k: h for h, k in re.findall(r"StatusStyle\(Color\(0xFF([0-9A-F]{6})\)[^']*'(status\.\w+)'", theme_src)}
rows = re.findall(r'\|\s*\[([^\]]+)\]\s*\|[^|\n]*`#([0-9A-Fa-f]{6})`', ug)
if len(rows) != len(theme_hex):
    err(f'USER_GUIDE 상태 표 {len(rows)}행 / 앱 상태 {len(theme_hex)}개')
for label, hx in rows:
    key = next((k for k, v in ko.items() if k.startswith('status.') and v == label), None)
    if theme_hex.get(key) != hx.upper():
        err(f'USER_GUIDE 상태 색 불일치 [{label}]: 문서 #{hx} / 앱 #{theme_hex.get(key)}')
for name, body in docs.items():
    spans = re.findall(r'`([^`\n]+)`', body) + re.findall(r'```[a-z]*\n(.*?)```', body, re.S)
    for ref in {r for sp in spans for r in re.findall(r'(?:^|[\s(="])((?:app|supabase|api)/[\w./~*-]*[\w/*])', sp)}:
        if '*' in ref or '~' in ref or ref in GENERATED:  # 패턴 표기 · 설치 도구가 만드는 파일
            continue
        if not (ROOT / ref.rstrip('/')).exists():
            err(f'{name}: 참조한 경로 없음 {ref}')

# ─────────────── 결과 ───────────────
print(f'i18n 키 {len(ko)} × 3언어 · 동적 계열 {sorted(families)}')
print(f'RPC 시그니처 {len(SIG)} · 테이블 {len(TABLES)} · 쓰기 호출 {len(writes)} · Dart 파일 {len(SRC)}')
for n in notes:
    print('  참고:', n)
for e in errors:
    print('  오류:', e)
print(f'결과: 오류 {len(errors)}건')
sys.exit(1 if errors else 0)
