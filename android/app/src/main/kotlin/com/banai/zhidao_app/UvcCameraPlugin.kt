package com.banai.zhidao_app

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbConstants
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Surface
import com.serenegiant.usb.Size
import com.serenegiant.usb.USBMonitor
import com.serenegiant.usb.UVCCamera
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * USB UVC 摄像头（libuvc 原生方案）。
 * 基于 Maven Central 的 org.uvccamera:lib（saki4510t UVCCamera 的活跃分叉）。
 * 通过 MethodChannel/EventChannel + SurfaceProducer 纹理桥接到 Flutter。
 *
 * 能力：
 *  - listDevices / requestPermission：设备枚举与 USB 权限
 *  - open：打开摄像头并把预览画面渲染到 Flutter Texture
 *  - startFrameStream：把 NV21 帧转 JPEG 后持续推送给 Dart（供 YOLO 推理）。
 *  - takePicture：抓拍一张 JPG 保存到缓存目录（供 Gemma 图像分析）。 */
class UvcCameraPlugin(
    private val engine: FlutterEngine,
    private val activity: Activity,
) {
    companion object {
        private const val TAG = "UvcCameraPlugin"
        const val CHANNEL = "com.banai.zhidao_app/uvc"
        const val DEVICE_EVENTS = "com.banai.zhidao_app/uvc/device_events"
        const val FRAME_EVENTS = "com.banai.zhidao_app/uvc/frame_events"
    }

    private val handler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()

    private lateinit var usbMonitor: USBMonitor
    private val textureRegistry: TextureRegistry = engine.renderer
    private val messenger: BinaryMessenger = engine.dartExecutor.binaryMessenger

    private var camera: UVCCamera? = null
    private var surfaceProducer: TextureRegistry.SurfaceProducer? = null
    private var previewSurface: Surface? = null
    private var previewWidth: Int = 0
    private var previewHeight: Int = 0

    private var deviceEventSink: EventChannel.EventSink? = null
    private var frameEventSink: EventChannel.EventSink? = null

    private var streaming = false
    private var pendingPermissionDevice: String? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    private var lastFrameSentAt: Long = 0
    private val minFrameIntervalMs = 60L

    fun register() {
        usbMonitor = USBMonitor(activity.applicationContext, object : USBMonitor.OnDeviceConnectListener {
            override fun onAttach(device: UsbDevice) {
                Log.i(TAG, "onAttach: ${device.deviceName}")
                emitDeviceEvent("attached", device)
            }

            override fun onDettach(device: UsbDevice) {
                Log.i(TAG, "onDettach: ${device.deviceName}")
                emitDeviceEvent("detached", device)
                // 设备拔出时主动释放已打开的摄像头
                handler.post {
                    if (pendingPermissionDevice == null) {
                        closeCameraInternal()
                    }
                }
            }

            override fun onConnect(
                device: UsbDevice,
                ctrlBlock: USBMonitor.UsbControlBlock,
                createNew: Boolean,
            ) {
                Log.i(TAG, "onConnect: ${device.deviceName}")
                emitDeviceEvent("connected", device)
                handler.post { fulfillPermission(device, granted = true) }
            }

            override fun onDisconnect(device: UsbDevice, ctrlBlock: USBMonitor.UsbControlBlock) {
                Log.i(TAG, "onDisconnect: ${device.deviceName}")
                emitDeviceEvent("disconnected", device)
            }

            override fun onCancel(device: UsbDevice) {
                Log.i(TAG, "onCancel: ${device.deviceName}")
                emitDeviceEvent("permission_denied", device)
                handler.post { fulfillPermission(device, granted = false) }
            }
        })
        usbMonitor.register()

        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> {
                    result.success(
                        activity.packageManager.hasSystemFeature(PackageManager.FEATURE_USB_HOST)
                    )
                }
                "listDevices" -> result.success(listDevices())
                "requestPermission" -> requestPermission(call, result)
                "open" -> open(call, result)
                "takePicture" -> takePicture(result)
                "startFrameStream" -> startFrameStream(result)
                "stopFrameStream" -> stopFrameStream(result)
                "close" -> close(result)
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, DEVICE_EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                deviceEventSink = sink
            }

            override fun onCancel(arguments: Any?) {
                deviceEventSink = null
            }
        })

        EventChannel(messenger, FRAME_EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                frameEventSink = sink
            }

            override fun onCancel(arguments: Any?) {
                frameEventSink = null
            }
        })
    }

    private fun listDevices(): List<Map<String, Any?>> {
        val devices = usbMonitor.getDeviceList().filter(::isUvcCamera)
        Log.i(TAG, "发现 ${devices.size} 个 UVC 摄像头")
        return devices.map { device ->
            mapOf(
                "name" to device.deviceName,
                "vendorId" to device.vendorId,
                "productId" to device.productId,
                "deviceClass" to device.deviceClass,
                "manufacturerName" to (device.manufacturerName ?: ""),
                "productName" to (device.productName ?: ""),
            )
        }
    }

    private fun isUvcCamera(device: UsbDevice): Boolean {
        if (device.deviceClass == UsbConstants.USB_CLASS_VIDEO) {
            return true
        }
        return (0 until device.interfaceCount).any { index ->
            device.getInterface(index).interfaceClass == UsbConstants.USB_CLASS_VIDEO
        }
    }

    private fun emitDeviceEvent(type: String, device: UsbDevice) {
        val sink = deviceEventSink ?: return
        val event = mapOf(
            "type" to type,
            "device" to mapOf(
                "name" to device.deviceName,
                "vendorId" to device.vendorId,
                "productId" to device.productId,
                "deviceClass" to device.deviceClass,
            ),
        )
        handler.post { sink.success(event) }
    }

    private fun requestPermission(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name")
        if (name == null) {
            result.error("INVALID_ARGUMENT", "name is null", null)
            return
        }
        val device = findDeviceByName(name)
        if (device == null) {
            result.error("DEVICE_NOT_FOUND", "未找到设备 $name", null)
            return
        }
        if (
            activity.checkSelfPermission(Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            result.error(
                "CAMERA_PERMISSION_REQUIRED",
                "Android 要求先授予相机权限，才能访问 USB 视频设备",
                null,
            )
            return
        }
        if (pendingPermissionResult != null) {
            result.error("PERMISSION_PENDING", "已有权限请求在等待中", null)
            return
        }
        pendingPermissionDevice = name
        pendingPermissionResult = result
        usbMonitor.requestPermission(device)
    }

    private fun fulfillPermission(device: UsbDevice, granted: Boolean) {
        val expected = pendingPermissionDevice
        val pending = pendingPermissionResult
        if (expected == null || pending == null) {
            return
        }
        if (expected != device.deviceName) {
            return
        }
        pendingPermissionDevice = null
        pendingPermissionResult = null
        if (granted) {
            pending.success(true)
        } else {
            pending.error("PERMISSION_DENIED", "用户拒绝了 USB 设备访问权限", null)
        }
    }

    private fun open(call: MethodCall, result: MethodChannel.Result) {
        val name = call.argument<String>("name")
        if (name == null) {
            result.error("INVALID_ARGUMENT", "name is null", null)
            return
        }
        val desiredWidth = call.argument<Int>("width") ?: 1280
        val desiredHeight = call.argument<Int>("height") ?: 720

        val device = findDeviceByName(name)
        if (device == null) {
            result.error("DEVICE_NOT_FOUND", "未找到设备 $name", null)
            return
        }

        try {
            closeCameraInternal()

            val ctrlBlock = usbMonitor.openDevice(device)
            val camera = UVCCamera()
            try {
                camera.open(ctrlBlock)
            } catch (e: Exception) {
                camera.destroy()
                result.error("OPEN_FAILED", "打开摄像头失败: ${e.message}", null)
                return
            }

            val supportedSizes: List<Size> = camera.getSupportedSizeList()
            val size = pickBestSize(supportedSizes, desiredWidth, desiredHeight)
            if (size == null) {
                camera.close()
                camera.destroy()
                result.error("NO_SIZE", "摄像头不支持任何分辨率", null)
                return
            }

            var frameFormat: Int? = null
            for (candidate in listOf(UVCCamera.FRAME_FORMAT_MJPEG, UVCCamera.FRAME_FORMAT_YUYV)) {
                try {
                    camera.setPreviewSize(size.width, size.height, candidate)
                    frameFormat = candidate
                    break
                } catch (e: IllegalArgumentException) {
                    Log.w(TAG, "不支持帧格式: $candidate")
                }
            }
            if (frameFormat == null) {
                camera.close()
                camera.destroy()
                result.error("NO_FORMAT", "摄像头不支持 MJPEG/YUYV", null)
                return
            }

            val producer = textureRegistry.createSurfaceProducer()
            producer.setSize(size.width, size.height)
            producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {
                    Log.i(TAG, "surface available")
                }

                @Deprecated("Deprecated in Java")
                override fun onSurfaceDestroyed() {
                    Log.i(TAG, "surface destroyed")
                    handler.post {
                        closeCameraInternal()
                    }
                }
            })
            val surface = producer.getSurface()

            try {
                camera.setPreviewDisplay(surface)
                camera.startPreview()
            } catch (e: Exception) {
                camera.close()
                camera.destroy()
                producer.release()
                result.error("PREVIEW_FAILED", "启动预览失败: ${e.message}", null)
                return
            }

            this.camera = camera
            this.surfaceProducer = producer
            this.previewSurface = surface
            this.previewWidth = size.width
            this.previewHeight = size.height

            result.success(
                mapOf(
                    "textureId" to producer.id(),
                    "width" to size.width,
                    "height" to size.height,
                )
            )
        } catch (e: Exception) {
            Log.e(TAG, "open failed", e)
            result.error("OPEN_ERROR", "打开摄像头异常: ${e.message}", null)
        }
    }

    private fun pickBestSize(sizes: List<Size>, desiredWidth: Int, desiredHeight: Int): Size? {
        if (sizes.isEmpty()) return null
        val desiredArea = desiredWidth * desiredHeight
        val sorted = sizes.sortedBy { it.width * it.height }
        // 优先选 <= 期望面积的最大分辨率，否则选最小分辨率
        var best: Size? = null
        for (size in sorted) {
            val area = size.width * size.height
            if (area <= desiredArea) {
                best = size
            }
        }
        return best ?: sorted.first()
    }

    private fun startFrameStream(result: MethodChannel.Result) {
        val camera = camera
        if (camera == null) {
            result.error("NOT_OPENED", "摄像头未打开", null)
            return
        }
        streaming = true
        lastFrameSentAt = 0L
        try {
            camera.setFrameCallback({ frame -> onFrame(frame) }, UVCCamera.PIXEL_FORMAT_NV21)
            result.success(true)
        } catch (e: Exception) {
            streaming = false
            result.error("STREAM_FAILED", "启动帧流失败: ${e.message}", null)
        }
    }

    private fun onFrame(frame: ByteBuffer) {
        val now = System.currentTimeMillis()
        if (now - lastFrameSentAt < minFrameIntervalMs) return
        lastFrameSentAt = now
        if (!streaming || frameEventSink == null) return

        val width = previewWidth
        val height = previewHeight
        if (width <= 0 || height <= 0) return

        val bytes = ByteArray(frame.remaining())
        frame.get(bytes)
        executor.execute {
            val jpeg = nv21ToJpeg(bytes, width, height)
            if (jpeg != null) {
                handler.post { frameEventSink?.success(jpeg) }
            }
        }
    }

    private fun stopFrameStream(result: MethodChannel.Result) {
        try {
            camera?.setFrameCallback(null, 0)
        } catch (e: Exception) {
            Log.w(TAG, "停止帧流失败", e)
        }
        streaming = false
        result.success(true)
    }

    private fun takePicture(result: MethodChannel.Result) {
        val camera = camera
        if (camera == null) {
            result.error("NOT_OPENED", "摄像头未打开", null)
            return
        }
        val outputDir = activity.cacheDir
        val outputFile = File.createTempFile("PIC", ".jpg", outputDir)

        val wasStreaming = streaming
        try {
            camera.setFrameCallback({ frame ->
                val bytes = ByteArray(frame.remaining())
                frame.get(bytes)
                handler.post {
                    try {
                        camera.setFrameCallback(null, 0)
                        val saved = saveJpeg(bytes, outputFile)
                        if (saved) {
                            result.success(outputFile.absolutePath)
                        } else {
                            result.error("SAVE_FAILED", "保存照片失败", null)
                        }
                    } catch (e: Exception) {
                        result.error("PICTURE_ERROR", "拍照失败: ${e.message}", null)
                    } finally {
                        if (wasStreaming && camera != null) {
                            try {
                                camera.setFrameCallback({ f -> onFrame(f) }, UVCCamera.PIXEL_FORMAT_NV21)
                            } catch (e: Exception) {
                                Log.w(TAG, "恢复帧流失败", e)
                            }
                        }
                    }
                }
            }, UVCCamera.PIXEL_FORMAT_NV21)
        } catch (e: Exception) {
            result.error("PICTURE_ERROR", "设置拍照回调失败: ${e.message}", null)
        }
    }

    private fun saveJpeg(nv21: ByteArray, file: File): Boolean {
        return try {
            val yuv = YuvImage(nv21, ImageFormat.NV21, previewWidth, previewHeight, null)
            val out = ByteArrayOutputStream()
            yuv.compressToJpeg(Rect(0, 0, previewWidth, previewHeight), 90, out)
            FileOutputStream(file).use { it.write(out.toByteArray()) }
            true
        } catch (e: Exception) {
            Log.e(TAG, "save jpeg failed", e)
            false
        }
    }

    private fun nv21ToJpeg(nv21: ByteArray, width: Int, height: Int): ByteArray? {
        return try {
            val yuv = YuvImage(nv21, ImageFormat.NV21, width, height, null)
            val out = ByteArrayOutputStream()
            yuv.compressToJpeg(Rect(0, 0, width, height), 85, out)
            out.toByteArray()
        } catch (e: Exception) {
            Log.w(TAG, "NV21->JPEG 转换失败: ${e.message}")
            null
        }
    }

    private fun close(result: MethodChannel.Result) {
        closeCameraInternal()
        result.success(true)
    }

    private fun closeCameraInternal() {
        try {
            camera?.setFrameCallback(null, 0)
        } catch (e: Exception) {
            Log.w(TAG, "取消帧回调失败", e)
        }
        streaming = false
        try {
            camera?.stopPreview()
        } catch (e: Exception) {
            Log.w(TAG, "停止预览失败", e)
        }
        try {
            camera?.close()
        } catch (e: Exception) {
            Log.w(TAG, "关闭摄像头失败", e)
        }
        try {
            camera?.destroy()
        } catch (e: Exception) {
            Log.w(TAG, "销毁摄像头失败", e)
        }
        camera = null
        try {
            previewSurface?.release()
        } catch (e: Exception) {
            Log.w(TAG, "释放预览 Surface 失败", e)
        }
        previewSurface = null
        try {
            surfaceProducer?.setCallback(null)
        } catch (e: Exception) {
            Log.w(TAG, "取消纹理回调失败", e)
        }
        try {
            surfaceProducer?.release()
        } catch (e: Exception) {
            Log.w(TAG, "释放纹理失败", e)
        }
        surfaceProducer = null
        previewWidth = 0
        previewHeight = 0
    }

    private fun findDeviceByName(name: String): UsbDevice? {
        return usbMonitor.getDeviceList().firstOrNull {
            it.deviceName == name && isUvcCamera(it)
        }
    }

    fun dispose() {
        closeCameraInternal()
        try {
            usbMonitor.unregister()
        } catch (e: Exception) {
            Log.w(TAG, "注销 USB 监听失败", e)
        }
        try {
            usbMonitor.destroy()
        } catch (e: Exception) {
            Log.w(TAG, "销毁 USB 监听失败", e)
        }
        deviceEventSink = null
        frameEventSink = null
        pendingPermissionDevice = null
        pendingPermissionResult = null
        executor.shutdown()
    }
}
