import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'app_store.dart';
import 'automation_scripts.dart';
import 'models.dart';

enum SurveyStateKind { loading, ready, submitted, closed, captcha, failed }

class SurveyState {
  const SurveyState(this.kind, {this.questionCount = 0, this.message = ''});

  final SurveyStateKind kind;
  final int questionCount;
  final String message;
}

class SurveyController extends ChangeNotifier {
  SurveyController({
    required this.store,
    required this.page,
    this.onSubmitted,
  }) {
    try {
      _webViewController = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFFFFFFFF))
        ..setNavigationDelegate(NavigationDelegate(
          onPageStarted: _onPageStarted,
          onPageFinished: _onPageFinished,
          onNavigationRequest: (_) => NavigationDecision.navigate,
          onWebResourceError: _onWebResourceError,
        ));
    } catch (_) {
      // Widget tests and unsupported desktop targets do not install a WebView.
    }
  }

  final AppStore store;
  final SurveyPageSession page;
  final VoidCallback? onSubmitted;
  WebViewController? _webViewController;
  WebViewController get webViewController => _webViewController!;

  SurveyState state = const SurveyState(SurveyStateKind.loading);
  bool isFilling = false;
  bool isWaitingToSubmit = false;
  bool isSubmitting = false;
  bool hasFilledCurrentForm = false;
  bool canGoBack = false;
  bool initialized = false;
  bool _disposed = false;
  bool _submissionNotified = false;
  Timer? _submitTimer;
  Timer? _countdownTimer;
  int _countdownChecks = 0;
  final List<AutomationLogEntry> logs = [];

  bool get isBusy => isFilling || isWaitingToSubmit || isSubmitting;

  String get statusTitle {
    if (isFilling) return '正在填写当前预设';
    if (isWaitingToSubmit) return '等待自动提交';
    if (isSubmitting) return '正在提交问卷';
    return switch (state.kind) {
      SurveyStateKind.loading => '正在加载问卷',
      SurveyStateKind.ready => hasFilledCurrentForm ? '已填好待提交' : '问卷已就绪',
      SurveyStateKind.submitted => '提交已完成',
      SurveyStateKind.closed => '问卷不可填写',
      SurveyStateKind.captcha => '需要安全验证',
      SurveyStateKind.failed => '页面加载失败',
    };
  }

  String get statusDetail {
    if (isFilling) return '使用 ${store.presetFor(page).name}';
    if (isWaitingToSubmit) {
      return '填写完成，${page.submitDelaySeconds} 秒后提交';
    }
    if (isSubmitting) return '等待问卷星返回结果';
    return switch (state.kind) {
      SurveyStateKind.loading => state.message.isNotEmpty
          ? state.message
          : (Uri.tryParse(page.surveyUrl)?.host ?? '正在连接'),
      SurveyStateKind.ready => hasFilledCurrentForm
          ? '已填好 ${state.questionCount} 道题目，等待提交'
          : '检测到 ${state.questionCount} 道可填写题目',
      SurveyStateKind.submitted ||
      SurveyStateKind.closed ||
      SurveyStateKind.failed =>
        state.message,
      SurveyStateKind.captcha => '请在当前页面完成验证后继续',
    };
  }

  Future<void> initialize() async {
    if (initialized) return;
    initialized = true;
    await loadSavedUrl();
  }

  Future<void> loadSavedUrl() async {
    final uri = store.validatedSurveyUri(page.surveyUrl);
    if (uri == null) return;
    _cancelSubmit();
    _cancelCountdown();
    state = const SurveyState(SurveyStateKind.loading);
    hasFilledCurrentForm = false;
    _submissionNotified = false;
    _log(LogLevel.info, '页面', '打开问卷：$uri');
    _notify();
    await webViewController.loadRequest(uri, headers: store.headersFor(uri));
  }

  Future<void> reload() async {
    if (isBusy) return;
    _log(LogLevel.info, '页面', '按已保存地址重新打开问卷');
    await loadSavedUrl();
  }

  Future<void> goBack() async {
    if (await webViewController.canGoBack()) await webViewController.goBack();
  }

  Future<void> fillCurrentPreset() async {
    if (isBusy || state.kind != SurveyStateKind.ready) return;
    isFilling = true;
    _log(LogLevel.info, '填写', '开始使用 ${store.presetFor(page).name}');
    _notify();
    try {
      final result =
          await _evaluate(AutomationScripts.fill(store.presetFor(page)));
      final matched = result['matched'] as int? ?? 0;
      final filled = result['filled'] as int? ?? 0;
      hasFilledCurrentForm = filled > 0;
      _log(
        filled > 0 ? LogLevel.success : LogLevel.warning,
        '填写',
        '匹配 $matched 项，填写 $filled 个控件',
      );
      if (filled > 0 && page.autoSubmitAfterFill) {
        _scheduleSubmit();
      }
    } catch (error) {
      _log(LogLevel.error, '填写', '自动填写失败：$error');
    } finally {
      isFilling = false;
      _notify();
    }
  }

  Future<void> submitOnce() async {
    if (isSubmitting) return;
    _cancelSubmit();
    isSubmitting = true;
    _log(LogLevel.info, '提交', '正在触发提交');
    _notify();
    try {
      final result = await _evaluate(AutomationScripts.submit);
      switch (result['status']) {
        case 'scheduled':
          _log(LogLevel.success, '提交', '已触发问卷提交');
          await Future<void>.delayed(const Duration(seconds: 2));
          await scanPage(allowAutoFill: false);
        case 'captcha':
          state = const SurveyState(SurveyStateKind.captcha);
          _log(LogLevel.warning, '验证', '页面要求人机验证');
        default:
          _log(
            LogLevel.error,
            '提交',
            result['message'] as String? ?? '当前页面无法提交',
          );
      }
    } catch (error) {
      _log(LogLevel.error, '提交', '提交失败：$error');
    } finally {
      isSubmitting = false;
      _notify();
    }
  }

  Future<void> resumeAfterCaptcha() async {
    await scanPage(allowAutoFill: false);
    if (state.kind == SurveyStateKind.ready) await submitOnce();
  }

  Future<void> scanPage({bool allowAutoFill = true}) async {
    try {
      final result = await _evaluate(AutomationScripts.scan);
      final status = result['status'] as String? ?? 'failed';
      switch (status) {
        case 'ready':
          final count =
              (result['questions'] as List<dynamic>? ?? const []).length;
          state = SurveyState(SurveyStateKind.ready, questionCount: count);
          _log(LogLevel.success, '页面', '检测到 $count 道可填写题目');
          _notify();
          if (allowAutoFill && page.autoFillOnLoad) await fillCurrentPreset();
        case 'submitted':
          state = SurveyState(
            SurveyStateKind.submitted,
            message: result['message'] as String? ?? '问卷已提交',
          );
          _log(LogLevel.success, '提交', state.message);
          if (!_submissionNotified) {
            _submissionNotified = true;
            onSubmitted?.call();
          }
        case 'closed':
          state = SurveyState(
            SurveyStateKind.closed,
            message: result['message'] as String? ?? '问卷已结束',
          );
          _log(LogLevel.warning, '页面', state.message);
        case 'captcha':
          state = const SurveyState(SurveyStateKind.captcha);
          _log(LogLevel.warning, '验证', '页面需要安全验证');
        default:
          state = const SurveyState(
            SurveyStateKind.failed,
            message: '无法识别当前页面',
          );
      }
    } catch (error) {
      state = SurveyState(SurveyStateKind.failed, message: error.toString());
      _log(LogLevel.error, '页面', '页面检测失败：$error');
    }
    _notify();
  }

  void clearLogs() {
    logs.clear();
    _notify();
  }

  Future<void> _onPageStarted(String url) async {
    _cancelCountdown();
    state = const SurveyState(SurveyStateKind.loading);
    hasFilledCurrentForm = false;
    _submissionNotified = false;
    canGoBack = await webViewController.canGoBack();
    _log(LogLevel.info, '页面', '正在加载页面：$url');
    _notify();
  }

  Future<void> _onPageFinished(String url) async {
    canGoBack = await webViewController.canGoBack();
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await webViewController.runJavaScript(
        AutomationScripts.installHeaderInterceptor(
          store.requestHeaderProfiles,
        ),
      );
    }
    await _continueAfterCountdownCheck();
  }

  Future<void> _continueAfterCountdownCheck() async {
    try {
      final result = await _evaluate(AutomationScripts.countdownAutoStart);
      final status = result['status'] as String? ?? 'none';
      if (status == 'waiting' && _countdownChecks < 3600) {
        _countdownChecks += 1;
        state = const SurveyState(
          SurveyStateKind.loading,
          message: '等待活动倒计时',
        );
        _notify();
        _countdownTimer = Timer(
          const Duration(seconds: 1),
          _continueAfterCountdownCheck,
        );
        return;
      }
      if (status == 'clicked') {
        _log(LogLevel.success, '页面', '倒计时结束，已自动点击“立即开始”');
        _countdownTimer = Timer(
          const Duration(milliseconds: 500),
          () => scanPage(),
        );
        return;
      }
    } catch (_) {
      // Continue with the normal page scan when countdown detection is absent.
    }
    await scanPage();
  }

  void _onWebResourceError(WebResourceError error) {
    if (error.isForMainFrame == false) return;
    state = SurveyState(SurveyStateKind.failed, message: error.description);
    _log(LogLevel.error, '页面', '加载失败：${error.description}');
    _notify();
  }

  void _scheduleSubmit() {
    _submitTimer?.cancel();
    isWaitingToSubmit = true;
    _notify();
    _submitTimer =
        Timer(Duration(seconds: page.submitDelaySeconds), submitOnce);
  }

  void _cancelSubmit() {
    _submitTimer?.cancel();
    _submitTimer = null;
    isWaitingToSubmit = false;
  }

  void _cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _countdownChecks = 0;
  }

  Future<Map<String, dynamic>> _evaluate(String script) async {
    final raw = await webViewController.runJavaScriptReturningResult(script);
    dynamic decoded = raw;
    for (var pass = 0; pass < 2 && decoded is String; pass++) {
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        break;
      }
    }
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw FormatException('Unexpected JavaScript result: $raw');
  }

  void _log(LogLevel level, String category, String message) {
    logs.add(AutomationLogEntry(level, category, message));
    if (logs.length > 500) logs.removeAt(0);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _submitTimer?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }
}
