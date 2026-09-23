// path: app/platform/android/app.build.gradle.additions.kts
// android/app/build.gradle.kts 에 병합(이 파일 자체는 빌드에 쓰이지 않음).
// 근거: flutter_local_notifications 21.0.0 CHANGELOG(minSdk 24 · compileSdk 36 · AGP 8.11.1), README(desugaring 2.1.4),
//       kakao_map_sdk README(minSdk 23, ProGuard 규칙). 두 요구 중 큰 값을 채택.
// Firebase: `flutterfire configure` 실행 시 google-services 플러그인·google-services.json 이 자동 추가됨(앱 코드는 옵션 없이 초기화).

android {
    compileSdk = 36
    defaultConfig {
        minSdk = 24
    }
    compileOptions {
        isCoreLibraryDesugaringEnabled = true // flutter_local_notifications 예약 알림(java.time) 필수
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildTypes {
        release {
            // 기존 signingConfig 유지. 코드 축소 시 카카오맵 클래스 보존 규칙 적용
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
