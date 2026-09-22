package com.banai.zhidao_app

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.IOException
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.security.KeyStore
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.banai.zhidao_app/bluetooth"
    // 经典蓝牙扫描结果与 SPP 接收数据使用独立事件通道，避免单一 Sink 多路复用职责混乱
    private val SCAN_EVENT_CHANNEL = "com.banai.zhidao_app/bluetooth/scan_events"
    private val SPP_EVENT_CHANNEL = "com.banai.zhidao_app/bluetooth/spp_events"

    private var uvcCameraPlugin: UvcCameraPlugin? = null
    private var androidTtsPlugin: AndroidTtsPlugin? = null
    private var screenCapturePlugin: ScreenCapturePlugin? = null

    // 经典蓝牙 SPP
    private var bluetoothSocket: BluetoothSocket? = null
    private var outputStream: OutputStream? = null
    private var inputStream: InputStream? = null

    // 雷达/串口数据读取线程
    private var sppReadThread: Thread? = null
    private val sppReadRunning = AtomicBoolean(false)
    private val sppUuid: UUID = UUID.fromString("00001101-0000-1000-8000-00805f9b34fb")
    private val handler = Handler(Looper.getMainLooper())

    // 经典蓝牙扫描
    private var discoveryReceiver: BroadcastReceiver? = null
    private var scanEventSink: EventChannel.EventSink? = null
    private var sppEventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // MethodChannel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getBondedDevices" -> {
                        try {
                            val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
                            val bluetoothAdapter = bluetoothManager.adapter

                            if (bluetoothAdapter == null) {
                                result.success(emptyList<Map<String, String>>())
                                return@setMethodCallHandler
                            }

                            val bondedDevices = bluetoothAdapter.bondedDevices
                            val deviceList = bondedDevices.map { device ->
                                mapOf(
                                    "address" to device.address,
                                    "name" to (device.name ?: "")
                                )
                            }

                            result.success(deviceList)
                        } catch (e: Exception) {
                            result.error("BLUETOOTH_ERROR", e.message, null)
                        }
                    }
                    "startClassicScan" -> {
                        startClassicScan(result)
                    }
                    "stopClassicScan" -> {
                        stopClassicScan(result)
                    }
                    "connectSpp" -> {
                        val address = call.argument<String>("address")
                        if (address == null) {
                            result.error("INVALID_ARGUMENT", "address is null", null)
                            return@setMethodCallHandler
                        }
                        val password = call.argument<String>("password")
                        connectSpp(address, password, result)
                    }
                    "sendSppData" -> {
                        val data = call.argument<String>("data")
                        if (data == null) {
                            result.error("INVALID_ARGUMENT", "data is null", null)
                            return@setMethodCallHandler
                        }
                        sendSppData(data, result)
                    }
                    "disconnectSpp" -> {
                        disconnectSpp(result)
                    }
                    "saveSppPassword" -> {
                        val password = call.argument<String>("password") ?: ""
                        result.success(saveSppPassword(password))
                    }
                    "getSppPassword" -> {
                        // 未配置时返回空串（Dart 侧再按需回退旧明文存储）
                        result.success(getSppPassword())
                    }
                    "isSppConnected" -> {
                        result.success(bluetoothSocket?.isConnected == true)
                    }
                    else -> {
                        result.notImplemented()
                    }
                }
            }

        // EventChannel - 经典蓝牙扫描结果
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SCAN_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    scanEventSink = sink
                }
                override fun onCancel(arguments: Any?) {
                    scanEventSink = null
                }
            })

        // EventChannel - SPP 接收数据（雷达/串口回传）
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, SPP_EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    sppEventSink = sink
                }
                override fun onCancel(arguments: Any?) {
                    sppEventSink = null
                }
            })

        // USB UVC 摄像头（libuvc 原生方案）
        uvcCameraPlugin = UvcCameraPlugin(flutterEngine, this).also { it.register() }

        // 语音播报：Android 原生 TextToSpeech + 振动
        androidTtsPlugin =
            AndroidTtsPlugin(this, flutterEngine.dartExecutor.binaryMessenger).also { it.register() }

        // 截屏监控：MediaProjection 屏幕捕获
        screenCapturePlugin = ScreenCapturePlugin(flutterEngine, this).also { it.register() }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // 截屏授权结果转发给 ScreenCapturePlugin
        val consumed = screenCapturePlugin?.onActivityResult(requestCode, resultCode, data) == true
        if (!consumed) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    /// 开始经典蓝牙扫描
        private fun startClassicScan(result: MethodChannel.Result) {
        try {
            val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            val bluetoothAdapter = bluetoothManager.adapter

            if (bluetoothAdapter == null) {
                result.error("BLUETOOTH_ERROR", "蓝牙适配器不可用", null)
                return
            }

            if (!bluetoothAdapter.isEnabled) {
                result.error("BLUETOOTH_DISABLED", "蓝牙未开启", null)
                return
            }

            // 取消之前的扫描
            bluetoothAdapter.cancelDiscovery()

            // 注册广播接收器
            discoveryReceiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    when (intent?.action) {
                        BluetoothDevice.ACTION_FOUND -> {
                            val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                            val rssi = intent.getShortExtra(BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE).toInt()
                            if (device != null) {
                                val deviceInfo = mapOf(
                                    "address" to device.address,
                                    "name" to (device.name ?: ""),
                                    "rssi" to rssi,
                                    "type" to "classic"
                                )
                                handler.post {
                                    scanEventSink?.success(deviceInfo)
                                }
                            }
                        }
                        BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> {
                            handler.post {
                                scanEventSink?.success(mapOf("action" to "scan_finished"))
                            }
                        }
                    }
                }
            }

            val filter = IntentFilter().apply {
                addAction(BluetoothDevice.ACTION_FOUND)
                addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
            }
            registerReceiver(discoveryReceiver, filter)

            // 开始扫描
            val started = bluetoothAdapter.startDiscovery()
            if (started) {
                result.success(true)
            } else {
                result.error("SCAN_FAILED", "无法启动扫描", null)
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", "缺少蓝牙权限: ${e.message}", null)
        } catch (e: Exception) {
            result.error("SCAN_ERROR", "扫描异常: ${e.message}", null)
        }
    }

    /// 停止经典蓝牙扫描
    private fun stopClassicScan(result: MethodChannel.Result) {
        try {
            val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
            val bluetoothAdapter = bluetoothManager.adapter
            bluetoothAdapter?.cancelDiscovery()

            discoveryReceiver?.let {
                try {
                    unregisterReceiver(it)
                } catch (e: Exception) {
                    // 忽略
                }
                discoveryReceiver = null
            }
            result.success(true)
        } catch (e: Exception) {
            result.error("SCAN_ERROR", "停止扫描失败: ${e.message}", null)
        }
    }

    /// 连接经典蓝牙 SPP 设备
    /// 密码由用户在设置中配置后随调用传入，不做任何硬编码
    private fun connectSpp(address: String, password: String?, result: MethodChannel.Result) {
        Thread {
            try {
                val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
                val bluetoothAdapter = bluetoothManager.adapter

                if (bluetoothAdapter == null) {
                    handler.post { result.error("BLUETOOTH_ERROR", "蓝牙适配器不可用", null) }
                    return@Thread
                }

                if (password.isNullOrBlank()) {
                    handler.post { result.error("PASSWORD_NOT_SET", "未设置蓝牙连接密码，请在设置中配置", null) }
                    return@Thread
                }

                // 取消扫描
                bluetoothAdapter.cancelDiscovery()

                val device: BluetoothDevice? = bluetoothAdapter.getRemoteDevice(address)
                if (device == null) {
                    handler.post { result.error("DEVICE_NOT_FOUND", "未找到设备 $address", null) }
                    return@Thread
                }

                // 先断开旧连接
                disconnectSppInternal()

                // 创建 RFCOMM Socket
                bluetoothSocket = device.createRfcommSocketToServiceRecord(sppUuid)

                // 连接（阻塞操作，需在子线程执行）
                bluetoothSocket?.connect()

                outputStream = bluetoothSocket?.outputStream
                inputStream = bluetoothSocket?.inputStream

                // 发送密码验证（自动补换行，兼容 ESP32-CAM 逐行读取）
                val normalized = password.trim() + "\n"
                val passwordBytes = normalized.toByteArray(Charsets.UTF_8)
                outputStream?.write(passwordBytes)
                outputStream?.flush()

                // 等待验证响应
                Thread.sleep(500)

                // 启动输入流读取线程（雷达报警/串口数据回传）
                startSppReadThread()

                handler.post {
                    result.success(true)
                }
            } catch (e: IOException) {
                handler.post {
                    result.error("CONNECT_FAILED", "连接失败: ${e.message}", null)
                }
                disconnectSppInternal()
            } catch (e: Exception) {
                handler.post {
                    result.error("CONNECT_ERROR", "连接异常: ${e.message}", null)
                }
                disconnectSppInternal()
            }
        }.start()
    }

    /// 发送数据到 SPP 设备
    private fun sendSppData(data: String, result: MethodChannel.Result) {
        try {
            if (outputStream == null || bluetoothSocket?.isConnected != true) {
                result.error("NOT_CONNECTED", "SPP未连接", null)
                return
            }

            val bytes = data.toByteArray(Charsets.UTF_8)
            outputStream?.write(bytes)
            outputStream?.flush()

            result.success(true)
        } catch (e: IOException) {
            result.error("SEND_FAILED", "发送失败 ${e.message}", null)
            disconnectSppInternal()
        } catch (e: Exception) {
            result.error("SEND_ERROR", "发送异常 ${e.message}", null)
        }
    }

    /// 断开 SPP 连接
    private fun disconnectSpp(result: MethodChannel.Result) {
        disconnectSppInternal()
        result.success(true)
    }

    // ── SPP 密码安全存储（Android Keystore AES-GCM 加密）───────────
    // 明文密码只在内存中（Dart 侧读取后传入 connectSpp）；落盘为
    // base64(iv + ciphertext)，密钥由操作系统 Keystore 保管，不落入 SharedPreferences。
    private val sppSecretAlias = "zhidao_spp_password_key"
    private val securePrefsName = "zhidao_secure"

    private fun saveSppPassword(password: String): Boolean {
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateSppSecretKey())
            val ct = cipher.doFinal(password.trim().toByteArray(Charsets.UTF_8))
            val blob = cipher.iv + ct
            getSharedPreferences(securePrefsName, Context.MODE_PRIVATE)
                .edit()
                .putString("spp_password", Base64.encodeToString(blob, Base64.NO_WRAP))
                .commit()
        } catch (e: Exception) {
            debugLog("保存 SPP 密码失败（Keystore）: ${e.message}")
            false
        }
    }

    /// 读取 SPP 密码；解密失败/未配置返回空串（由 Dart 侧回退旧明文）
    private fun getSppPassword(): String {
        val raw = getSharedPreferences(securePrefsName, Context.MODE_PRIVATE)
            .getString("spp_password", null) ?: return ""
        return try {
            val blob = Base64.decode(raw, Base64.NO_WRAP)
            if (blob.size <= 12) return ""
            val iv = blob.copyOfRange(0, 12)
            val ct = blob.copyOfRange(12, blob.size)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                getOrCreateSppSecretKey(),
                GCMParameterSpec(128, iv)
            )
            String(cipher.doFinal(ct), Charsets.UTF_8)
        } catch (e: Exception) {
            debugLog("读取 SPP 密码失败（Keystore 解密）: ${e.message}")
            ""
        }
    }

    /// 获取或创建 Keystore 中的 AES-256 密钥（GCM 模式）
    private fun getOrCreateSppSecretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(sppSecretAlias, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                sppSecretAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    /// 启动 SPP 输入流读取线程，逐行推送雷达数据到 Flutter
    ///
    /// 保持阻塞式 [BufferedReader.readLine]：EOF 与 IOException 是检测
    /// 对端关闭/链路断链的最可靠信号（蓝牙 ACL 链路丢失会在几十秒内
    /// 使阻塞读抛 IOException）。半开链路（链路上层存活但固件停止发送）
    /// 无法在传输层探测，由 Dart 侧"已连接但无数据"健康检测兜底呈现。
    private fun startSppReadThread() {
        stopSppReadThread()
        if (bluetoothSocket?.isConnected != true) return

        sppReadRunning.set(true)
        sppReadThread = Thread {
            try {
                val socket = bluetoothSocket ?: return@Thread
                val reader = BufferedReader(InputStreamReader(socket.inputStream, Charsets.UTF_8))
                var unexpectedEnd = false
                while (sppReadRunning.get()) {
                    val line = reader.readLine() ?: run {
                        unexpectedEnd = true
                        break
                    }
                    if (line.isEmpty()) continue
                    handler.post {
                        sppEventSink?.success(
                            mapOf(
                                "action" to "spp_data",
                                "data" to line
                            )
                        )
                    }
                }
                // 对端关闭或 EOF，非用户主动停止 → 通知 Flutter 断连
                if (unexpectedEnd && sppReadRunning.get()) {
                    notifySppDisconnected()
                }
            } catch (e: IOException) {
                debugLog("SPP 读取结束: ${e.message}")
                if (sppReadRunning.get()) {
                    notifySppDisconnected()
                }
            } catch (e: Exception) {
                // 忽略
            } finally {
                sppReadRunning.set(false)
            }
        }.apply { isDaemon = true }
        sppReadThread?.start()
    }

    private fun notifySppDisconnected() {
        handler.post {
            sppEventSink?.success(
                mapOf("action" to "spp_disconnected")
            )
        }
    }

private fun stopSppReadThread() {
    // readLine() 不响应 interrupt：真正解除阻塞靠上层随后关闭 socket
    // （disconnectSppInternal），届时抛 IOException 退出读取循环；
    // 此处 interrupt 仅作标记，线程退出后置空引用。
    sppReadRunning.set(false)
    sppReadThread?.interrupt()
    sppReadThread = null
}

    private fun debugLog(message: String) {
        android.util.Log.d("MainActivity", message)
    }

    /// 内部断开方法
    private fun disconnectSppInternal() {
        stopSppReadThread()
        try {
            inputStream?.close()
            inputStream = null
        } catch (e: Exception) {
            // 忽略
        }
        try {
            outputStream?.close()
            outputStream = null
        } catch (e: Exception) {
            // 忽略
        }
        try {
            bluetoothSocket?.close()
            bluetoothSocket = null
        } catch (e: Exception) {
            // 忽略
        }
    }

    override fun onDestroy() {
        try {
            uvcCameraPlugin?.dispose()
            uvcCameraPlugin = null
        } catch (e: Exception) {
            // 忽略
        }
        try {
            androidTtsPlugin?.dispose()
            androidTtsPlugin = null
        } catch (e: Exception) {
            // 忽略
        }
        try {
            screenCapturePlugin?.dispose()
            screenCapturePlugin = null
        } catch (e: Exception) {
            // 忽略
        }
        try {
            stopClassicScan(object : MethodChannel.Result {
                override fun success(result: Any?) {}
                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
                override fun notImplemented() {}
            })
        } catch (e: Exception) {
            // 忽略
        }
        disconnectSppInternal()
        super.onDestroy()
    }
}
