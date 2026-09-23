// path: app/test/widgets_test.dart
// 상태 표기(색·아이콘·텍스트·깜빡임) 위젯 · 상태 색 대비율(WCAG AA)
import 'package:fieldsync/core/i18n.dart';
import 'package:fieldsync/core/theme.dart';
import 'package:fieldsync/data/models.dart';
import 'package:fieldsync/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget w, {bool reduceMotion = false}) =>
    MaterialApp(home: MediaQuery(data: MediaQueryData(disableAnimations: reduceMotion), child: Scaffold(body: Center(child: w))));

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
}

void main() {
  tearDown(() => I18n.lang = 'ko');

  testWidgets('상태별 텍스트 라벨(한국어·영어)', (t) async {
    const ko = ['대기중', '진행중', '작업중', '일시중단', '작업완료'];
    for (var i = 0; i < SiteStatus.values.length; i++) {
      await t.pumpWidget(_wrap(StatusChip(SiteStatus.values[i], blink: false)));
      expect(find.text(ko[i]), findsOneWidget);
    }
    I18n.lang = 'en';
    await t.pumpWidget(_wrap(const StatusChip(SiteStatus.paused, blink: false)));
    expect(find.text('Paused'), findsOneWidget);
  });

  testWidgets('작업중만 깜빡임, 동작 줄이기 설정 시 정지', (t) async {
    await t.pumpWidget(_wrap(const StatusChip(SiteStatus.working)));
    await t.pump(const Duration(milliseconds: 250));
    expect(find.descendant(of: find.byType(StatusChip), matching: find.byType(FadeTransition)), findsOneWidget);

    await t.pumpWidget(_wrap(const StatusChip(SiteStatus.working), reduceMotion: true));
    expect(find.descendant(of: find.byType(StatusChip), matching: find.byType(FadeTransition)), findsNothing);

    await t.pumpWidget(_wrap(const StatusChip(SiteStatus.paused)));
    expect(find.descendant(of: find.byType(StatusChip), matching: find.byType(FadeTransition)), findsNothing);
  });

  testWidgets('오프라인 대기 표시(구름 아이콘) · 스크린리더 라벨', (t) async {
    final h = t.ensureSemantics();
    await t.pumpWidget(_wrap(const StatusChip(SiteStatus.enRoute, pending: true)));
    expect(find.byIcon(Icons.cloud_upload_outlined), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('진행중')), findsWidgets);
    h.dispose();
  });

  test('상태 색 대비율 ≥ 4.5:1 (WCAG AA 본문)', () {
    for (final s in SiteStatus.values) {
      final st = StatusStyle.of(s);
      expect(_contrast(st.bg, st.fg), greaterThanOrEqualTo(4.5), reason: s.db);
    }
  });
}
