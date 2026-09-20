package com.banai.zhidao_app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 截屏监控模块（MediaProjection）桥接插件。
 *
 * MethodChannel `com.banai.zhidao_app/screen_capture`：
 *  - requestPermission —— 拉起系统"屏幕捕获"授权对话框；
 *  - getScreenInfo     —— 返回屏幕物理分辨率；
 *  - start             —— 启动前台截屏服务（需先授权）；
 *  - updateConfig      —— 热更新截屏频率 / 区域 / 目标尺寸；
 *  - stop              —— 停止截屏；
 *  - isCapturing       —— 查询是否正在截屏。
 *
 * EventChannel `.../frames`   —— 周期性推送预处理后的 JPEG 帧（640x640）。
 * EventChannel `.../status`   —— 权限拒绝 / 启停 / 错误等状态事件。
 *
 * 授权结果经 [onActivityResult] 转交；用户拒绝（RESULT_CANCELED）会在 Dart 侧
 * 提示手动到系统设置开启"屏幕捕获"权限。
 */
class ScreenCapturePlugin(
    private val engine: FlutterEngine,
    private val activity: Activity,
) {
    companion object {
        private const val TAG = "ScreenCapturePlugin"
        const val CHANNEL = "com.banai.zhidao_app/screen_capture"
        const val FRAME_EVENTS = "com.banai.zhidao_app/screen_capture/frames"
        const val STATUS_EVENTS = "com.banai.zhidao_app/screen_capture/status"
        const val REQUEST_SCREEN_CAPTURE = 0x5C41
    }

    private val messenger: BinaryMessenger = engine.dartExecutor.binaryMessenger
    private val handler = Handler(Looper.getMainLooper())

    private var frameEventSink: EventChannel.EventSink? = null
    private var statusEventSink: EventChannel.EventSink? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    /** 授权成功后系统返回的投影 token（创建 MediaProjection 所需） */
    private var projectionData: Intent? = null

    private val listener = object : ScreenCaptureService.Listener {
        override fun onFrame(bytes: ByteArray) {
            val sink = frameEventSink ?: return
            handler.post { sink.success(bytes) }
        }

        override fun onCapturingStarted(intervalMs: Int) {
            emitStatus(
                "capturing_started",
                "截屏监控已启动（每 ${intervalMs}ms 一帧）",
            )
        }

        override fun onCapturingStopped() {
            emitStatus("capturing_stopped", "截屏监控已停止")
        }

        override fun onError(message: String) {
            emitStatus("error", message)
        }
    }

    fun register() {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isPermissionGranted" -> result.success(projectionData != null)
                "getScreenInfo" -> result.success(getScreenInfo())
                "requestPermission" -> requestPermission(result)
                "start" -> start(call, result)
                "updateConfig" -> updateConfig(call, result)
                "stop" -> stop(result)
                "isCapturing" -> result.success(ScreenCaptureService.isRunning)
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, FRAME_EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                frameEventSink = sink
            }

            override fun onCancel(arguments: Any?) {
                frameEventSink = null
            }
        })

        EventChannel(messenger, STATUS_EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                statusEventSink = sink
            }

            override fun onCancel(arguments: Any?) {
                statusEventSink = null
            }
        })
    }

    private fun getScreenInfo(): Map<String, Int> {
        val dm = activity.resources.displayMetrics
        return mapOf(
            "width" to dm.widthPixels,
            "height" to dm.heightPixels,
            "densityDpi" to dm.densityDpi,
        )
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (pendingPermissionResult != null) {
            result.error("PERMISSION_PENDING", "已有屏幕捕获授权请求正在进行中", null)
            return
        }
        val mpm = activity.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        pendingPermissionResult = result
        try {
            activity.startActivityForResult(mpm.createScreenCaptureIntent(), REQUEST_SCREEN_CAPTURE)
        } catch (e: Exception) {
            pendingPermissionResult = null
            result.error("LAUNCH_FAILED", "无法启动屏幕捕获授权: ${e.message}", null)
        }
    }

    /**
     * 屏幕捕获授权结果。由 MainActivity.onActivityResult 转发。
     * 返回 true 表示该请求已由本插件消费。
     */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_SCREEN_CAPTURE) return false
        val pending = pendingPermissionResult ?: return true
        pendingPermissionResult = null
        if (resultCode == Activity.RESULT_OK && data != null) {
            projectionData = data
            pending.success(true)
        } else {
            projectionData = null
            pending.success(false)
            emitStatus(
                "permission_denied",
                "未获得屏幕捕获授权，请在系统设置中允许后重试",
            )
        }
        return true
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val data = projectionData
        if (data == null) {
            result.error("PERMISSION_REQUIRED", "尚未获得屏幕捕获授权", null)
            return
        }
        try {
            val config = parseConfig(call)
            val ok = ScreenCaptureService.start(
                activity.applicationContext,
                Activity.RESULT_OK,
                data,
                config,
                listener,
            )
            if (ok) {
                result.success(true)
            } else {
                result.error("START_FAILED", "启动截屏服务失败", null)
            }
        } catch (e: Exception) {
            Log.e(TAG, "start 失败", e)
            result.error("START_ERROR", "启动截屏监控异常: ${e.message}", null)
        }
    }

    private fun updateConfig(call: MethodCall, result: MethodChannel.Result) {
        try {
            val config = parseConfig(call)
            ScreenCaptureService.updateConfig(config)
            result.success(true)
        } catch (e: Exception) {
            result.error("UPDATE_ERROR", "更新截屏配置失败: ${e.message}", null)
        }
    }

    private fun stop(result: MethodChannel.Result) {
        try {
            ScreenCaptureService.stop(activity.applicationContext)
            result.success(true)
        } catch (e: Exception) {
            result.error("STOP_ERROR", "停止截屏失败: ${e.message}", null)
        }
    }

    private fun parseConfig(call: MethodCall): ScreenCaptureService.CaptureConfig {
        val region = call.argument<Map<*, *>>("region")
        val regionLeft = (region?.get("left") as? Number)?.toInt()
        val regionTop = (region?.get("top") as? Number)?.toInt()
        val regionRight = (region?.get("right") as? Number)?.toInt()
        val regionBottom = (region?.get("bottom") as? Number)?.toInt()
        return ScreenCaptureService.CaptureConfig(
            intervalMs = (call.argument<Number>("intervalMs")?.toInt() ?: 1000).coerceAtLeast(100),
            targetSize = (call.argument<Number>("targetSize")?.toInt() ?: 640).coerceIn(128, 1024),
            jpegQuality = (call.argument<Number>("jpegQuality")?.toInt() ?: 85).coerceIn(1, 100),
            regionLeft = regionLeft,
            regionTop = regionTop,
            regionRight = regionRight,
            regionBottom = regionBottom,
        )
    }

    private fun emitStatus(typeParam: String, message: String) {
        val sink = statusEventSink ?: return
        handler.post {
            sink.success(mapOf("type" to typeParam, "message" to message))
        }
    }

    fun dispose() {
        try {
            ScreenCaptureService.stop(activity.applicationContext)
        } catch (e: Exception) {
            Log.w(TAG, "dispose 停止截屏失败", e)
        }
        frameEventSink = null
        statusEventSink = null
        pendingPermissionResult = null
        projectionData = null
    }
}