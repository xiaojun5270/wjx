import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wjx_auto_fill/app_store.dart';
import 'package:wjx_auto_fill/main.dart';
import 'package:wjx_auto_fill/settings_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('phone workspace does not overflow at 390x844', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final store = await AppStore.create(restoreSecureHeaders: false);
    store.synchronizeSurveyUrl('invalid-url');

    await tester.pumpWidget(WjxAutoFillApp(store: store));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('问卷地址无效'), findsOneWidget);
    expect(find.byTooltip('新增页面'), findsOneWidget);
    expect(find.byTooltip('问卷与预设'), findsNWidgets(2));
    expect(find.text('1 个 · Blocal'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('page-sidebar'))).width,
      closeTo(85.8, .1),
    );
    expect(tester.getRect(find.text('下一页')).center.dy, greaterThan(760));
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('sidebar-settings')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('问卷与预设'), findsWidgets);
    expect(find.text('自动流程'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('phone settings do not overflow at 390x844', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final store = await AppStore.create(restoreSecureHeaders: false);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: SettingsSheet(store: store, page: store.selectedPage),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('问卷与预设'), findsOneWidget);
    expect(find.text('自动流程'), findsOneWidget);
    final titleRect =
        tester.getRect(find.byKey(const ValueKey('settings-title')));
    final doneRect =
        tester.getRect(find.byKey(const ValueKey('settings-done')));
    expect(titleRect.overlaps(doneRect), isFalse);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('批量').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('10 组提交内容'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('scheduled refresh hour and minute can be changed inline',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final store = await AppStore.create(restoreSecureHeaders: false);
    store.synchronizeSurveyUrl('invalid-url');

    await tester.pumpWidget(WjxAutoFillApp(store: store));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('定时刷新'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const ValueKey('schedule-date-picker')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('schedule-hour-selector')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('schedule-minute-selector')), findsOneWidget);

    final hourDropdown = tester.widget<DropdownButton<int>>(
      find.descendant(
        of: find.byKey(const ValueKey('schedule-hour-selector')),
        matching: find.byType(DropdownButton<int>),
      ),
    );
    final newHour = ((hourDropdown.value ?? 0) + 2) % 24;
    hourDropdown.onChanged!(newHour);
    await tester.pump();

    final selectedTime = tester.widget<Text>(
      find.byKey(const ValueKey('schedule-selected-time')),
    );
    expect(
      selectedTime.data,
      contains('${newHour.toString().padLeft(2, '0')}:00'),
    );
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
