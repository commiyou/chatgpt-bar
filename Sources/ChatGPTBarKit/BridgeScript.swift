import Foundation

/// The page-side bridge.
///
/// Two rules the prototype broke and this version keeps:
/// 1. every entry point returns `{ ok, value | error }`, so Swift can report
///    failures instead of silently doing nothing;
/// 2. nothing relies on a fixed delay - readiness is polled with a deadline.
public enum BridgeScript {
    public static let globalName = "__chatgptBar"
    public static let version = 2

    public static func source(selectors: SelectorSet) -> String {
        let json = jsonObjectLiteral(selectors.resolvedJSONObject)
        return """
        (function () {
          if (window.\(globalName)) { return; }
          var SELECTORS = \(json);
          var DEFAULT_TIMEOUT = 8000;
          var mutationObserver = null;
          var mutationWaiters = [];

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
          function stopMutationObserverIfIdle() {
            if (mutationObserver && mutationWaiters.length === 0) {
              mutationObserver.disconnect();
              mutationObserver = null;
            }
          }
          function ensureMutationObserver() {
            if (mutationObserver || !window.MutationObserver) { return; }
            mutationObserver = new MutationObserver(function () {
              var waiters = mutationWaiters.slice();
              waiters.forEach(function (waiter) { waiter(); });
            });
            mutationObserver.observe(document.documentElement || document, {
              subtree: true,
              childList: true,
              characterData: true,
              attributes: true,
              attributeFilter: ['aria-label', 'data-testid', 'data-message-author-role', 'disabled', 'aria-disabled']
            });
          }
          async function waitFor(key, timeout, predicate) {
            ensureMutationObserver();
            return await new Promise(function (resolve) {
              var done = false;
              var deadline = Date.now() + (timeout || DEFAULT_TIMEOUT);
              var waiter = function () {
                if (done) { return; }
                var hit = firstMatch(key, predicate);
                if (hit) {
                  done = true;
                  mutationWaiters = mutationWaiters.filter(function (item) { return item !== waiter; });
                  clearTimeout(timer);
                  stopMutationObserverIfIdle();
                  resolve(hit);
                }
              };
              var timer = setTimeout(function () {
                if (done) { return; }
                done = true;
                mutationWaiters = mutationWaiters.filter(function (item) { return item !== waiter; });
                stopMutationObserverIfIdle();
                resolve(null);
              }, Math.max(0, deadline - Date.now()));
              mutationWaiters.push(waiter);
              waiter();
            });
          }
          function ok(value) { return { ok: true, value: value === undefined ? null : value }; }
          function fail(code, detail) { return { ok: false, error: code, detail: detail === undefined ? null : detail }; }
          function isEnabled(el) {
            return !el.disabled && el.getAttribute('aria-disabled') !== 'true';
          }
          function isField(el) { return el.tagName === 'TEXTAREA' || el.tagName === 'INPUT'; }
          function textOf(el) { return el.innerText || el.textContent || ''; }
          function isNonContent(node) {
            if (!node || node.nodeType !== 1) { return false; }
            var tag = node.tagName.toLowerCase();
            return tag === 'button' || tag === 'nav' || tag === 'footer'
              || tag === 'script' || tag === 'style' || tag === 'svg';
          }
          function inlineMarkdown(node) {
            if (node.nodeType === 3) {
              return node.nodeValue.replace(/\\s+/g, ' ');
            }
            if (node.nodeType !== 1) { return ''; }
            if (isNonContent(node)) { return ''; }
            var mathSource = node.getAttribute('data-math-source');
            if (node.getAttribute('role') === 'math' && mathSource) {
              return '$' + mathSource + '$';
            }
            var tag = node.tagName.toLowerCase();
            if (tag === 'br') { return '\\n'; }
            if (tag === 'code' && node.parentElement && node.parentElement.tagName.toLowerCase() !== 'pre') {
              return '`' + (node.textContent || '').replace(/`/g, '\\\\`') + '`';
            }
            if (tag === 'strong' || tag === 'b') { return '**' + inlineChildren(node) + '**'; }
            if (tag === 'em' || tag === 'i') { return '*' + inlineChildren(node) + '*'; }
            if (tag === 'del' || tag === 's') { return '~~' + inlineChildren(node) + '~~'; }
            if (tag === 'a' && node.getAttribute('href')) {
              return '[' + inlineChildren(node).trim() + '](' + node.getAttribute('href') + ')';
            }
            if (tag === 'img' && node.getAttribute('src')) {
              return '![' + (node.getAttribute('alt') || '') + '](' + node.getAttribute('src') + ')';
            }
            return inlineChildren(node);
          }
          function inlineChildren(node) {
            var out = '';
            for (var child = node.firstChild; child; child = child.nextSibling) {
              out += inlineMarkdown(child);
            }
            return out;
          }
          function markdownOf(root) {
            function tableCellMarkdown(cell) {
              return inlineChildren(cell)
                .replace(/\\s+/g, ' ')
                .replace(/\\|/g, '\\\\|')
                .trim();
            }
            function tableMarkdown(table) {
              var rows = table.querySelectorAll('tr');
              var parsed = [];
              for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
                var row = rows[rowIndex];
                var cells = [];
                var aligns = [];
                for (var cell = row.firstElementChild; cell; cell = cell.nextElementSibling) {
                  var cellTag = cell.tagName.toLowerCase();
                  if (cellTag !== 'th' && cellTag !== 'td') { continue; }
                  cells.push(tableCellMarkdown(cell));
                  var style = (cell.getAttribute('style') || '').toLowerCase().replace(/\\s+/g, '');
                  aligns.push(style.indexOf('text-align:right') >= 0 ? 'right'
                    : style.indexOf('text-align:center') >= 0 ? 'center' : 'left');
                }
                if (cells.length) { parsed.push({ cells: cells, aligns: aligns }); }
              }
              if (!parsed.length) { return ''; }
              var width = parsed.reduce(function (max, row) { return Math.max(max, row.cells.length); }, 0);
              function padded(row) {
                var cells = row ? row.cells.slice() : [];
                while (cells.length < width) { cells.push(''); }
                return '| ' + cells.join(' | ') + ' |';
              }
              var header = padded(parsed[0]);
              var separators = [];
              for (var column = 0; column < width; column++) {
                var alignment = parsed[0].aligns[column] || 'left';
                separators.push(alignment === 'right' ? '---:'
                  : alignment === 'center' ? ':---:' : '---');
              }
              var output = '\\n' + header + '\\n| ' + separators.join(' | ') + ' |';
              for (var bodyIndex = 1; bodyIndex < parsed.length; bodyIndex++) {
                output += '\\n' + padded(parsed[bodyIndex]);
              }
              return output + '\\n\\n';
            }
            function render(node, depth) {
              if (node.nodeType === 3) { return node.nodeValue.replace(/\\s+/g, ' ').trim(); }
              if (node.nodeType !== 1) { return ''; }
              if (isNonContent(node)) { return ''; }
              var mathSource = node.getAttribute('data-math-source');
              if (node.getAttribute('role') === 'math' && mathSource) {
                return '\\n$$\\n' + mathSource + '\\n$$\\n\\n';
              }
              var tag = node.tagName.toLowerCase();
              if (tag === 'pre') {
                var code = node.querySelector('code');
                var value = (code ? code.textContent : node.textContent || '').replace(/\\r\\n/g, '\\n').replace(/\\n+$/, '');
                var className = code ? (code.className || '') : '';
                var match = className.match(/language-([\\w+-]+)/);
                return '\\n```' + (match ? match[1] : '') + '\\n' + value + '\\n```\\n';
              }
              if (tag === 'table') { return tableMarkdown(node); }
              if (/^h[1-6]$/.test(tag)) {
                return '\\n' + '#'.repeat(parseInt(tag.slice(1), 10)) + ' ' + inlineChildren(node).trim() + '\\n\\n';
              }
              if (tag === 'blockquote') {
                var quote = '';
                for (var quoteChild = node.firstChild; quoteChild; quoteChild = quoteChild.nextSibling) {
                  quote += quoteChild.nodeType === 1 ? render(quoteChild, depth) : inlineMarkdown(quoteChild);
                }
                return '\\n' + quote.trim().split('\\n').map(function (line) { return '> ' + line; }).join('\\n') + '\\n\\n';
              }
              if (tag === 'hr') { return '\\n---\\n\\n'; }
              if (tag === 'ul' || tag === 'ol') {
                var ordered = tag === 'ol';
                var index = 1;
                var lines = [];
                for (var item = node.firstElementChild; item; item = item.nextElementSibling) {
                  if (item.tagName.toLowerCase() !== 'li') { continue; }
                  var nested = '';
                  var content = '';
                  for (var child = item.firstChild; child; child = child.nextSibling) {
                    if (child.nodeType === 1 && (child.tagName.toLowerCase() === 'ul' || child.tagName.toLowerCase() === 'ol')) {
                      nested += render(child, depth + 1);
                    } else {
                      content += inlineMarkdown(child);
                    }
                  }
                  var prefix = ordered ? (index++) + '. ' : '- ';
                  lines.push('  '.repeat(depth) + prefix + content.trim() + (nested ? '\\n' + nested.trimEnd() : ''));
                }
                return '\\n' + lines.join('\\n') + '\\n\\n';
              }
              if (tag === 'p' || tag === 'div' || tag === 'section' || tag === 'article') {
                var body = '';
                for (var child = node.firstChild; child; child = child.nextSibling) {
                  body += child.nodeType === 1 ? render(child, depth) : inlineMarkdown(child);
                }
                return body.trim() ? '\\n' + body.trim() + '\\n\\n' : '';
              }
              return inlineChildren(node);
            }
            var result = '';
            for (var child = root.firstChild; child; child = child.nextSibling) {
              result += child.nodeType === 1 ? render(child, 0) : inlineMarkdown(child);
            }
            return result.replace(/[ \\t]+\\n/g, '\\n').replace(/\\n{3,}/g, '\\n\\n').trim();
          }
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
          function firstButtonInScope(scope) {
            var selectors = list('copyButton');
            var fallback = null;
            for (var i = 0; i < selectors.length; i++) {
              try {
                var nodes = scope.querySelectorAll(selectors[i]);
                for (var j = 0; j < nodes.length; j++) {
                  var button = nodes[j];
                  if (button.tagName.toLowerCase() !== 'button' || !isEnabled(button)) { continue; }
                  var label = (button.getAttribute('aria-label') || button.getAttribute('title') || button.textContent || '').trim().toLowerCase();
                  if (label === 'copy response' || label === '复制回复') {
                    return { el: button, selector: selectors[i] };
                  }
                  if (!fallback && !button.closest('pre, table')
                      && label !== 'copy table' && label !== '复制表格'
                      && label !== 'copy message' && label !== '复制消息') {
                    fallback = { el: button, selector: selectors[i] };
                  }
                }
              } catch (e) {}
            }
            return fallback;
          }
          function copyButtonForLastResponse() {
            var hit = allMatches('assistant');
            if (!hit) { return null; }
            var last = hit.nodes[hit.nodes.length - 1];
            var scope = last;
            for (var depth = 0; scope && depth < 6; depth++, scope = scope.parentElement) {
              var button = firstButtonInScope(scope);
              if (button) { return { button: button.el, selector: button.selector }; }
            }
            return null;
          }
          // Frame-time sampler. Long Tasks is not available in every WebKit
          // version, so keep an rAF fallback. The public perfRun method keeps
          // the sampler and scroll loop in one JS task boundary.
          var perf = null;
          var longTaskState = { supported: false, count: 0, totalMs: 0, maxMs: 0 };
          var resourceState = { count: -1, transfer: 0, duration: 0 };
          try {
            var supportedTypes = (window.PerformanceObserver && PerformanceObserver.supportedEntryTypes) || [];
            longTaskState.supported = supportedTypes.indexOf('longtask') >= 0;
            if (longTaskState.supported) {
              var longTaskObserver = new PerformanceObserver(function (list) {
                list.getEntries().forEach(function (entry) {
                  var duration = Number(entry.duration) || 0;
                  longTaskState.count++;
                  longTaskState.totalMs += duration;
                  if (duration > longTaskState.maxMs) { longTaskState.maxMs = duration; }
                });
              });
              longTaskObserver.observe({ entryTypes: ['longtask'] });
            }
          } catch (e) {
            longTaskState.supported = false;
          }

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

          function perfResult() {
            return {
              supported: perf.frames > 0,
              visibilityState: document.visibilityState || null,
              durationMs: Math.round(performance.now() - perf.startedAt),
              frames: perf.frames,
              longFrames: perf.longFrames,
              maxFrameMs: Math.round(perf.maxFrame),
              blockingMs: Math.round(perf.blocking)
            };
          }

          // The conversation scroller is an inner element, not the document, and
          // its ancestors are not reliably marked, so pick the tallest element
          // that actually scrolls.
          var cachedScroller = null;
          function findScroller() {
            if (cachedScroller && cachedScroller.isConnected
                && cachedScroller.scrollHeight > cachedScroller.clientHeight + 40) {
              return cachedScroller;
            }
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
            if (best) {
              cachedScroller = best;
              return best;
            }
            if (fallback) {
              cachedScroller = fallback;
              return fallback;
            }
            var root = document.scrollingElement || document.body;
            cachedScroller = root;
            return root;
          }

          function contentSnapshot() {
            var turns = allMatches('turn');
            var assistants = allMatches('assistant');
            var lastAssistant = assistants && assistants.nodes.length
              ? assistants.nodes[assistants.nodes.length - 1] : null;
            var scroller = findScroller();
            var isConversation = !!(turns || assistants)
              || /\\/c\\//.test(location.pathname || '');
            return {
              isConversation: isConversation,
              turns: turns ? turns.nodes.length : 0,
              assistants: assistants ? assistants.nodes.length : 0,
              scrollHeight: scroller ? scroller.scrollHeight : 0,
              lastTextLength: lastAssistant ? (lastAssistant.textContent || '').length : 0,
              codeBlocks: document.querySelectorAll('pre').length
            };
          }

          async function waitForContentStableInternal(timeoutMs, quietMs) {
            ensureMutationObserver();
            return await new Promise(function (resolve) {
              var started = performance.now();
              var timeout = timeoutMs || 15000;
              var quiet = quietMs || 500;
              var settled = false;
              var quietTimer = null;
              var deadlineTimer = null;
              var previous = null;
              function finish(snapshot, stable) {
                if (settled) { return; }
                settled = true;
                clearTimeout(quietTimer);
                clearTimeout(deadlineTimer);
                mutationWaiters = mutationWaiters.filter(function (item) { return item !== check; });
                stopMutationObserverIfIdle();
                resolve({
                  stable: stable,
                  elapsedMs: Math.round(performance.now() - started),
                  turns: snapshot.turns,
                  assistants: snapshot.assistants,
                  scrollHeight: snapshot.scrollHeight
                });
              }
              function armQuietTimer(snapshot) {
                clearTimeout(quietTimer);
                quietTimer = setTimeout(function () {
                  var latest = contentSnapshot();
                  var same = JSON.stringify(latest) === JSON.stringify(snapshot);
                  finish(latest, same);
                }, quiet);
              }
              function check() {
                if (settled) { return; }
                var snapshot = contentSnapshot();
                if (!snapshot.isConversation) {
                  finish(snapshot, true);
                  return;
                }
                if (snapshot.turns > 0 || snapshot.assistants > 0) {
                  if (!previous || JSON.stringify(previous) !== JSON.stringify(snapshot)) {
                    previous = snapshot;
                    armQuietTimer(snapshot);
                  }
                }
              }
              deadlineTimer = setTimeout(function () {
                finish(contentSnapshot(), false);
              }, timeout);
              mutationWaiters.push(check);
              check();
            });
          }

          window.\(globalName) = {
            version: \(version),
            selectors: SELECTORS,

            configure(nextSelectors) {
              if (!nextSelectors || typeof nextSelectors !== 'object') {
                return fail('invalid_selectors');
              }
              Object.keys(nextSelectors).forEach(function (key) {
                if (Array.isArray(nextSelectors[key])) { SELECTORS[key] = nextSelectors[key].slice(); }
              });
              cachedScroller = null;
              return ok({ configured: true, selectors: SELECTORS });
            },

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

            getLastResponse() {
              var hit = allMatches('assistant');
              if (!hit) { return fail('assistant_not_found'); }
              var last = hit.nodes[hit.nodes.length - 1];
              var markdown = '';
              try { markdown = markdownOf(last); } catch (e) { markdown = textOf(last); }
              if (!markdown) { return fail('assistant_empty', hit.selector); }
              return ok({ markdown: markdown, text: markdown, selector: hit.selector, count: hit.nodes.length });
            },

            // Kept as a compatibility alias for older callers.
            lastResponse() {
              return this.getLastResponse();
            },

            clickCopyButton() {
              var hit = copyButtonForLastResponse();
              if (!hit) { return fail('copy_button_not_found'); }
              if (!isEnabled(hit.button)) { return fail('copy_button_disabled', hit.selector); }
              hit.button.click();
              return ok({ selector: hit.selector, strategy: 'chatgpt-copy-button' });
            },

            waitForContentStable(timeoutMs, quietMs) {
              return waitForContentStableInternal(timeoutMs, quietMs).then(ok);
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
              return ok(perfResult());
            },

            /// Runs frame sampling and a deterministic scroll sweep in one
            /// async invocation so WebKit cannot suspend the rAF loop between
            /// separate bridge calls.
            async perfRun(durationMs) {
              var scroller = findScroller();
              if (!scroller) { return fail('scroller_not_found'); }
              perfReset();
              perf.on = true;
              perf.startedAt = performance.now();
              requestAnimationFrame(perfTick);
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
              perf.on = false;
              return ok({
                sample: perfResult(),
                steps: steps,
                scrollHeight: scroller.scrollHeight,
                clientHeight: scroller.clientHeight,
                tag: scroller.tagName.toLowerCase(),
                scrollable: scroller.scrollHeight > scroller.clientHeight + 40
              });
            },

            // Compatibility alias for callers that only want the scroll result.
            async scrollBench(durationMs) {
              var result = await this.perfRun(durationMs);
              if (!result.ok) { return result; }
              return ok({
                steps: result.value.steps,
                scrollHeight: result.value.scrollHeight,
                clientHeight: result.value.clientHeight,
                tag: result.value.tag,
                scrollable: result.value.scrollable
              });
            },

            metrics() {
              var turns = allMatches('turn');
              var assistants = allMatches('assistant');
              var nav = (performance.getEntriesByType && performance.getEntriesByType('navigation')[0]) || null;
              var firstTurn = (turns && turns.nodes.length) ? turns.nodes[0] : null;
              var scroller = findScroller();
              var isConversation = !!(turns || assistants)
                || /\\/c\\//.test(location.pathname || '');
              var resources = (performance.getEntriesByType && performance.getEntriesByType('resource')) || [];
              if (resources.length !== resourceState.count) {
                resourceState.count = resources.length;
                resourceState.transfer = 0;
                resourceState.duration = 0;
                for (var resourceIndex = 0; resourceIndex < resources.length; resourceIndex++) {
                  resourceState.transfer += Number(resources[resourceIndex].transferSize) || 0;
                  resourceState.duration = Math.max(resourceState.duration, Number(resources[resourceIndex].duration) || 0);
                }
              }
              return ok({
                url: location.href,
                contentState: isConversation
                  ? ((turns && turns.nodes.length) || (assistants && assistants.nodes.length)
                    ? 'conversation'
                    : 'conversation_loading')
                  : 'home',
                isConversation: isConversation,
                domNodes: document.getElementsByTagName('*').length,
                turns: turns ? turns.nodes.length : 0,
                turnSelector: turns ? turns.selector : null,
                assistantNodes: assistants ? assistants.nodes.length : 0,
                codeBlocks: document.querySelectorAll('pre').length,
                images: document.querySelectorAll('img').length,
                documentScrollHeight: document.documentElement.scrollHeight,
                conversationScroller: scroller ? {
                  tag: scroller.tagName.toLowerCase(),
                  scrollHeight: scroller.scrollHeight,
                  clientHeight: scroller.clientHeight,
                  scrollable: scroller.scrollHeight > scroller.clientHeight + 40
                } : null,
                resourceCount: resources.length,
                resourceTransferSizeKB: resourceState.transfer ? Math.round(resourceState.transfer / 1024) : 0,
                slowestResourceMs: resourceState.duration ? Math.round(resourceState.duration) : 0,
                longTasks: {
                  supported: longTaskState.supported,
                  count: longTaskState.count,
                  totalMs: Math.round(longTaskState.totalMs),
                  maxMs: Math.round(longTaskState.maxMs)
                },
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
    public func number(_ key: String) -> Double? {
        if let value = value?[key] as? NSNumber { return value.doubleValue }
        if let value = value?[key] as? Double { return value }
        if let value = value?[key] as? Int { return Double(value) }
        return nil
    }
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
        case "copy_button_not_found":
            return "找不到页面 Copy 按钮（可在页面适配中检查 copyButton 选择器）"
        case "copy_button_disabled":
            return "页面 Copy 按钮不可用"
        case "page_copy_not_captured":
            return "未能捕获页面 Copy 内容，已尝试从渲染 DOM 回退"
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
