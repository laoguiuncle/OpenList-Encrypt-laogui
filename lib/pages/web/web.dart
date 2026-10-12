import 'dart:developer';
import 'dart:io';

import 'package:openlist_encrypt/contant/native_bridge.dart';
import 'package:openlist_encrypt/generated_api.dart';
import 'package:openlist_encrypt/utils/encrypt_home_pref.dart';
import 'package:openlist_encrypt/utils/intent_utils.dart';
import 'package:openlist_encrypt/utils/download_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';

import '../../generated/l10n.dart';

GlobalKey<WebScreenState> webGlobalKey = GlobalKey();

class WebScreen extends StatefulWidget {
  const WebScreen({Key? key}) : super(key: key);

  @override
  State<StatefulWidget> createState() {
    return WebScreenState();
  }
}

class WebScreenState extends State<WebScreen> {
  InAppWebViewController? _webViewController;
  InAppWebViewSettings settings = InAppWebViewSettings(
    allowsInlineMediaPlayback: true,
    allowBackgroundAudioPlaying: true,
    iframeAllowFullscreen: true,
    javaScriptEnabled: true,
    mediaPlaybackRequiresUserGesture: false,
    useShouldOverrideUrlLoading: true,
  );

  double _progress = 0;
  String? _url;
  bool _canGoBack = false;
  int _proxyErrorRetry = 0;

  /// 仅在「启动/切换首页」这一次加载期间启用上游报错兜底，
  /// 加载成功后立即关闭，避免正常浏览（前进后退）时被误判重载。
  bool _startupGuard = false;

  onClickNavigationBar() {
    log("onClickNavigationBar");
    _webViewController?.reload();
  }

  /// 解析首页地址：
  /// - 「设置加密页为首页」打开 → 加密页端口（5344）
  /// - 关闭 → 普通网页端口（5244）
  ///
  /// ⚠️ 首次启动时后台服务/加密代理可能尚未监听端口，若立即加载会得到
  /// `connection refused` 错误页。故先等服务就绪（探测端口可连）再创建 WebView。
  Future<void> _resolveHomeUrl() async {
    // 1) 上游 OpenList 端口（加密代理会把请求转发到它）
    int openListPort = 5244;
    try {
      final p = await Android().getOpenListHttpPort();
      if (p > 0) openListPort = p;
    } catch (e) {
      log("getOpenListHttpPort failed: $e");
    }

    // 2) 目标端口：加密页为首页 → 加密代理端口(5344)；否则 → OpenList 端口(5244)
    bool encryptAsHome = false;
    try {
      encryptAsHome = await EncryptHomePref.isEnabled();
    } catch (e) {
      log("EncryptHomePref read failed: $e");
    }
    int targetPort = openListPort;
    if (encryptAsHome) {
      try {
        final p = await NativeBridge.encryptProxy.getEncryptProxyPort();
        if (p > 0) targetPort = p;
      } catch (e) {
        log("getEncryptProxyPort failed: $e");
      }
      if (targetPort <= 0) targetPort = 5344;
    }

    // 3) 确保底层服务已启动（首次启动时 onInit 的启动可能还没跑完）
    try {
      if (!await Android().isRunning()) {
        await Android().startService();
      }
    } catch (e) {
      log("ensure service failed: $e");
    }

    // 4) 等端口就绪再加载。⚠️ 打开加密页时必须先等**上游** OpenList(5244) 就绪：
    //    加密代理(5344)在启动上早于 OpenList 服务，若此时加载 5344，代理会把
    //    Go 的报错正文直接返回给 WebView（形如
    //    `Get "http://127.0.0.1:5244/": dial tcp ...: connection refused`），
    //    这种响应属于“加载成功”，onReceivedError 不会触发 ⇒ 表现为错误页常驻。
    if (targetPort != openListPort) {
      await _waitForPortReady(openListPort);
    }
    await _waitForPortReady(targetPort);

    if (!mounted) return;
    final url = "http://localhost:$targetPort";
    _proxyErrorRetry = 0;
    _startupGuard = true; // 仅本次加载启用兜底
    setState(() {
      _url = url;
    });
    // 若 WebView 已创建，直接加载新地址（设置变更时即时生效）
    await _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  /// 探测本地端口是否已可连接；未就绪则间隔重试，最多约 [maxTries]×[intervalMs]。
  Future<bool> _waitForPortReady(int port,
      {int maxTries = 40, int intervalMs = 250}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 500);
    try {
      for (int i = 0; i < maxTries; i++) {
        try {
          final req = await client.getUrl(Uri.parse("http://127.0.0.1:$port/"));
          final resp = await req.close();
          await resp.drain();
          return true;
        } catch (_) {
          await Future.delayed(Duration(milliseconds: intervalMs));
        }
      }
    } finally {
      client.close(force: true);
    }
    return false;
  }

  /// 兜底：页面虽「加载成功」，正文却可能是加密代理返回的上游报错
  /// （Go 的 `Get "http://127.0.0.1:5244/": dial tcp ...: connection refused`）。
  /// ⚠️ 仅在 [_startupGuard] 为真（启动/切换首页那一次加载）时检查，
  /// 加载到正常正文后立即关闭，正常浏览时不会再触发重载。
  Future<void> _recoverFromUpstreamError(
      InAppWebViewController controller) async {
    if (!_startupGuard) return;
    if (_proxyErrorRetry >= 5) {
      _startupGuard = false;
      return;
    }
    try {
      final raw = await controller.evaluateJavascript(
          source:
              "(document.body && document.body.innerText) ? document.body.innerText.slice(0, 400) : ''");
      final text = raw?.toString() ?? '';
      final looksLikeUpstreamError = text.contains('connection refused') &&
          (text.contains('dial tcp') || text.contains('Get "http'));
      if (!looksLikeUpstreamError) {
        _proxyErrorRetry = 0;
        _startupGuard = false; // 正常正文 → 关闭兜底
        return;
      }
      _proxyErrorRetry++;
      log("detected upstream error page, reload #$_proxyErrorRetry");
      await Future.delayed(const Duration(milliseconds: 800));
      controller.reload();
    } catch (e) {
      log("upstream error check failed: $e");
    }
  }

  /// 供设置页在切换「设置加密页为首页」后调用，使网页标签立即生效。
  void onHomeSettingChanged() {
    _resolveHomeUrl();
  }

  @override
  void initState() {
    _resolveHomeUrl();

    // NativeEvent().addServiceStatusListener((isRunning) {
    //   if (isRunning) _webViewController?.reload();
    // });
    super.initState();
  }

  @override
  void dispose() {
    _webViewController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
        canPop: !_canGoBack,
        onPopInvoked: (didPop) async {
          log("onPopInvoked $didPop");
          if (didPop) return;
          _webViewController?.goBack();
        },
        child: Scaffold(
          body: Column(children: <Widget>[
            SizedBox(height: MediaQuery.of(context).padding.top),
            LinearProgressIndicator(
              value: _progress,
              backgroundColor: Colors.grey[200],
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
            ),
            Expanded(
              child: _url == null ? const SizedBox.shrink() : InAppWebView(
                initialSettings: settings,
                initialUrlRequest: URLRequest(url: WebUri(_url!)),
                onWebViewCreated: (InAppWebViewController controller) {
                  _webViewController = controller;
                },
                onLoadStart: (InAppWebViewController controller, Uri? url) {
                  log("onLoadStart $url");
                  setState(() {
                    _progress = 0;
                  });
                },
                shouldOverrideUrlLoading: (controller, navigationAction) async {
                  log("shouldOverrideUrlLoading ${navigationAction.request.url}");

                  var uri = navigationAction.request.url!;
                  if (![
                    "http",
                    "https",
                    "file",
                    "chrome",
                    "data",
                    "javascript",
                    "about"
                  ].contains(uri.scheme)) {
                    log("shouldOverrideUrlLoading ${uri.toString()}");
                    final silentMode =
                        await NativeBridge.appConfig.isSilentJumpAppEnabled();
                    if (silentMode) {
                      NativeCommon().startActivityFromUri(uri.toString());
                    } else {
                      Get.showSnackbar(GetSnackBar(
                          message: S.current.jumpToOtherApp,
                          duration: const Duration(seconds: 5),
                          mainButton: TextButton(
                            onPressed: () {
                              NativeCommon()
                                  .startActivityFromUri(uri.toString());
                            },
                            child: Text(S.current.goTo),
                          )));
                    }

                    return NavigationActionPolicy.CANCEL;
                  }

                  return NavigationActionPolicy.ALLOW;
                },
                onReceivedError: (controller, request, error) async {
                  // ⚠️ 只在「本地服务确实没在跑」时才尝试拉起并重载。
                  // 手机后退/取消在途请求也会触发本回调（ERR_ABORTED 等），
                  // 若无条件重载会导致页面反复刷新 —— 故此处严格收窄条件。
                  try {
                    final u = request.url;
                    final isLocal = u.host == 'localhost' ||
                        u.host == '127.0.0.1' ||
                        u.host == '::1';
                    if (!isLocal) return;
                    if (!await Android().isRunning()) {
                      await Android().startService();
                      for (int i = 0; i < 3; i++) {
                        await Future.delayed(const Duration(milliseconds: 500));
                        if (await Android().isRunning()) {
                          controller.reload();
                          break;
                        }
                      }
                    }
                  } catch (_) {}
                },
                onDownloadStartRequest: (controller, url) async {
                  Get.showSnackbar(GetSnackBar(
                    title: S.of(context).downloadThisFile,
                    message: url.suggestedFilename ??
                        url.contentDisposition ??
                        url.toString(),
                    duration: const Duration(seconds: 5),
                    mainButton: Column(children: [
                      TextButton(
                        onPressed: () async {
                          Get.closeCurrentSnackbar();
                          // 使用内置下载管理器后台下载
                          DownloadManager.downloadFileInBackground(
                            url: url.url.toString(),
                            filename: url.suggestedFilename,
                          );
                        },
                        child: Text(S.of(context).directDownload),
                      ),
                      TextButton(
                        onPressed: () {
                          IntentUtils.getUrlIntent(url.url.toString())
                              .launchChooser(S.of(context).selectAppToOpen);
                        },
                        child: Text(S.of(context).selectAppToOpen),
                      ),
                      TextButton(
                        onPressed: () {
                          IntentUtils.getUrlIntent(url.url.toString()).launch();
                        },
                        child: Text(S.of(context).browserDownload),
                      ),
                    ]),
                    onTap: (_) {
                      Clipboard.setData(
                          ClipboardData(text: url.url.toString()));
                      Get.closeCurrentSnackbar();
                      Get.showSnackbar(GetSnackBar(
                        message: S.of(context).copiedToClipboard,
                        duration: const Duration(seconds: 1),
                      ));
                    },
                  ));
                },
                onLoadStop:
                    (InAppWebViewController controller, Uri? url) async {
                  setState(() {
                    _progress = 0;
                  });
                  // 仅启动那一次做上游报错兜底检查（正常浏览不会重载）
                  _recoverFromUpstreamError(controller);
                },
                onProgressChanged:
                    (InAppWebViewController controller, int progress) {
                  setState(() {
                    _progress = progress / 100;
                    if (_progress == 1) _progress = 0;
                  });
                  controller.canGoBack().then((value) => setState(() {
                        _canGoBack = value;
                      }));
                },
                onUpdateVisitedHistory: (InAppWebViewController controller,
                    WebUri? url, bool? isReload) {
                  _url = url.toString();
                },
              ),
            ),
          ]),
        ));
  }
}
