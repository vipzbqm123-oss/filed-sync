// path: app/lib/core/theme.dart
// 테마(라이트/다크/야외 고대비) + 상태 표기 규칙(색·아이콘·텍스트). 상태 색은 테마와 무관하게 고정.
import 'package:flutter/material.dart';

import '../data/models.dart';
import 'i18n.dart';

enum ThemeChoice { system, light, dark, outdoor }

class StatusStyle {
  const StatusStyle(this.bg, this.fg, this.icon, this.labelKey);
  final Color bg, fg;
  final IconData icon;
  final String labelKey;

  String get label => tr(labelKey);

  // 대비율 5.1~10.7:1 (WCAG AA 통과, 1단계에서 계산 검증)
  static const _styles = {
    SiteStatus.pending: StatusStyle(Color(0xFF616161), Colors.white, Icons.radio_button_unchecked, 'status.pending'),
    SiteStatus.enRoute: StatusStyle(Color(0xFF1565C0), Colors.white, Icons.directions_walk, 'status.en_route'),
    SiteStatus.working: StatusStyle(Color(0xFFC62828), Colors.white, Icons.build, 'status.working'),
    SiteStatus.paused: StatusStyle(Color(0xFFF9A825), Colors.black, Icons.pause_circle, 'status.paused'),
    SiteStatus.done: StatusStyle(Color(0xFF2E7D32), Colors.white, Icons.check_circle, 'status.done'),
  };

  static StatusStyle of(SiteStatus s) => _styles[s]!;
}

ThemeData buildTheme(ThemeChoice choice, Brightness platform) {
  final dark = choice == ThemeChoice.dark || (choice == ThemeChoice.system && platform == Brightness.dark);
  if (choice == ThemeChoice.outdoor) {
    // 직사광선용: 흰 바탕·검정 글자·굵은 테두리
    return ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme.highContrastLight(primary: Colors.black, secondary: Color(0xFF0D47A1)),
      scaffoldBackgroundColor: Colors.white,
      filledButtonTheme: _buttons(),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(minimumSize: const Size(56, 56), side: const BorderSide(width: 2))),
    );
  }
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0), brightness: dark ? Brightness.dark : Brightness.light),
    filledButtonTheme: _buttons(),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(minimumSize: const Size(56, 56))),
  );
}

// 장갑 착용 고려: 최소 56dp 터치 영역
FilledButtonThemeData _buttons() => FilledButtonThemeData(
    style: FilledButton.styleFrom(minimumSize: const Size(56, 56), textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)));
