package dev.duohuo.nuist_sta_app

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.res.AssetManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Message
import android.os.Messenger
import android.os.RemoteException
import org.libreoffice.kit.LibreOfficeKit
import org.libreoffice.kit.Office
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

/** 在独立进程中串行转换公告 Word，转换异常不影响应用阅读界面。 */
class BulletinWordPdfService : Service() {
    override fun onBind(intent: Intent?): IBinder {
        val engine = messenger ?: createMessenger(applicationContext).also { messenger = it }
        return engine.binder
    }

    companion object {
        // 同一进程的后续绑定继续使用原生引擎初始化时的线程。
        private var messenger: Messenger? = null

        private fun createMessenger(context: Context): Messenger {
            val converter = BulletinWordPdfConverter(context)
            val worker = HandlerThread("公告 Word 转换").also { it.start() }
            return Messenger(Handler(worker.looper) { request ->
                val path = try {
                    request.data.getString("path")?.let(converter::convert)?.path
                } catch (_: Exception) {
                    null
                } catch (_: LinkageError) {
                    null
                }
                val response = Message.obtain().apply {
                    arg1 = request.arg1
                    data = Bundle().apply { putString("path", path) }
                }
                try {
                    request.replyTo?.send(response)
                } catch (_: RemoteException) {
                    // 阅读界面已关闭时，完成的 PDF 仍可供下次读取。
                }
                true
            })
        }
    }
}

private class BulletinWordPdfConverter(private val context: Context) {
    private var office: Office? = null

    fun convert(path: String): File {
        val source = File(path).canonicalFile
        val attachments = File(context.cacheDir, "bulletin_attachments").canonicalPath + File.separator
        require(source.path.startsWith(attachments) && source.isFile)
        require(source.length() in 1L..BulletinOfficeRenderer.MAX_FILE_BYTES)
        val outputDir = File(context.cacheDir, "bulletin_word_pdf/$CACHE_VERSION")
        outputDir.mkdirs()
        val output = File(outputDir, "${digest(source)}.pdf")
        if (output.isFile) {
            output.setLastModified(System.currentTimeMillis())
            return output
        }
        val partial = File.createTempFile("word-", ".pdf", outputDir)
        try {
            val engine = office ?: openEngine().also { office = it }
            checkNotNull(engine.open(Uri.fromFile(source).toString())).use { document ->
                require(document.isText())
                document.saveAs(Uri.fromFile(partial).toString(), "pdf", "")
            }
            check(partial.inputStream().use { input ->
                "%PDF-".all { input.read() == it.code }
            })
            check(partial.renameTo(output))
            trimCache(outputDir, output)
            return output
        } finally {
            partial.delete()
        }
    }

    private fun openEngine(): Office {
        val data = File(context.applicationInfo.dataDir)
        val installed = File(context.filesDir, "bulletin_word_engine_$CACHE_VERSION")
        if (!installed.isFile) {
            unpack(context.assets, "unpack", data)
            installed.writeText(CACHE_VERSION)
        }
        val registry = File(data, "user/registrymodifications.xcu")
        registry.parentFile?.mkdirs()
        registry.writeText(
            """<?xml version="1.0" encoding="UTF-8"?>
               <oor:items xmlns:oor="http://openoffice.org/2001/registry">
                 <item oor:path="/org.openoffice.Office.Common/Security/Scripting">
                   <prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop>
                   <prop oor:name="DisableActiveContent" oor:op="fuse"><value>true</value></prop>
                   <prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop>
                 </item>
                 <item oor:path="/org.openoffice.Office.Writer/Content/Update">
                   <prop oor:name="Link" oor:op="fuse"><value>2</value></prop>
                 </item>
               </oor:items>
            """.trimIndent(),
        )
        val fonts = File(data, "etc/fonts/fonts.conf")
        val configuration = fonts.readText()
        val upstreamCache = "/data/data/org.documentfoundation.libreoffice/fontconfig"
        if (upstreamCache in configuration) {
            val fontCache = File(context.cacheDir, "bulletin_word_fonts")
            fontCache.mkdirs()
            fonts.writeText(configuration.replace(upstreamCache, fontCache.absolutePath))
        }
        return LibreOfficeKit.open(context, registry)
    }

    private fun unpack(assets: AssetManager, path: String, target: File) {
        val children = assets.list(path).orEmpty()
        if (children.isEmpty()) {
            assets.open(path).use { input ->
                target.outputStream().buffered().use { input.copyTo(it) }
            }
        } else {
            target.mkdirs()
            for (name in children) unpack(assets, "$path/$name", File(target, name))
        }
    }

    private fun digest(source: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        source.inputStream().buffered().use { input ->
            val bytes = ByteArray(64 * 1024)
            while (true) {
                val count = input.read(bytes)
                if (count == -1) break
                digest.update(bytes, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun trimCache(directory: File, current: File) {
        val files = directory.listFiles().orEmpty()
            .filter { it.isFile && it != current }
            .sortedByDescending(File::lastModified)
        var bytes = current.length()
        val cutoff = System.currentTimeMillis() - TimeUnit.DAYS.toMillis(7)
        for (file in files) {
            val size = file.length()
            if (file.lastModified() < cutoff || bytes + size > MAX_CACHE_BYTES) {
                file.delete()
            } else {
                bytes += size
            }
        }
    }

    companion object {
        private const val CACHE_VERSION = "26.2.7.3-1"
        private const val MAX_CACHE_BYTES = 256L * 1024 * 1024
    }
}
