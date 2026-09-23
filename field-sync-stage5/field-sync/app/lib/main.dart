// path: app/lib/main.dart
// 진입점: 설정 검증 → Supabase·카카오맵 초기화 → 상태 복원(캐시) → 앱 실행 → 로그인 후 푸시 등록.
import 'package:flutter/material.dart';
import 'package:kakao_map_sdk/kakao_map_sdk.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'data/api.dart';
import 'services/location.dart';
import 'services/notif.dart';
import 'state/app_state.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Config.valid) {
    runApp(const MaterialApp(home: Scaffold(body: Center(child: Text('설정 누락: env.json (SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY / KAKAO_NATIVE_APP_KEY)')))));
    return;
  }
  await Supabase.initialize(url: Config.supabaseUrl, publishableKey: Config.supabaseKey);
  await KakaoMapSdk.instance.initialize(Config.kakaoNativeKey);

  final state = AppState(Api(Supabase.instance.client));
  final notif = NotifService(onTap: state.handleNotification);
  state
    ..reminders = notif
    ..locator = GeoLocator();
  await state.init();
  await notif.init();

  // 로그인되면 한 번만 푸시 권한 요청·토큰 등록
  var pushStarted = false;
  void registerPush() {
    if (state.loggedIn && !pushStarted) {
      pushStarted = true;
      notif.initPush((token, platform, ok) => state.api.registerDevice(token, platform, ok).then((_) {}));
    }
  }

  state.addListener(registerPush);
  registerPush();
  runApp(FieldSyncApp(state: state));
}
