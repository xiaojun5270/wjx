import 'dart:convert';

import 'models.dart';

class AutomationScripts {
  static const countdownAutoStart = r'''
(() => {
  const clean = value => (value || '').replace(/\s+/g, ' ').trim();
  const visible = element => {
    if (!element) return false;
    const style = window.getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
  };
  const candidates = Array.from(document.querySelectorAll('button, a, input[type="button"], input[type="submit"]'));
  const startButton = candidates.find(element => {
    const label = clean(element.innerText || element.textContent || element.value);
    return visible(element) && /\u7acb\u5373\u5f00\u59cb|\u5f00\u59cb\u586b\u5199|\u8fdb\u5165\u95ee\u5377/.test(label);
  });
  if (startButton && !startButton.disabled && startButton.getAttribute('aria-disabled') !== 'true') {
    startButton.click();
    return JSON.stringify({status: 'clicked'});
  }
  const pageText = clean(document.body?.innerText);
  const seconds = Number(window.leftSeconds);
  const countdown = /\u5c06\u4e8e.{0,40}\u5f00\u653e|\u8ddd(?:\u79bb)?.{0,12}\u5f00\u59cb|\u6d3b\u52a8(?:\u5c1a\u672a|\u672a)\u5f00\u59cb|\u95ee\u5377(?:\u5c1a\u672a|\u672a)\u5f00\u59cb|\u5012\u8ba1\u65f6/.test(pageText)
    || (Number.isFinite(seconds) && seconds > 0)
    || !!document.querySelector('#countdownHtml');
  return JSON.stringify({status: countdown ? 'waiting' : 'none'});
})()
''';

  static const scan = r'''
(() => {
  const clean = value => (value || '').replace(/\s+/g, ' ').trim();
  const visible = element => {
    if (!element) return false;
    const style = window.getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
  };
  const pageText = clean(document.body?.innerText);
  const path = (window.location.pathname || '').toLowerCase();
  const controls = Array.from(document.querySelectorAll(
    '[topic] input:not([type="hidden"]):not([type="button"]):not([type="submit"]), ' +
    '[topic] textarea, [topic] select, [topic] [contenteditable="true"], ' +
    'div.field input:not([type="hidden"]):not([type="button"]):not([type="submit"]), ' +
    'div.field textarea, div.field select, div.field [contenteditable="true"], ' +
    'fieldset input:not([type="hidden"]):not([type="button"]):not([type="submit"]), ' +
    'fieldset textarea, fieldset select, fieldset [contenteditable="true"]'
  ));
  const success = ['\u7b54\u5377\u5df2\u7ecf\u63d0\u4ea4', '\u63d0\u4ea4\u6210\u529f\uff01', '\u63d0\u4ea4\u5b8c\u6210\uff01', '\u611f\u8c22\u60a8\u7684\u53c2\u4e0e\uff01']
    .find(message => pageText.includes(message));
  if (path.includes('/join/complete') || (!controls.some(visible) && success)) {
    return JSON.stringify({status: 'submitted', message: success || '\u9875\u9762\u5df2\u8fdb\u5165\u63d0\u4ea4\u5b8c\u6210\u72b6\u6001\u3002', questions: []});
  }
  const closed = ['\u4e0d\u80fd\u518d\u63a5\u53d7\u65b0\u7684\u7b54\u5377', '\u5df2\u8fbe\u5230\u53d1\u5e03\u8005\u8bbe\u7f6e\u7684\u6700\u5927\u586b\u5199\u4efd\u6570', '\u95ee\u5377\u5df2\u7ecf\u7ed3\u675f', '\u95ee\u5377\u5df2\u505c\u6b62', '\u8be5\u95ee\u5377\u4e0d\u5b58\u5728']
    .find(message => pageText.includes(message));
  if (closed) return JSON.stringify({status: 'closed', message: closed, questions: []});

  const captchaText = ['\u8bf7\u5b8c\u6210\u5b89\u5168\u9a8c\u8bc1', '\u70b9\u51fb\u5f00\u59cb\u667a\u80fd\u9a8c\u8bc1', '\u8bf7\u5148\u5b8c\u6210\u9a8c\u8bc1']
    .some(message => pageText.includes(message));
  const captcha = Array.from(document.querySelectorAll(
    '#captchaOut, #captcha, #captchabtn, #captchaWrap, .captcha-wrap, .tcaptcha-transform, iframe[src*="captcha"], iframe[src*="verify"]'
  )).some(element => visible(element));
  if (captchaText || captcha) return JSON.stringify({status: 'captcha', questions: []});

  const primary = Array.from(document.querySelectorAll('[topic], div.field'));
  const containers = primary.length ? primary : Array.from(document.querySelectorAll('fieldset'));
  const questions = [];
  const seen = new Set();
  for (const container of containers) {
    const inputs = container.querySelectorAll('input:not([type="hidden"]), textarea, select, [contenteditable="true"]');
    if (!inputs.length) continue;
    const title = container.querySelector('.field-label, .topichtml, .div_title_question, .title, legend');
    let text = clean(title?.innerText || title?.textContent || container.innerText)
      .replace(/^\s*\d+[\.\u3001]\s*/, '').slice(0, 160);
    if (!text || seen.has(text)) continue;
    seen.add(text);
    const kind = container.querySelector('input[type="radio"], input[type="checkbox"]')
      ? '\u9009\u62e9\u9898'
      : (container.querySelector('select') ? '\u4e0b\u62c9\u9898' : '\u586b\u7a7a\u9898');
    questions.push({text, kind});
  }
  return JSON.stringify({status: 'ready', questions});
})()
''';

  static String fill(SubmissionPreset preset) {
    final rules = SubmissionPreset.requiredFields
        .map((key) => {'question': key, 'answer': preset.answers[key] ?? ''})
        .where((rule) => (rule['answer'] ?? '').trim().isNotEmpty)
        .toList();
    final payload = jsonEncode(rules);
    return '''
(() => {
  const rules = $payload;
  const clean = value => (value || '').replace(/\\s+/g, ' ').trim();
  const normalized = value => clean(value).toLocaleLowerCase('zh-CN');
  const visible = element => {
    if (!element) return false;
    const style = window.getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
  };
  const fire = element => ['input', 'change', 'blur'].forEach(name =>
    element.dispatchEvent(new Event(name, {bubbles: true})));
  const setValue = (element, value) => {
    const prototype = element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
    setter ? setter.call(element, value) : (element.value = value);
    fire(element);
  };
  const primary = Array.from(document.querySelectorAll('[topic], div.field'));
  const containers = primary.length ? primary : Array.from(document.querySelectorAll('fieldset'));
  let matched = 0;
  let filled = 0;
  for (const rule of rules) {
    const container = containers.find(item => normalized(item.innerText).includes(normalized(rule.question)));
    if (!container || !clean(rule.answer)) continue;
    matched += 1;
    const selects = Array.from(container.querySelectorAll('select')).filter(item => !item.disabled);
    if (selects.length) {
      const answers = rule.answer.split(/[;\uff1b]/).map(clean).filter(Boolean);
      selects.forEach((select, index) => {
        const target = normalized(answers[index] || answers[0]);
        const option = Array.from(select.options).find(item => normalized(item.text).includes(target));
        if (option) { select.value = option.value; fire(select); filled += 1; }
      });
      continue;
    }
    const choices = Array.from(container.querySelectorAll('input[type="radio"], input[type="checkbox"]')).filter(item => !item.disabled);
    if (choices.length) {
      const targets = rule.answer.split(/[;\uff1b]/).map(normalized).filter(Boolean);
      for (const input of choices) {
        const root = input.closest('label, li, .ui-radio, .ui-checkbox, .option') || input.parentElement;
        if (targets.some(target => normalized(root?.innerText || root?.textContent).includes(target))) {
          if (!input.checked) input.click();
          fire(input); filled += 1;
        }
      }
      continue;
    }
    const fields = Array.from(container.querySelectorAll(
      'input:not([type="hidden"]):not([type="button"]):not([type="submit"]), textarea'
    )).filter(item => visible(item) && !item.disabled && !item.readOnly);
    const answers = rule.answer.split(/[;\uff1b]/).map(clean);
    fields.forEach((field, index) => { setValue(field, answers[index] || answers[0] || ''); filled += 1; });
    Array.from(container.querySelectorAll('[contenteditable="true"]')).filter(visible).forEach((field, index) => {
      field.textContent = answers[index] || answers[0] || ''; fire(field); filled += 1;
    });
  }
  return JSON.stringify({status: 'ok', matched, filled});
})()
''';
  }

  static const submit = r'''
(() => {
  const clean = value => (value || '').replace(/\s+/g, ' ').trim();
  const visible = element => {
    if (!element) return false;
    const style = window.getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
  };
  const pageText = clean(document.body?.innerText);
  const captcha = ['\u8bf7\u5b8c\u6210\u5b89\u5168\u9a8c\u8bc1', '\u70b9\u51fb\u5f00\u59cb\u667a\u80fd\u9a8c\u8bc1', '\u8bf7\u5148\u5b8c\u6210\u9a8c\u8bc1']
    .some(message => pageText.includes(message));
  if (captcha) return JSON.stringify({status: 'captcha'});
  const button = document.querySelector('#ctlNext, #submit_button, #lxNextBtn, #ytyyNextBtn, #divNext, button[type="submit"], input[type="submit"]');
  if (!button || !visible(button)) return JSON.stringify({status: 'unavailable', message: '\u5f53\u524d\u9875\u9762\u6ca1\u6709\u53ef\u7528\u7684\u63d0\u4ea4\u6309\u94ae\u3002'});
  setTimeout(() => button.click(), 80);
  return JSON.stringify({status: 'scheduled'});
})()
''';

  static String installHeaderInterceptor(
    List<RequestHeaderProfile> profiles,
  ) {
    final payload = jsonEncode(profiles.map((item) => item.toJson()).toList());
    return '''
(() => {
  const profiles = $payload;
'''
        r'''
  const existing = window.__wjxRequestHeaderInterceptorV1;
  if (existing?.update) { existing.update(profiles); return; }
  let activeProfiles = profiles;
  window.__wjxRequestHeaderInterceptorV1 = {
    update(nextProfiles) { activeProfiles = Array.isArray(nextProfiles) ? nextProfiles : []; }
  };
  const escapeRegExp = value => {
    const slash = String.fromCharCode(92);
    const dollar = String.fromCharCode(36);
    const specials = new Set(['.', '*', '+', '?', '^', dollar, '{', '}', '(', ')', '|', '[', ']', slash]);
    return Array.from(value).map(character => specials.has(character) ? slash + character : character).join('');
  };
  const matches = (patternValue, rawURL) => {
    const pattern = String(patternValue || '').trim();
    if (!pattern) return false;
    if (pattern === '*') return true;
    let target;
    try { target = new URL(rawURL, window.location.href); } catch (_) { return false; }
    const host = target.hostname.toLowerCase();
    const lower = pattern.toLowerCase();
    if (lower.startsWith('||')) {
      const domain = lower.slice(2).replace(/^\*\./, '').replace(/\/$/, '');
      return host === domain || host.endsWith('.' + domain);
    }
    if (lower.startsWith('*.') && !lower.includes('/')) {
      const domain = lower.slice(2);
      return host === domain || host.endsWith('.' + domain);
    }
    if (!lower.includes('/') && !lower.includes('*')) {
      return host === lower || host.endsWith('.' + lower);
    }
    if (lower.includes('*')) {
      const expression = '^' + pattern.split('*').map(escapeRegExp).join('.*') + '$';
      return new RegExp(expression, 'i').test(target.href);
    }
    if (/^https?:\/\//i.test(pattern)) return target.href.toLowerCase().startsWith(lower);
    return target.href.toLowerCase().includes(lower);
  };
  const resolve = rawURL => {
    const result = new Map();
    for (const profile of activeProfiles) {
      if (!profile.isEnabled || !matches(profile.urlPattern, rawURL)) continue;
      for (const header of profile.headers || []) {
        const name = String(header.name || '').trim();
        if (!name) continue;
        result.set(name.toLowerCase(), {
          action: String(header.action || 'add'), name, value: String(header.value || '')
        });
      }
    }
    return result;
  };
  const nativeFetch = window.fetch?.bind(window);
  if (nativeFetch && window.Headers && window.Request) {
    window.fetch = function(input, init = {}) {
      const rawURL = typeof input === 'string' || input instanceof URL ? String(input) : input?.url;
      const merged = new Headers(init.headers || (input instanceof Request ? input.headers : undefined));
      for (const mutation of resolve(rawURL || window.location.href).values()) {
        try {
          if (mutation.action === 'delete') merged.delete(mutation.name);
          else merged.set(mutation.name, mutation.value);
        } catch (_) {}
      }
      return nativeFetch(input, {...init, headers: merged});
    };
  }
  if (window.XMLHttpRequest) {
    const nativeOpen = XMLHttpRequest.prototype.open;
    const nativeSet = XMLHttpRequest.prototype.setRequestHeader;
    const nativeSend = XMLHttpRequest.prototype.send;
    const stateKey = Symbol('wjxHeaderState');
    XMLHttpRequest.prototype.open = function(method, url) {
      let absoluteURL = String(url || '');
      try { absoluteURL = new URL(absoluteURL, window.location.href).href; } catch (_) {}
      this[stateKey] = {url: absoluteURL, headers: new Map()};
      return nativeOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
      const state = this[stateKey];
      if (!state) return nativeSet.call(this, name, value);
      const key = String(name).toLowerCase();
      const current = state.headers.get(key);
      state.headers.set(key, {name: String(name), value: current ? current.value + ', ' + value : String(value)});
    };
    XMLHttpRequest.prototype.send = function() {
      const state = this[stateKey];
      if (state) {
        for (const mutation of resolve(state.url).values()) {
          const key = mutation.name.toLowerCase();
          if (mutation.action === 'delete') state.headers.delete(key);
          else state.headers.set(key, {name: mutation.name, value: mutation.value});
        }
        for (const header of state.headers.values()) {
          try { nativeSet.call(this, header.name, header.value); } catch (_) {}
        }
      }
      return nativeSend.apply(this, arguments);
    };
  }
})()
''';
  }
}
