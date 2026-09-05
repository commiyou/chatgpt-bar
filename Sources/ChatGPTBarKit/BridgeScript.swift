import Foundation

/// The page-side bridge.
///
/// Two rules the prototype broke and this version keeps:
/// 1. every entry point returns `{ ok, value | error }`, so Swift can report
///    failures instead of silently doing nothing;
/// 2. nothing relies on a fixed delay - readiness is polled with a deadline.
public enum BridgeScript {
    public static let globalName = "__chatgptBar"
    public static let version = 1

    public static func source(selectors: SelectorSet) -> String {
        let json = jsonObjectLiteral(selectors.resolvedJSONObject)
        return """
        (function () {
          if (window.\(globalName)) { return; }
          var SELECTORS = \(json);
          var DEFAULT_TIMEOUT = 8000;

          function list(key) { return SELECTORS[key] || []; }
          function firstMatch(key, predicate) {
            var sels = list(key);
            for (var i = 0; i < sels.length; i++) {
              try {
                var el = document.querySelector(sels[i]);
                if (el && (!predicate || predicate(el))) { return { el: el, selector: sels[i] }; }
              } catch (e) { /* invalid selector, keep going */ }
            }
            return null;
          }
          function allMatches(key) {
            var sels = list(key);
            for (var i = 0; i < sels.length; i++) {
              try {
                var nodes = document.querySelectorAll(sels[i]);
                if (nodes.length) { return { nodes: Array.prototype.slice.call(nodes), selector: sels[i] }; }
              } catch (e) {}
            }
            return null;
          }
          function sleep(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }
          async function waitFor(key, timeout, predicate) {
            var deadline = Date.now() + (timeout || DEFAULT_TIMEOUT);
            for (;;) {
              var hit = firstMatch(key, predicate);
              if (hit) { return hit; }
              if (Date.now() >= deadline) { return null; }
              await sleep(100);
            }
          }
          function ok(value) { return { ok: true, value: value === undefined ? null : value }; }
          function fail(code, detail) { return { ok: false, error: code, detail: detail === undefined ? null : detail }; }
          function isEnabled(el) {
            return !el.disabled && el.getAttribute('aria-disabled') !== 'true';
          }
          function isField(el) { return el.tagName === 'TEXTAREA' || el.tagName === 'INPUT'; }
          function textOf(el) { return el.innerText || el.textContent || ''; }
          function caretToEnd(el) {
            el.focus();
            if (isField(el)) {
              try { el.setSelectionRange(el.value.length, el.value.length); } catch (e) {}
              return;
            }
            var sel = window.getSelection();
            if (!sel) { return; }
            var range = document.createRange();
            range.selectNodeContents(el);
            range.collapse(false);
            sel.removeAllRanges();
            sel.addRange(range);
          }
          function clearEditor(el) {
            el.focus();
            if (isField(el)) {
              el.value = '';
              el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
              return;
            }
            var sel = window.getSelection();
            if (sel) {
              var range = document.createRange();
              range.selectNodeContents(el);
              sel.removeAllRanges();
              sel.addRange(range);
            }
            try { document.execCommand('delete', false, null); } catch (e) {}
          }
          function typeInto(el, text) {
            el.focus();
            if (isField(el)) {
              el.value = el.value + text;
              el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
              try { el.setSelectionRange(el.value.length, el.value.length); } catch (e) {}
              return true;
            }
            var inserted = false;
            try { inserted = document.execCommand('insertText', false, text); } catch (e) { inserted = false; }
            if (!inserted) {
              try {
                var dt = new DataTransfer();
                dt.setData('text/plain', text);
                // preventDefault by the page means the editor consumed the paste.
                inserted = !el.dispatchEvent(new ClipboardEvent('paste', {
                  clipboardData: dt, bubbles: true, cancelable: true
                }));
              } catch (e) { inserted = false; }
            }
            return inserted;
          }
          function pressEnter(el) {
            var init = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
            el.focus();
            el.dispatchEvent(new KeyboardEvent('keydown', init));
            el.dispatchEvent(new KeyboardEvent('keyup', init));
          }

          // Frame-time sampler. WebKit has no Long Tasks API, so jank is
          // measured as requestAnimationFrame gaps. Only runs while sampling.
          var perf = null;
          function perfReset() {
            perf = { on: false, frames: 0, longFrames: 0, maxFrame: 0, blocking: 0, last: 0, startedAt: 0 };
          }
          perfReset();
          function perfTick(ts) {
            if (!perf.on) { return; }
            if (perf.last) {
              var delta = ts - perf.last;
              perf.frames++;
              if (delta > 50) { perf.longFrames++; perf.blocking += delta - 50; }
              if (delta > perf.maxFrame) { perf.maxFrame = delta; }
            }
            perf.last = ts;
            requestAnimationFrame(perfTick);
          }

          // The conversation scroller is an inner element, not the document, and
          // its ancestors are not reliably marked, so pick the tallest element
          // that actually scrolls.
          function findScroller() {
            var best = null;
            var fallback = null;
            var nodes = document.querySelectorAll('div, main, section, article');
            for (var i = 0; i < nodes.length; i++) {
              var el = nodes[i];
              if (el.scrollHeight <= el.clientHeight + 40) { continue; }
              if (!fallback || (el.scrollHeight - el.clientHeight) > (fallback.scrollHeight - fallback.clientHeight)) {
                fallback = el;
              }
              var overflow = getComputedStyle(el).overflowY;
              if (overflow !== 'auto' && overflow !== 'scroll' && overflow !== 'overlay') { continue; }
              if (!best || el.clientHeight > best.clientHeight) { best = el; }
            }
            if (best) { return best; }
            if (fallback) { return fallback; }
            var root = document.scrollingElement || document.body;
            return root;
          }

          window.\(globalName) = {
            version: \(version),
            selectors: SELECTORS,

            async ready(timeout) {
              var hit = await waitFor('editor', timeout);
              return hit ? ok({ selector: hit.selector }) : fail('editor_not_found');
            },

            async insert(text, mode, submitAfter, timeout) {
              var hit = await waitFor('editor', timeout);
              if (!hit) { return fail('editor_not_found'); }
              if (mode === 'replace') { clearEditor(hit.el); } else { caretToEnd(hit.el); }
              if (!typeInto(hit.el, text)) { return fail('insert_failed', hit.selector); }
              if (!submitAfter) {
                return ok({ inserted: true, submitted: false, selector: hit.selector });
              }
              var sent = await this.submit(timeout);
              return ok({
                inserted: true,
                submitted: sent.ok === true,
                submitError: sent.ok === true ? null : sent.error
              });
            },

            async submit(timeout) {
              var hit = await waitFor('send', timeout, isEnabled);
              if (hit) {
                hit.el.click();
                return ok({ strategy: 'button', selector: hit.selector });
              }
              var editor = firstMatch('editor');
              if (editor) {
                pressEnter(editor.el);
                return ok({ strategy: 'enter', selector: editor.selector });
              }
              return fail('send_button_not_found');
            },

            getInput() {
              var hit = firstMatch('editor');
              if (!hit) { return fail('editor_not_found'); }
              return ok({ text: isField(hit.el) ? hit.el.value : textOf(hit.el) });
            },

            clear() {
              var hit = firstMatch('editor');
              if (!hit) { return fail('editor_not_found'); }
              clearEditor(hit.el);
              return ok({ cleared: true });
            },

            lastResponse() {
              var hit = allMatches('assistant');
              if (!hit) { return fail('assistant_not_found'); }
              var last = hit.nodes[hit.nodes.length - 1];
              var text = textOf(last);
              if (!text) { return fail('assistant_empty', hit.selector); }
              return ok({ text: text, selector: hit.selector, count: hit.nodes.length });
            },

            newChat() {
              var hit = firstMatch('newChat');
              if (hit) {
                hit.el.click();
                return ok({ strategy: 'click', selector: hit.selector });
              }
              location.assign('/');
              return ok({ strategy: 'navigate' });
            },

            tempChat() {
              var hit = firstMatch('tempChat');
              if (hit) {
                hit.el.click();
                return ok({ strategy: 'click', selector: hit.selector });
              }
              location.assign('/?temporary-chat=true');
              return ok({ strategy: 'navigate' });
            },

            probe() {
              var results = [];
              Object.keys(SELECTORS).forEach(function (key) {
                SELECTORS[key].forEach(function (sel) {
                  var found = false;
                  var error = null;
                  try { found = !!document.querySelector(sel); }
                  catch (e) { error = String((e && e.message) || e); }
                  results.push({ key: key, selector: sel, found: found, error: error });
                });
              });
              return ok({ url: location.href, results: results });
            },

            perfStart() {
              perfReset();
              perf.on = true;
              perf.startedAt = performance.now();
              requestAnimationFrame(perfTick);
              return ok({ started: true });
            },

            perfStop() {
              if (!perf.on) { return fail('perf_not_running'); }
              perf.on = false;
              return ok({
                durationMs: Math.round(performance.now() - perf.startedAt),
                frames: perf.frames,
                longFrames: perf.longFrames,
                maxFrameMs: Math.round(perf.maxFrame),
                blockingMs: Math.round(perf.blocking)
              });
            },

            /// Deterministic scroll sweep so jank numbers are comparable.
            async scrollBench(durationMs) {
              var scroller = findScroller();
              if (!scroller) { return fail('scroller_not_found'); }
              var started = performance.now();
              var direction = 1;
              var steps = 0;
              while (performance.now() - started < (durationMs || 4000)) {
                scroller.scrollTop += direction * 500;
                steps++;
                if (scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 2) { direction = -1; }
                if (scroller.scrollTop <= 0) { direction = 1; }
                await sleep(32);
              }
              return ok({
                steps: steps,
                scrollHeight: scroller.scrollHeight,
                clientHeight: scroller.clientHeight,
                tag: scroller.tagName.toLowerCase(),
                scrollable: scroller.scrollHeight > scroller.clientHeight + 40
              });
            },

            metrics() {
              var turns = allMatches('turn');
              var assistants = allMatches('assistant');
              var nav = (performance.getEntriesByType && performance.getEntriesByType('navigation')[0]) || null;
              var firstTurn = (turns && turns.nodes.length) ? turns.nodes[0] : null;
              return ok({
                url: location.href,
                domNodes: document.getElementsByTagName('*').length,
                turns: turns ? turns.nodes.length : 0,
                turnSelector: turns ? turns.selector : null,
                assistantNodes: assistants ? assistants.nodes.length : 0,
                codeBlocks: document.querySelectorAll('pre').length,
                images: document.querySelectorAll('img').length,
                scrollHeight: document.documentElement.scrollHeight,
                turnContentVisibility: firstTurn ? getComputedStyle(firstTurn).contentVisibility : null,
                domContentLoadedMs: nav ? Math.round(nav.domContentLoadedEventEnd) : null,
                loadEventMs: nav ? Math.round(nav.loadEventEnd) : null,
                transferSizeKB: nav && nav.transferSize ? Math.round(nav.transferSize / 1024) : null
              });
            },

            dump() {
              var seen = {};
              var out = [];
              function add(line) { if (line && !seen[line]) { seen[line] = 1; out.push(line); } }
              document.querySelectorAll('[data-testid]').forEach(function (el) {
                add('testid=' + el.getAttribute('data-testid') + '  tag=' + el.tagName.toLowerCase());
              });
              document.querySelectorAll('[aria-label]').forEach(function (el) {
                add('aria=' + el.getAttribute('aria-label') + '  tag=' + el.tagName.toLowerCase());
              });
              document.querySelectorAll('[data-message-author-role]').forEach(function (el) {
                add('role=' + el.getAttribute('data-message-author-role') + '  tag=' + el.tagName.toLowerCase());
              });
              document.querySelectorAll('[contenteditable="true"]').forEach(function (el) {
                add('contenteditable  tag=' + el.tagName.toLowerCase() + '  id=' + (el.id || '-'));
              });
              return ok({ url: location.href, text: out.slice(0, 400).join('\\n'), count: out.length });
            }
          };
        })();
        """
    }

    /// Deterministic JSON so the generated script is stable between launches.
    static func jsonObjectLiteral(_ object: [String: [String]]) -> String {
        let pairs = object.keys.sorted().map { key -> String in
            let values = (object[key] ?? []).map { jsonString($0) }.joined(separator: ", ")
            return "\(jsonString(key)): [\(values)]"
        }
        return "{ " + pairs.joined(separator: ", ") + " }"
    }

    static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "<": out += "\\u003c"
            case ">": out += "\\u003e"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// Opt-in rendering tweaks for long conversations.
///
/// ChatGPT keeps the whole thread in the DOM, so a long conversation pays
/// layout and paint for every offscreen turn. `content-visibility: auto` lets
/// WebKit skip that work until a turn is near the viewport.
public enum RenderTweaks {
    public static let styleElementID = "chatgpt-bar-render-tweaks"

    public static func css(selectors: SelectorSet) -> String {
        // One rule per selector: an unsupported selector is dropped on its own
        // instead of invalidating the whole rule.
        selectors.selectors(for: .turn).map { selector in
            "\(selector) { content-visibility: auto; contain-intrinsic-size: auto 480px; }"
        }.joined(separator: "\n")
    }

    public static func source(selectors: SelectorSet) -> String {
        """
        (function () {
          if (document.getElementById(\(BridgeScript.jsonString(styleElementID)))) { return; }
          var style = document.createElement('style');
          style.id = \(BridgeScript.jsonString(styleElementID));
          style.textContent = \(BridgeScript.jsonString(css(selectors: selectors)));
          (document.head || document.documentElement).appendChild(style);
        })();
        """
    }
}

/// Swift-side view of the `{ ok, value | error }` contract.
public struct BridgeResponse {
    public let isOK: Bool
    public let error: String?
    public let detail: String?
    public let value: [String: Any]?

    public init(isOK: Bool, error: String? = nil, detail: String? = nil, value: [String: Any]? = nil) {
        self.isOK = isOK
        self.error = error
        self.detail = detail
        self.value = value
    }

    public static func parse(_ raw: Any?) -> BridgeResponse {
        guard let dict = raw as? [String: Any] else {
            return BridgeResponse(isOK: false, error: "malformed_response")
        }
        let isOK = (dict["ok"] as? Bool) ?? false
        let error = dict["error"] as? String
        let detail = dict["detail"] as? String
        let value = dict["value"] as? [String: Any]
        return BridgeResponse(isOK: isOK, error: error, detail: detail, value: value)
    }

    public func string(_ key: String) -> String? { value?[key] as? String }
    public func bool(_ key: String) -> Bool? { value?[key] as? Bool }
    public func array(_ key: String) -> [[String: Any]]? { value?[key] as? [[String: Any]] }
}

/// Human readable text for the failure codes the bridge can return.
public enum BridgeErrorText {
    public static func describe(_ code: String?) -> String {
        switch code {
        case "editor_not_found":
            return "找不到输入框（editor 选择器失配）"
        case "insert_failed":
            return "文本插入被页面拒绝"
        case "send_button_not_found":
            return "找不到发送按钮（send 选择器失配）"
        case "assistant_not_found":
            return "找不到回复内容（assistant 选择器失配）"
        case "assistant_empty":
            return "最后一条回复为空"
        case "not_loaded":
            return "页面尚未加载完成"
        case "bridge_missing":
            return "页面桥未注入，试试 Reload"
        case "malformed_response":
            return "页面桥返回了无法解析的结果"
        case .some(let other):
            return other
        case .none:
            return "未知错误"
        }
    }
}
