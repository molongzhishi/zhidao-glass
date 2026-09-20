# zhidao_glass

Android 端离线多模态 AI 智能眼镜/导盲助手。支持蓝牙 SPP 雷达避障、摄像头视觉识别与语音交互（唤醒 / ASR / TTS / 离线大模型问答）。

## 功能特性

- **雷达 + 视觉融合避障**：蓝牙 SPP 接收雷达模块报警帧（`RADAR:OBSTACLE [LEFT|RIGHT|FRONT]` / `RADAR:CLEAR`，兼容中英文关键词），雷达触发后从摄像头取帧做 YOLO 识别，按"雷达方位 + 物品名"融合播报，不支持的方向退化为画面坐标五档映射。
- **摄像头双来源**：手机内置摄像头（携带场景）与外接 USB/UVC 摄像头（导盲杖场景），场景可切换，当前源故障时自动降级到备用源。
- **离线语音交互**：`sherpa-onnx` 端侧 ASR / TTS / VAD（`silero_vad.int8.onnx`），录音前用 PCM 噪声滤波与环形缓冲去噪。
- **离线大模型问答**：`flutter_gemma` / `sherpa-onnx` 端侧 LLM 推理，模型按需从 ModelScope 下载至应用私有目录（首次使用需联网）。
- **语音唤醒**：VAD 唤醒词检测（Qwen-ASR 模型按需下载）。
- **引导与状态页**：首次使用三步引导（蓝牙 / 摄像头 / 语音），状态页聚合雷达、视觉、播报三路实时状态。
- 聊天记录本地存储（`sqflite`）、图片分析（`image_picker`）、设置管理（`shared_preferences`）。

## 雷达与视觉融合规则

| 雷达 | 视觉 | 播报结果 |
|---|---|---|
| 有障碍物 + 方向 | 识别到目标 | `[雷达方位]有[物品名]`（如"前方左侧有行人"） |
| 有障碍物 | 无目标 | `[雷达方位]有障碍物` |
| 无障碍物 | 大目标（权重 > 30%） | 视觉独立播报（雷达失效兜底通道） |
| 无障碍物 | 小目标/无 | 不播报 |

方位优先级：雷达方向为主；雷达方向未知时退化为视觉目标中心 X 的五档映射（左 / 左前 / 正前 / 右前 / 右）。同一障碍物重复触发间隔 10s，同文案 700ms 去重。

## 目录结构

```
lib/
  services/  雷达协议、融合引擎、检测管线、摄像头源、语音、推理、唤醒、下载等服务
  ui/        聊天、设置、视觉、图像分析、引导、状态等界面
  ui/guide/  首次引导与状态页
android/
  app/src/main/kotlin/com/banai/zhidao_app/  原生插件（TTS、屏幕取帧、UVC 摄像头等）
test/        雷达/融合/方位/检测/摄像头/播报等单元与端到端测试
assets/models/  YOLO 检测模型与 VAD 模型（小模型随包）
```

## 技术栈

- Flutter / Dart（`>= 3.12`）
- 原生：sherpa-onnx（ASR/TTS/VAD）、LiteRT/`ultralytics_yolo`（视觉检测）、libuvc（UVC 摄像头，`org.uvccamera:0.0.13`）
- 蓝牙：`flutter_blue_plus`（SPP）
- 状态管理：`provider`

## 构建

要求：Flutter SDK、Android SDK（compileSdk 36）、NDK（arm64-v8a，服务于 sherpa-onnx 等原生库）。

```bash
flutter pub get
flutter build apk --release
```

> 说明：
> - 部分原生依赖（如 sqlite3 构建产物）经 `ghproxy.net` 下载，请确保构建网络可达（见 `pubspec.yaml` 的 `hooks` 配置）。
> - 当前 `release` 使用 debug 签名（`build.gradle.kts`），仅供测试安装；对外发布请配置正式 `key.properties`（已被 `.gitignore` 忽略）。
> - Windows 上若用户目录含非 ASCII 字符（如 `C:\Users\<中文用户名>`），Gradle/NDK 可能报路径错误。可用 `subst` 将缓存目录映射到 ASCII 虚拟盘后构建：

```powershell
$env:GRADLE_USER_HOME = 'G:\'; $env:PUB_CACHE = 'P:\'; $env:TEMP = 'T:\'
subst G: "$env:USERPROFILE\.gradle"
subst P: "$env:USERPROFILE\AppData\Local\Pub\Cache"
subst T: "$env:USERPROFILE\AppData\Local\Temp"
flutter build apk --release
subst G: /D; subst P: /D; subst T: /D
```

## 测试

```bash
flutter test
```

## 模型

- 随包小模型：`assets/models/yolo26n_w8a32.tflite`（视觉检测）、`assets/models/silero_vad.int8.onnx`（VAD）。
- 按需下载大模型：LLM / Qwen 大模型运行时从 ModelScope 下载至应用私有目录，不入库。

## 许可证

[GNU AGPL-3.0](./LICENSE) — 本应用链接了 AGPL-3.0 许可的 `ultralytics_yolo` 视觉检测组件，故整体按 AGPL-3.0 提供（含仓库内该组件的版权与许可提示）。

> 说明：运行时从 ModelScope 下载的大模型（LLM/Qwen 等）遵循各模型各自的许可协议，不随本仓库分发。