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
          const rules = #(json);
          const clean = value => (value || '').replace(/\s+/g, ' ').trim();
          const normalized = value => clean(value).toLocaleLowerCase('zh-CN');
          const resolveDynamicAnswer = rawValue => {
            const value = clean(rawValue);
            const match = value.match(/^\{\{random_email(?::([^}]+))?\}\}$/i);
            if (!match) return value;
            const domain = clean(match[1] || 'example.com')
              .replace(/^@+/, '')
              .replace(/\s+/g, '') || 'example.com';
            const timestamp = Date.now().toString(36);
            const randomPart = Math.random().toString(36).slice(2, 10);
            return `test_${timestamp}_${randomPart}@${domain}`;
          };
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
            const answer = resolveDynamicAnswer(rule.answer);
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
