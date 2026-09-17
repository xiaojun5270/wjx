import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wjx_auto_fill/app_store.dart';
import 'package:wjx_auto_fill/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('creates ten presets and one default workspace page', () async {
    final store = await AppStore.create();

    expect(store.presets, hasLength(10));
    expect(store.pages, hasLength(1));
    expect(store.selectedPage.surveyUrl, AppStore.defaultSurveyUrl);
    expect(store.presetFor(store.selectedPage).name, '预设 1');
  });

  test('accepts only HTTPS wjx.cn survey URLs', () async {
    final store = await AppStore.create();

    expect(
        store.validatedSurveyUri('https://www.wjx.cn/vm/test.aspx'), isNotNull);
    expect(store.validatedSurveyUri('https://wjx.cn/test'), isNotNull);
    expect(store.validatedSurveyUri('http://www.wjx.cn/test'), isNull);
    expect(store.validatedSurveyUri('https://example.com/test'), isNull);
  });

  test('new pages map to the matching preset slot', () async {
    final store = await AppStore.create();

    store.addPage();
    store.addPage();

    expect(store.pages, hasLength(3));
    expect(store.pages[1].selectedPresetId, store.presets[1].id);
    expect(store.pages[2].selectedPresetId, store.presets[2].id);
    expect(store.selectedPage.pageNumber, 3);
  });

  test('batch validation detects missing and duplicated data', () async {
    final store = await AppStore.create();
    expect(store.batchValidationMessage, '请完整填写全部 10 组');

    for (var index = 0; index < store.presets.length; index++) {
      final preset = store.presets[index];
      store.updateAnswer(preset.id, '姓名', '用户$index');
      store.updateAnswer(preset.id, '工号', 'ID$index');
      store.updateAnswer(preset.id, '邮箱', 'user$index@example.com');
    }
    expect(store.batchValidationMessage, isNull);

    store.updateAnswer(
      store.presets[1].id,
      '工号',
      store.presets[0].answers['工号']!,
    );
    expect(store.batchValidationMessage, '10 组的工号不能重复');
  });

  test('header profiles apply later modifications and deletions', () async {
    final store = await AppStore.create();
    store.requestHeaderProfiles = [
      RequestHeaderProfile(
        name: 'base',
        urlPattern: '*.wjx.cn',
        headers: [
          HeaderMutation(name: 'Authorization', value: 'Bearer first'),
          HeaderMutation(name: 'X-Trace', value: 'a'),
        ],
      ),
      RequestHeaderProfile(
        name: 'override',
        urlPattern: 'www.wjx.cn',
        headers: [
          HeaderMutation(
            action: HeaderAction.modify,
            name: 'X-Trace',
            value: 'b',
          ),
          HeaderMutation(
            action: HeaderAction.delete,
            name: 'Authorization',
          ),
        ],
      ),
    ];

    final headers = store.headersFor(Uri.parse('https://www.wjx.cn/vm/test'));
    expect(headers['X-Trace'], 'b');
    expect(headers.containsKey('Authorization'), isFalse);
  });
}
