import Foundation

enum AutomationScript {
    static let scan = #"""
    (() => {
      const clean = value => (value || '').replace(/\s+/g, ' ').trim();
      const visible = element => {
        if (!element) return false;
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
      };
      const pageText = clean(document.body?.innerText);
      const path = (window.location.pathname || '').toLocaleLowerCase();
      const successMessages = ['答卷已经提交', '提交成功！', '提交完成！', '感谢您的参与！'];
      const successMessage = successMessages.find(message => pageText.includes(message));
      if (path.includes('/join/complete') || successMessage) {
        return JSON.stringify({
          status: 'submitted',
          message: successMessage || '页面已进入提交完成状态。',
          questions: []
        });
      }
      const closeMessages = [
        '不能再接受新的答卷', '已达到发布者设置的最大填写份数',
        '问卷已经结束', '问卷已停止', '该问卷不存在'
      ];
      const closeMessage = closeMessages.find(message => pageText.includes(message));
      if (closeMessage) {
        return JSON.stringify({ status: 'closed', message: closeMessage, questions: [] });
      }

      const captchaRoot = document.querySelector('#captchaOut, #captcha, #captchabtn');
      if (captchaRoot && visible(captchaRoot) && clean(captchaRoot.innerText || captchaRoot.textContent)) {
        return JSON.stringify({ status: 'captcha', questions: [] });
      }

      const primaryContainers = Array.from(document.querySelectorAll('[topic], div.field'));
      const containers = primaryContainers.length
        ? primaryContainers
        : Array.from(document.querySelectorAll('fieldset'));
      const questions = [];
      const seen = new Set();
      for (const container of containers) {
        const controls = container.querySelectorAll('input:not([type="hidden"]), textarea, select, [contenteditable="true"]');
        if (!controls.length) continue;
        const titleNode = container.querySelector('.field-label, .topichtml, .div_title_question, .title, legend');
        let text = clean(titleNode?.innerText || titleNode?.textContent || container.innerText);
        text = text.replace(/^\s*\d+[\.、]\s*/, '').slice(0, 160);
        if (!text || seen.has(text)) continue;
        seen.add(text);
        const hasChoices = container.querySelector('input[type="radio"], input[type="checkbox"]');
        const hasSelect = container.querySelector('select');
        const kind = hasChoices ? '选择题' : (hasSelect ? '下拉题' : '填空题');
        questions.push({ text, kind });
      }
      return JSON.stringify({ status: 'ready', questions });
    })()
    """#

    static func fill(rules: [FillRule]) -> String? {
        let payload = rules
            .filter { $0.isEnabled }
            .map { ["question": $0.questionContains, "answer": $0.answer] }

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }

        return #"""
        (() => {
          const rules = \#(json);
          const clean = value => (value || '').replace(/\s+/g, ' ').trim();
          const normalized = value => clean(value).toLocaleLowerCase('zh-CN');
          const visible = element => {
            if (!element) return false;
            const style = window.getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
          };
          const fire = element => {
            ['input', 'change', 'blur'].forEach(name =>
              element.dispatchEvent(new Event(name, { bubbles: true }))
            );
          };
          const setNativeValue = (element, value) => {
            const prototype = element instanceof HTMLTextAreaElement
              ? HTMLTextAreaElement.prototype
              : HTMLInputElement.prototype;
            const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
            setter ? setter.call(element, value) : (element.value = value);
            fire(element);
          };
          const pageText = clean(document.body?.innerText);
          const closeMessages = [
            '不能再接受新的答卷', '已达到发布者设置的最大填写份数',
            '问卷已经结束', '问卷已停止', '该问卷不存在'
          ];
          const closeMessage = closeMessages.find(message => pageText.includes(message));
          if (closeMessage) {
            return JSON.stringify({ status: 'closed', message: closeMessage, matched: 0, filled: 0 });
          }

          const primaryContainers = Array.from(document.querySelectorAll('[topic], div.field'));
          const containers = primaryContainers.length
            ? primaryContainers
            : Array.from(document.querySelectorAll('fieldset'));
          let matched = 0;
          let filled = 0;
          const details = [];

          for (const rule of rules) {
            const question = normalized(rule.question);
            const answer = clean(rule.answer);
            if (!question || !answer) continue;

            const container = containers.find(candidate => normalized(candidate.innerText).includes(question));
            if (!container) continue;
            matched += 1;
            let countForRule = 0;

            const selects = Array.from(container.querySelectorAll('select')).filter(select => !select.disabled);
            if (selects.length) {
              const answers = answer.split(/[;；]/).map(clean).filter(Boolean);
              selects.forEach((select, index) => {
                const target = normalized(answers[index] || answers[0]);
                const option = Array.from(select.options).find(item => normalized(item.text).includes(target));
                if (option) {
                  select.value = option.value;
                  fire(select);
                  countForRule += 1;
                }
              });
            } else {
              const choiceInputs = Array.from(container.querySelectorAll('input[type="radio"], input[type="checkbox"]'))
                .filter(input => !input.disabled);
              if (choiceInputs.length) {
                const targets = answer.split(/[;；]/).map(normalized).filter(Boolean);
                for (const input of choiceInputs) {
                  const optionRoot = input.closest('label, li, .ui-radio, .ui-checkbox, .option') || input.parentElement;
                  const optionText = normalized(optionRoot?.innerText || optionRoot?.textContent);
                  const shouldSelect = targets.some(target => optionText.includes(target));
                  if (shouldSelect && !input.checked) {
                    input.click();
                    fire(input);
                    countForRule += 1;
                  } else if (shouldSelect && input.checked) {
                    countForRule += 1;
                  }
                }
              } else {
                const textControls = Array.from(container.querySelectorAll(
                  'input:not([type="hidden"]):not([type="button"]):not([type="submit"]), textarea'
                )).filter(control => visible(control) && !control.disabled && !control.readOnly);
                const answers = answer.split(/[;；]/).map(clean);
                textControls.forEach((control, index) => {
                  setNativeValue(control, answers[index] || answers[0] || '');
                  countForRule += 1;
                });

                const editable = Array.from(container.querySelectorAll('[contenteditable="true"]')).filter(visible);
                editable.forEach((control, index) => {
                  control.textContent = answers[index] || answers[0] || '';
                  fire(control);
                  countForRule += 1;
                });
              }
            }

            filled += countForRule;
            details.push({ question: rule.question, count: countForRule });
          }

          return JSON.stringify({ status: 'ok', matched, filled, details });
        })()
        """#
    }

    static func parallelFill(
        presets: [SubmissionPreset],
        surveyURL: URL,
        concurrency: Int,
        runID: String
    ) -> String? {
        let tasks: [[String: Any]] = presets.compactMap { preset in
            guard let fillScript = fill(rules: preset.usableRules) else { return nil }
            return [
                "name": preset.name,
                "fillScript": fillScript
            ]
        }
        let config: [String: Any] = [
            "runID": runID,
            "surveyURL": surveyURL.absoluteString,
            "concurrency": max(1, min(concurrency, 10)),
            "tasks": tasks,
            "scanScript": scan,
            "submitScript": submit
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }

        return #"""
        (() => {
          const config = \#(json);
          const previous = window.__wjxParallelTest;
          if (previous && typeof previous.cancel === 'function') previous.cancel(false);

          const notify = payload => {
            try {
              window.webkit.messageHandlers.parallelTest.postMessage({
                runID: config.runID,
                ...payload
              });
            } catch (_) {}
          };
          const parseResult = value => {
            if (typeof value === 'string') return JSON.parse(value);
            return value || {};
          };

          const host = document.createElement('div');
          host.id = `wjx-parallel-${config.runID}`;
          host.style.cssText = 'position:fixed;left:-12000px;top:0;width:390px;height:844px;overflow:hidden;opacity:0.01;pointer-events:none;z-index:-2147483647;';
          document.body.appendChild(host);

          const runner = {
            cancelled: false,
            nextIndex: 0,
            active: 0,
            processed: 0,
            succeeded: 0,
            failed: 0,
            frames: new Set(),
            cancel(shouldNotify = true) {
              if (this.cancelled) return;
              this.cancelled = true;
              for (const frame of this.frames) {
                try { frame.remove(); } catch (_) {}
              }
              this.frames.clear();
              try { host.remove(); } catch (_) {}
              if (window.__wjxParallelTest === this) delete window.__wjxParallelTest;
              if (shouldNotify) notify({ type: 'stopped' });
            }
          };
          window.__wjxParallelTest = runner;

          const total = config.tasks.length;
          const concurrency = Math.max(1, Math.min(Number(config.concurrency) || 1, 10));

          const evaluateInFrame = (task, script) => {
            const frameWindow = task.frame.contentWindow;
            if (!frameWindow) throw new Error('后台页面尚未就绪。');
            return parseResult(frameWindow.eval(script));
          };

          const finishTask = (task, succeeded, errorMessage = '') => {
            if (task.done || runner.cancelled) return;
            task.done = true;
            runner.active -= 1;
            runner.processed += 1;
            succeeded ? (runner.succeeded += 1) : (runner.failed += 1);
            runner.frames.delete(task.frame);
            try { task.frame.remove(); } catch (_) {}

            notify({
              type: 'progress',
              completed: runner.processed,
              succeeded: runner.succeeded,
              failed: runner.failed,
              active: runner.active,
              total,
              presetName: task.name,
              error: errorMessage
            });

            if (runner.processed >= total) {
              notify({
                type: 'complete',
                completed: runner.processed,
                succeeded: runner.succeeded,
                failed: runner.failed,
                total
              });
              runner.cancel(false);
            } else {
              pump();
            }
          };

          const stopAll = message => {
            if (runner.cancelled) return;
            notify({
              type: 'fatal',
              message,
              completed: runner.processed,
              succeeded: runner.succeeded,
              failed: runner.failed,
              total
            });
            runner.cancel(false);
          };

          const inspectSubmittedPage = task => {
            let scanResult;
            try {
              scanResult = evaluateInFrame(task, config.scanScript);
            } catch (error) {
              finishTask(task, false, `无法读取提交结果：${error.message || error}`);
              return;
            }
            if (scanResult.status === 'submitted') {
              finishTask(task, true);
            } else if (scanResult.status === 'captcha') {
              stopAll('页面要求人机验证，后台并行测试已停止。');
            } else if (scanResult.status === 'closed') {
              stopAll(scanResult.message || '问卷当前不可提交。');
            } else {
              finishTask(task, false, '提交后仍停留在填写页面，可能有必填项或格式校验未通过。');
            }
          };

          const handleFrameLoad = task => {
            if (task.done || runner.cancelled) return;
            try {
              const href = task.frame.contentWindow && task.frame.contentWindow.location.href;
              if (!href || href === 'about:blank') return;
            } catch (error) {
              finishTask(task, false, `后台页面发生跨域跳转：${error.message || error}`);
              return;
            }

            if (task.phase === 'submitting') {
              inspectSubmittedPage(task);
              return;
            }

            let scanResult;
            try {
              scanResult = evaluateInFrame(task, config.scanScript);
            } catch (error) {
              finishTask(task, false, `无法读取后台页面：${error.message || error}`);
              return;
            }

            if (scanResult.status === 'captcha') {
              stopAll('页面要求人机验证，后台并行测试已停止。');
              return;
            }
            if (scanResult.status === 'closed') {
              stopAll(scanResult.message || '问卷当前不可填写。');
              return;
            }
            if (scanResult.status !== 'ready' || !(scanResult.questions || []).length) {
              finishTask(task, false, '后台页面没有检测到可填写题目。');
              return;
            }

            let fillResult;
            try {
              fillResult = evaluateInFrame(task, task.fillScript);
            } catch (error) {
              finishTask(task, false, `自动填写失败：${error.message || error}`);
              return;
            }
            if (!fillResult.filled) {
              finishTask(task, false, '没有匹配到可填写控件。');
              return;
            }

            let submitResult;
            try {
              submitResult = evaluateInFrame(task, config.submitScript);
            } catch (error) {
              finishTask(task, false, `触发提交失败：${error.message || error}`);
              return;
            }
            if (submitResult.status === 'captcha') {
              stopAll('页面要求人机验证，后台并行测试已停止。');
              return;
            }
            if (submitResult.status !== 'scheduled') {
              finishTask(task, false, submitResult.message || '当前页面无法提交。');
              return;
            }

            task.phase = 'submitting';
            setTimeout(() => {
              if (!task.done && !runner.cancelled && task.phase === 'submitting') {
                inspectSubmittedPage(task);
              }
            }, 5000);
          };

          const startTask = taskConfig => {
            const frame = document.createElement('iframe');
            frame.style.cssText = 'display:block;width:390px;height:844px;border:0;';
            const task = {
              name: taskConfig.name,
              fillScript: taskConfig.fillScript,
              frame,
              phase: 'loading',
              done: false
            };
            runner.active += 1;
            runner.frames.add(frame);
            frame.addEventListener('load', () => handleFrameLoad(task));
            frame.addEventListener('error', () => finishTask(task, false, '后台页面加载失败。'));
            frame.src = config.surveyURL;
            host.appendChild(frame);
          };

          function pump() {
            if (runner.cancelled) return;
            while (runner.active < concurrency && runner.nextIndex < total) {
              startTask(config.tasks[runner.nextIndex]);
              runner.nextIndex += 1;
            }
          }

          if (!total) {
            notify({ type: 'fatal', message: '没有可用的测试预设。', total: 0 });
            runner.cancel(false);
            return JSON.stringify({ status: 'empty' });
          }

          notify({ type: 'started', completed: 0, succeeded: 0, failed: 0, active: 0, total });
          pump();
          return JSON.stringify({ status: 'started', total, concurrency });
        })()
        """#
    }

    static func cancelParallel(runID: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [runID]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return #"""
        (() => {
          const requestedRunID = \#(json)[0];
          const runner = window.__wjxParallelTest;
          if (runner && typeof runner.cancel === 'function') {
            runner.cancel(false);
            return JSON.stringify({ status: 'cancelled', runID: requestedRunID });
          }
          return JSON.stringify({ status: 'idle', runID: requestedRunID });
        })()
        """#
    }

    static let submit = #"""
    (() => {
      const clean = value => (value || '').replace(/\s+/g, ' ').trim();
      const visible = element => {
        if (!element) return false;
        const style = window.getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
      };
      const pageText = clean(document.body?.innerText);
      const closeMessages = [
        '不能再接受新的答卷', '已达到发布者设置的最大填写份数',
        '问卷已经结束', '问卷已停止', '该问卷不存在'
      ];
      const closeMessage = closeMessages.find(message => pageText.includes(message));
      if (closeMessage) return JSON.stringify({ status: 'closed', message: closeMessage });

      const captchaCandidates = Array.from(document.querySelectorAll('#captcha, #captchabtn, .captcha-wrap, iframe[src*="captcha"]'));
      if (captchaCandidates.some(visible)) {
        return JSON.stringify({ status: 'captcha', message: '请先在页面中完成人机验证。' });
      }

      const button = document.querySelector('#ctlNext, #submit_button, button[type="submit"], input[type="submit"]');
      if (!button || !visible(button)) {
        return JSON.stringify({ status: 'unavailable', message: '当前页面没有可用的提交按钮。' });
      }

      setTimeout(() => button.click(), 80);
      return JSON.stringify({ status: 'scheduled' });
    })()
    """#
}
