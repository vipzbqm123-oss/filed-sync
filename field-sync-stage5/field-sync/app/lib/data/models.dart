// path: app/lib/data/models.dart
// DB 행 ↔ Dart 모델. 모든 fromJson은 누락·null에 관대하게(오프라인 캐시·Realtime 페이로드 겸용).

DateTime? _dt(Object? v) => v is String && v.isNotEmpty ? DateTime.tryParse(v)?.toLocal() : null;
double _d(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
int _i(Object? v, [int def = 0]) => v is num ? v.toInt() : int.tryParse('$v') ?? def;
String? _s(Object? v) => v == null ? null : '$v';
Map<String, dynamic> _m(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

enum SiteStatus {
  pending('pending'),
  enRoute('en_route'),
  working('working'),
  paused('paused'),
  done('done');

  const SiteStatus(this.db);
  final String db;

  static SiteStatus of(Object? v) => values.firstWhere((s) => s.db == v, orElse: () => pending);

  /// 진행중·작업중·일시중단 = 점유(타인 맡기 불가)
  bool get occupied => this == enRoute || this == working || this == paused;
}

enum Role {
  admin,
  leader,
  worker;

  static Role of(Object? v) => values.firstWhere((r) => r.name == v, orElse: () => worker);
}

class Site {
  Site({
    required this.id,
    required this.groupId,
    required this.bunji,
    required this.jibun,
    required this.lat,
    required this.lng,
    this.seq = 0,
    this.label,
    this.road,
    this.unit = '',
    this.note,
    this.status = SiteStatus.pending,
    this.sessionId,
    this.occupantId,
    this.occupantName,
    this.occupantTeam,
    this.startedAt,
    this.statusAt,
    this.urgent = false,
    this.archived = false,
    this.updatedAt,
    this.pendingSync = false,
  });

  final String id, groupId, bunji, jibun, unit;
  final String? label, road, note, sessionId, occupantId, occupantName, occupantTeam;
  final double lat, lng;
  final int seq;
  final SiteStatus status;
  final DateTime? startedAt, statusAt, updatedAt;
  final bool urgent, archived;

  /// 오프라인 대기 중인 내 조작이 낙관적으로 반영된 상태(점선 표시)
  final bool pendingSync;

  factory Site.fromJson(Map<String, dynamic> j) => Site(
        id: '${j['id']}',
        groupId: '${j['group_id']}',
        seq: _i(j['seq']),
        label: _s(j['label']),
        bunji: '${j['bunji'] ?? ''}',
        jibun: '${j['jibun'] ?? ''}',
        road: _s(j['road']),
        unit: '${j['unit'] ?? ''}',
        note: _s(j['note']),
        lat: _d(j['lat']),
        lng: _d(j['lng']),
        status: SiteStatus.of(j['status']),
        sessionId: _s(j['session_id']),
        occupantId: _s(j['occupant_id']),
        occupantName: _s(j['occupant_name']),
        occupantTeam: _s(j['occupant_team']),
        startedAt: _dt(j['started_at']),
        statusAt: _dt(j['status_at']),
        urgent: j['urgent'] == true,
        archived: j['archived'] == true,
        updatedAt: _dt(j['updated_at']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'group_id': groupId,
        'seq': seq,
        'label': label,
        'bunji': bunji,
        'jibun': jibun,
        'road': road,
        'unit': unit,
        'note': note,
        'lat': lat,
        'lng': lng,
        'status': status.db,
        'session_id': sessionId,
        'occupant_id': occupantId,
        'occupant_name': occupantName,
        'occupant_team': occupantTeam,
        'started_at': startedAt?.toUtc().toIso8601String(),
        'status_at': statusAt?.toUtc().toIso8601String(),
        'urgent': urgent,
        'archived': archived,
        'updated_at': updatedAt?.toUtc().toIso8601String(),
      };

  /// 낙관적 반영용(서버 응답 전 임시 상태)
  Site optimistic({required SiteStatus status, String? occupantId, String? occupantName, bool keepOccupant = true}) =>
      Site(
        id: id,
        groupId: groupId,
        seq: seq,
        label: label,
        bunji: bunji,
        jibun: jibun,
        road: road,
        unit: unit,
        note: note,
        lat: lat,
        lng: lng,
        status: status,
        sessionId: keepOccupant ? sessionId : null,
        occupantId: keepOccupant ? (occupantId ?? this.occupantId) : null,
        occupantName: keepOccupant ? (occupantName ?? this.occupantName) : null,
        occupantTeam: keepOccupant ? occupantTeam : null,
        startedAt: status == SiteStatus.working ? (startedAt ?? DateTime.now()) : (keepOccupant ? startedAt : null),
        statusAt: DateTime.now(),
        urgent: urgent,
        archived: archived,
        updatedAt: updatedAt,
        pendingSync: true,
      );
}

class SiteGroup {
  SiteGroup({
    required this.id,
    required this.name,
    this.workDate,
    this.teamId,
    this.templateId,
    this.kakaoFolderUrl,
    this.published = false,
    this.publishedAt,
    this.archived = false,
  });

  final String id, name;
  final String? workDate, teamId, templateId, kakaoFolderUrl;
  final bool published, archived;
  final DateTime? publishedAt;

  factory SiteGroup.fromJson(Map<String, dynamic> j) => SiteGroup(
        id: '${j['id']}',
        name: '${j['name'] ?? ''}',
        workDate: _s(j['work_date']),
        teamId: _s(j['team_id']),
        templateId: _s(j['template_id']),
        kakaoFolderUrl: _s(j['kakao_folder_url']),
        published: j['published'] == true,
        publishedAt: _dt(j['published_at']),
        archived: j['archived'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'work_date': workDate,
        'team_id': teamId,
        'template_id': templateId,
        'kakao_folder_url': kakaoFolderUrl,
        'published': published,
        'published_at': publishedAt?.toUtc().toIso8601String(),
        'archived': archived,
      };
}

class Profile {
  Profile({required this.id, required this.loginId, required this.name, this.role = Role.worker, this.teamId, this.lang = 'ko', this.active = true});

  final String id, loginId, name, lang;
  final Role role;
  final String? teamId;
  final bool active;

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: '${j['id']}',
        loginId: '${j['login_id'] ?? ''}',
        name: '${j['name'] ?? ''}',
        role: Role.of(j['role']),
        teamId: _s(j['team_id']),
        lang: '${j['lang'] ?? 'ko'}',
        active: j['active'] != false,
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'login_id': loginId, 'name': name, 'role': role.name, 'team_id': teamId, 'lang': lang, 'active': active};
}

class Team {
  Team(this.id, this.name);
  final String id, name;
  factory Team.fromJson(Map<String, dynamic> j) => Team('${j['id']}', '${j['name'] ?? ''}');
}

class CheckItem {
  CheckItem({required this.key, required this.label, required this.type, this.section = '', this.required = false, this.options = const [], this.unit, this.min, this.max});

  final String key, label, type, section; // type: bool | number | select | text
  final bool required;
  final List<String> options;
  final String? unit;
  final num? min, max;

  factory CheckItem.fromJson(Map<String, dynamic> j) => CheckItem(
        key: '${j['key']}',
        label: '${j['label'] ?? j['key']}',
        type: '${j['type'] ?? 'text'}',
        section: '${j['section'] ?? ''}',
        required: j['required'] == true,
        options: (j['options'] is List) ? (j['options'] as List).map((e) => '$e').toList() : const [],
        unit: _s(j['unit']),
        min: j['min'] is num ? j['min'] as num : null,
        max: j['max'] is num ? j['max'] as num : null,
      );

  Map<String, dynamic> toJson() => {
        'key': key,
        'label': label,
        'type': type,
        if (section.isNotEmpty) 'section': section,
        'required': required,
        if (type == 'select') 'options': options,
        if (unit != null) 'unit': unit,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
      };

  /// 서버 private.valid_check_value와 동일 규칙(오프라인에서도 제출 전 검사)
  bool valid(Object? v) {
    if (v == null) return !required;
    if (v == '' && required) return false; // 선택 항목의 ''는 서버처럼 타입 검사로 넘김(text만 통과)
    switch (type) {
      case 'bool':
        return v is bool;
      case 'number':
        if (v is! num) return false;
        return (min == null || v >= min!) && (max == null || v <= max!);
      case 'select':
        return v is String && options.contains(v);
      case 'text':
        return v is String && v.runes.length <= 500; // PG length()=문자(코드포인트) 수와 맞춤
      default:
        return false;
    }
  }
}

class Template {
  Template({required this.id, required this.name, required this.items, this.requirePhoto = 0, this.requireSignature = false});

  final String id, name;
  final List<CheckItem> items;
  final int requirePhoto;
  final bool requireSignature;

  factory Template.fromJson(Map<String, dynamic> j) => Template(
        id: '${j['id']}',
        name: '${j['name'] ?? ''}',
        items: (j['items'] is List) ? (j['items'] as List).map((e) => CheckItem.fromJson(_m(e))).toList() : [],
        requirePhoto: _i(j['require_photo']),
        requireSignature: j['require_signature'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'items': items.map((e) => e.toJson()).toList(),
        'require_photo': requirePhoto,
        'require_signature': requireSignature,
      };

  /// 누락·형식 오류 항목 key 목록 (서버 missing_checks와 동일 순서)
  List<String> missing(Map<String, dynamic> checks) => [for (final it in items) if (!it.valid(checks[it.key])) it.key];
}

class Session {
  Session({required this.id, required this.siteId, required this.status, this.startedAt, this.completedAt, this.nextRemindAt, this.remindCount = 0, this.checks = const {}});

  final String id, siteId, status;
  final DateTime? startedAt, completedAt, nextRemindAt;
  final int remindCount;
  final Map<String, dynamic> checks;

  bool get active => status == 'en_route' || status == 'working' || status == 'paused';

  factory Session.fromJson(Map<String, dynamic> j) => Session(
        id: '${j['id']}',
        siteId: '${j['site_id']}',
        status: '${j['status']}',
        startedAt: _dt(j['started_at']),
        completedAt: _dt(j['completed_at']),
        nextRemindAt: _dt(j['next_remind_at']),
        remindCount: _i(j['remind_count']),
        checks: _m(j['checks']),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'site_id': siteId,
        'status': status,
        'started_at': startedAt?.toUtc().toIso8601String(),
        'completed_at': completedAt?.toUtc().toIso8601String(),
        'next_remind_at': nextRemindAt?.toUtc().toIso8601String(),
        'remind_count': remindCount,
        'checks': checks,
      };
}

/// 서버 RPC 공통 결과 {ok, code, site, session, occupant, missing, replayed}
class RpcResult {
  RpcResult({required this.ok, required this.code, this.site, this.session, this.occupantName, this.occupantTeam, this.occupantSince, this.occupantStatus, this.missing = const [], this.replayed = false, this.raw = const {}});

  final bool ok, replayed;
  final String code;
  final Site? site;
  final Session? session;
  final String? occupantName, occupantTeam;
  final DateTime? occupantSince;
  final SiteStatus? occupantStatus;
  final List<String> missing;
  final Map<String, dynamic> raw;

  factory RpcResult.fromJson(Map<String, dynamic> j) {
    final occ = j['occupant'] is Map ? _m(j['occupant']) : null;
    return RpcResult(
      ok: j['ok'] == true,
      code: '${j['code'] ?? 'UNKNOWN'}',
      site: j['site'] is Map ? Site.fromJson(_m(j['site'])) : null,
      session: j['session'] is Map ? Session.fromJson(_m(j['session'])) : null,
      occupantName: _s(occ?['name']),
      occupantTeam: _s(occ?['team']),
      occupantSince: _dt(occ?['since']),
      occupantStatus: occ == null ? null : SiteStatus.of(occ['status']),
      missing: (j['missing'] is List) ? (j['missing'] as List).map((e) => '$e').toList() : const [],
      replayed: j['replayed'] == true,
      raw: j,
    );
  }
}

class Settings {
  Settings(this.j);
  final Map<String, dynamic> j;
  int _v(String k, int def) => _i(j[k], def);

  int get workingFirstMin => _v('remind_working_first_min', 90);
  int get workingRepeatMin => _v('remind_working_repeat_min', 30);
  int get remindMax => _v('remind_max', 8);
  int get escalateAt => _v('escalate_at', 3);
  int get enRouteAfterMin => _v('remind_en_route_after_min', 45);
  int get pausedAfterMin => _v('remind_paused_after_min', 240);
  int get maxClaims => _v('max_claims_per_user', 3);
  int get arriveRadiusM => _v('arrive_radius_m', 50);
  int get undoWindowMin => _v('undo_complete_window_min', 5);
  String get minAppVersion => '${j['min_app_version'] ?? '1.0.0'}';

  /// 상태별 리마인더 반복 간격(서버 private.run_reminders와 동일)
  Duration repeatFor(String status) => Duration(
      minutes: status == 'working'
          ? workingRepeatMin
          : status == 'en_route'
              ? enRouteAfterMin
              : pausedAfterMin);
}

class LogEntry {
  LogEntry({required this.id, required this.at, required this.action, this.ok = true, this.actorName, this.siteBunji, this.siteId, this.fromStatus, this.toStatus, this.lat, this.lng, this.siteLat, this.siteLng, this.clientAt, this.meta = const {}});

  final int id;
  final DateTime at;
  final String action;
  final bool ok;
  final String? actorName, siteBunji, siteId, fromStatus, toStatus;
  final double? lat, lng, siteLat, siteLng;
  final DateTime? clientAt;
  final Map<String, dynamic> meta;

  factory LogEntry.fromJson(Map<String, dynamic> j) {
    final site = j['site'] is Map ? _m(j['site']) : null;
    return LogEntry(
      id: _i(j['id']),
      at: _dt(j['at']) ?? DateTime.now(),
      action: '${j['action']}',
      ok: j['ok'] != false,
      actorName: j['actor'] is Map ? _s(_m(j['actor'])['name']) : null,
      siteBunji: _s(site?['bunji']),
      siteId: _s(j['site_id']),
      siteLat: site?['lat'] is num ? _d(site!['lat']) : null,
      siteLng: site?['lng'] is num ? _d(site!['lng']) : null,
      fromStatus: _s(j['from_status']),
      toStatus: _s(j['to_status']),
      lat: j['lat'] is num ? _d(j['lat']) : null,
      lng: j['lng'] is num ? _d(j['lng']) : null,
      clientAt: _dt(j['client_at']),
      meta: _m(j['meta']),
    );
  }
}

class AppNotif {
  AppNotif({required this.id, required this.kind, required this.title, required this.body, required this.createdAt, this.readAt, this.data = const {}});

  final int id;
  final String kind, title, body;
  final DateTime createdAt;
  final DateTime? readAt;
  final Map<String, dynamic> data;

  factory AppNotif.fromJson(Map<String, dynamic> j) => AppNotif(
        id: _i(j['id']),
        kind: '${j['kind']}',
        title: '${j['title'] ?? ''}',
        body: '${j['body'] ?? ''}',
        createdAt: _dt(j['created_at']) ?? DateTime.now(),
        readAt: _dt(j['read_at']),
        data: _m(j['data']),
      );
}

class Urgent {
  Urgent({required this.id, required this.message, this.siteId, required this.createdAt});
  final String id, message;
  final String? siteId;
  final DateTime createdAt;

  factory Urgent.fromJson(Map<String, dynamic> j) =>
      Urgent(id: '${j['id']}', message: '${j['message'] ?? ''}', siteId: _s(j['site_id']), createdAt: _dt(j['created_at']) ?? DateTime.now());
}

class StatsRow {
  StatsRow(this.j);
  final Map<String, dynamic> j;
  String get name => '${j['name'] ?? ''}';
  int get claimed => _i(j['claimed']);
  int get completed => _i(j['completed']);
  int get released => _i(j['released']);
  int get rejectedDuplicates => _i(j['rejected_duplicates']);
  double get completionRate => _d(j['completion_rate']);
  double? get avgWorkMin => j['avg_work_min'] == null ? null : _d(j['avg_work_min']);
  int get longRunning => _i(j['long_running']);
}
