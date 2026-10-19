package dev.duohuo.nuist_sta_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!flutterEngine.plugins.has(AttachmentPdfPreviewPlugin::class.java)) {
            flutterEngine.plugins.add(AttachmentPdfPreviewPlugin())
        }
    }
}
