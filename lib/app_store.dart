import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

class AppStore extends ChangeNotifier {
  AppStore._();

  static const presetCount = 10;
  static const maximumSubmitDelaySeconds = 300;
  static const defaultSurveyUrl = 'https://www.wjx.cn/vm/moYL383.aspx';
  static const _secureHeadersKey = 'requestHeaderProfiles.v1';
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  late SharedPreferences _preferences;
  List<SubmissionPreset> presets = [];
  List<SurveyPageSession> pages = [];
  List<RequestHeaderProfile> requestHeaderProfiles = [];
  String? selectedPageId;
  DateTime? scheduledRefresh;

  static Future<AppStore> create({bool restoreSecureHeaders = true}) async {
    final store = AppStore._();
    store._preferences = await SharedPreferences.getInstance();
    await store._restore(restoreSecureHeaders: restoreSecureHeaders);
    return store;
  }

  SurveyPageSession get selectedPage => pages.firstWhere(
        (page) => page.id == selectedPageId,
        orElse: () => pages.first,
      );

  SubmissionPreset presetFor(SurveyPageSession page) => presets.firstWhere(
        (preset) => preset.id == page.selectedPresetId,
        orElse: () => presets.first,
      );

  int get completePresetCount =>
      presets.where((preset) => preset.isReady).length;
  bool get isBatchReady => batchValidationMessage == null;

  String? get batchValidationMessage {
    if (completePresetCount != presetCount) {
      return '请完整填写全部 10 组';
    }
    for (final key in SubmissionPreset.requiredFields) {
      final values = presets
          .map((preset) => (preset.answers[key] ?? '').trim().toLowerCase())
          .toSet();
      if (values.length != presetCount) return '10 组的$key不能重复';
    }
    return null;
  }

  String? validationMessage(SubmissionPreset preset) {
    if (preset.missingFields.isNotEmpty) {
      return '缺少${preset.missingFields.join('、')}';
    }
    final duplicates = <String>[];
    for (final key in SubmissionPreset.requiredFields) {
      final value = (preset.answers[key] ?? '').trim().toLowerCase();
      final count = presets
          .where(
              (item) => (item.answers[key] ?? '').trim().toLowerCase() == value)
          .length;
      if (value.isNotEmpty && count > 1) duplicates.add(key);
    }
    return duplicates.isEmpty ? null : '${duplicates.join('、')}重复';
  }

  Uri? validatedSurveyUri(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.scheme != 'https') return null;
    final host = uri.host.toLowerCase();
    if (host != 'wjx.cn' && !host.endsWith('.wjx.cn')) return null;
    return uri;
  }

  void selectPage(String id) {
    selectedPageId = id;
    _persistWorkspace();
    notifyListeners();
  }

  void addPage() {
    final source = selectedPage;
    final pageNumber = pages.fold<int>(
            0, (max, page) => page.pageNumber > max ? page.pageNumber : max) +
        1;
    pages.add(SurveyPageSession(
      pageNumber: pageNumber,
      surveyUrl: source.surveyUrl,
      selectedPresetId: presets[(pageNumber - 1) % presets.length].id,
      autoFillOnLoad: source.autoFillOnLoad,
      autoSubmitAfterFill: source.autoSubmitAfterFill,
      submitDelaySeconds: source.submitDelaySeconds,
    ));
    selectedPageId = pages.last.id;
    _persistWorkspace();
    notifyListeners();
  }

  void removePage(String id) {
    if (pages.length == 1) return;
    final removedIndex = pages.indexWhere((page) => page.id == id);
    pages.removeWhere((page) => page.id == id);
    if (selectedPageId == id) {
      selectedPageId =
          pages[removedIndex.clamp(0, pages.length - 1).toInt()].id;
    }
    _persistWorkspace();
    notifyListeners();
  }

  void selectNextPage() {
    final index = pages.indexWhere((page) => page.id == selectedPageId);
    if (index >= 0 && index < pages.length - 1) selectPage(pages[index + 1].id);
  }

  void synchronizeSurveyUrl(String value) {
    for (final page in pages) {
      page.surveyUrl = value.trim();
    }
    _preferences.setString('surveyUrl', value.trim());
    _persistWorkspace();
    notifyListeners();
  }

  void updatePage(SurveyPageSession page) {
    page.submitDelaySeconds =
        page.submitDelaySeconds.clamp(0, maximumSubmitDelaySeconds).toInt();
    _persistWorkspace();
    notifyListeners();
  }

  void updateAnswer(String presetId, String key, String value) {
    final preset = presets.firstWhere((item) => item.id == presetId);
    preset.answers[key] = value;
    _persistPresets();
    notifyListeners();
  }

  void clearPreset(String id) {
    final preset = presets.firstWhere((item) => item.id == id);
    for (final key in SubmissionPreset.requiredFields) {
      preset.answers[key] = '';
    }
    _persistPresets();
    notifyListeners();
  }

  Future<void> upsertHeaderProfile(RequestHeaderProfile profile) async {
    final index =
        requestHeaderProfiles.indexWhere((item) => item.id == profile.id);
    if (index == -1) {
      requestHeaderProfiles.add(profile);
    } else {
      requestHeaderProfiles[index] = profile;
    }
    await _persistHeaders();
    notifyListeners();
  }

  Future<void> toggleHeaderProfile(String id, bool enabled) async {
    requestHeaderProfiles.firstWhere((item) => item.id == id).isEnabled =
        enabled;
    await _persistHeaders();
    notifyListeners();
  }

  Future<void> cloneHeaderProfile(String id) async {
    final source = requestHeaderProfiles.firstWhere((item) => item.id == id);
    final copy = source.copy()
      ..id = uniqueId()
      ..name = '${source.name} 副本';
    for (final header in copy.headers) {
      header.id = uniqueId();
    }
    requestHeaderProfiles.add(copy);
    await _persistHeaders();
    notifyListeners();
  }

  Future<void> deleteHeaderProfile(String id) async {
    requestHeaderProfiles.removeWhere((item) => item.id == id);
    await _persistHeaders();
    notifyListeners();
  }

  Map<String, String> headersFor(Uri uri) {
    final headers = <String, String>{};
    for (final mutation in headerMutationsFor(uri)) {
      String? existingKey;
      for (final key in headers.keys) {
        if (key.toLowerCase() == mutation.name.toLowerCase()) {
          existingKey = key;
          break;
        }
      }
      if (existingKey != null) headers.remove(existingKey);
      if (mutation.action != HeaderAction.delete) {
        headers[mutation.name] = mutation.value;
      }
    }
    return headers;
  }

  List<HeaderMutation> headerMutationsFor(Uri uri) {
    final order = <String>[];
    final resolved = <String, HeaderMutation>{};
    for (final profile
        in requestHeaderProfiles.where((item) => item.isEnabled)) {
      if (!_matchesPattern(profile.urlPattern, uri)) continue;
      for (final source in profile.headers) {
        final name = source.name.trim();
        if (name.isEmpty) continue;
        final key = name.toLowerCase();
        if (!resolved.containsKey(key)) order.add(key);
        resolved[key] = source.copy()
          ..name = name
          ..value = source.value.trim();
      }
    }
    return order.map((key) => resolved[key]!).toList();
  }

  void scheduleRefresh(DateTime? date) {
    scheduledRefresh = date;
    notifyListeners();
  }

  Future<void> _restore({required bool restoreSecureHeaders}) async {
    final presetJson = _preferences.getString('presets.v2');
    if (presetJson != null) {
      try {
        presets = (jsonDecode(presetJson) as List<dynamic>)
            .map((item) =>
                SubmissionPreset.fromJson(item as Map<String, dynamic>))
            .toList();
      } catch (_) {
        presets = [];
      }
    }
    while (presets.length < presetCount) {
      presets.add(SubmissionPreset(name: '预设 ${presets.length + 1}'));
    }
    presets = presets.take(presetCount).toList();
    for (var index = 0; index < presets.length; index++) {
      presets[index].name = '预设 ${index + 1}';
      for (final key in SubmissionPreset.requiredFields) {
        presets[index].answers.putIfAbsent(key, () => '');
      }
    }

    final workspaceJson = _preferences.getString('workspace.v1');
    if (workspaceJson != null) {
      try {
        pages = (jsonDecode(workspaceJson) as List<dynamic>)
            .map((item) =>
                SurveyPageSession.fromJson(item as Map<String, dynamic>))
            .toList();
      } catch (_) {
        pages = [];
      }
    }
    if (pages.isEmpty) {
      pages = [
        SurveyPageSession(
          pageNumber: 1,
          surveyUrl: _preferences.getString('surveyUrl') ?? defaultSurveyUrl,
          selectedPresetId: presets.first.id,
          autoFillOnLoad: _preferences.getBool('autoFill') ?? true,
          autoSubmitAfterFill: _preferences.getBool('autoSubmit') ?? true,
          submitDelaySeconds: _preferences.getInt('submitDelay') ?? 2,
        ),
      ];
    }
    for (final page in pages) {
      if (!presets.any((preset) => preset.id == page.selectedPresetId)) {
        page.selectedPresetId =
            presets[(page.pageNumber - 1) % presets.length].id;
      }
    }
    selectedPageId = pages.first.id;

    if (!restoreSecureHeaders) return;
    try {
      final headersJson = await _secureStorage.read(key: _secureHeadersKey);
      if (headersJson != null) {
        requestHeaderProfiles = (jsonDecode(headersJson) as List<dynamic>)
            .map((item) =>
                RequestHeaderProfile.fromJson(item as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {
      requestHeaderProfiles = [];
    }
  }

  bool _matchesPattern(String pattern, Uri uri) {
    final value = pattern.trim().toLowerCase();
    if (value.isEmpty) return false;
    if (value == '*') return true;
    final host = uri.host.toLowerCase();
    if (value.startsWith('||')) {
      final domain = value
          .substring(2)
          .replaceFirst(RegExp(r'^\*\.'), '')
          .replaceFirst(RegExp(r'/$'), '');
      return host == domain || host.endsWith('.$domain');
    }
    if (value.startsWith('*.') && !value.contains('/')) {
      final suffix = value.substring(2);
      return host == suffix || host.endsWith('.$suffix');
    }
    if (!value.contains('/') && !value.contains('*')) {
      return host == value || host.endsWith('.$value');
    }
    if (value.contains('*')) {
      final expression = value.split('*').map(RegExp.escape).join('.*');
      return RegExp('^$expression\$', caseSensitive: false)
          .hasMatch(uri.toString());
    }
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return uri.toString().toLowerCase().startsWith(value);
    }
    return uri.toString().toLowerCase().contains(value);
  }

  void _persistPresets() {
    _preferences.setString(
      'presets.v2',
      jsonEncode(presets.map((item) => item.toJson()).toList()),
    );
  }

  void _persistWorkspace() {
    _preferences.setString(
      'workspace.v1',
      jsonEncode(pages.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> _persistHeaders() => _secureStorage.write(
        key: _secureHeadersKey,
        value: jsonEncode(
          requestHeaderProfiles.map((item) => item.toJson()).toList(),
        ),
      );
}
