import Foundation
import Security

enum LegacyRemovedFeatureCleanup {
    static func removeOfficialAPIData(defaults: UserDefaults) {
        defaults.removeObject(forKey: "officialAPISettings.v1")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.example.WJXAutoFill.official-api",
            kSecAttrAccount as String: "gateway-access-token"
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum RequestHeaderAction: String, Codable, CaseIterable, Identifiable, Hashable {
    case add
    case modify
    case delete

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .add: return "新增"
        case .modify: return "修改"
        case .delete: return "删除"
        }
    }

    var symbolName: String {
        switch self {
        case .add: return "plus.circle"
        case .modify: return "pencil.circle"
        case .delete: return "minus.circle"
        }
    }
}

struct RequestHeaderMutation: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var action: RequestHeaderAction = .add
    var name: String = ""
    var value: String = ""

    var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct RequestHeaderProfile: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var urlPattern: String
    var isEnabled: Bool = true
    var headers: [RequestHeaderMutation]

    static var newProfile: RequestHeaderProfile {
        RequestHeaderProfile(
            name: "新请求头配置",
            urlPattern: "*.wjx.cn",
            headers: [RequestHeaderMutation()]
        )
    }
}

enum RequestHeaderProfileValidator {
    private static let unsupportedNames: Set<String> = [
        "connection",
        "content-length",
        "cookie",
        "host",
        "set-cookie",
        "transfer-encoding"
    ]

    static func validationMessage(for profile: RequestHeaderProfile) -> String? {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "请输入配置名称"
        }
        guard !profile.urlPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "请输入网址匹配规则"
        }
        guard !profile.headers.isEmpty else {
            return "请至少添加一条请求头规则"
        }

        var seenNames = Set<String>()
        for (index, header) in profile.headers.enumerated() {
            let name = header.normalizedName
            guard isValidHeaderName(name) else {
                return "第 \(index + 1) 条请求头名称无效"
            }
            let key = name.lowercased()
            guard !unsupportedNames.contains(key) else {
                return "iOS WebView 不支持修改请求头 \(name)"
            }
            guard seenNames.insert(key).inserted else {
                return "请求头 \(name) 在同一配置中重复"
            }
            if header.action != .delete,
               header.value.contains("\r") || header.value.contains("\n") {
                return "请求头 \(name) 的值不能包含换行符"
            }
        }
        return nil
    }

    static func isSensitiveHeader(_ name: String) -> Bool {
        ["authorization", "proxy-authorization", "x-api-key", "api-key"]
            .contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func isValidHeaderName(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowed = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        )
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

enum RequestHeaderResolver {
    static func matches(_ profile: RequestHeaderProfile, url: URL) -> Bool {
        matches(pattern: profile.urlPattern, url: url)
    }

    static func mutations(
        for url: URL,
        profiles: [RequestHeaderProfile]
    ) -> [RequestHeaderMutation] {
        var order: [String] = []
        var resolved: [String: RequestHeaderMutation] = [:]
        for profile in profiles where profile.isEnabled && matches(profile, url: url) {
            for header in profile.headers {
                let key = header.normalizedName.lowercased()
                guard !key.isEmpty else { continue }
                if resolved[key] == nil { order.append(key) }
                var normalized = header
                normalized.name = header.normalizedName
                normalized.value = header.value.trimmingCharacters(in: .newlines)
                resolved[key] = normalized
            }
        }
        return order.compactMap { resolved[$0] }
    }

    static func apply(
        profiles: [RequestHeaderProfile],
        to request: inout URLRequest
    ) {
        guard let url = request.url else { return }
        for mutation in mutations(for: url, profiles: profiles) {
            switch mutation.action {
            case .add, .modify:
                request.setValue(mutation.value, forHTTPHeaderField: mutation.name)
            case .delete:
                request.setValue(nil, forHTTPHeaderField: mutation.name)
            }
        }
    }

    static func customUserAgent(
        for url: URL,
        profiles: [RequestHeaderProfile]
    ) -> String? {
        guard let mutation = mutations(for: url, profiles: profiles)
            .last(where: { $0.name.caseInsensitiveCompare("User-Agent") == .orderedSame }) else {
            return nil
        }
        guard mutation.action != .delete else { return nil }
        return mutation.value
    }

    static func injectionScript(profiles: [RequestHeaderProfile]) -> String? {
        let enabledProfiles = profiles.filter(\.isEnabled)
        guard let data = try? JSONEncoder().encode(enabledProfiles) else {
            return nil
        }
        let payload = data.base64EncodedString()
        return #"""
        (() => {
          const installKey = '__wjxRequestHeaderInterceptorV1';
          let profiles = [];
          try {
            const bytes = Uint8Array.from(atob('\#(payload)'), value => value.charCodeAt(0));
            profiles = JSON.parse(new TextDecoder().decode(bytes));
          } catch (_) {
            return;
          }
          const existing = window[installKey];
          if (existing && typeof existing.update === 'function') {
            existing.update(profiles);
            return;
          }
          let activeProfiles = profiles;
          Object.defineProperty(window, installKey, {
            value: {
              update(nextProfiles) {
                activeProfiles = Array.isArray(nextProfiles) ? nextProfiles : [];
              }
            },
            configurable: false,
            enumerable: false,
            writable: false
          });

          const escapeRegExp = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
          const wildcardRegExp = value => new RegExp(
            '^' + value.split('*').map(escapeRegExp).join('.*') + '$',
            'i'
          );
          const matches = (patternValue, rawURL) => {
            const pattern = String(patternValue || '').trim();
            if (!pattern) return false;
            if (pattern === '*') return true;
            let target;
            try { target = new URL(rawURL, window.location.href); } catch (_) { return false; }
            const host = target.hostname.toLocaleLowerCase();
            const lowerPattern = pattern.toLocaleLowerCase();
            if (lowerPattern.startsWith('||')) {
              const domain = lowerPattern.slice(2).replace(/^\*\./, '').replace(/\/$/, '');
              return host === domain || host.endsWith('.' + domain);
            }
            if (lowerPattern.startsWith('*.') && !lowerPattern.includes('/')) {
              const domain = lowerPattern.slice(2);
              return host === domain || host.endsWith('.' + domain);
            }
            if (!lowerPattern.includes('/') && !lowerPattern.includes('*')) {
              return host === lowerPattern || host.endsWith('.' + lowerPattern);
            }
            if (lowerPattern.includes('*')) {
              return wildcardRegExp(pattern).test(target.href);
            }
            if (/^https?:\/\//i.test(pattern)) {
              return target.href.toLocaleLowerCase().startsWith(lowerPattern);
            }
            return target.href.toLocaleLowerCase().includes(lowerPattern);
          };
          const resolve = rawURL => {
            const result = new Map();
            for (const profile of activeProfiles) {
              if (!profile.isEnabled || !matches(profile.urlPattern, rawURL)) continue;
              for (const header of profile.headers || []) {
                const name = String(header.name || '').trim();
                if (!name) continue;
                result.set(name.toLocaleLowerCase(), {
                  action: String(header.action || 'add'),
                  name,
                  value: String(header.value || '')
                });
              }
            }
            return result;
          };

          const nativeFetch = window.fetch?.bind(window);
          if (nativeFetch && window.Headers && window.Request) {
            window.fetch = function(input, init) {
              const options = { ...(init || {}) };
              const rawURL = typeof input === 'string' || input instanceof URL
                ? String(input)
                : input?.url;
              const sourceHeaders = options.headers ||
                (input instanceof Request ? input.headers : undefined);
              const headers = new Headers(sourceHeaders || undefined);
              for (const mutation of resolve(rawURL || window.location.href).values()) {
                try {
                  if (mutation.action === 'delete') headers.delete(mutation.name);
                  else headers.set(mutation.name, mutation.value);
                } catch (_) {}
              }
              options.headers = headers;
              return nativeFetch(input, options);
            };
          }

          if (window.XMLHttpRequest) {
            const nativeOpen = XMLHttpRequest.prototype.open;
            const nativeSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
            const nativeSend = XMLHttpRequest.prototype.send;
            const stateKey = Symbol('wjxHeaderState');

            XMLHttpRequest.prototype.open = function(method, url) {
              let absoluteURL = String(url || '');
              try { absoluteURL = new URL(absoluteURL, window.location.href).href; } catch (_) {}
              this[stateKey] = { url: absoluteURL, headers: new Map() };
              return nativeOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
              const state = this[stateKey];
              if (!state) return nativeSetRequestHeader.call(this, name, value);
              const key = String(name).toLocaleLowerCase();
              const existing = state.headers.get(key);
              state.headers.set(key, {
                name: String(name),
                value: existing ? existing.value + ', ' + String(value) : String(value)
              });
            };
            XMLHttpRequest.prototype.send = function() {
              const state = this[stateKey];
              if (state) {
                for (const mutation of resolve(state.url).values()) {
                  const key = mutation.name.toLocaleLowerCase();
                  if (mutation.action === 'delete') state.headers.delete(key);
                  else state.headers.set(key, { name: mutation.name, value: mutation.value });
                }
                for (const header of state.headers.values()) {
                  try { nativeSetRequestHeader.call(this, header.name, header.value); } catch (_) {}
                }
              }
              return nativeSend.apply(this, arguments);
            };
          }
        })();
        """#
    }

    private static func matches(pattern rawPattern: String, url: URL) -> Bool {
        let pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return false }
        if pattern == "*" { return true }

        let lowerPattern = pattern.lowercased()
        let host = url.host?.lowercased() ?? ""
        if lowerPattern.hasPrefix("||") {
            let domain = String(lowerPattern.dropFirst(2))
                .trimmingCharacters(in: CharacterSet(charactersIn: "*/"))
            return host == domain || host.hasSuffix(".\(domain)")
        }
        if lowerPattern.hasPrefix("*.") && !lowerPattern.contains("/") {
            let domain = String(lowerPattern.dropFirst(2))
            return host == domain || host.hasSuffix(".\(domain)")
        }
        if !lowerPattern.contains("/") && !lowerPattern.contains("*") {
            return host == lowerPattern || host.hasSuffix(".\(lowerPattern)")
        }

        let target = url.absoluteString
        if pattern.contains("*") {
            let pieces = pattern.split(separator: "*", omittingEmptySubsequences: false)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            let expression = "^" + pieces.joined(separator: ".*") + "$"
            return target.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if lowerPattern.hasPrefix("http://") || lowerPattern.hasPrefix("https://") {
            return target.lowercased().hasPrefix(lowerPattern)
        }
        return target.localizedCaseInsensitiveContains(pattern)
    }
}

enum RequestHeaderProfileStore {
    private static let service = "com.example.WJXAutoFill.request-headers"
    private static let account = "profiles-v1"

    static func read() -> [RequestHeaderProfile] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let profiles = try? JSONDecoder().decode([RequestHeaderProfile].self, from: data) else {
            return []
        }
        return profiles
    }

    static func store(_ profiles: [RequestHeaderProfile]) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard !profiles.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}
