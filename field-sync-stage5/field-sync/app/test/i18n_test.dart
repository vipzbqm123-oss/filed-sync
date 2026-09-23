// path: app/test/i18n_test.dart
// 다국어: 3개 언어 키·자리표시자 동일 · 치환 · 대체(fallback) · 상태 라벨
import 'package:fieldsync/core/i18n.dart';
import 'package:fieldsync/data/models.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_test/flutter_test.dart';

Set<String> _ph(String s) => RegExp(r'\{(\w+)\}').allMatches(s).map((m) => m.group(1)!).toSet();

void main() {
  tearDown(() => I18n.lang = 'ko');

  test('지원 언어 = 사전 언어', () => expect(dict.keys.toSet(), I18n.supported.toSet()));

  for (final lang in ['en', 'vi']) {
    test('$lang: 키 집합이 한국어와 동일', () => expect(dict[lang]!.keys.toSet(), dict['ko']!.keys.toSet()));
    test('$lang: 모든 키의 {자리표시자}가 한국어와 동일', () {
      final bad = [for (final k in dict['ko']!.keys) if (!setEquals(_ph(dict['ko']![k]!), _ph(dict[lang]![k] ?? ''))) k];
      expect(bad, isEmpty);
    });
  }

  test('빈 문자열 값 없음', () {
    for (final l in dict.keys) {
      expect(dict[l]!.entries.where((e) => e.value.trim().isEmpty).map((e) => e.key), isEmpty, reason: l);
    }
  });

  test('치환 · null 인자는 빈 문자열', () {
    expect(tr('csv.result', {'n': 3}), '3곳 등록');
    I18n.lang = 'en';
    expect(tr('csv.result', {'n': 3}), '3 site(s) added');
    expect(tr('csv.result', {'n': null}), ' site(s) added');
  });

  test('모르는 키 → 키 그대로(화면이 깨지지 않음)', () {
    I18n.lang = 'vi';
    expect(tr('no.such.key'), 'no.such.key');
  });

  test('모든 상태에 3개 언어 라벨', () {
    for (final l in I18n.supported) {
      for (final s in SiteStatus.values) {
        expect(dict[l]!['status.${s.db}'], isNotNull, reason: '$l/${s.db}');
      }
    }
  });
}
