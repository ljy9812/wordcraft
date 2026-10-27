import { webview } from '@kit.ArkWeb';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';

const TAG: string = 'WordCraft';
const MAIN_URL: string = 'https://local.wordcraft/index.html';
const URL_PREFIX: string = 'https://local.wordcraft/';
const RAW_PREFIX: string = 'web/';
const CHUNK_SIZE: number = 262144; // 256 KiB per message port frame (base64)
const URL_PATTERN: string = 'https://local.wordcraft/*';

interface ExportMsg {
  t: string;
  name?: string;
  data?: string;
}

// Injected before page scripts run:
// 1. receive the MessageChannel port handed over by ArkTS (window.__pc_port)
// 2. intercept <a download href="blob:..."> clicks and stream the blob through
//    the port in chunks. Two interception paths, because the apps differ:
//    - photocraft's wasm attaches its download anchor to the DOM before
//      clicking, so the click bubbles and the document listener (path 1) sees it.
//    - pdfcraft's wasm download() (ui-egui/src/editing.rs) creates the anchor,
//      sets download/href and clicks it WITHOUT appending — the click event of
//      a detached node never propagates to document, so no document listener
//      can see it. Desktop Chrome still runs the download activation for a
//      detached anchor (which is why upstream never noticed); ArkWeb does
//      nothing at all. Path 2 overrides HTMLAnchorElement.prototype.click to
//      catch programmatic clicks on detached (and attached) anchors.
//    wordcraft saves through the browser save picker first and falls back to
//    the same download path (apps/wordcraft-web/src/save_fallback.rs), so both
//    paths stay armed.
const START_SCRIPT: string = `(function() {
  if (window.__pc_hook) { return; }
  window.__pc_hook = true;
  console.log('[pc] hook installed');
  // Save-path routing fix (wordcraft round, 2026-10-26): this wasm saves through
  // the File System Access API (window.showSaveFilePicker called straight from
  // wasm with {types, suggestedName} — both option names are embedded in the
  // v0.11.0 binary). This ArkWeb build (6.1.0.117, API 23) bridges that call to
  // the embedder's onShowFileSelector — the same event this shell answers with a
  // select-only DocumentViewPicker (existing files only, no name field), so a
  // save could never create a file, and cancelling maps back to AbortError,
  // which the app's own save policy treats as "cancelled, no fallback". Neuter
  // the API instead: the call then throws TypeError, which save_fallback.rs
  // (tested for exactly this browser class: Security / NotSupported / TypeError)
  // answers with download() — the a[download] anchor Path 2 below intercepts,
  // streams through the port, and the shell ends in DocumentSavePicker with
  // newFileNames prefill = new-file creation (the photocraft/pdfcraft-proven
  // save path). Delete first, then shadow with an own undefined property
  // (WebIDL methods live on Window.prototype; a plain assignment shadowing it
  // would be undone by the delete).
  try {
    console.log('[pc] savepicker pre: ' + (typeof window.showSaveFilePicker));
    try { delete window.showSaveFilePicker; } catch (e) {}
    try { Object.defineProperty(window, 'showSaveFilePicker', { value: undefined, writable: true, configurable: true }); } catch (e) {}
    if (typeof window.showSaveFilePicker !== 'undefined') {
      try { window.showSaveFilePicker = undefined; } catch (e) {}
    }
    console.log('[pc] savepicker post: ' + (typeof window.showSaveFilePicker));
  } catch (e) { console.log('[pc] savepicker neuter failed'); }
  function pcSend(href, name, src) {
    var port = window.__pc_port;
    console.log('[pc] download click: ' + name + ' port=' + (port ? 'yes' : 'NO') + (src ? ' [' + src + ']' : ''));
    if (!port) { return; }
    fetch(href).then(function(r) { return r.blob(); }).then(function(b) {
      console.log('[pc] blob fetched: ' + b.size + ' B');
      var fr = new FileReader();
      fr.onload = function() {
        var du = String(fr.result);
        var b64 = du.substring(du.indexOf(',') + 1);
        port.postMessage(JSON.stringify({ t: 'begin', name: name, total: Math.ceil(b64.length / 262144) }));
        var i = 0;
        while (i * 262144 < b64.length) {
          port.postMessage(JSON.stringify({ t: 'chunk', i: i, data: b64.substr(i * 262144, 262144) }));
          i++;
        }
        port.postMessage(JSON.stringify({ t: 'end' }));
      };
      fr.onerror = function() {};
      fr.readAsDataURL(b);
    }).catch(function() { console.log('[pc] blob fetch failed'); });
  }
  window.addEventListener('message', function(e) {
    if (e.ports && e.ports.length > 0) {
      window.__pc_port = e.ports[0];
      console.log('[pc] port received');
    }
  });
  // Path 1: real user clicks on attached a[download] anchors.
  document.addEventListener('click', function(e) {
    var t = e.target;
    if (!t || !t.closest) { return; }
    var a = t.closest('a[download]');
    if (!a) { return; }
    var href = a.getAttribute('href') || '';
    if (href.indexOf('blob:') !== 0) { return; }
    e.preventDefault();
    e.stopPropagation();
    pcSend(href, a.getAttribute('download') || 'export.bin', 'doc');
  }, true);
  // Path 2: programmatic .click() — including detached anchors.
  var origClick = HTMLAnchorElement.prototype.click;
  if (!origClick.__pc_patched) {
    var patched = function() {
      try {
        var href = this.getAttribute('href') || '';
        var name = this.getAttribute('download');
        if (name && href.indexOf('blob:') === 0 && window.__pc_port) {
          pcSend(href, name, 'proto');
          return; // swallow: the native activation is useless in ArkWeb anyway
        }
      } catch (e) {}
      return origClick.apply(this, arguments);
    };
    try { Object.defineProperty(patched, '__pc_patched', { value: true }); } catch (e) {}
    HTMLAnchorElement.prototype.click = patched;
  }
})();`;

// One-shot UI language force. The release build defaults UiState.language to
// "auto", which on web follows navigator.languages — the device is zh-CN, and
// this wasm carries no CJK face (every UI menu would be tofu and unnavigable,
// the pdfcraft P2 lesson). Write the English preference into the app's own
// settings JSON: eframe's web storage is plain localStorage, key "wordcraft.ui"
// (apps/wordcraft-web/src/prefs.rs KEY), holding the same UiState the desktop
// app keeps in ui.json, read once at boot by prefs::restore. No reload from
// here: a reload aborts the in-flight wasm fetch, and the port cannot be
// re-posted to a reloaded page anyway. The operator force-stops and relaunches
// once after the "[pc] language forced" log line. The marker key makes this
// fire once ever; a language the user picks later in Options is never
// overridden.
const FORCE_EN: string = `(function() {
  try {
    if (localStorage.getItem('wc_lang_forced')) { return; }
    localStorage.setItem('wc_lang_forced', '1');
    var raw = localStorage.getItem('wordcraft.ui');
    var v = {};
    try { v = raw ? (JSON.parse(raw) || {}) : {}; } catch (e) { v = {}; }
    v.language = 'en';
    localStorage.setItem('wordcraft.ui', JSON.stringify(v));
    console.log('[pc] language forced to en');
  } catch (e) { console.log('[pc] language force failed'); }
})();`;

// One-shot CJK font seed. wordcraft-web has a designed user-font channel
// (apps/wordcraft-web/src/web/font_store.rs, #582): fonts the user adds are
// kept in IndexedDB ("wordcraft" db, "fonts" store — the doc comment's whole
// motivation is "localStorage holds about 5 MB, less than one CJK font") and
// installed into the font database at every boot (font_store::load_all →
// FontDb::global().install_font, limit 50 MB, ttf/otf/ttc/otc/woff/woff2).
// The release wasm itself embeds no CJK face, so this seeds the store once
// from the rawfile copy of the craft-fonts Noto Sans CJK SC (Hans) — the next
// boot installs it, giving CJK text a face to render with (the app's
// want_system_cjk / document font fallback then has something to find).
// Marker set only after a successful put, so a failed fetch retries next boot.
const FONT_SEED: string = `(function() {
  try {
    if (localStorage.getItem('wc_font_seeded')) { return; }
    fetch('fonts/noto-sans-cjk-sc/NotoSansCJKsc-Regular.otf').then(function(r) {
      if (!r.ok) { throw new Error('http ' + r.status); }
      return r.arrayBuffer();
    }).then(function(buf) {
      var req = indexedDB.open('wordcraft', 1);
      req.onupgradeneeded = function() {
        if (!req.result.objectStoreNames.contains('fonts')) {
          req.result.createObjectStore('fonts');
        }
      };
      req.onsuccess = function() {
        var db = req.result;
        var put = db.transaction('fonts', 'readwrite').objectStore('fonts').put(buf, 'NotoSansCJKsc-Regular.otf');
        put.onsuccess = function() {
          localStorage.setItem('wc_font_seeded', '1');
          db.close();
          console.log('[pc] cjk font seeded: ' + buf.byteLength + ' B');
        };
        put.onerror = function() { console.log('[pc] cjk font put failed'); };
      };
      req.onerror = function() { console.log('[pc] indexeddb open failed'); };
    }).catch(function(e) { console.log('[pc] cjk font fetch failed: ' + e); });
  } catch (e) { console.log('[pc] cjk seed error'); }
})();`;

function mimeFor(path: string): string {
  const dot: number = path.lastIndexOf('.');
  if (dot < 0) {
    return 'application/octet-stream';
  }
  switch (path.substring(dot).toLowerCase()) {
    case '.html':
    case '.htm':
      return 'text/html';
    case '.js':
      return 'text/javascript';
    case '.css':
      return 'text/css';
    case '.wasm':
      return 'application/wasm';
    case '.txt':
      return 'text/plain';
    case '.json':
      return 'application/json';
    case '.otf':
      return 'font/otf';
    case '.ttf':
      return 'font/ttf';
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.svg':
      return 'image/svg+xml';
    case '.ico':
      return 'image/x-icon';
    default:
      return 'application/octet-stream';
  }
}

@Entry
@Component
struct Index {
  controller: webview.WebviewController = new webview.WebviewController();
  private sendPort: webview.WebMessagePort | null = null;
  private exportName: string = '';
  private exportChunks: string[] = [];

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  // F7 fix: the shell only serves the virtual source, so page links to the
  // outside web used to 404 silently (dead click). Hand external navigations
  // to the system browser instead.
  private openExternal(url: string): void {
    try {
      const context = getContext(this) as common.UIAbilityContext;
      context.openLink(url, { appLinkingOnly: false })
        .then(() => hilog.info(0x0000, TAG, 'external link opened: ' + url))
        .catch((e: BusinessError) => hilog.warn(0x0000, TAG, 'openLink failed: ' + e.code + ' ' + url));
    } catch (e) {
      hilog.warn(0x0000, TAG, 'openLink threw: ' + url);
    }
  }

  private notFound(path: string): WebResourceResponse {
    const resp: WebResourceResponse = new WebResourceResponse();
    resp.setResponseData('404 Not Found: ' + path);
    resp.setResponseMimeType('text/plain');
    resp.setResponseEncoding('utf-8');
    resp.setResponseCode(404);
    resp.setReasonMessage('Not Found');
    resp.setResponseIsReady(true);
    return resp;
  }

  // Map https://local.wordcraft/<path> to rawfile web/<path>.
  private handleRequest(url: string): WebResourceResponse {
    if (!url.startsWith(URL_PREFIX)) {
      return this.notFound(url);
    }
    let path: string = url.substring(URL_PREFIX.length);
    const q: number = path.indexOf('?');
    if (q >= 0) {
      path = path.substring(0, q);
    }
    const h: number = path.indexOf('#');
    if (h >= 0) {
      path = path.substring(0, h);
    }
    if (path.length === 0) {
      path = 'index.html';
    }
    if (path.includes('..') || !/^[A-Za-z0-9._\-/]+$/.test(path)) {
      return this.notFound(path);
    }
    try {
      const data: Uint8Array = getContext(this).resourceManager.getRawFileContentSync(RAW_PREFIX + path);
      const mime: string = mimeFor(path);
      const resp: WebResourceResponse = new WebResourceResponse();
      resp.setResponseData(data.buffer as ArrayBuffer);
      resp.setResponseMimeType(mime);
      if (mime.startsWith('text/') || mime === 'application/json' || mime === 'image/svg+xml') {
        resp.setResponseEncoding('utf-8');
      }
      resp.setResponseCode(200);
      resp.setReasonMessage('OK');
      const hdr: Header = { headerKey: 'Cache-Control', headerValue: 'no-store' };
      resp.setResponseHeader([hdr]);
      resp.setResponseIsReady(true);
      return resp;
    } catch (e) {
      hilog.warn(0x0000, TAG, 'rawfile miss: ' + path);
      return this.notFound(path);
    }
  }

  // PhotoCraft web opens files via <input type=file>; take over with the system picker.
  private pickFiles(event: OnShowFileSelectorEvent): boolean {
    hilog.info(0x0000, TAG, 'file selector requested (multi=' +
      (event.fileSelector.getMode() === FileSelectorMode.FileOpenMultipleMode) + ')');
    const multi: boolean = event.fileSelector.getMode() === FileSelectorMode.FileOpenMultipleMode;
    const opts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = multi ? 10 : 1;
    const dvp: picker.DocumentViewPicker = new picker.DocumentViewPicker(getContext(this));
    dvp.select(opts).then((uris: Array<string>) => {
      event.result.handleFileList(uris);
    }).catch((err: BusinessError) => {
      hilog.warn(0x0000, TAG, 'file picker failed: ' + err.code);
      event.result.handleFileList([]);
    });
    return true;
  }

  private setupPorts(): void {
    const ports: Array<webview.WebMessagePort> = this.controller.createWebMessagePorts();
    const recv: webview.WebMessagePort = ports[1];
    recv.onMessageEvent((msg: webview.WebMessage) => {
      this.onExportMessage(msg);
    });
    this.sendPort = ports[0];
  }

  private onExportMessage(msg: webview.WebMessage): void {
    if (typeof msg !== 'string') {
      return;
    }
    let m: ExportMsg;
    try {
      m = JSON.parse(msg) as ExportMsg;
    } catch (e) {
      return;
    }
    if (m.t === 'begin') {
      this.exportChunks = [];
      this.exportName = m.name ? m.name : 'export.bin';
      hilog.info(0x0000, TAG, 'export begin: ' + this.exportName);
    } else if (m.t === 'chunk') {
      if (m.data) {
        this.exportChunks.push(m.data);
      }
    } else if (m.t === 'end') {
      hilog.info(0x0000, TAG, 'export end: chunks=' + this.exportChunks.length);
      this.saveExport();
    }
  }

  private saveExport(): void {
    const b64: string = this.exportChunks.join('');
    const name: string = this.exportName;
    this.exportChunks = [];
    this.exportName = '';
    if (b64.length === 0) {
      return;
    }
    try {
      const data: Uint8Array = new util.Base64Helper().decodeSync(b64);
      const opts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      opts.newFileNames = [name];
      const dvp: picker.DocumentViewPicker = new picker.DocumentViewPicker(getContext(this));
      dvp.save(opts).then((uris: Array<string>) => {
        if (uris.length === 0) {
          this.toast('保存已取消');
          return;
        }
        hilog.info(0x0000, TAG, 'export write: ' + data.byteLength + ' B -> ' + uris[0]);
        const file: fs.File = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        try {
          fs.writeSync(file.fd, data.buffer as ArrayBuffer);
        } finally {
          fs.closeSync(file);
        }
        this.toast('已保存 ' + name);
      }).catch((err: BusinessError) => {
        hilog.warn(0x0000, TAG, 'save failed: ' + err.code);
        this.toast('保存失败或已取消');
      });
    } catch (e) {
      hilog.warn(0x0000, TAG, 'export decode/write error');
      this.toast('保存失败');
    }
  }

  build() {
    Column() {
      Web({ src: MAIN_URL, controller: this.controller })
        .fileAccess(true)
        .domStorageAccess(true)
        .javaScriptAccess(true)
        .zoomAccess(false)
        .onLoadIntercept((event: OnLoadInterceptEvent) => {
          // F7: our virtual source passes through; external http(s) main-frame
          // navigations go to the system browser, external subresources are
          // blocked (same semantics as the old 404, but visible for links).
          const url: string = event.data.getRequestUrl();
          if (url.startsWith(URL_PREFIX)) {
            return false;
          }
          if (url.startsWith('http://') || url.startsWith('https://')) {
            if (event.data.isMainFrame()) {
              hilog.info(0x0000, TAG, 'external nav -> browser: ' + url);
              this.openExternal(url);
            } else {
              hilog.warn(0x0000, TAG, 'external subresource blocked: ' + url);
            }
            return true;
          }
          return false; // blob:/data:/about: — the webview's own business
        })
        .multiWindowAccess(true)
        .onWindowNew((event: OnWindowNewEvent) => {
          // F7 part 2: the wasm apps open their links via window.open(url,
          // '_blank') (eframe web open_url -> web_sys Window.open). With
          // multiWindowAccess(false) ArkWeb drops that popup silently — no
          // onLoadIntercept event fires, so part 1 alone cannot catch it.
          // Accept the request, route the URL to the system browser, and
          // decline the popup itself: a null controller means "no new window".
          // The setWebController call is mandatory — skipping it blocks the
          // renderer.
          hilog.info(0x0000, TAG, 'window.open -> browser: ' + event.targetUrl);
          this.openExternal(event.targetUrl);
          event.handler.setWebController(null);
        })
        .onInterceptRequest((event: OnInterceptRequestEvent) => {
          return this.handleRequest(event.request.getRequestUrl());
        })
        .onShowFileSelector((event: OnShowFileSelectorEvent) => {
          return this.pickFiles(event);
        })
        .javaScriptOnDocumentStart([
          {
            script: START_SCRIPT,
            scriptRules: [URL_PATTERN]
          }
        ])
        .onPageEnd(() => {
          // One-shot English UI force + one-shot CJK font seed: both write
          // persistent state the app reads at boot, so they take effect on
          // the NEXT launch — the operator force-stops and relaunches once
          // after the "[pc] language forced" / "[pc] cjk font seeded" lines.
          this.controller.runJavaScript(FORCE_EN)
            .catch((e: BusinessError) => hilog.warn(0x0000, TAG, 'lang force inject failed: ' + e.code));
          this.controller.runJavaScript(FONT_SEED)
            .catch((e: BusinessError) => hilog.warn(0x0000, TAG, 'font seed inject failed: ' + e.code));
          // Re-hand the port to every (re)loaded page instance — a fresh port
          // pair per page, so a future reload never inherits a dead port.
          // Note: javaScriptOnDocumentStart shows no trace on this ArkWeb
          // build (hook/port console lines never surface), so the hook is
          // (re)installed from the main world here BEFORE the port is posted —
          // the message listener must exist when the port arrives, or the
          // port is lost. __pc_hook guard makes the double injection
          // idempotent.
          this.setupPorts();
          if (this.sendPort) {
            this.controller.runJavaScript(START_SCRIPT)
              .then(() => {
                this.controller.postMessage('wordcraft_port', [this.sendPort], '*');
                hilog.info(0x0000, TAG, 'port posted to page');
                this.controller.runJavaScript(
                  "console.log('[pc] main world: hook=' + (window.__pc_hook ? 'y' : 'n') + ' port=' + (window.__pc_port ? 'y' : 'n'))");
              })
              .catch((e: BusinessError) => hilog.warn(0x0000, TAG, 'hook inject failed: ' + e.code));
          }
        })
        .backgroundColor('#141414')
        .width('100%')
        .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
