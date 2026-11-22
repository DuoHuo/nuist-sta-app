package dev.duohuo.nuist_sta_app

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.View
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.annotation.Keep
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream

/** 仅在用户打开 Office 附件时创建离线阅读窗口。 */
internal class BulletinOfficeViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        BulletinOfficeWebView(context, MethodChannel(messenger, "$VIEW_TYPE/$viewId"))

    companion object {
        const val VIEW_TYPE = "nuist/bulletin_office_view"
    }
}

private class BulletinOfficeWebView(
    private val context: Context,
    private val channel: MethodChannel,
) : PlatformView {
    private val container = FrameLayout(context)
    private var webView: WebView? = null

    @Volatile
    private var renderer: BulletinOfficeRenderer? = null

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "load" -> load(call, result)
                "find" -> {
                    // WebView 的页内查找会进入正文 iframe，并能匹配跨元素的文字；不区分大小写。
                    val view = webView
                    val query = call.argument<String>("query").orEmpty()
                    if (view == null || query.isBlank()) {
                        view?.clearMatches()
                        result.success(null)
                    } else {
                        view.findAllAsync(query)
                        result.success(null)
                    }
                }
                "findNext" -> {
                    webView?.findNext(call.argument<Boolean>("forward") != false)
                    result.success(null)
                }
                "clearFind" -> {
                    webView?.clearMatches()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }



    private fun load(call: MethodCall, result: MethodChannel.Result) {
        try {
            val file = File(requireNotNull(call.argument<String>("path"))).canonicalFile
            val roots = listOf("bulletin_attachments", BulletinWordHtml.DIRECTORY).map {
                File(context.cacheDir, it).canonicalPath + File.separator
            }
            require(roots.any(file.path::startsWith) && file.isFile && file.length() in 1L..BulletinOfficeRenderer.MAX_FILE_BYTES)
            require(webView == null)
            val convertedWord = file.path.startsWith(roots.last()) && file.extension == "html"
            require(convertedWord || !file.path.startsWith(roots.last()))
            show(file, call.argument<Boolean>("dark") == true, convertedWord)
            result.success(null)
        } catch (_: Exception) {
            result.error("office_unavailable", "无法加载离线预览", null)
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun show(file: File, dark: Boolean, convertedWord: Boolean) {
        val view = WebView(context)
        webView = view
        renderer = BulletinOfficeRenderer(file, dark, convertedWord)
        view.setFindListener { active, count, done ->
            if (done && view === webView) {
                channel.invokeMethod("found", mapOf("active" to active, "count" to count))
            }
        }
        container.addView(view, FrameLayout.LayoutParams(-1, -1))
        view.settings.apply {
            javaScriptEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            blockNetworkLoads = true
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            useWideViewPort = true
            setSupportZoom(true)
            builtInZoomControls = true
            displayZoomControls = false
        }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(view, "OfficePreview", setOf(ORIGIN)) {
                    viewSender, message, _, isMainFrame, _ ->
                if (viewSender === webView && isMainFrame) publishStatus(message.data)
            }
        } else {
            // 旧 WebView 只接收阅读状态。附件正文的 iframe 禁止运行脚本。
            val main = Handler(Looper.getMainLooper())
            view.addJavascriptInterface(OfficePreviewStatus { status ->
                main.post { if (view === webView) publishStatus(status) }
            }, "OfficePreview")
        }
        view.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                view: WebView,
                request: WebResourceRequest,
            ): WebResourceResponse = resource(request)

            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                request.isForMainFrame || request.url.toString() !in setOf("about:blank", "about:srcdoc")

            override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                if (request.isForMainFrame) reportFailure()
            }

            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                releaseView()
                reportFailure()
                return true
            }
        }
        val url = Uri.parse("$ORIGIN/viewer.html").buildUpon()
            .appendQueryParameter("dark", if (dark) "1" else "0")
            .build()
        view.loadUrl(url.toString())
    }

    private fun publishStatus(status: String?) {
        if (status == "failed") {
            reportFailure()
        } else if (status != null && status.length <= 128 && status.startsWith("ready:")) {
            channel.invokeMethod("ready", status.removePrefix("ready:"))
        }
    }

    private fun resource(request: WebResourceRequest): WebResourceResponse {
        val url = request.url
        if (request.method != "GET" || url.scheme != "https" || url.host != HOST ||
            (url.port != -1 && url.port != 443)) return denied()
        val path = url.encodedPath.orEmpty()
        return try {
            when (path) {
                "/viewer.html" -> response("text/html", context.assets.open("bulletin_office$path"))
                "/viewer.js" -> response("text/javascript", context.assets.open("bulletin_office$path"))
                "/views" -> {
                    val width = url.getQueryParameter("width")?.toIntOrNull()?.coerceIn(240, 1920) ?: 400
                    val bytes = renderer?.metadata(width)?.toByteArray() ?: return denied()
                    response("application/json", ByteArrayInputStream(bytes))
                }
                else -> {
                    val index = path.takeIf { it.startsWith("/view/") }
                        ?.removePrefix("/view/")?.toIntOrNull() ?: return denied()
                    val bytes = renderer?.render(index) ?: return denied()
                    response("text/html", ByteArrayInputStream(bytes))
                }
            }
        } catch (_: IOException) {
            denied()
        } catch (_: RuntimeException) {
            denied()
        } catch (_: LinkageError) {
            denied()
        }
    }

    private fun response(mimeType: String, stream: InputStream) = WebResourceResponse(
        mimeType,
        "UTF-8",
        200,
        "OK",
        mapOf(
            "Content-Security-Policy" to
                "default-src 'none'; script-src 'self'; connect-src 'self'; frame-src 'self' about:; " +
                "style-src 'unsafe-inline'; img-src data:; font-src data:; base-uri 'none'",
            "Cache-Control" to "no-store",
            "X-Content-Type-Options" to "nosniff",
        ),
        stream,
    )

    private fun denied() = WebResourceResponse(
        "text/plain", "UTF-8", 404, "Not Found", emptyMap(), ByteArrayInputStream(byteArrayOf()),
    )

    private fun reportFailure() {
        channel.invokeMethod("failed", null)
    }

    private fun releaseView() {
        renderer?.close()
        renderer = null
        val view = webView ?: return
        webView = null
        container.removeView(view)
        view.destroy()
    }

    override fun getView(): View = container

    override fun dispose() {
        channel.setMethodCallHandler(null)
        releaseView()
    }

    private class OfficePreviewStatus(private val onMessage: (String?) -> Unit) {
        @Keep
        @JavascriptInterface
        fun postMessage(status: String?) = onMessage(status)
    }

    companion object {
        private const val HOST = "bulletin-office.invalid"
        private const val ORIGIN = "https://$HOST"
    }
}
