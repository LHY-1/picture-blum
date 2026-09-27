// ============================================================
// PhotoServer.swift
// 上传服务 —— 让别的设备把照片传进 iPad
//
// 传输层（HTTP 解析、NWListener）在 HTTPServerCore.swift 里，
// 这一层只管业务：把请求映射到 LocalPhotoStore 的操作。
//
// ⚠️ Info.plist 必须有 NSLocalNetworkUsageDescription，
//    否则 iOS 14 会拒绝局域网设备连进来。见 Info.plist。
//
// 线程模型：
//   HTTPServer 的 handler 在它自己的后台队列上被调用，
//   而 LocalPhotoStore 的 @Published 状态约定只在主线程读写，
//   所以读状态一律走 mainSync 切回主线程（见下）。
//
// 兼容：iOS 14.0+
// ============================================================

import Foundation
import Combine
import UIKit

final class PhotoServer: ObservableObject {

    static let shared = PhotoServer()

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = 8080
    @Published private(set) var errorMessage: String?

    /// 本次开启后收到的上传数量，UI 上给个反馈
    @Published private(set) var receivedCount = 0
    @Published private(set) var lastReceivedName: String?

    private let store = LocalPhotoStore.shared

    /// 8080 被占就往后试。都是常见的空闲端口。
    private lazy var server = HTTPServer(
        ports: [8080, 8081, 8000, 8888, 9000],
        handler: { [weak self] request in
            guard let self = self else { return .text(503, "服务未就绪") }
            return self.route(request)
        }
    )

    private init() {
        server.onReady = { [weak self] port in
            self?.port = port
            self?.isRunning = true
            self?.errorMessage = nil
        }
        server.onError = { [weak self] message in
            self?.isRunning = false
            self?.errorMessage = message
        }
        server.onStopped = { [weak self] in
            self?.isRunning = false
        }
    }

    // MARK: - 开关

    func start() {
        guard !isRunning else { return }
        errorMessage = nil
        server.start()
    }

    func stop() {
        server.stop()
        // 立刻反映到 UI，不等 NWListener 的 .cancelled 回调
        isRunning = false
        receivedCount = 0
        lastReceivedName = nil
    }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    // MARK: - 路由

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        switch (request.method, request.path) {

        case ("GET", "/"), ("GET", "/index.html"):
            return .html(Self.uploadPage(
                url: NetworkInfo.urlString(port: port) ?? "",
                version: AppInfo.display))

        case ("GET", "/api/list"):
            return .json(listPayload())

        case ("POST", "/upload"), ("POST", "/music"):
            return handleUpload(request)

        case ("POST", "/import"):
            return handleImport(request)

        case ("POST", "/delete"):
            return handleDelete(request)

        case ("POST", "/music/delete"):
            return handleMusicDelete(request)

        case ("GET", let path) where path.hasPrefix("/thumb/"):
            return serveThumbnail(name: String(path.dropFirst("/thumb/".count)))

        case ("GET", let path) where path.hasPrefix("/file/"):
            return serveOriginal(name: String(path.dropFirst("/file/".count)))

        default:
            return .text(404, "没有这个地址")
        }
    }

    // MARK: - 各接口

    /// 读 @Published 状态必须回主线程。
    ///
    /// LocalPhotoStore 的 inbox / media 约定只在主线程写；HTTP handler 跑在
    /// 服务器的后台队列上，直接读会撞上主线程的写操作 —— Swift 数组是值类型，
    /// 并发读写同一份 COW 缓冲区会直接崩。
    private func mainSync<T>(_ block: () -> T) -> T {
        if Thread.isMainThread { return block() }
        return DispatchQueue.main.sync(execute: block)
    }

    private func listPayload() -> [String: Any] {
        mainSync {
            func describe(_ urls: [URL]) -> [[String: Any]] {
                urls.map { url in
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?
                        .fileSize ?? 0
                    return [
                        "name": url.lastPathComponent,
                        "size": size,
                        "sizeText": LocalPhotoStore.formatBytes(size)
                    ]
                }
            }

            let music = (try? FileManager.default.contentsOfDirectory(
                at: MusicStore.shared.musicDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ))?.compactMap { url in
                MusicStore.audioExtensions.contains(url.pathExtension.lowercased())
                    ? url : nil
            } ?? []

            return [
                "inbox": describe(store.inbox),
                "media": describe(store.media),
                "music": describe(music),
                "autoImport": store.autoImport,
                "received": receivedCount
            ]
        }
    }

    private func handleUpload(_ request: HTTPRequest) -> HTTPResponse {
        let rawName = request.param("name") ?? "photo.jpg"
        let name = LocalPhotoStore.sanitize(rawName)
        let ext = (name as NSString).pathExtension.lowercased()

        guard !request.body.isEmpty else {
            return .json(["error": "空文件"], status: 400)
        }

        // 音乐文件走曲库，不进照片
        if MusicStore.audioExtensions.contains(ext) {
            guard let saved = MusicStore.shared.add(filename: name, data: request.body) else {
                return .json(["error": "格式不支持：\(name)"], status: 400)
            }
            return .json([
                "ok": true,
                "name": saved.lastPathComponent,
                "kind": "music"
            ], status: 201)
        }

        // autoImport 在主线程读好再传进去
        let autoImport = mainSync { store.autoImport }

        guard let saved = store.saveUpload(filename: name,
                                           data: request.body,
                                           importImmediately: autoImport) else {
            return .json(["error": "格式不支持：\(name)"], status: 400)
        }

        publish {
            self.receivedCount += 1
            self.lastReceivedName = name
        }

        return .json([
            "ok": true,
            "name": saved.lastPathComponent,
            "imported": autoImport
        ], status: 201)
    }

    private func handleImport(_ request: HTTPRequest) -> HTTPResponse {
        let payload = (try? JSONSerialization.jsonObject(with: request.body))
            as? [String: Any] ?? [:]

        return mainSync {
            if let names = payload["names"] as? [String], !names.isEmpty {
                var moved = 0
                for name in names {
                    if let url = findPhoto(named: name), store.inbox.contains(url) {
                        if store.importOne(url) != nil { moved += 1 }
                    }
                }
                return .json(["imported": moved])
            }
            return .json(["imported": store.importAll()])
        }
    }

    private func handleDelete(_ request: HTTPRequest) -> HTTPResponse {
        let payload = (try? JSONSerialization.jsonObject(with: request.body))
            as? [String: Any] ?? [:]
        let names = payload["names"] as? [String] ?? []

        return mainSync {
            let targets = names.compactMap { findPhoto(named: $0) }
            store.delete(targets)
            return .json(["deleted": targets.count])
        }
    }

    private func handleMusicDelete(_ request: HTTPRequest) -> HTTPResponse {
        let payload = (try? JSONSerialization.jsonObject(with: request.body))
            as? [String: Any] ?? [:]
        let names = payload["names"] as? [String] ?? []

        return mainSync {
            let targets = names.compactMap { MusicStore.shared.url(named: $0) }
            MusicStore.shared.delete(targets)
            return .json(["deleted": targets.count])
        }
    }

    private func serveThumbnail(name: String) -> HTTPResponse {
        guard let url = findPhoto(named: name) else {
            return .text(404, "找不到")
        }
        guard let thumb = store.makeThumbnail(for: url),
              let data = try? Data(contentsOf: thumb) else {
            return .text(404, "缩略图生成失败")
        }
        return .data(data, type: "image/jpeg")
    }

    private func serveOriginal(name: String) -> HTTPResponse {
        guard let url = findPhoto(named: name),
              let data = try? Data(contentsOf: url) else {
            return .text(404, "找不到")
        }
        return .data(data, type: mimeType(for: url.pathExtension))
    }

    /// 按文件名在两个目录里找。
    /// 只比对 lastPathComponent，天然挡掉 ../ 之类的路径穿越。
    private func findPhoto(named name: String) -> URL? {
        mainSync {
            let target = LocalPhotoStore.sanitize(name)
            return store.media.first { $0.lastPathComponent == target }
                ?? store.inbox.first { $0.lastPathComponent == target }
        }
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg":  return "image/jpeg"
        case "png":          return "image/png"
        case "gif":          return "image/gif"
        case "heic", "heif": return "image/heic"
        case "webp":         return "image/webp"
        case "tif", "tiff":  return "image/tiff"
        case "bmp":          return "image/bmp"
        default:             return "application/octet-stream"
        }
    }

    // MARK: - 工具

    /// 切回主线程改 @Published —— 后台线程改会崩
    private func publish(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}

// MARK: - 上传页面
//
// 注意：这是 Swift 的多行字符串，里面出现的反斜杠会被当成转义。
// 所以下面的 JS 里刻意不写正则、不写 \n，需要的地方用字符串拼接绕开。

extension PhotoServer {

    static func uploadPage(url: String, version: String) -> String {
        return """
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<title>上传照片 · 相框</title>
<style>
  :root{--bg:#0d0f14;--panel:#171b23;--line:#272e3a;--fg:#e9edf4;--dim:#8b95a7;--blue:#4a8cff;--red:#ff5a5a}
  *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
  body{margin:0;background:var(--bg);color:var(--fg);
       font:15px/1.55 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;
       padding-bottom:calc(24px + env(safe-area-inset-bottom))}
  header{position:sticky;top:0;z-index:9;padding:14px 16px;
         padding-top:calc(14px + env(safe-area-inset-top));
         background:rgba(13,15,20,.86);backdrop-filter:blur(20px);
         -webkit-backdrop-filter:blur(20px);border-bottom:1px solid var(--line)}
  h1{margin:0;font-size:17px;font-weight:600}
  .sub{color:var(--dim);font-size:12px;margin-top:2px}
  .wrap{padding:16px}
  #pick{border:2px dashed var(--line);border-radius:16px;padding:36px 16px;
        text-align:center;color:var(--dim);transition:.2s}
  #pick.over{border-color:var(--blue);background:rgba(74,140,255,.08);color:var(--fg)}
  #pick .ico{font-size:40px;line-height:1}
  #pick b{color:var(--fg);display:block;margin:10px 0 4px;font-size:16px}
  .btn{font:inherit;color:var(--fg);background:var(--panel);border:1px solid var(--line);
       border-radius:10px;padding:11px 18px;cursor:pointer;transition:.15s}
  .btn:active{transform:scale(.97)}
  .btn.blue{background:var(--blue);border-color:var(--blue);color:#fff;font-weight:600}
  .btn.red{color:var(--red);border-color:#4a2b2b}
  .btn:disabled{opacity:.4}
  #bar{display:none;margin-top:14px;height:6px;background:var(--panel);border-radius:3px;overflow:hidden}
  #bar.on{display:block}
  #bar i{display:block;height:100%;width:0;background:var(--blue);transition:width .2s}
  h2{font-size:13px;color:var(--dim);font-weight:600;margin:26px 0 10px;
     text-transform:uppercase;letter-spacing:.6px}
  .row{display:flex;align-items:center;gap:12px;padding:9px;background:var(--panel);
       border:1px solid var(--line);border-radius:11px;margin-bottom:7px}
  .row img{width:52px;height:52px;object-fit:cover;border-radius:8px;background:#0a0c10;flex:none}
  .row .meta{min-width:0;flex:1}
  .row .nm{font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .row .sz{font-size:11px;color:var(--dim);margin-top:2px}
  .empty{color:var(--dim);font-size:13px;padding:14px 2px}
  #toast{position:fixed;left:50%;bottom:34px;transform:translateX(-50%);
         background:rgba(32,38,50,.97);padding:11px 20px;border-radius:11px;
         font-size:14px;opacity:0;transition:opacity .25s;pointer-events:none;
         max-width:82vw;text-align:center}
  #toast.on{opacity:1}
</style>
</head>
<body>

<header>
  <h1>上传到相框</h1>
  <div class="sub">\(url)</div>
</header>

<div class="wrap">
  <div id="pick">
    <div class="ico">🖼</div>
    <b>选照片，或拖进来</b>
    <span>HEIC 也能传，iPad 上直接能放</span>
  </div>

  <div style="text-align:center;margin-top:16px">
    <button class="btn blue" id="pickBtn">从相册选照片</button>
  </div>

  <div id="bar"><i></i></div>

  <h2 id="inboxTitle" style="display:none">待导入</h2>
  <div id="inbox"></div>

  <h2>已在相框里</h2>
  <div id="media"></div>

  <h2>音乐</h2>
  <div id="music"></div>
</div>

<div style="text-align:center;color:var(--dim);font-size:11px;margin-top:28px;
     padding-bottom:4px">相框 \(version)</div>

<div id="toast"></div>
<input type="file" id="file" multiple accept="image/*,.heic,.heif,.mp3,.m4a,.aac,.wav" hidden>

<script>
(function(){
  var state = {inbox:[], media:[], music:[], autoImport:true};
  var busy = false;

  function $(id){ return document.getElementById(id); }

  function toast(msg){
    var t = $('toast');
    t.textContent = msg;
    t.classList.add('on');
    clearTimeout(t._t);
    t._t = setTimeout(function(){ t.classList.remove('on'); }, 2400);
  }

  function load(){
    fetch('api/list').then(function(r){ return r.json(); }).then(function(d){
      state = d;
      render();
    }).catch(function(){ toast('连不上，刷新试试'); });
  }

  function row(item, isInbox){
    var el = document.createElement('div');
    el.className = 'row';

    var img = document.createElement('img');
    img.src = 'thumb/' + encodeURIComponent(item.name);
    img.alt = '';
    el.appendChild(img);

    var meta = document.createElement('div');
    meta.className = 'meta';
    var nm = document.createElement('div');
    nm.className = 'nm';
    nm.textContent = item.name;
    var sz = document.createElement('div');
    sz.className = 'sz';
    sz.textContent = item.sizeText;
    meta.appendChild(nm);
    meta.appendChild(sz);
    el.appendChild(meta);

    var btn = document.createElement('button');
    btn.className = 'btn ' + (isInbox ? 'blue' : 'red');
    btn.textContent = isInbox ? '导入' : '删除';
    btn.onclick = function(){
      btn.disabled = true;
      if (isInbox) {
        post('import', {names:[item.name]}).then(function(){
          toast('已导入'); load();
        });
      } else {
        if (!confirm('删除 ' + item.name + ' ？')) { btn.disabled = false; return; }
        post('delete', {names:[item.name]}).then(function(){
          toast('已删除'); load();
        });
      }
    };
    el.appendChild(btn);

    return el;
  }

  // 音乐行：左边是音符，右边是删除（走专门的 music/delete）
  function musicRow(item){
    var el = document.createElement('div');
    el.className = 'row';

    var ico = document.createElement('div');
    ico.style.cssText = 'width:52px;height:52px;flex:none;display:flex;align-items:center;' +
                        'justify-content:center;font-size:24px';
    ico.textContent = '🎵';
    el.appendChild(ico);

    var meta = document.createElement('div');
    meta.className = 'meta';
    var nm = document.createElement('div');
    nm.className = 'nm';
    nm.textContent = item.name;
    var sz = document.createElement('div');
    sz.className = 'sz';
    sz.textContent = item.sizeText;
    meta.appendChild(nm);
    meta.appendChild(sz);
    el.appendChild(meta);

    var btn = document.createElement('button');
    btn.className = 'btn red';
    btn.textContent = '删除';
    btn.onclick = function(){
      btn.disabled = true;
      if (!confirm('删除 ' + item.name + ' ？')) { btn.disabled = false; return; }
      post('music/delete', {names:[item.name]}).then(function(){
        toast('已删除'); load();
      });
    };
    el.appendChild(btn);

    return el;
  }

  function fill(container, items, isInbox, emptyText){
    container.innerHTML = '';
    if (!items.length) {
      var e = document.createElement('div');
      e.className = 'empty';
      e.textContent = emptyText;
      container.appendChild(e);
      return;
    }
    items.forEach(function(it){ container.appendChild(row(it, isInbox)); });
  }

  function fillMusic(container, items){
    container.innerHTML = '';
    if (!items.length) {
      var e = document.createElement('div');
      e.className = 'empty';
      e.textContent = '还没有音乐。把歌曲文件拖进来，相框就有背景音乐了。';
      container.appendChild(e);
      return;
    }
    items.forEach(function(it){ container.appendChild(musicRow(it)); });
  }

  function render(){
    var hasInbox = state.inbox.length > 0;
    $('inboxTitle').style.display = hasInbox ? 'block' : 'none';
    $('inboxTitle').textContent = '待导入 · ' + state.inbox.length + ' 张';
    fill($('inbox'), state.inbox, true, '');
    fill($('media'), state.media, false,
         '还没有照片。传一张试试，会自动进相框。');
    fillMusic($('music'), state.music || []);
  }

  function post(path, payload){
    return fetch(path, {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(payload)
    }).then(function(r){ return r.json(); });
  }

  function upload(files){
    if (!files || !files.length || busy) return;
    busy = true;

    var list = Array.prototype.slice.call(files);
    var done = 0, failed = 0, failedNames = [];

    $('bar').classList.add('on');
    $('bar').firstElementChild.style.width = '0%';

    function next(){
      if (done + failed >= list.length){
        busy = false;
        $('bar').firstElementChild.style.width = '100%';
        setTimeout(function(){ $('bar').classList.remove('on'); }, 500);
        if (failed) {
          toast('成功 ' + done + ' 张，失败 ' + failed + ' 张：' + failedNames.join('、'));
        } else {
          toast('已上传 ' + done + ' 张');
        }
        load();
        return;
      }

      var f = list[done + failed];
      fetch('upload?name=' + encodeURIComponent(f.name), {
        method: 'POST',
        body: f,
        headers: {'Content-Type': 'application/octet-stream'}
      }).then(function(r){
        if (r.ok) { done++; } else { failed++; failedNames.push(f.name); }
      }).catch(function(){
        failed++; failedNames.push(f.name);
      }).then(function(){
        var pct = Math.round((done + failed) / list.length * 100);
        $('bar').firstElementChild.style.width = pct + '%';
        next();
      });
    }

    next();
  }

  $('pickBtn').onclick = function(){ $('file').click(); };
  $('file').onchange = function(e){
    upload(e.target.files);
    e.target.value = '';
  };

  var pick = $('pick');
  ['dragenter','dragover'].forEach(function(ev){
    pick.addEventListener(ev, function(e){
      e.preventDefault(); pick.classList.add('over');
    });
  });
  ['dragleave','drop'].forEach(function(ev){
    pick.addEventListener(ev, function(e){
      e.preventDefault(); pick.classList.remove('over');
    });
  });
  pick.addEventListener('drop', function(e){ upload(e.dataTransfer.files); });

  document.addEventListener('dragover', function(e){ e.preventDefault(); });
  document.addEventListener('drop', function(e){
    e.preventDefault();
    if (e.target !== pick) upload(e.dataTransfer.files);
  });

  load();
  setInterval(load, 5000);
})();
</script>
</body>
</html>
"""
    }
}
