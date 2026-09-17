import 'dart:convert';

enum HeaderAction { add, modify, delete }

extension HeaderActionLabel on HeaderAction {
  String get label => switch (this) {
        HeaderAction.add => '新增',
        HeaderAction.modify => '修改',
        HeaderAction.delete => '删除',
      };
}

class HeaderMutation {
  HeaderMutation({
    String? id,
    this.action = HeaderAction.add,
    this.name = '',
    this.value = '',
  }) : id = id ?? uniqueId();

  String id;
  HeaderAction action;
  String name;
  String value;

  Map<String, dynamic> toJson() => {
        'id': id,
        'action': action.name,
        'name': name,
        'value': value,
      };

  factory HeaderMutation.fromJson(Map<String, dynamic> json) => HeaderMutation(
        id: json['id'] as String?,
        action: HeaderAction.values.firstWhere(
          (item) => item.name == json['action'],
          orElse: () => HeaderAction.add,
        ),
        name: json['name'] as String? ?? '',
        value: json['value'] as String? ?? '',
      );

  HeaderMutation copy() => HeaderMutation.fromJson(toJson());
}

class RequestHeaderProfile {
  RequestHeaderProfile({
    String? id,
    this.name = '新配置',
    this.urlPattern = '*.wjx.cn',
    this.isEnabled = true,
    List<HeaderMutation>? headers,
  })  : id = id ?? uniqueId(),
        headers = headers ?? [HeaderMutation()];

  String id;
  String name;
  String urlPattern;
  bool isEnabled;
  List<HeaderMutation> headers;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'urlPattern': urlPattern,
        'isEnabled': isEnabled,
        'headers': headers.map((item) => item.toJson()).toList(),
      };

  factory RequestHeaderProfile.fromJson(Map<String, dynamic> json) =>
      RequestHeaderProfile(
        id: json['id'] as String?,
        name: json['name'] as String? ?? '新配置',
        urlPattern: json['urlPattern'] as String? ?? '*.wjx.cn',
        isEnabled: json['isEnabled'] as bool? ?? true,
        headers: (json['headers'] as List<dynamic>? ?? const [])
            .map(
                (item) => HeaderMutation.fromJson(item as Map<String, dynamic>))
            .toList(),
      );

  RequestHeaderProfile copy() => RequestHeaderProfile.fromJson(toJson());
}

class SubmissionPreset {
  SubmissionPreset(
      {String? id, required this.name, Map<String, String>? answers})
      : id = id ?? uniqueId(),
        answers = answers ?? {'姓名': '', '工号': '', '邮箱': ''};

  static const requiredFields = ['姓名', '工号', '邮箱'];

  String id;
  String name;
  Map<String, String> answers;

  int get completedFieldCount => requiredFields
      .where((key) => (answers[key] ?? '').trim().isNotEmpty)
      .length;
  bool get isReady => completedFieldCount == requiredFields.length;
  List<String> get missingFields => requiredFields
      .where((key) => (answers[key] ?? '').trim().isEmpty)
      .toList();

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'answers': answers,
      };

  factory SubmissionPreset.fromJson(Map<String, dynamic> json) =>
      SubmissionPreset(
        id: json['id'] as String?,
        name: json['name'] as String? ?? '预设',
        answers: Map<String, String>.from(
          json['answers'] as Map<dynamic, dynamic>? ?? const {},
        ),
      );
}

class SurveyPageSession {
  SurveyPageSession({
    String? id,
    required this.pageNumber,
    required this.surveyUrl,
    required this.selectedPresetId,
    required this.autoFillOnLoad,
    required this.autoSubmitAfterFill,
    required this.submitDelaySeconds,
  }) : id = id ?? uniqueId();

  String id;
  int pageNumber;
  String surveyUrl;
  String selectedPresetId;
  bool autoFillOnLoad;
  bool autoSubmitAfterFill;
  int submitDelaySeconds;

  String get title => '问卷页 $pageNumber';

  Map<String, dynamic> toJson() => {
        'id': id,
        'pageNumber': pageNumber,
        'surveyUrl': surveyUrl,
        'selectedPresetId': selectedPresetId,
        'autoFillOnLoad': autoFillOnLoad,
        'autoSubmitAfterFill': autoSubmitAfterFill,
        'submitDelaySeconds': submitDelaySeconds,
      };

  factory SurveyPageSession.fromJson(Map<String, dynamic> json) =>
      SurveyPageSession(
        id: json['id'] as String?,
        pageNumber: json['pageNumber'] as int? ?? 1,
        surveyUrl: json['surveyUrl'] as String? ?? '',
        selectedPresetId: json['selectedPresetId'] as String? ?? '',
        autoFillOnLoad: json['autoFillOnLoad'] as bool? ?? true,
        autoSubmitAfterFill: json['autoSubmitAfterFill'] as bool? ?? true,
        submitDelaySeconds: json['submitDelaySeconds'] as int? ?? 2,
      );
}

enum LogLevel { info, success, warning, error }

class AutomationLogEntry {
  AutomationLogEntry(this.level, this.category, this.message)
      : timestamp = DateTime.now();

  final DateTime timestamp;
  final LogLevel level;
  final String category;
  final String message;
}

String uniqueId() => '${DateTime.now().microsecondsSinceEpoch}-${_nextId++}';
int _nextId = 0;

String encodeList(List<Map<String, dynamic>> value) => jsonEncode(value);
