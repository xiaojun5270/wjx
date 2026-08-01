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

      const captchaText = ['请完成安全验证', '点击开始智能验证', '请先完成验证']
        .some(message => pageText.includes(message));
      const captchaCandidates = Array.from(document.querySelectorAll(
        '#captchaOut, #captcha, #captchabtn, #captchaWrap, .captcha-wrap, .tcaptcha-transform, iframe[src*="captcha"], iframe[src*="verify"]'
      ));
      const visibleCaptcha = captchaCandidates.some(element => {
        if (!visible(element)) return false;
        const rect = element.getBoundingClientRect();
        const hasFrame = element.matches('iframe') || !!element.querySelector?.('iframe');
        const hasText = !!clean(element.innerText || element.textContent);
        return hasFrame || hasText || rect.height >= 80;
      });
      if (captchaText || visibleCaptcha) {
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

    static func installCountdownAutoStart(generation: Int) -> String {
        #"""
        (() => {
          const storageKey = '__wjxCountdownAutoStart';
          const generationKey = '__wjxAutomationGeneration';
          const generation = \#(generation);
          const latestGeneration = Number(window[generationKey]);
          if (Number.isFinite(latestGeneration) && latestGeneration > generation) {
            return JSON.stringify({ status: 'stale', generation });
          }
          window[generationKey] = generation;
          const existing = window[storageKey];
          if (existing && existing.generation === generation &&
              typeof existing.inspect === 'function') {
            return JSON.stringify({
              status: existing.inspect(),
              generation
            });
          }
          if (existing && typeof existing.dispose === 'function') {
            existing.dispose('replaced');
          } else if (existing) {
            delete window[storageKey];
          }

          const interactiveSelector =
            'button, a, input[type="button"], input[type="submit"], [role="button"]';
          const clean = value => (value || '').replace(/\s+/g, ' ').trim();
          const visible = element => {
            if (!element) return false;
            const style = window.getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return style.display !== 'none' &&
              style.visibility !== 'hidden' &&
              style.pointerEvents !== 'none' &&
              Number(style.opacity || 1) > 0 &&
              rect.width > 0 && rect.height > 0;
          };
          const exposed = element => {
            if (!visible(element)) return false;
            const rect = element.getBoundingClientRect();
            const x = Math.min(Math.max(rect.left + rect.width / 2, 0), window.innerWidth - 1);
            const y = Math.min(Math.max(rect.top + rect.height / 2, 0), window.innerHeight - 1);
            const topElement = document.elementFromPoint(x, y);
            const questionContainer = element.closest('[topic], div.field, fieldset');
            return !!topElement && (
              topElement === element ||
              element.contains(topElement) ||
              !!questionContainer?.contains(topElement)
            );
          };
          const labelFor = element => clean(
            element?.value || element?.innerText || element?.textContent
          );
          const actionLabelFor = element => labelFor(element).replace(/\s+/g, '');
          const disabled = element =>
            !!element?.disabled ||
            element?.getAttribute('aria-disabled') === 'true' ||
            Array.from(element?.classList || []).some(name =>
              name.toLocaleLowerCase().includes('disabled')
            );
          const questionControls = () => Array.from(document.querySelectorAll(
            '[topic] input:not([type="hidden"]):not([type="button"]):not([type="submit"]), ' +
            '[topic] textarea, [topic] select, [topic] [contenteditable="true"], ' +
            'div.field input:not([type="hidden"]):not([type="button"]):not([type="submit"]), ' +
            'div.field textarea, div.field select, div.field [contenteditable="true"], ' +
            'fieldset input:not([type="hidden"]):not([type="button"]):not([type="submit"]), ' +
            'fieldset textarea, fieldset select, fieldset [contenteditable="true"]'
          )).filter(visible);
          const hasQuestionControls = () => questionControls().length > 0;
          const hasExposedQuestionControls = () => questionControls().some(exposed);
          const statusContainers = () => Array.from(document.querySelectorAll(
            '#divTip, #divWorkError'
          )).filter(visible);
          const hasCountdownSignal = () => {
            const containers = statusContainers();
            const visibleCountdown = containers.some(container =>
              Array.from(container.querySelectorAll('#countdownHtml')).some(visible)
            );
            if (visibleCountdown) return true;
            const statusText = containers.map(container =>
              clean(container.innerText || container.textContent)
            ).join(' ');
            const countdownText = /将于.{0,40}开放|距(?:离)?.{0,12}开始|活动(?:尚未|未)开始|问卷(?:尚未|未)开始|倒计时/;
            const seconds = Number(window.leftSeconds);
            return countdownText.test(statusText) ||
              (containers.length > 0 && Number.isFinite(seconds) && seconds > 0);
          };
          const isTerminalPage = () => {
            const path = (window.location.pathname || '').toLocaleLowerCase();
            if (path.includes('/join/complete')) return true;
            const text = statusContainers().map(container =>
              clean(container.innerText || container.textContent)
            ).join(' ');
            if ([
              '答卷已经提交', '提交成功！', '提交完成！', '感谢您的参与！',
              '不能再接受新的答卷', '已达到发布者设置的最大填写份数',
              '问卷已经结束', '问卷已停止', '该问卷不存在',
              '请完成安全验证', '点击开始智能验证', '请先完成验证'
            ].some(value => text.includes(value))) return true;
            return Array.from(document.querySelectorAll(
              '#captchaOut, #captcha, #captchabtn, #captchaWrap, .captcha-wrap, ' +
              '.tcaptcha-transform, iframe[src*="captcha"], iframe[src*="verify"]'
            )).some(visible);
          };
          const matchingStartButtons = () => {
            const containers = statusContainers();
            const countdownScopes = containers.flatMap(container =>
              Array.from(container.querySelectorAll('#countdownHtml')).filter(visible)
            );
            const candidates = [...countdownScopes, ...containers].flatMap(scope =>
              Array.from(scope.querySelectorAll(interactiveSelector))
            );
            return Array.from(new Set(candidates)).filter(element => {
              if (!visible(element) || disabled(element) ||
                  actionLabelFor(element) !== '立即开始') {
                return false;
              }
              const nestedMatch = Array.from(
                element.querySelectorAll?.(interactiveSelector) || []
              ).some(child => visible(child) && actionLabelFor(child) === '立即开始');
              return !nestedMatch;
            });
          };
          const countdownStartButton = () => {
            if (isTerminalPage()) return null;
            const buttons = matchingStartButtons();
            if (buttons.length === 1) return buttons[0];
            if (buttons.length > 1) return null;
            const fallback = document.querySelector('#cgstartbutton');
            const fallbackLabel = actionLabelFor(fallback);
            if (visible(fallback) && !disabled(fallback) &&
                ['立即开始', '开始作答', '开始答题'].includes(fallbackLabel)) {
              return fallback;
            }
            return null;
          };

          const state = {
            generation,
            clicked: false,
            sawCountdown: false,
            lastCountdownAt: 0,
            notifiedReady: false,
            hasInspected: false,
            disposed: false,
            observer: null,
            timer: null,
            unknownDeadline: Date.now() + 15000,
            inspect: null,
            dispose: null
          };
          const dispose = status => {
            if (!state.disposed) {
              state.disposed = true;
              state.observer?.disconnect();
              state.observer = null;
              if (state.timer !== null) {
                window.clearInterval(state.timer);
                state.timer = null;
              }
            }
            if (window[storageKey] === state) delete window[storageKey];
            return status;
          };
          const notifyClicked = label => {
            const handler = window.webkit?.messageHandlers?.countdownAutoStart;
            handler?.postMessage({ type: 'clicked', label, generation });
          };
          const notifyReady = () => {
            if (state.notifiedReady) return;
            state.notifiedReady = true;
            const handler = window.webkit?.messageHandlers?.countdownAutoStart;
            handler?.postMessage({ type: 'ready', generation });
          };
          const inspect = () => {
            const isFirstInspection = !state.hasInspected;
            state.hasInspected = true;
            if (state.clicked) return 'clicked';
            if (state.disposed) return 'inactive';
            const countdownVisible = hasCountdownSignal();
            if (countdownVisible) {
              state.sawCountdown = true;
              state.lastCountdownAt = Date.now();
            }
            if (isTerminalPage()) {
              return dispose('inactive');
            }
            const exposedQuestions = hasExposedQuestionControls();
            const button = state.sawCountdown && (countdownVisible || !exposedQuestions)
              ? countdownStartButton()
              : null;
            if (button) {
              const label = labelFor(button);
              state.clicked = true;
              try {
                button.click();
              } catch (_) {
                state.clicked = false;
                return state.sawCountdown ? 'waiting' : 'watching';
              }
              dispose('clicked');
              try { notifyClicked(label); } catch (_) {}
              return 'clicked';
            }
            const hasQuestions = hasQuestionControls();
            if (hasQuestions && exposedQuestions) {
              if (state.sawCountdown || !isFirstInspection) {
                try { notifyReady(); } catch (_) {}
              }
              return dispose('inactive');
            }
            if (countdownVisible ||
                (state.sawCountdown && Date.now() - state.lastCountdownAt < 2000)) {
              return 'waiting';
            }
            if (hasQuestions) {
              if (state.sawCountdown || !isFirstInspection) {
                try { notifyReady(); } catch (_) {}
              }
              return dispose('inactive');
            }

            if (!state.sawCountdown && Date.now() >= state.unknownDeadline) {
              return dispose('inactive');
            }
            return state.sawCountdown ? 'waiting' : 'watching';
          };

          state.dispose = dispose;
          state.inspect = inspect;
          window[storageKey] = state;
          state.observer = new MutationObserver(inspect);
          state.observer.observe(document.documentElement, {
            subtree: true,
            childList: true,
            characterData: true,
            attributes: true,
            attributeFilter: ['class', 'style', 'disabled', 'aria-disabled', 'value']
          });
          state.timer = window.setInterval(inspect, 250);

          return JSON.stringify({ status: inspect(), generation });
        })()
        """#
    }

    static func stopCountdownAutoStart(generation: Int) -> String {
        #"""
        (() => {
          const storageKey = '__wjxCountdownAutoStart';
          const generationKey = '__wjxAutomationGeneration';
          const generation = \#(generation);
          const latestGeneration = Number(window[generationKey]);
          if (!Number.isFinite(latestGeneration) || latestGeneration <= generation) {
            window[generationKey] = generation + 1;
          }
          const state = window[storageKey];
          if (!state || state.generation !== generation) return false;
          if (typeof state.dispose === 'function') {
            state.dispose('stopped');
          }
          if (window[storageKey] === state) delete window[storageKey];
          return true;
        })()
        """#
    }

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
            runID: config.runID,
            cancelled: false,
            active: 0,
            prepared: 0,
            processed: 0,
            succeeded: 0,
            failed: 0,
            submissionStarted: false,
            frames: new Set(),
            submitQueue: [],
            cancel(shouldNotify = true) {
              if (this.cancelled) return;
              this.cancelled = true;
              this.submitQueue = [];
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

          const evaluateInFrame = (task, script) => {
            const frameWindow = task.frame.contentWindow;
            if (!frameWindow) throw new Error('后台页面尚未就绪。');
            return parseResult(frameWindow.eval(script));
          };

          const finishTask = (task, succeeded, errorMessage = '') => {
            if (task.done || runner.cancelled) return;
            if (task.phase !== 'submitting') {
              stopAll(`${task.name}准备失败：${errorMessage || '无法完成自动填写。'}`);
              return;
            }
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

          const cleanMessage = value => {
            const holder = document.createElement('div');
            holder.innerHTML = String(value || '');
            return (holder.textContent || holder.innerText || '')
              .replace(/\s+/g, ' ')
              .trim()
              .slice(0, 240);
          };

          const readableFrameURL = task => {
            try {
              return task.frame.contentWindow?.location.href || '未知地址';
            } catch (_) {
              return '跨域页面';
            }
          };

          const finishFromWJXResponse = (task, observation) => {
            if (task.done || runner.cancelled) return;
            task.ajaxObserved = true;

            if (observation.kind === 'network-error') {
              const status = Number(observation.httpStatus) || 0;
              const detail = cleanMessage(observation.error || observation.statusText);
              finishTask(
                task,
                false,
                `问卷星提交请求失败（HTTP ${status || '未知'}）${detail ? `：${detail}` : ''}`
              );
              return;
            }

            const responseText = String(observation.responseText || '');
            const parts = responseText.split('〒');
            const code = (parts[0] || '').trim();
            const message = cleanMessage(parts[1] || '');
            const preview = cleanMessage(responseText);
            task.wjxCode = code;

            if (code === '10' || code === '11') {
              finishTask(task, true);
              return;
            }

            const detail = message || preview || '空响应';
            if (code === '22' || code === '7' || /验证码|人机验证|安全验证|智能验证/.test(detail)) {
              stopAll(`问卷星要求人机验证（返回码 ${code || '未知'}），批量任务已停止。`);
              return;
            }
            finishTask(task, false, `问卷星返回码 ${code || '未知'}：${detail}`);
          };

          const installSubmitObserver = task => {
            const frameWindow = task.frame.contentWindow;
            if (!frameWindow) throw new Error('后台页面尚未就绪。');

            task.ajaxObserved = false;
            task.submitButtonClicked = false;
            const submitButton = frameWindow.document.querySelector(
              '#ctlNext, #submit_button, button[type="submit"], input[type="submit"]'
            );
            submitButton?.addEventListener('click', () => {
              task.submitButtonClicked = true;
            }, { capture: true, once: true });

            const jq = frameWindow.jQuery || frameWindow.$;
            if (!jq || typeof jq.ajax !== 'function') {
              throw new Error('页面提交组件尚未加载。');
            }

            const originalAjax = jq.ajax;
            jq.ajax = function(urlOrOptions, maybeOptions) {
              const options = typeof urlOrOptions === 'string'
                ? { ...(maybeOptions || {}), url: urlOrOptions }
                : { ...(urlOrOptions || {}) };
              const requestURL = String(options.url || '');
              if (!requestURL.includes('processjq.ashx')) {
                return originalAjax.apply(this, arguments);
              }

              const originalSuccess = options.success;
              const originalError = options.error;
              options.success = function(data, textStatus, xhr) {
                try {
                  return typeof originalSuccess === 'function'
                    ? originalSuccess.apply(this, arguments)
                    : undefined;
                } finally {
                  finishFromWJXResponse(task, {
                    kind: 'response',
                    responseText: typeof data === 'string' ? data : xhr?.responseText,
                    httpStatus: xhr?.status,
                    statusText: textStatus
                  });
                }
              };
              options.error = function(xhr, textStatus, errorThrown) {
                try {
                  return typeof originalError === 'function'
                    ? originalError.apply(this, arguments)
                    : undefined;
                } finally {
                  finishFromWJXResponse(task, {
                    kind: 'network-error',
                    responseText: xhr?.responseText,
                    httpStatus: xhr?.status,
                    statusText: textStatus,
                    error: errorThrown
                  });
                }
              };
              return originalAjax.call(this, options);
            };
          };

          const submissionDiagnostics = task => {
            let validationMessage = '';
            try {
              const frameDocument = task.frame.contentWindow?.document;
              const nodes = Array.from(frameDocument?.querySelectorAll(
                '#ValError, #captchaTit, .errorMessage, .field.error'
              ) || []);
              validationMessage = cleanMessage(
                nodes.map(node => node.innerText || node.textContent).filter(Boolean).join(' ')
              );
            } catch (_) {}
            const details = [
              `点击=${task.submitButtonClicked ? '是' : '否'}`,
              `AJAX响应=${task.ajaxObserved ? '是' : '否'}`,
              `页面=${readableFrameURL(task)}`
            ];
            if (validationMessage) details.push(`提示=${validationMessage}`);
            return details.join('，');
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
              stopAll('页面要求人机验证，批量任务已停止。');
            } else if (scanResult.status === 'closed') {
              stopAll(scanResult.message || '问卷当前不可提交。');
            } else {
              finishTask(
                task,
                false,
                `未收到问卷星提交结果；${submissionDiagnostics(task)}`
              );
            }
          };

          const submitFilledTask = task => {
            if (task.done || runner.cancelled || task.phase !== 'queued-for-submit') return;
            task.phase = 'submitting';

            let submitResult;
            try {
              submitResult = evaluateInFrame(task, config.submitScript);
            } catch (error) {
              finishTask(task, false, `触发提交失败：${error.message || error}`);
              return;
            }
            if (submitResult.status === 'captcha') {
              stopAll('页面要求人机验证，批量任务已停止。');
              return;
            }
            if (submitResult.status !== 'scheduled') {
              finishTask(task, false, submitResult.message || '当前页面无法提交。');
              return;
            }

            setTimeout(() => {
              if (!task.done && !runner.cancelled && task.phase === 'submitting') {
                inspectSubmittedPage(task);
              }
            }, 8000);
          };

          runner.submitAll = () => {
            if (runner.cancelled) return { status: 'stopped' };
            if (runner.submissionStarted) return { status: 'already-submitting' };
            if (runner.prepared !== total || runner.submitQueue.length !== total) {
              return { status: 'not-ready', prepared: runner.prepared, total };
            }

            runner.submissionStarted = true;
            const preparedTasks = runner.submitQueue.splice(0);
            notify({
              type: 'submittingAll',
              completed: 0,
              succeeded: 0,
              failed: 0,
              active: runner.active,
              total
            });
            preparedTasks.forEach(submitFilledTask);
            return { status: 'submitting', total: preparedTasks.length };
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
            if (task.phase === 'queued-for-submit') return;

            let scanResult;
            try {
              scanResult = evaluateInFrame(task, config.scanScript);
            } catch (error) {
              finishTask(task, false, `无法读取后台页面：${error.message || error}`);
              return;
            }

            if (scanResult.status === 'captcha') {
              stopAll('页面要求人机验证，批量任务已停止。');
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

            try {
              installSubmitObserver(task);
            } catch (error) {
              finishTask(task, false, `无法监听提交结果：${error.message || error}`);
              return;
            }

            task.phase = 'queued-for-submit';
            runner.submitQueue.push(task);
            runner.prepared += 1;
            notify({
              type: 'prepared',
              prepared: runner.prepared,
              active: runner.active,
              total,
              presetName: task.name
            });
            if (runner.prepared === total) {
              notify({
                type: 'readyToSubmit',
                prepared: runner.prepared,
                active: runner.active,
                total
              });
            }
          };

          const workerURL = (() => {
            const requested = new URL(config.surveyURL, window.location.href);
            const currentHost = window.location.hostname.toLocaleLowerCase();
            const requestedHost = requested.hostname.toLocaleLowerCase();
            const isWJXHost = hostName => hostName === 'wjx.cn' || hostName.endsWith('.wjx.cn');
            if (isWJXHost(currentHost) && isWJXHost(requestedHost)) {
              requested.protocol = window.location.protocol;
              requested.host = window.location.host;
            }
            return requested.href;
          })();

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
            frame.src = workerURL;
            host.appendChild(frame);
          };

          if (!total) {
            notify({ type: 'fatal', message: '没有可用的测试预设。', total: 0 });
            runner.cancel(false);
            return JSON.stringify({ status: 'empty' });
          }

          config.tasks.forEach(startTask);
          notify({
            type: 'started',
            completed: 0,
            succeeded: 0,
            failed: 0,
            active: runner.active,
            total
          });
          return JSON.stringify({ status: 'started', total });
        })()
        """#
    }

    static func submitPreparedParallel(runID: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [runID]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return #"""
        (() => {
          const requestedRunID = \#(json)[0];
          const runner = window.__wjxParallelTest;
          if (!runner || runner.runID !== requestedRunID || typeof runner.submitAll !== 'function') {
            return JSON.stringify({ status: 'unavailable' });
          }
          return JSON.stringify(runner.submitAll());
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
          if (runner && runner.runID === requestedRunID && typeof runner.cancel === 'function') {
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

      const captchaText = ['请完成安全验证', '点击开始智能验证', '请先完成验证']
        .some(message => pageText.includes(message));
      const captchaCandidates = Array.from(document.querySelectorAll(
        '#captcha, #captchabtn, #captchaWrap, .captcha-wrap, .tcaptcha-transform, iframe[src*="captcha"], iframe[src*="verify"]'
      ));
      if (captchaText || captchaCandidates.some(element => {
        if (!visible(element)) return false;
        const rect = element.getBoundingClientRect();
        return element.matches('iframe') || !!element.querySelector?.('iframe') || rect.height >= 80;
      })) {
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
