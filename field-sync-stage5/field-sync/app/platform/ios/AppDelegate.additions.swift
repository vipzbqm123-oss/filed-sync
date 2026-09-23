// path: app/platform/ios/AppDelegate.additions.swift
// ios/Runner/AppDelegate.swift 의 application(_:didFinishLaunchingWithOptions:) 안, `return super.application(...)` 앞에 추가.
// 근거: flutter_local_notifications README(iOS) — 앱이 켜져 있을 때 알림 표시·알림 버튼(작업완료/30분 연기) 응답 전달.
// (알림 버튼은 모두 앱을 여는 foreground 동작이라 백그라운드 isolate 등록은 불필요)

UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
