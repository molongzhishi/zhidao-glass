package com.banai.zhidao_app

import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.UUID

/**
 * Android 原生 TextToSpeech + 振动。
 * 语音播报模块的底层引擎：以 android.speech.tts.TextToSpeech 驱动中文（zh-CN）合成，
 * 通过 UtteranceProgressListener 把"开始/完成/错误/停止"事件推送给 Dart；
 * 提供 restart 以在初始化失败后重启 TTS 引擎，提供 vibrate 作为播报不可用时的振动回退。
 */
class AndroidTtsPlugin(
    private val context: Context,
    private val messenger: BinaryMessenger,
) {
    companion object {
        private const val TAG = "AndroidTtsPlugin"
        const val CHANNEL = "com.banai.zhidao_app/android_tts"
        const val EVENTS = "com.banai.zhidao_app/android_tts/events"
        const val DEFAULT_LANGUAGE = "zh-CN"
    }

    private val handler = Handler(Looper.getMainLooper())

    private var tts: TextToSpeech? = null

    @Volatile
    private var ready = false

    @Volatile
    private var speaking = false

    private var eventSink: EventChannel.EventSink? = null

    fun register() {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> initializeTts(call, result)
                "restart" -> restart(call, result)
                "speak" -> speak(call, result)
                "stop" -> stop(result)
                "isReady" -> result.success(ready)
                "vibrate" -> vibrate(call, result)
                else -> result.notImplemented()
            }
        }

        EventChannel(messenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                eventSink = sink
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    private fun initializeTts(call: MethodCall, result: MethodChannel.Result) {
        val language = call.argument<String>("language") ?: DEFAULT_LANGUAGE
        initEngine(language) { ok, message ->
            if (ok) {
                result.success(mapOf("available" to true, "ready" to true))
            } else {
                result.error("TTS_INIT_FAILED", message ?: "Android TTS 初始化失败", null)
            }
        }
    }

    private fun restart(call: MethodCall, result: MethodChannel.Result) {
        val language = call.argument<String>("language") ?: DEFAULT_LANGUAGE
        shutdownEngine()
        initEngine(language) { ok, message ->
            if (ok) {
                result.success(mapOf("available" to true, "ready" to true))
            } else {
                result.error("TTS_INIT_FAILED", message ?: "Android TTS 重启失败", null)
            }
        }
    }

    /** 创建并初始化 TextToSpeech 引擎；回调在主线程执行 */
    private fun initEngine(language: String, onComplete: (Boolean, String?) -> Unit) {
        lateinit var instance: TextToSpeech
        try {
            instance = TextToSpeech(
                context.applicationContext,
                TextToSpeech.OnInitListener { status ->
                    handler.post {
                        when (status) {
                            TextToSpeech.SUCCESS -> {
                                try {
                                    val locale = when {
                                        language.equals("zh-CN", ignoreCase = true) ->
                                            Locale.SIMPLIFIED_CHINESE
                                        else -> Locale.CHINESE
                                    }
                                    val availability = instance.isLanguageAvailable(locale)
                                    if (availability < TextToSpeech.LANG_AVAILABLE) {
                                        instance.setLanguage(Locale.CHINESE)
                                    } else {
                                        instance.setLanguage(locale)
                                    }
                                    instance.setOnUtteranceProgressListener(
                                        object : UtteranceProgressListener() {
                                            override fun onStart(utteranceId: String?) {
                                                speaking = true
                                                emitEvent("utterance_start", utteranceId)
                                            }

                                            override fun onDone(utteranceId: String?) {
                                                speaking = false
                                                emitEvent("utterance_done", utteranceId)
                                            }

                                            override fun onStop(utteranceId: String?, interrupt: Boolean) {
                                                speaking = false
                                                emitEvent("utterance_stopped", utteranceId)
                                            }

                                            override fun onError(utteranceId: String?) {
                                                speaking = false
                                                emitEvent("utterance_error", utteranceId)
                                            }

                                            override fun onError(utteranceId: String?, errorCode: Int) {
                                                speaking = false
                                                emitEvent("utterance_error", utteranceId)
                                            }
                                        }
                                    )
                                    tts = instance
                                    ready = true
                                    Log.i(TAG, "Android TTS 就绪 (locale=${instance.language})")
                                    onComplete(true, null)
                                } catch (e: Exception) {
                                    try {
                                        instance.shutdown()
                                    } catch (ignored: Exception) {
                                        // 忽略
                                    }
                                    Log.e(TAG, "配置 TTS 失败", e)
                                    onComplete(false, e.message)
                                }
                            }
                            else -> {
                                try {
                                    instance.shutdown()
                                } catch (ignored: Exception) {
                                    // 忽略
                                }
                                Log.e(TAG, "Android TTS 初始化失败, status=$status")
                                onComplete(false, "Android TTS 初始化失败, status=$status")
                            }
                        }
                    }
                },
            )
        } catch (e: Exception) {
            Log.e(TAG, "创建 TextToSpeech 异常", e)
            onComplete(false, e.message)
        }
    }

    private fun speak(call: MethodCall, result: MethodChannel.Result) {
        val engine = tts
        if (engine == null || !ready) {
            result.error("TTS_NOT_READY", "TTS 尚未就绪", null)
            return
        }
        val text = call.argument<String>("text")
        if (text.isNullOrEmpty()) {
            result.error("INVALID_ARGUMENT", "text is null or empty", null)
            return
        }
        val utteranceId = UUID.randomUUID().toString()
        val bundle = Bundle().apply {
            putString(TextToSpeech.Engine.KEY_PARAM_UTTERANCE_ID, utteranceId)
        }
        val status: Int = engine.speak(text, TextToSpeech.QUEUE_FLUSH, bundle, utteranceId)
        result.success(status == TextToSpeech.SUCCESS)
    }

    private fun stop(result: MethodChannel.Result) {
        try {
            tts?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "stop 失败", e)
        }
        speaking = false
        result.success(true)
    }

    private fun vibrate(call: MethodCall, result: MethodChannel.Result) {
        val duration = (call.argument<Number>("duration")?.toLong() ?: 300L).coerceIn(50L, 10_000L)
        vibrateInternal(duration)
        result.success(true)
    }

    private fun vibrateInternal(durationMillis: Long) {
        try {
            val vibrator: Vibrator =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val manager =
                        context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                    manager.defaultVibrator
                } else {
                    @Suppress("DEPRECATION")
                    context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (vibrator.hasVibrator()) {
                    vibrator.vibrate(
                        VibrationEffect.createOneShot(durationMillis, VibrationEffect.DEFAULT_AMPLITUDE)
                    )
                }
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(durationMillis)
            }
        } catch (e: Exception) {
            Log.w(TAG, "振动失败", e)
        }
    }

    private fun emitEvent(type: String, utteranceId: String?) {
        val sink = eventSink ?: return
        val event = mapOf("event" to type, "id" to (utteranceId ?: ""))
        handler.post { sink.success(event) }
    }

    private fun shutdownEngine() {
        ready = false
        speaking = false
        try {
            tts?.shutdown()
        } catch (e: Exception) {
            Log.w(TAG, "shutdown 失败", e)
        }
        tts = null
    }

    fun dispose() {
        shutdownEngine()
        eventSink = null
    }
}