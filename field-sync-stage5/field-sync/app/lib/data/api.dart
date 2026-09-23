// path: app/lib/data/api.dart
// Supabase 호출 모음. 상태 변경은 전부 RPC(서버가 유일한 판단 주체), 조회는 PostgREST(RLS 적용).
import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart' hide Session; // 작업 세션 모델(models.dart)과 이름 충돌 방지

import '../config.dart';
import 'models.dart';
import 'outbox.dart';

const _timeout = Duration(seconds: 12);

/// 영구 오류(입력·권한)는 그대로, 네트워크·일시 장애는 TransientError로 변환 → 아웃박스가 재시도
Future<T> guard<T>(Future<T> f) async {
  try {
    return await f.timeout(_timeout);
  } on PostgrestException catch (e) {
    // 재시도: PGRST000~003(DB 연결 불가·풀 대기 초과, HTTP 503/504), PGRST301/303(토큰 만료 → 자동 갱신 후 성공),
    // SQLSTATE 08(연결)·40(교착·직렬화)·5x(자원 부족·시간 초과). 근거: PostgREST v12 오류 코드 문서
    final c = e.code ?? '';
    if (c.isEmpty || c.startsWith('PGRST00') || c.startsWith('5') || c.startsWith('08') || c.startsWith('40') || c == 'PGRST301' || c == 'PGRST303') {
      throw TransientError(e);
    }
    rethrow;
  } on FunctionException catch (e) {
    if (e.status >= 500) throw TransientError(e);
    rethrow;
  } on AuthException {
    rethrow;
  } on StorageException catch (e) {
    if ((e.statusCode ?? '').startsWith('5')) throw TransientError(e);
    rethrow;
  } on TransientError {
    rethrow;
  } catch (e) {
    throw TransientError(e); // SocketException·ClientException·TimeoutException 등
  }
}

class Api {
  Api(this.db);
  final SupabaseClient db;

  String? get uid => db.auth.currentUser?.id;

  // ───────── 인증 ─────────
  Future<void> signIn(String loginId, String password) => guard(db.auth
      .signInWithPassword(email: '${loginId.trim().toLowerCase()}@${Config.emailDomain}', password: password));

  Future<void> signOut() => db.auth.signOut();

  // ───────── RPC ─────────
  Future<RpcResult> rpc(String fn, Map<String, dynamic> params) async {
    final res = await guard(db.rpc(fn, params: params));
    return RpcResult.fromJson(Map<String, dynamic>.from(res as Map));
  }

  // ───────── 조회 ─────────
  Future<Profile?> me() async {
    final id = uid;
    if (id == null) return null;
    final r = await guard(db.from('profiles').select().eq('id', id).maybeSingle());
    return r == null ? null : Profile.fromJson(r);
  }

  Future<Settings> settings() async => Settings(await guard(db.from('settings').select().eq('id', 1).single()));

  Future<List<SiteGroup>> groups() async {
    final r = await guard(db.from('site_groups').select().eq('archived', false).order('work_date', ascending: false));
    return r.map(SiteGroup.fromJson).toList();
  }

  /// 초기 로딩(since=null) 또는 재연결 델타(updated_at > since)
  Future<List<Site>> sites(String groupId, {DateTime? since}) async {
    var q = db.from('sites').select().eq('group_id', groupId);
    if (since != null) q = q.gt('updated_at', since.toUtc().toIso8601String());
    final r = await guard(q.order('seq'));
    return r.map(Site.fromJson).toList();
  }

  Future<Site?> site(String id) async {
    final r = await guard(db.from('sites').select().eq('id', id).maybeSingle());
    return r == null ? null : Site.fromJson(r);
  }

  Future<List<Template>> templates() async {
    final r = await guard(db.from('check_templates').select().order('name'));
    return r.map(Template.fromJson).toList();
  }

  Future<List<Session>> mySessions() async {
    final id = uid;
    if (id == null) return [];
    final r = await guard(
        db.from('work_sessions').select().eq('user_id', id).inFilter('status', ['en_route', 'working', 'paused']));
    return r.map(Session.fromJson).toList();
  }

  Future<List<Urgent>> openUrgent() async {
    final r = await guard(db.from('urgent_requests').select().isFilter('resolved_at', null).order('created_at', ascending: false));
    return r.map(Urgent.fromJson).toList();
  }

  /// 로그: 키셋 페이지네이션(id < cursor). RLS가 범위(본인/팀/전체)를 결정. O(log n) 인덱스
  Future<List<LogEntry>> logs({int? beforeId, String? siteId, DateTime? from, int limit = 50}) async {
    var q = db.from('work_logs').select('*, actor:profiles!actor_id(name), site:sites!site_id(bunji,lat,lng)');
    if (beforeId != null) q = q.lt('id', beforeId);
    if (siteId != null) q = q.eq('site_id', siteId);
    if (from != null) q = q.gte('at', from.toUtc().toIso8601String());
    final r = await guard(q.order('id', ascending: false).limit(limit));
    return r.map(LogEntry.fromJson).toList();
  }

  Future<List<AppNotif>> notifications() async {
    final r = await guard(db.from('notifications').select().order('created_at', ascending: false).limit(100));
    return r.map(AppNotif.fromJson).toList();
  }

  Future<void> markRead(List<int> ids) async {
    if (ids.isEmpty) return;
    await guard(db.from('notifications').update({'read_at': DateTime.now().toUtc().toIso8601String()}).inFilter('id', ids));
  }

  Future<List<StatsRow>> stats(DateTime from, DateTime to, String by) async {
    String d(DateTime t) => t.toIso8601String().substring(0, 10);
    final r = await guard(db.rpc('get_stats', params: {'p_from': d(from), 'p_to': d(to), 'p_by': by}));
    return (r as List).map((e) => StatsRow(Map<String, dynamic>.from(e as Map))).toList();
  }

  // ───────── 증빙 업로드 (Storage 'evidence' 버킷, 경로 = {session_id}/{op_id}.{ext}) ─────────
  Future<void> uploadEvidence({required String sessionId, required String siteId, required String kind, required String name, required Uint8List bytes, DateTime? takenAt, double? lat, double? lng}) async {
    final path = '$sessionId/$name';
    try {
      // upsert=false: 덮어쓰기(UPDATE 정책) 불필요. 파일명=op_id라 재전송 시 "이미 존재"(409) = 성공(멱등)
      await guard(db.storage.from('evidence').uploadBinary(path, bytes,
          fileOptions: FileOptions(contentType: name.endsWith('.png') ? 'image/png' : 'image/jpeg')));
    } on StorageException catch (e) {
      if (e.statusCode != '409' && !e.message.toLowerCase().contains('already exists')) rethrow;
    }
    try {
      await guard(db.from('attachments').insert({
        'session_id': sessionId,
        'site_id': siteId,
        'kind': kind,
        'path': path,
        'taken_at': takenAt?.toUtc().toIso8601String(),
        'lat': lat,
        'lng': lng,
      }));
    } on PostgrestException catch (e) {
      if (e.code != '23505') rethrow; // 재전송으로 이미 등록됨 = 성공(멱등)
    }
  }

  Future<List<Map<String, dynamic>>> attachments(String sessionId) =>
      guard(db.from('attachments').select().eq('session_id', sessionId).order('created_at'));

  // ───────── Edge Functions ─────────
  Future<Map<String, dynamic>> invoke(String fn, Map<String, dynamic> body) async {
    try {
      final r = await guard(db.functions.invoke(fn, body: body));
      return Map<String, dynamic>.from(r.data as Map);
    } on FunctionException catch (e) {
      final d = e.details;
      throw ApiError(d is Map ? '${d['message'] ?? d['code'] ?? e.status}' : '${e.reasonPhrase ?? e.status}');
    }
  }

  // ───────── 관리(조회·편집: RLS가 권한 판정) ─────────
  Future<List<Profile>> profiles() async =>
      (await guard(db.from('profiles').select().order('name'))).map(Profile.fromJson).toList();

  Future<List<Team>> teams() async => (await guard(db.from('teams').select().order('name'))).map(Team.fromJson).toList();

  Future<Map<String, Set<String>>> rolePerms() async {
    final r = await guard(db.from('role_permissions').select());
    final out = <String, Set<String>>{'leader': {}, 'worker': {}};
    for (final row in r) {
      out.putIfAbsent('${row['role']}', () => {}).add('${row['perm']}');
    }
    return out;
  }

  Future<List<SiteGroup>> allGroups() async {
    final r = await guard(db.from('site_groups').select().order('created_at', ascending: false));
    return r.map(SiteGroup.fromJson).toList();
  }

  Future<SiteGroup> saveGroup(Map<String, dynamic> values, {String? id}) async {
    final q = id == null ? db.from('site_groups').insert(values) : db.from('site_groups').update(values).eq('id', id);
    return SiteGroup.fromJson(await guard(q.select().single()));
  }

  Future<void> insertSite(Map<String, dynamic> values) => guard(db.from('sites').insert(values));

  Future<void> updateSite(String id, Map<String, dynamic> values) => guard(db.from('sites').update(values).eq('id', id));

  Future<void> saveTemplate(Map<String, dynamic> values, {String? id}) => guard(id == null
      ? db.from('check_templates').insert(values)
      : db.from('check_templates').update(values).eq('id', id));

  Future<void> addTeam(String name) => guard(db.from('teams').insert({'name': name}));

  Future<void> setLang(String lang) async {
    final id = uid;
    if (id != null) await guard(db.from('profiles').update({'lang': lang}).eq('id', id));
  }

  Future<RpcResult> registerDevice(String token, String platform, bool permitted) =>
      rpc('register_device', {'p_token': token, 'p_platform': platform, 'p_notif_permission': permitted});
}

class ApiError implements Exception {
  ApiError(this.message);
  final String message;
  @override
  String toString() => message;
}
