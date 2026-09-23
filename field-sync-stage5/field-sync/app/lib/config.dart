// path: app/lib/config.dart
// 빌드 시 주입되는 설정. 비밀값(서버 키)은 앱에 넣지 않는다 — publishable 키와 카카오 네이티브 키만(둘 다 공개 전제).
// 실행: flutter run --dart-define-from-file=env.json
class Config {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  static const kakaoNativeKey = String.fromEnvironment('KAKAO_NATIVE_APP_KEY');
  static const appVersion = '1.0.0'; // settings.min_app_version과 비교
  static const emailDomain = 'staff.fieldsync.local'; // 로그인 ID → 가상 이메일 (서버 admin-users와 동일)

  static bool get valid => supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty && kakaoNativeKey.isNotEmpty;
}
