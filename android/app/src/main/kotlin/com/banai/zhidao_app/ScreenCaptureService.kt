package com.banai.zhidao_app

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * 截屏监控前台服务（MediaProjection 方案）。
 *
 * 职责：
 *  - 持有 [MediaProjection] token 并创建 [VirtualDisplay] + [ImageReader]（RGBA_8888）；
 *  - 在独立后台线程按 [CaptureConfig.intervalMs] 周期性抓帧；
 *  - 图像预处理：按区域裁剪 → 缩放填充到 [CaptureConfig.targetSize] x targetSize → JPEG；
 *  - 不阻塞主线程：抓帧、裁剪、缩放、编码全部在后台线程完成，仅通过 [Listener] 回调结果；
 *  - Android 14+（API 34+）要求 MediaProjection 依赖 type=mediaProjection 的前台服务，
 *    因此整机以前台服务运行并展示持续通知。
 */
class ScreenCaptureService : Service() {
    /** 由插件注册，把帧/状态事件桥接到 Flutter */
    interface Listener {
        fun onFrame(bytes: ByteArray)
        fun onCapturingStarted(intervalMs: Int)
        fun onCapturingStopped()
        fun onError(message: String)
    }

    /**
     * 截屏配置：频率 / 目标分辨率 / JPEG 质量 / 裁剪区域（屏幕像素坐标，null 为全屏）。
     * 独立于 companion 定义，避免任何平台/编码解析歧义。
     */
    data class CaptureConfig(
        val intervalMs: Int = 1000,
        val targetSize: Int = 640,
        val jpegQuality: Int = 85,
        val regionLeft: Int? = null,
        val regionTop: Int? = null,
        val regionRight: Int? = null,
        val regionBottom: Int? = null,
    )

    companion object {
        private const val TAG = "ScreenCaptureService"
        private const val CHANNEL_ID = "screen_capture"
        private const val NOTIFICATION_ID = 0x5C42

        private const val EXTRA_RESULT_CODE = "resultCode"
        private const val EXTRA_RESULT_DATA = "resultData"
        private const val EXTRA_INTERVAL_MS = "intervalMs"
        private const val EXTRA_TARGET_SIZE = "targetSize"
        private const val EXTRA_JPEG_QUALITY = "jpegQuality"
        private const val EXTRA_REGION = "region"

        @Volatile
        var listener: Listener? = null
            private set

        @Volatile
        var isRunning: Boolean = false
            private set

        /** 当前生效的截屏配置（抓帧线程每轮实时读取，支持热更新） */
        @Volatile
        var captureConfig: CaptureConfig = CaptureConfig()
            private set

        /**
         * 启动前台截屏服务。需要先通过 requestPermission 获得授权 token。
         */
        fun start(
            context: Context,
            resultCode: Int,
            resultData: Intent,
            config: CaptureConfig,
            pluginListener: Listener?,
        ): Boolean {
            listener = pluginListener
            captureConfig = config
            val intent = Intent(context, ScreenCaptureService::class.java).apply {
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_RESULT_DATA, resultData)
                putExtra(EXTRA_INTERVAL_MS, config.intervalMs)
                putExtra(EXTRA_TARGET_SIZE, config.targetSize)
                putExtra(EXTRA_JPEG_QUALITY, config.jpegQuality)
                val region = configRegionToMap(config)
                if (region != null) putExtra(EXTRA_REGION, region)
            }
            return try {
                ContextCompat.startForegroundService(context, intent)
                true
            } catch (e: Exception) {
                Log.e(TAG, "启动前台服务失败", e)
                pluginListener?.onError("启动截屏服务失败: ${e.message}")
                false
            }
        }

        /** 热更新截屏配置（仅对运行中的服务生效，抓帧线程下一轮立即采用） */
        fun updateConfig(config: CaptureConfig) {
            captureConfig = config
        }

        /** 停止截屏服务 */
        fun stop(context: Context) {
            captureConfig = CaptureConfig()
            try {
                context.stopService(Intent(context, ScreenCaptureService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "停止截屏服务失败", e)
            }
        }

        private fun configRegionToMap(config: CaptureConfig): HashMap<String, Int>? {
            val left = config.regionLeft ?: return null
            val top = config.regionTop ?: return null
            val right = config.regionRight ?: return null
            val bottom = config.regionBottom ?: return null
            return hashMapOf(
                "left" to left,
                "top" to top,
                "right" to right,
                "bottom" to bottom,
            )
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private val running = AtomicBoolean(false)

    private var mediaProjection: MediaProjection? = null
    private var imageReader: ImageReader? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var captureThread: Thread? = null
    private var mediaProjectionCallback: MediaProjection.Callback? = null

    private var screenWidth = 0
    private var screenHeight = 0
    private var readerWidth = 0
    private var readerHeight = 0
    private var readerScale = 1.0f

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null || running.get()) {
            // 服务已运行，直接返回
            return START_STICKY
        }
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
        val resultData = getParcelableIntent(intent, EXTRA_RESULT_DATA)
        if (resultData == null) {
            listener?.onError("缺少屏幕捕获授权数据")
            stopSelf()
            return START_NOT_STICKY
        }

        startAsForeground()

        val configMs = intent.getIntExtra(EXTRA_INTERVAL_MS, 1000)
        val configSize = intent.getIntExtra(EXTRA_TARGET_SIZE, 640)
        val configJpeg = intent.getIntExtra(EXTRA_JPEG_QUALITY, 85)
        val regionExtra = if (Build.VERSION.SDK_INT >= 33) {
            intent.getSerializableExtra(EXTRA_REGION, HashMap::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getSerializableExtra(EXTRA_REGION)
        } as? Map<*, *>
        captureConfig = CaptureConfig(
            intervalMs = (configMs).coerceAtLeast(100),
            targetSize = (configSize).coerceIn(128, 1024),
            jpegQuality = (configJpeg).coerceIn(1, 100),
            regionLeft = (regionExtra?.get("left") as? Number)?.toInt(),
            regionTop = (regionExtra?.get("top") as? Number)?.toInt(),
            regionRight = (regionExtra?.get("right") as? Number)?.toInt(),
            regionBottom = (regionExtra?.get("bottom") as? Number)?.toInt(),
        )

        if (!setupProjection(resultCode, resultData)) {
            listener?.onError("初始化屏幕捕获失败，请重新授权")
            stopSelf()
            return START_NOT_STICKY
        }

        running.set(true)
        isRunning = true
        startCaptureThread()

        listener?.onCapturingStarted(captureConfig.intervalMs)
        Log.i(TAG, "截屏监控已启动: 间隔=${captureConfig.intervalMs}ms 目标=${captureConfig.targetSize}px")
        return START_STICKY
    }

    private fun startAsForeground() {
        createNotificationChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "截屏监控",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "屏幕捕获实时监控运行状态"
            setShowBadge(false)
        }
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("截屏监控运行中")
            .setContentText("正在进行屏幕实时监控")
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun setupProjection(resultCode: Int, resultData: Intent): Boolean {
        val metrics = resources.displayMetrics
        screenWidth = metrics.widthPixels
        screenHeight = metrics.heightPixels
        if (screenWidth <= 0 || screenHeight <= 0) return false

        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val projection: MediaProjection = try {
            mpm.getMediaProjection(resultCode, resultData) ?: return false
        } catch (e: Exception) {
            Log.e(TAG, "获取 MediaProjection 失败", e)
            return false
        }
        mediaProjection = projection

        // 限制 ImageReader 分辨率以降低内存占用，区域坐标按该比例换算
        val maxDim = 1280
        readerScale = min(1.0f, maxDim.toFloat() / max(screenWidth, screenHeight))
        readerWidth = (screenWidth * readerScale).roundToInt().coerceAtLeast(1)
        readerHeight = (screenHeight * readerScale).roundToInt().coerceAtLeast(1)

        imageReader = ImageReader.newInstance(
            readerWidth,
            readerHeight,
            PixelFormat.RGBA_8888,
            2,
        )

        virtualDisplay = try {
            projection.createVirtualDisplay(
                "ScreenCaptureVirtualDisplay",
                readerWidth,
                readerHeight,
                metrics.densityDpi,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                imageReader!!.surface,
                null,
                null,
            )
        } catch (e: Exception) {
            Log.e(TAG, "创建 VirtualDisplay 失败", e)
            return false
        }

        mediaProjectionCallback = object : MediaProjection.Callback() {
            override fun onStop() {
                // 用户从系统通知栏停止了屏幕捕获，或 token 被系统回收
                Log.i(TAG, "MediaProjection onStop")
                if (running.get()) {
                    handler.post { onProjectionStopped() }
                }
            }
        }
        projection.registerCallback(mediaProjectionCallback!!, handler)
        return true
    }

    private fun onProjectionStopped() {
        if (!running.get()) return
        Log.i(TAG, "屏幕捕获被外部停止，正在关闭服务")
        stopSelf()
    }

    private fun startCaptureThread() {
        captureThread = Thread({
            while (running.get()) {
                val startMs = System.currentTimeMillis()
                try {
                    val bytes = captureOnce()
                    if (bytes != null && running.get()) {
                        listener?.onFrame(bytes)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "截屏帧处理异常", e)
                    if (running.get()) {
                        listener?.onError("截屏失败: ${e.message}")
                    }
                }
                if (!running.get()) break
                val elapsed = System.currentTimeMillis() - startMs
                Thread.sleep(max(10L, captureConfig.intervalMs.toLong() - elapsed))
            }
        }, "ScreenCaptureThread")
        captureThread?.priority = Thread.NORM_PRIORITY
        captureThread?.start()
    }

    /**
     * 抓取一帧：ImageReader 最新图像 → 区域裁剪 → 缩放填充到 targetSize x targetSize → JPEG。
     * 全程在本线程执行，不回主线程。
     */
    private fun captureOnce(): ByteArray? {
        val reader = imageReader ?: return null
        val image = reader.acquireLatestImage() ?: return null
        try {
            val plane = image.planes[0]
            val buffer = plane.buffer
            val pixelStride = plane.pixelStride
            val rowStride = plane.rowStride
            val width = image.width
            val height = image.height

            val rowPadding = rowStride - pixelStride * width
            val fullBmp = Bitmap.createBitmap(
                width + rowPadding / pixelStride,
                height,
                Bitmap.Config.ARGB_8888,
            )
            buffer.rewind()
            fullBmp.copyPixelsFromBuffer(buffer)

            val srcRect = computeSourceRect()
            val targetSize = captureConfig.targetSize
            val regionBmp = if (srcRect.width() == width && srcRect.height() == height) {
                fullBmp
            } else {
                Bitmap.createBitmap(
                    fullBmp,
                    srcRect.left,
                    srcRect.top,
                    srcRect.width(),
                    srcRect.height(),
                )
            }
            val scaled = Bitmap.createScaledBitmap(regionBmp, targetSize, targetSize, true)

            val out = ByteArrayOutputStream()
            scaled.compress(
                Bitmap.CompressFormat.JPEG,
                captureConfig.jpegQuality,
                out,
            )
            val bytes = out.toByteArray()

            if (scaled !== regionBmp) scaled.recycle()
            if (regionBmp !== fullBmp) regionBmp.recycle()
            fullBmp.recycle()
            return bytes
        } catch (e: Exception) {
            Log.e(TAG, "截屏帧处理失败", e)
            return null
        } finally {
            image.close()
        }
    }

    /** 计算 ImageReader 坐标系下的裁剪区域（区域以屏幕像素传入） */
    private fun computeSourceRect(): Rect {
        val cfg = captureConfig
        val leftScreen = cfg.regionLeft ?: return Rect(0, 0, readerWidth, readerHeight)
        val cfgTop = cfg.regionTop ?: return Rect(0, 0, readerWidth, readerHeight)
        val cfgRight = cfg.regionRight ?: return Rect(0, 0, readerWidth, readerHeight)
        val cfgBottom = cfg.regionBottom ?: return Rect(0, 0, readerWidth, readerHeight)

        val left = (leftScreen * readerScale).roundToInt().coerceIn(0, readerWidth - 1)
        val top = (cfgTop * readerScale).roundToInt().coerceIn(0, readerHeight - 1)
        val right = (cfgRight * readerScale).roundToInt().coerceIn(left + 1, readerWidth)
        val bottom = (cfgBottom * readerScale).roundToInt().coerceIn(top + 1, readerHeight)
        return Rect(left, top, right, bottom)
    }

    override fun onDestroy() {
        Log.i(TAG, "ScreenCaptureService.onDestroy")
        running.set(false)
        isRunning = false

        try {
            captureThread?.interrupt()
            captureThread?.join(500)
        } catch (e: Exception) {
            // 忽略
        }
        captureThread = null

        try {
            mediaProjectionCallback?.let { mediaProjection?.unregisterCallback(it) }
        } catch (e: Exception) {
            Log.w(TAG, "注销 MediaProjection 回调失败", e)
        }
        mediaProjectionCallback = null

        try {
            mediaProjection?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "停止 MediaProjection 失败", e)
        }
        mediaProjection = null

        try {
            virtualDisplay?.release()
        } catch (e: Exception) {
            Log.w(TAG, "释放 VirtualDisplay 失败", e)
        }
        virtualDisplay = null

        try {
            imageReader?.close()
        } catch (e: Exception) {
            Log.w(TAG, "关闭 ImageReader 失败", e)
        }
        imageReader = null

        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }

        captureConfig = CaptureConfig()
        isRunning = false
        listener?.onCapturingStopped()
        super.onDestroy()
    }

    @Suppress("DEPRECATION")
    private fun getParcelableIntent(intent: Intent, key: String): Intent? {
        return if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(key, Intent::class.java)
        } else {
            intent.getParcelableExtra(key)
        }
    }
}