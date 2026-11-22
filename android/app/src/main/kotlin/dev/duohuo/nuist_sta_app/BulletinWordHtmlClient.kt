package dev.duohuo.nuist_sta_app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.RemoteException
import io.flutter.plugin.common.MethodChannel
import java.io.File

/** 把转换工作交给独立进程，所有状态在主线程处理。 */
internal class BulletinWordHtmlClient(private val context: Context) : ServiceConnection {
    private val main = Handler(Looper.getMainLooper())
    private val pending = mutableMapOf<Int, Request>()
    private val idle = Runnable { disconnect() }
    private var nextId = 0
    private var bound = false
    private var service: Messenger? = null
    private val replies = Messenger(Handler(Looper.getMainLooper()) { message ->
        val request = pending.remove(message.arg1)
        if (request != null) {
            val path = message.data.getString("path")
            if (path == null) fail(request) else request.result.success(path)
        }
        if (pending.isEmpty()) main.postDelayed(idle, 15_000L)
        true
    })

    fun convert(file: File, result: MethodChannel.Result) {
        main.removeCallbacks(idle)
        val id = ++nextId
        val request = Request(file.path, result)
        pending[id] = request
        val connected = service
        if (connected != null) {
            send(connected, id, request)
        } else if (!bound) {
            val intent = Intent(context, BulletinWordHtmlService::class.java)
            bound = try {
                context.bindService(intent, this, Context.BIND_AUTO_CREATE)
            } catch (_: RuntimeException) {
                false
            }
            if (!bound) close()
        }
    }

    override fun onServiceConnected(name: ComponentName, binder: IBinder) {
        if (!bound) return
        val connected = Messenger(binder)
        service = connected
        for ((id, request) in pending.toMap()) {
            if (!send(connected, id, request)) break
        }
    }

    override fun onServiceDisconnected(name: ComponentName) = close()
    override fun onBindingDied(name: ComponentName) = close()
    override fun onNullBinding(name: ComponentName) = close()

    fun close() {
        disconnect()
        pending.values.forEach(::fail)
        pending.clear()
    }

    private fun send(connected: Messenger, id: Int, request: Request): Boolean {
        val message = Message.obtain().apply {
            arg1 = id
            data = Bundle().apply { putString("path", request.path) }
            replyTo = replies
        }
        return try {
            connected.send(message)
            true
        } catch (_: RemoteException) {
            close()
            false
        }
    }

    private fun disconnect() {
        main.removeCallbacks(idle)
        service = null
        if (bound) {
            bound = false
            context.unbindService(this)
        }
    }

    private fun fail(request: Request) {
        request.result.error("word_conversion_failed", "无法预览此附件", null)
    }

    private data class Request(val path: String, val result: MethodChannel.Result)
}
