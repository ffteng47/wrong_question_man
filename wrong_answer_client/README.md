# 错题本 Flutter 客户端

## 项目结构

```
lib/
├── main.dart                    # 入口
├── utils/
│   ├── theme.dart               # 颜色、主题、常量（AppConst.baseUrl 在这里改）
│   └── db_helper.dart           # SQLite 本地存储
├── api/
│   └── api_client.dart          # Dio HTTP 客户端
├── models/
│   └── wrong_answer_record.dart # 数据模型（对应服务端 schema）
├── widgets/
│   ├── roi_selector.dart        # 核心：图片上手指框选 ROI
│   ├── math_markdown.dart       # Markdown + LaTeX 渲染
│   └── record_card.dart         # 列表卡片
└── screens/
    ├── home_screen.dart         # 首页（列表 + 统计 + 筛选）
    ├── capture_screen.dart      # 拍照/上传/ROI 选取
    ├── preview_screen.dart      # AI 提取结果预览 + 编辑
    ├── detail_screen.dart       # 已保存记录详情
    └── settings_screen.dart     # 设置（服务器地址 + 健康检查）
```

---

## 快速开始（VSCode）

### 1. 环境准备

```bash
# 确认 Flutter 版本 >= 3.22
flutter --version

# 安装依赖
flutter pub get
```

### 2. 配置服务器地址

打开 `lib/utils/theme.dart`，修改：

```dart
static const baseUrl = 'http://192.168.x.x:9000'; // ← 改成你的服务端 IP
```

> 手机和电脑必须在同一 Wi-Fi 局域网下。
> 用 `ip addr` 或 `ipconfig` 查看服务端 IP。

### 3. Android 权限文件

将 `android_manifest.xml` 内容覆盖到：
```
android/app/src/main/AndroidManifest.xml
```

将 `file_paths.xml` 复制到：
```
android/app/src/main/res/xml/file_paths.xml
```
（如果 res/xml 目录不存在，先创建）

### 4. 运行

```bash
# 连接 Android 手机（开启开发者模式 + USB 调试）
flutter devices

# 运行
flutter run

# 或在 VSCode 中按 F5
```

---

## 完整使用流程

```
启动 App
    ↓
首页（查看已有错题 / 统计）
    ↓
点击「添加错题」
    ↓
选择拍照 / 相册
    ↓
[自动] 上传图片 → 服务端 Stage1: MinerU OCR
    ↓
图片上手指划框选取错题区域
    ↓
点击「确认选区」
    ↓
[自动] 服务端 Stage2: Qwen2.5-VL 语义分析（约 5-15s）
    ↓
预览 AI 提取结果（题目 / 分析 / 信息三个 Tab）
    ↓
可编辑科目、年级、难度、复习状态等字段
    ↓
点击「保存」
    ↓
同步服务端 + 本地 SQLite
    ↓
返回首页，列表自动刷新
```

---

## 关键包说明

| 包 | 用途 |
|---|---|
| `dio` | HTTP 客户端，上传图片、调用 API |
| `sqflite` | 本地 SQLite，离线存储 |
| `image_picker` | 调用系统相机/相册 |
| `flutter_markdown` | 渲染 problem/answer/solution Markdown |
| `flutter_math_fork` | 渲染 `$LaTeX$` 公式 |
| `cached_network_image` | 缓存服务端返回的裁切图片 |
| `shimmer` | 加载骨架屏效果 |

---

## 常见问题

**Q: 连接失败 / 请求超时**
- 确认手机和电脑在同一 Wi-Fi
- 确认 FastAPI 用 `--host 0.0.0.0`（不能是 127.0.0.1）
- Android 9+ 默认禁止明文 HTTP，已在 manifest 加 `usesCleartextTraffic="true"`

**Q: 图片上传成功但提取失败**
- 检查服务端日志：`tail -f logs/mineru.log`
- 查看 `/health` 接口确认 MinerU 状态

**Q: LaTeX 公式显示异常**
- `flutter_math_fork` 不支持所有 LaTeX 命令
- 有 fallback：显示原始 LaTeX 文本（紫色等宽字体）

**Q: ROI 坐标偏移**
- `roi_selector.dart` 的坐标换算依赖 `BoxFit.contain`
- 确保 `imageWidthPx/imageHeightPx` 是服务端返回的原图尺寸（不是压缩后的）
