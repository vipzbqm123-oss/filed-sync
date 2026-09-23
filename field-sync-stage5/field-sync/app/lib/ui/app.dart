// path: app/lib/ui/app.dart
import 'package:flutter/material.dart';

import '../core/i18n.dart';
import '../core/theme.dart';
import '../state/app_state.dart';
import 'home_page.dart';
import 'login_page.dart';
import 'widgets.dart';

class FieldSyncApp extends StatelessWidget {
  const FieldSyncApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => AppScope(
        state: state,
        child: ListenableBuilder(
          listenable: state,
          builder: (context, _) {
            final platform = MediaQuery.platformBrightnessOf(context);
            return MaterialApp(
              title: 'FieldSync',
              debugShowCheckedModeBanner: false,
              navigatorKey: state.navigator,
              scaffoldMessengerKey: state.messenger,
              theme: buildTheme(state.theme, platform),
              // 큰 글씨 3단계: 시스템 글꼴 크기 × 앱 배율
              builder: (c, child) => MediaQuery(
                data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(MediaQuery.of(c).textScaler.scale(1) * state.fontScale)),
                child: child!,
              ),
              home: state.loggedIn ? const HomePage() : const LoginPage(),
              key: ValueKey(I18n.lang), // 언어 변경 시 전체 문자열 갱신
            );
          },
        ),
      );
}
