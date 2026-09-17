import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_store.dart';
import 'models.dart';

enum _SettingsPage { survey, preset, batch, headers }

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({super.key, required this.store, required this.page});

  final AppStore store;
  final SurveyPageSession page;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  _SettingsPage selectedPage = _SettingsPage.survey;
  late final TextEditingController urlController;

  AppStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    urlController = TextEditingController(text: widget.page.surveyUrl);
  }

  @override
  void dispose() {
    urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) => Column(
        children: [
          SizedBox(
            height: 44,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const Text(
                  '问卷与预设',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
                Positioned(
                  right: 8,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('完成'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<_SettingsPage>(
                segments: const [
                  ButtonSegment(value: _SettingsPage.survey, label: Text('问卷')),
                  ButtonSegment(value: _SettingsPage.preset, label: Text('预设')),
                  ButtonSegment(value: _SettingsPage.batch, label: Text('批量')),
                  ButtonSegment(
                      value: _SettingsPage.headers, label: Text('请求头')),
                ],
                selected: {selectedPage},
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity(horizontal: -2, vertical: -2),
                  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 13)),
                ),
                onSelectionChanged: (value) {
                  setState(() => selectedPage = value.first);
                },
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: switch (selectedPage) {
              _SettingsPage.survey => _SurveySettings(
                  store: store,
                  page: widget.page,
                  urlController: urlController,
                ),
              _SettingsPage.preset => _PresetSettings(
                  store: store,
                  page: widget.page,
                ),
              _SettingsPage.batch => _BatchSettings(
                  store: store,
                  page: widget.page,
                ),
              _SettingsPage.headers => _HeaderProfiles(store: store),
            },
          ),
        ],
      ),
    );
  }
}

class _SurveySettings extends StatelessWidget {
  const _SurveySettings({
    required this.store,
    required this.page,
    required this.urlController,
  });

  final AppStore store;
  final SurveyPageSession page;
  final TextEditingController urlController;

  @override
  Widget build(BuildContext context) {
    final uri = store.validatedSurveyUri(urlController.text);
    final preset = store.presetFor(page);
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 30),
      children: [
        _SectionTitle('问卷地址'),
        _SettingsCard(
          children: [
            TextField(
              controller: urlController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              textCapitalization: TextCapitalization.none,
              decoration:
                  const InputDecoration(hintText: 'https://www.wjx.cn/...'),
              onChanged: store.synchronizeSurveyUrl,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  uri == null ? Icons.warning_rounded : Icons.check_circle,
                  size: 19,
                  color: uri == null ? Colors.orange : Colors.green,
                ),
                const SizedBox(width: 8),
                Text(
                  uri == null ? '地址无效' : uri.host,
                  style: const TextStyle(fontSize: 14),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SectionTitle('自动流程'),
        _SettingsCard(
          padding: EdgeInsets.zero,
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.auto_awesome, size: 21),
              title: const Text('页面加载后自动填写'),
              value: page.autoFillOnLoad,
              onChanged: (value) {
                page.autoFillOnLoad = value;
                store.updatePage(page);
              },
            ),
            const Divider(height: 1, indent: 54),
            SwitchListTile(
              secondary: const Icon(Icons.send_outlined, size: 21),
              title: const Text('单组填写后自动提交'),
              value: page.autoSubmitAfterFill,
              onChanged: (value) {
                page.autoSubmitAfterFill = value;
                store.updatePage(page);
              },
            ),
            const Divider(height: 1, indent: 54),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  const Icon(Icons.timer_outlined, size: 21),
                  const SizedBox(width: 12),
                  const Expanded(child: Text('单组提交等待')),
                  IconButton(
                    onPressed: page.submitDelaySeconds > 0
                        ? () {
                            page.submitDelaySeconds -= 1;
                            store.updatePage(page);
                          }
                        : null,
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                  SizedBox(
                    width: 34,
                    child: Text(
                      '${page.submitDelaySeconds}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    onPressed: page.submitDelaySeconds <
                            AppStore.maximumSubmitDelaySeconds
                        ? () {
                            page.submitDelaySeconds += 1;
                            store.updatePage(page);
                          }
                        : null,
                    icon: const Icon(Icons.add_circle_outline),
                  ),
                  const Text('秒', style: TextStyle(color: Colors.black54)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SectionTitle('当前单次预设'),
        _SettingsCard(
          children: [
            Row(
              children: [
                const Icon(Icons.lock, size: 18),
                const SizedBox(width: 8),
                Text(preset.name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                const Text('与页面编号对应',
                    style: TextStyle(fontSize: 12, color: Colors.black54)),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Text('数据完整度'),
                const Spacer(),
                Text(
                  '${preset.completedFieldCount} / 3',
                  style: TextStyle(
                    color: preset.isReady ? Colors.green : Colors.orange,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class _PresetSettings extends StatelessWidget {
  const _PresetSettings({required this.store, required this.page});

  final AppStore store;
  final SurveyPageSession page;

  @override
  Widget build(BuildContext context) {
    final preset = store.presetFor(page);
    final validation = store.validationMessage(preset);
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 30),
      children: [
        _SettingsCard(
          children: [
            Row(
              children: [
                const Icon(Icons.lock, size: 18),
                const SizedBox(width: 8),
                Text(preset.name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                const Text('与页面编号对应',
                    style: TextStyle(fontSize: 12, color: Colors.black54)),
              ],
            ),
          ],
        ),
        const SizedBox(height: 18),
        _SettingsCard(
          children: [
            Row(
              children: [
                Icon(
                  validation == null
                      ? Icons.check_circle
                      : Icons.warning_rounded,
                  color: validation == null ? Colors.green : Colors.orange,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(validation ?? '当前预设可用')),
                Text('${preset.completedFieldCount} / 3',
                    style:
                        const TextStyle(fontSize: 12, color: Colors.black54)),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: preset.completedFieldCount / 3,
              color: preset.isReady ? Colors.green : Colors.orange,
              backgroundColor: const Color(0xFFE5E5EA),
              borderRadius: BorderRadius.circular(3),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _SectionTitle('固定提交内容'),
        _SettingsCard(
          children: [
            _AnswerField(
              label: '姓名',
              icon: Icons.person_outline,
              value: preset.answers['姓名'] ?? '',
              hint: '请输入姓名',
              onChanged: (value) => store.updateAnswer(preset.id, '姓名', value),
            ),
            const SizedBox(height: 14),
            _AnswerField(
              label: '工号',
              icon: Icons.numbers,
              value: preset.answers['工号'] ?? '',
              hint: '请输入工号',
              onChanged: (value) => store.updateAnswer(preset.id, '工号', value),
            ),
            const SizedBox(height: 14),
            _AnswerField(
              label: '邮箱',
              icon: Icons.mail_outline,
              value: preset.answers['邮箱'] ?? '',
              hint: '请输入固定邮箱',
              keyboardType: TextInputType.emailAddress,
              onChanged: (value) => store.updateAnswer(preset.id, '邮箱', value),
            ),
          ],
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: () => _confirmClear(context, preset),
          style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
          icon: const Icon(Icons.delete_outline),
          label: const Text('清空当前预设'),
        ),
      ],
    );
  }

  Future<void> _confirmClear(
      BuildContext context, SubmissionPreset preset) async {
    final clear = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空这组预设？'),
        content: const Text('姓名、工号和邮箱都将被清空。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (clear == true) store.clearPreset(preset.id);
  }
}

class _BatchSettings extends StatelessWidget {
  const _BatchSettings({required this.store, required this.page});

  final AppStore store;
  final SurveyPageSession page;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _SettingsCard(
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('批量数据',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 3),
                      Text(
                        store.batchValidationMessage ?? '10 组数据检查通过',
                        style: TextStyle(
                          fontSize: 12,
                          color: store.isBatchReady
                              ? Colors.black54
                              : Colors.orange,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${store.completePresetCount} / ${AppStore.presetCount}',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    color: store.isBatchReady ? Colors.green : Colors.orange,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: store.completePresetCount / AppStore.presetCount,
              color: store.isBatchReady ? Colors.green : Colors.orange,
              backgroundColor: const Color(0xFFE5E5EA),
              borderRadius: BorderRadius.circular(3),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 18, 4, 9),
          child: Text('10 组提交内容',
              style: TextStyle(fontSize: 12, color: Colors.black54)),
        ),
        for (var index = 0; index < store.presets.length; index++) ...[
          _BatchPresetCard(
            store: store,
            preset: store.presets[index],
            number: index + 1,
            selected: store.presets[index].id == page.selectedPresetId,
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _BatchPresetCard extends StatelessWidget {
  const _BatchPresetCard({
    required this.store,
    required this.preset,
    required this.number,
    required this.selected,
  });

  final AppStore store;
  final SubmissionPreset preset;
  final int number;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final message = store.validationMessage(preset);
    final color = message == null ? Colors.green : Colors.orange;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(.18)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withOpacity(.14),
                ),
                child: Text('$number',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: color)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(preset.name,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600)),
                    Text(
                      message ?? '数据完整且不重复',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12,
                          color:
                              message == null ? Colors.black54 : Colors.orange),
                    ),
                  ],
                ),
              ),
              Icon(selected ? Icons.check_circle : Icons.circle_outlined,
                  color: selected ? Colors.green : Colors.black38),
              IconButton(
                tooltip: '清空该预设',
                onPressed: () => store.clearPreset(preset.id),
                color: Colors.red,
                icon: const Icon(Icons.delete_outline, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _CompactAnswerField(
                  label: '姓名',
                  value: preset.answers['姓名'] ?? '',
                  onChanged: (value) =>
                      store.updateAnswer(preset.id, '姓名', value),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CompactAnswerField(
                  label: '工号',
                  value: preset.answers['工号'] ?? '',
                  onChanged: (value) =>
                      store.updateAnswer(preset.id, '工号', value),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _CompactAnswerField(
            label: '邮箱',
            value: preset.answers['邮箱'] ?? '',
            keyboardType: TextInputType.emailAddress,
            onChanged: (value) => store.updateAnswer(preset.id, '邮箱', value),
          ),
        ],
      ),
    );
  }
}

class _HeaderProfiles extends StatelessWidget {
  const _HeaderProfiles({required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final profiles = store.requestHeaderProfiles;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('请求头配置',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    Text(
                      '已启用 ${profiles.where((item) => item.isEnabled).length} / ${profiles.length}',
                      style:
                          const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: () => _editProfile(context, RequestHeaderProfile()),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新增'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: profiles.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(30),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.swap_horizontal_circle_outlined,
                            size: 36, color: Colors.black38),
                        const SizedBox(height: 12),
                        const Text('暂无请求头配置',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        const Text(
                          '新增配置后，可按网址为问卷主请求和页面内 fetch/XHR 设置请求头。',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: () =>
                              _editProfile(context, RequestHeaderProfile()),
                          child: const Text('创建第一个配置'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 30),
                  itemCount: profiles.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1, indent: 50),
                  itemBuilder: (context, index) {
                    final profile = profiles[index];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Switch(
                        value: profile.isEnabled,
                        onChanged: (value) =>
                            store.toggleHeaderProfile(profile.id, value),
                      ),
                      title: Text(profile.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(profile.urlPattern,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) {
                          if (action == 'edit') {
                            _editProfile(context, profile.copy());
                          }
                          if (action == 'clone') {
                            store.cloneHeaderProfile(profile.id);
                          }
                          if (action == 'delete') {
                            store.deleteHeaderProfile(profile.id);
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(value: 'clone', child: Text('克隆')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                      onTap: () => _editProfile(context, profile.copy()),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _editProfile(
      BuildContext context, RequestHeaderProfile profile) async {
    final saved = await showModalBottomSheet<RequestHeaderProfile>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .92,
        child: _HeaderProfileEditor(profile: profile),
      ),
    );
    if (saved != null) await store.upsertHeaderProfile(saved);
  }
}

class _HeaderProfileEditor extends StatefulWidget {
  const _HeaderProfileEditor({required this.profile});

  final RequestHeaderProfile profile;

  @override
  State<_HeaderProfileEditor> createState() => _HeaderProfileEditorState();
}

class _HeaderProfileEditorState extends State<_HeaderProfileEditor> {
  late RequestHeaderProfile draft;

  @override
  void initState() {
    super.initState();
    draft = widget.profile.copy();
  }

  String? get validationMessage {
    if (draft.name.trim().isEmpty) return '请输入配置名称';
    if (draft.urlPattern.trim().isEmpty) return '请输入网址匹配规则';
    if (draft.headers.isEmpty) return '请至少添加一条请求头规则';
    const unsupported = {
      'connection',
      'content-length',
      'cookie',
      'host',
      'set-cookie',
      'transfer-encoding',
    };
    final seenNames = <String>{};
    final validName = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");
    for (var index = 0; index < draft.headers.length; index++) {
      final header = draft.headers[index];
      final name = header.name.trim();
      if (!validName.hasMatch(name)) {
        return '第 ${index + 1} 条请求头名称无效';
      }
      final key = name.toLowerCase();
      if (unsupported.contains(key)) {
        return 'WebView 不支持修改请求头 $name';
      }
      if (!seenNames.add(key)) return '请求头 $name 在同一配置中重复';
      if (header.action != HeaderAction.delete &&
          (header.value.contains('\r') || header.value.contains('\n'))) {
        return '请求头 $name 的值不能包含换行符';
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                draft.name.isEmpty ? '请求头配置' : draft.name,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              Positioned(
                  left: 6,
                  child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'))),
              Positioned(
                right: 6,
                child: TextButton(
                  onPressed: validationMessage == null
                      ? () => Navigator.pop(context, draft)
                      : null,
                  child: const Text('保存'),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 18, 14, 30),
            children: [
              _SectionTitle('配置'),
              _SettingsCard(
                children: [
                  TextFormField(
                    initialValue: draft.name,
                    decoration: const InputDecoration(labelText: '配置名称'),
                    onChanged: (value) => setState(() => draft.name = value),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: draft.urlPattern,
                    decoration:
                        const InputDecoration(labelText: '网址规则，例如 *.wjx.cn'),
                    onChanged: (value) =>
                        setState(() => draft.urlPattern = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启用配置'),
                    value: draft.isEnabled,
                    onChanged: (value) =>
                        setState(() => draft.isEnabled = value),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _SectionTitle('请求头规则'),
              for (var index = 0; index < draft.headers.length; index++) ...[
                _HeaderRuleEditor(
                  key: ValueKey(draft.headers[index].id),
                  header: draft.headers[index],
                  onChanged: () => setState(() {}),
                  onDelete: () => setState(() => draft.headers.removeAt(index)),
                ),
                const SizedBox(height: 10),
              ],
              OutlinedButton.icon(
                onPressed: () =>
                    setState(() => draft.headers.add(HeaderMutation())),
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('添加请求头'),
              ),
              if (validationMessage != null) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.warning_rounded,
                        size: 18, color: Colors.orange),
                    const SizedBox(width: 7),
                    Expanded(
                        child: Text(validationMessage!,
                            style: const TextStyle(
                                fontSize: 12, color: Colors.orange))),
                  ],
                ),
              ],
              const SizedBox(height: 18),
              const Text(
                '支持域名（wjx.cn）、通配符（*.wjx.cn）和完整网址。主页面请求与页面内 fetch/XHR 都会应用匹配规则。',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HeaderRuleEditor extends StatelessWidget {
  const _HeaderRuleEditor({
    super.key,
    required this.header,
    required this.onChanged,
    required this.onDelete,
  });

  final HeaderMutation header;
  final VoidCallback onChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final sensitive = const {
      'authorization',
      'proxy-authorization',
      'x-api-key',
      'api-key',
    }.contains(header.name.trim().toLowerCase());
    return _SettingsCard(
      children: [
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<HeaderAction>(
            segments: [
              for (final action in HeaderAction.values)
                ButtonSegment(value: action, label: Text(action.label)),
            ],
            selected: {header.action},
            showSelectedIcon: false,
            onSelectionChanged: (value) {
              header.action = value.first;
              onChanged();
            },
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          initialValue: header.name,
          decoration:
              const InputDecoration(labelText: '请求头名称，例如 Authorization'),
          onChanged: (value) {
            header.name = value;
            onChanged();
          },
        ),
        if (header.action != HeaderAction.delete) ...[
          const SizedBox(height: 12),
          TextFormField(
            initialValue: header.value,
            obscureText: sensitive,
            decoration: const InputDecoration(labelText: '请求头值'),
            onChanged: (value) {
              header.value = value;
              onChanged();
            },
          ),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: onDelete,
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            icon: const Icon(Icons.delete_outline, size: 17),
            label: const Text('删除这条规则'),
          ),
        ),
      ],
    );
  }
}

class _AnswerField extends StatelessWidget {
  const _AnswerField({
    required this.label,
    required this.icon,
    required this.value,
    required this.hint,
    required this.onChanged,
    this.keyboardType,
  });

  final String label;
  final IconData icon;
  final String value;
  final String hint;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: Colors.black54),
              const SizedBox(width: 6),
              Text(label,
                  style: const TextStyle(
                      fontSize: 12,
                      color: Colors.black54,
                      fontWeight: FontWeight.w500)),
            ],
          ),
          const SizedBox(height: 7),
          _ManagedTextField(
            value: value,
            keyboardType: keyboardType,
            autocorrect: false,
            inputFormatters: label == '工号'
                ? [FilteringTextInputFormatter.singleLineFormatter]
                : null,
            hintText: hint,
            onChanged: onChanged,
          ),
        ],
      );
}

class _CompactAnswerField extends StatelessWidget {
  const _CompactAnswerField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.keyboardType,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 11,
                  color: Colors.black54,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 5),
          _ManagedTextField(
            value: value,
            keyboardType: keyboardType,
            hintText: label,
            onChanged: onChanged,
          ),
        ],
      );
}

class _ManagedTextField extends StatefulWidget {
  const _ManagedTextField({
    required this.value,
    required this.hintText,
    required this.onChanged,
    this.keyboardType,
    this.autocorrect = false,
    this.inputFormatters,
  });

  final String value;
  final String hintText;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;
  final bool autocorrect;
  final List<TextInputFormatter>? inputFormatters;

  @override
  State<_ManagedTextField> createState() => _ManagedTextFieldState();
}

class _ManagedTextFieldState extends State<_ManagedTextField> {
  late final TextEditingController controller;
  late final FocusNode focusNode;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: widget.value);
    focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _ManagedTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!focusNode.hasFocus && controller.text != widget.value) {
      controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    controller.dispose();
    focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        focusNode: focusNode,
        keyboardType: widget.keyboardType,
        autocorrect: widget.autocorrect,
        inputFormatters: widget.inputFormatters,
        decoration: InputDecoration(hintText: widget.hintText),
        onChanged: widget.onChanged,
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 7),
        child: Text(text,
            style: const TextStyle(fontSize: 12, color: Colors.black54)),
      );
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard(
      {required this.children, this.padding = const EdgeInsets.all(14)});

  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0x12000000)),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );
}
