# wrong_answer_client × semecTeaching 集成开发文档

> 文档版本: v1.0  
> 创建日期: 2026-04-26  
> 涉及分支: `dev/temp-20250425-wrong-question-man-integration`

---

## 1. 项目概述

### 1.1 背景
`wrong_answer_client`（Flutter OCR 错题本）原本是一个纯本地 AI 驱动的错题管理工具，使用 FastAPI 中间层（端口 9000）进行 OCR 识别和题目解析。本次集成将其扩展为可与 `semecTeaching` 智慧教育平台（Node.js + Express，端口 3000）互通，实现：

- **图片上传**：Flutter 拍摄的错题图片上传到 semecTeaching 服务器
- **错题同步**：本地识别的错题记录保存到 semecTeaching 的 `incorrect_question` 表
- **统一题库**：学生可在 semecTeaching Web 端查看从纸质试卷录入的错题

### 1.2 架构概览

```
┌─────────────────────┐         ┌─────────────────────────────┐
│  wrong_answer_client │         │      semecTeaching          │
│  (Flutter App)       │         │  (Node.js + Express)        │
│                      │         │                             │
│  ┌───────────────┐   │  HTTP   │  ┌─────────────────────┐   │
│  │ SemecTeaching │◄──┼─────────┼─►│ POST /api/auth/login │   │
│  │ Api (Dio)     │   │         │  │ GET /auth/csrf-init  │   │
│  └───────────────┘   │         │  │ POST /upload/image   │   │
│         │            │         │  │ POST /incorrect/...  │   │
│  ┌───────────────┐   │         │  └─────────────────────┘   │
│  │ SyncService   │   │         │           │                │
│  └───────────────┘   │         │           ▼                │
│         │            │         │  ┌─────────────────────┐   │
│  ┌───────────────┐   │         │  │   MySQL 8.0         │   │
│  │ SQLite (本地)  │   │         │  │   incorrect_question│   │
│  └───────────────┘   │         │  └─────────────────────┘   │
└─────────────────────┘         └─────────────────────────────┘
```

### 1.3 技术栈
| 层级 | 技术 |
|------|------|
| Flutter 客户端 | Flutter 3.41 + Dart 3.11 + Dio 5.4 |
| 安全存储 | `flutter_secure_storage` 9.2 |
| semecTeaching 后端 | Node.js + Express + MySQL 8.0 |
| 认证机制 | JWT Cookie + CSRF Double-Submit Cookie |
| 文件上传 | `multer` (磁盘存储) |

---

## 2. 后端变更 (semecTeaching)

### 2.1 数据库变更

**迁移文件**: `exam-server/database/migrations/014-wrong-question-man-support.sql`

```sql
-- 扩展 incorrect_question 表支持纸质错题
ALTER TABLE incorrect_question 
  MODIFY question_id BIGINT NOT NULL DEFAULT 0 COMMENT '题目ID, 0表示纸质错题',
  MODIFY source_type ENUM('exam','homework','practice','wrong_question_man') DEFAULT 'exam';

-- 新增字段存储题目内容（因为纸质错题无法 JOIN paper_items）
ALTER TABLE incorrect_question 
  ADD COLUMN question_content TEXT COMMENT '题目内容(Markdown)',
  ADD COLUMN question_answer TEXT COMMENT '正确答案',
  ADD COLUMN question_solution TEXT COMMENT '详细解析',
  ADD COLUMN question_images JSON COMMENT '题目图片URL列表';

-- 移除唯一约束（纸质错题 question_id=0 会冲突）
DROP INDEX IF EXISTS uk_user_incorrect ON incorrect_question;

-- 创建普通索引
CREATE INDEX idx_user_paper_incorrect ON incorrect_question(user_id, question_id);
```

**设计决策**: 选择扩展 `incorrect_question` 表（Option A），而非创建 `question_bank` 记录。原因：
- 避免将非标准纸质题目污染正式题库
- 保持纸质错题与系统错题的数据隔离
- 查询时通过 `COALESCE(pi.question_snapshot_content, iq.question_content)` 兼容两种来源

### 2.2 新增文件

#### `exam-server/utils/knowledgeValidator.js`
验证知识点名称是否存在于 `knowledge_detail` 表，过滤非法知识点。

```javascript
async function validateKnowledgePoints(knowledgePointNames) {
    const placeholders = knowledgePointNames.map(() => '?').join(',');
    const [rows] = await pool.execute(
        `SELECT knowledge_point_name FROM knowledge_detail WHERE knowledge_point_name IN (${placeholders})`,
        knowledgePointNames
    );
    return rows.map(r => r.knowledge_point_name);
}
```

#### `exam-server/routes/uploadRoutes.js`
图片上传端点，供 Flutter 调用。

| 属性 | 值 |
|------|-----|
| 路径 | `POST /api/upload/image` |
| 权限 | `requireRole(['admin','teacher','student'])` |
| CSRF | 需要 (`csrfMiddleware`) |
| 存储 | `exam-client/public/static/images/` |
| 限制 | 5MB, jpg/png/gif/webp |
| 返回 | `{ code: 0, data: { url, filename, size } }` |

### 2.3 修改文件

#### `exam-server/services/incorrectService.js`

**新增方法** `createFromWrongQuestionMan(data)`:
- `question_id` 固定为 0（标识纸质错题）
- `source_type` 为 `'wrong_question_man'`
- 难度映射：`1-5` → `'1星'-'5星'`
- 验证知识点名称
- 将错题内容直接写入新字段

**修改查询** `getStudentIncorrectQuestions()`:
```sql
SELECT 
    iq.*,
    COALESCE(pi.question_snapshot_content, iq.question_content) as question_content,
    COALESCE(pi.question_snapshot_answer, iq.question_answer) as correct_answer,
    COALESCE(pi.question_snapshot_solution, iq.question_solution) as solution
FROM incorrect_question iq
LEFT JOIN paper_items pi ON iq.question_id = pi.question_id AND iq.paper_id = pi.paper_id
```

#### `exam-server/controller/incorrectController.js`

**新增方法** `saveFromWrongQuestionMan(req, res)`:
- 参数校验：`user_id`, `subject`, `problem` 必填
- **身份验证**：`req.user.id === parseInt(user_id)`，防止学生操作他人数据
- 返回格式：`{ code: 0, success: true, data: { incorrect_id } }`

#### `exam-server/routes/incorrectRoutes.js`

新增路由：
```javascript
router.post('/from-wrong-question-man', csrfMiddleware, controller.saveFromWrongQuestionMan);
```

#### `exam-server/routes/index.js`

注册上传路由：
```javascript
const uploadRoutes = require('./uploadRoutes');
router.use('/upload', uploadRoutes);
```

---

## 3. Flutter 客户端实现

### 3.1 新增依赖

**`pubspec.yaml`**:
```yaml
dependencies:
  flutter_secure_storage: ^9.2.2  # 安全存储 JWT/CSRF Token
```

### 3.2 新增文件

#### `lib/api/semec_teaching_api.dart`

与 semecTeaching 后端通信的核心 API 客户端。

**类**: `SemecTeachingApi`（单例模式）

| 方法 | 说明 |
|------|------|
| `setBaseUrl(url)` | 配置服务器地址（默认 `http://192.168.41.138:3000`） |
| `login(username, password)` | 登录获取 JWT + CSRF Token |
| `logout()` | 清除所有 Token |
| `uploadImage(File)` | 上传图片到 `/api/upload/image` |
| `saveIncorrectQuestion(...)` | 保存错题到 `/api/incorrect/from-wrong-question-man` |
| `isLoggedIn` (getter) | 检查是否持有有效 Token |
| `currentUser` (getter) | 获取当前登录用户信息 |

**Token 管理**:
- 使用 `FlutterSecureStorage` 加密持久化存储
- 存储键：`semec_access_token`, `semec_csrf_token`, `semec_user_json`
- 应用启动时自动从 SecureStorage 恢复 Token
- 请求拦截器自动附加 `x-xsrf-token` Header

**JWT 解析** (Base64URL decode):
```dart
SemecUser? _parseJwt(String token) {
    final parts = token.split('.');
    final payload = utf8.decode(base64Url.decode(normalize(parts[1])));
    return SemecUser.fromJson(jsonDecode(payload));
}
```

**模型**:
```dart
class SemecUser {
    final int id;
    final String username;
    final String role;
    final String realName;
}

class SemecLoginResult { bool success; String? message; SemecUser? user; }
class SemecUploadResult { bool success; String? url; String? filename; String? error; }
class SemecSaveResult { bool success; int? incorrectId; String? error; }
```

#### `lib/services/sync_service.dart`

同步服务层，协调图片上传和错题保存。

**类**: `SyncService`（单例模式）

| 方法 | 说明 |
|------|------|
| `isLoggedIn` (getter) | 委托给 `SemecTeachingApi` |
| `currentUser` (getter) | 委托给 `SemecTeachingApi` |
| `syncRecord(WrongAnswerRecord)` | 单条记录同步（上传图片 → 保存错题） |
| `syncBatch(List<WrongAnswerRecord>)` | 批量同步（扩展用） |

**同步流程**:
```
1. 检查登录状态 → 未登录返回错误
2. 遍历 record.assets，上传图片到 /api/upload/image
   - 单张失败不影响整体
   - 收集成功上传的 URL 列表
3. 调用 /api/incorrect/from-wrong-question-man 保存错题
4. 返回 SyncResult { success, incorrectId, error, uploadedImages }
```

**字段映射** (`WrongAnswerRecord` → semecTeaching API):

| WrongAnswerRecord | semecTeaching API |
|-------------------|-------------------|
| `subject` | `subject` |
| `grade` | `grade` |
| `problem` | `problem` |
| `answer` | `answer` |
| `solution` | `solution` |
| `errorAnalysis.studentAnswer` | `student_answer` |
| `errorAnalysis.errorCategory` | `error_category` |
| `errorAnalysis.errorDesc` | `error_desc` |
| `knowledgePoints` | `knowledge_points` |
| `difficulty` (1-5) | `difficulty` (1-5) |
| `realScore` | `real_score` |
| `assets` (本地文件) | 上传后 → `images` (URL 列表) |

### 3.3 修改文件

#### `lib/screens/settings_screen.dart`

新增 **semecTeaching 云端同步** 配置区域：

```
┌─────────────────────────────────────┐
│ semecTeaching 云端同步 [已登录: 张三] │
├─────────────────────────────────────┤
│ 服务器地址 [http://192.168.41.138:3000]│
├─────────────────────────────────────┤
│ 用户名 [rabbit]                      │
│ 密码   [••••••]                      │
│ [登录按钮]                           │
├─────────────────────────────────────┤
│ 用户: rabbit                         │
│ 姓名: 张三                           │
│ 角色: student                        │
│ ID:   13                             │
│ [退出登录]                           │
└─────────────────────────────────────┘
```

**交互逻辑**:
- 输入地址/用户名/密码 → 点击登录 → 调用 `SemecTeachingApi.login()`
- 登录成功：显示用户信息，清空密码框
- 登录失败：显示错误提示
- 已登录状态：显示用户详情 + 退出登录按钮

#### `lib/screens/preview_screen.dart`

修改 `_save()` 方法，增加云端同步逻辑：

**原有流程**:
```
保存 → 同步到 OCR 服务端 → 本地 SQLite 保存
```

**新流程**:
```
1. 同步到 OCR 服务端（原有，失败不影响）
2. 本地 SQLite 保存（必须成功）
3. 如果已登录 semecTeaching：
   a. 上传图片 assets
   b. 调用 /api/incorrect/from-wrong-question-man
4. 显示结果 SnackBar：
   - 成功: "✓ 已保存并同步到云端"
   - 失败: "已本地保存，云端同步失败: ..."
   - 未登录: "✓ 已保存"（原有提示）
```

#### `lib/screens/detail_screen.dart`

新增 **云同步按钮** 在 AppBar actions：

```dart
IconButton(
    icon: const Icon(Icons.cloud_upload_outlined),
    tooltip: '同步到 semecTeaching',
    onPressed: _syncToSemec,
)
```

- 点击调用 `SyncService.syncRecord(_record)`
- 未登录时提示："未登录 semecTeaching，请先到设置页登录"
- 同步中显示 CircularProgressIndicator
- 成功/失败分别显示不同颜色的 SnackBar

---

## 4. 认证流程详解

### 4.1 登录流程

```
Flutter App                                    semecTeaching Backend
    │                                                  │
    │── POST /api/auth/login ──► {username, password}  │
    │◄── 200 OK + Set-Cookie: access_token=xxx         │
    │◄── Set-Cookie: refresh_token=xxx                 │
    │                                                  │
    │── GET /api/auth/csrf-init ──► Cookie: access_token
    │◄── 200 OK + Set-Cookie: XSRF-TOKEN=yyy           │
    │                                                  │
    │  解析 access_token JWT payload 获取 user info    │
    │  存储到 FlutterSecureStorage:                    │
    │    - semec_access_token                          │
    │    - semec_csrf_token                            │
    │    - semec_user_json                             │
```

### 4.2 请求受保护端点

```
Flutter App                                    semecTeaching Backend
    │                                                  │
    │── POST /api/upload/image ──►                     │
    │    Header: x-xsrf-token=yyy  (从存储读取)         │
    │    Cookie: access_token=xxx  (Dio 自动携带)       │
    │                                                  │
    │◄── 200 OK (CSRF 验证通过 + JWT 验证通过)          │
```

**CSRF 双提交 Cookie 机制**:
- Cookie 中携带 `XSRF-TOKEN`
- Header 中携带 `x-xsrf-token`
- 后端比较两者是否一致

---

## 5. API 接口定义

### 5.1 登录
```http
POST /api/auth/login
Content-Type: application/json

{ "username": "rabbit", "password": "123456" }

Response:
200 OK
Set-Cookie: access_token=eyJhbG...; Path=/; HttpOnly
Set-Cookie: refresh_token=eyJhbG...; Path=/; HttpOnly
{ "code": 0, "success": true, "message": "OK", "data": { "id": 13, ... } }
```

### 5.2 获取 CSRF Token
```http
GET /api/auth/csrf-init
Cookie: access_token=eyJhbG...

Response:
200 OK
Set-Cookie: XSRF-TOKEN=abc123...; Path=/
```

### 5.3 上传图片
```http
POST /api/upload/image
Content-Type: multipart/form-data
x-xsrf-token: abc123...
Cookie: access_token=eyJhbG...

Body (multipart):
- file: [图片二进制数据]

Response:
200 OK
{ "code": 0, "success": true, "data": {
    "url": "/static/images/123456_abc.jpg",
    "filename": "123456_abc.jpg",
    "size": 102400
}}
```

### 5.4 保存纸质错题
```http
POST /api/incorrect/from-wrong-question-man
Content-Type: application/json
x-xsrf-token: abc123...
Cookie: access_token=eyJhbG...

Body:
{
    "user_id": 13,
    "subject": "数学",
    "grade": "七年级",
    "knowledge_points": ["一元一次方程"],
    "problem": "解方程 $2x = 10$",
    "answer": "$x = 5$",
    "solution": "两边除以2",
    "student_answer": "$x = 10$",
    "error_category": "计算失误",
    "error_desc": "符号错误",
    "images": ["/static/images/123.jpg"],
    "difficulty": 3,
    "real_score": 0
}

Response:
200 OK
{ "code": 0, "success": true, "message": "OK", "data": {
    "incorrect_id": 808
}}
```

---

## 6. 测试记录

### 6.1 后端 API 测试 (Python requests)

**测试结果**: ✅ 全部通过

```python
# 登录
session.post('/api/auth/login', json={'username':'rabbit','password':'123456'})
# → 200, access_token + refresh_token cookies

# 获取 CSRF
session.get('/api/auth/csrf-init')
# → 200, XSRF-TOKEN cookie

# 保存错题
session.post('/api/incorrect/from-wrong-question-man',
    json={'user_id':13, 'subject':'数学', 'problem':'解方程 2x = 10', ...},
    headers={'x-xsrf-token': xsrf})
# → 200, {incorrect_id: 808}

# 查询错题列表
session.post('/api/incorrect/getMyCollection', json={'page':1,'pageSize':10})
# → 200, 包含新保存的记录，source_type: 'wrong_question_man'
```

### 6.2 验证数据

保存的记录特征：
- `incorrectId`: 808
- `questionId`: 0（纸质错题标识）
- `sourceType`: `wrong_question_man`
- `questionContent`: `解方程 2x = 10`
- `correctAnswer`: `x = 5`
- `subject`: `数学`
- `difficulty`: `3星`

### 6.3 Flutter 编译验证

```bash
flutter pub get      # ✅ 成功安装 flutter_secure_storage
flutter analyze      # ✅ 无新增错误（仅剩项目原有弃用警告）
```

---

## 7. 部署与配置

### 7.1 semecTeaching 后端部署

1. **应用数据库迁移**:
```bash
mysql -h 192.168.31.213 -P 33306 -u teaching -pteaching teaching < exam-server/database/migrations/014-wrong-question-man-support.sql
```

2. **确保目录存在**（图片上传存储）:
```bash
mkdir -p exam-client/public/static/images/
```

3. **重启 Node.js 服务**:
```bash
cd exam-server
npm run dev   # 或 pm2 restart
```

### 7.2 Flutter 客户端配置

1. **安装依赖**:
```bash
cd wrong_answer_client
flutter pub get
```

2. **Android 平台配置** (如需支持 Android):
`flutter_secure_storage` 在 Android 上需要 `minSdkVersion >= 23`，已在默认模板中满足。

3. **iOS 平台配置** (如需支持 iOS):
在 `ios/Runner/Info.plist` 添加 Keychain Sharing 权限（SecureStorage 需要）。

### 7.3 默认配置

| 配置项 | 默认值 |
|--------|--------|
| semecTeaching 服务器 | `http://192.168.41.138:3000` |
| 测试账号 | `rabbit` / `123456` (学生) |
| 图片存储路径 | `exam-client/public/static/images/` |
| 图片访问 URL | `http://192.168.41.138:3000/static/images/<filename>` |

---

## 8. 安全考虑

1. **用户身份验证**: 后端强制检查 `req.user.id === req.body.user_id`，防止学生保存错题到其他用户账号
2. **JWT Cookie**: `HttpOnly` 标志防止 XSS 窃取
3. **CSRF 保护**: 双提交 Cookie 模式，所有 POST/PUT/DELETE 请求需要验证
4. **图片限制**: 5MB 大小限制，仅允许 jpg/png/gif/webp 格式
5. **加密存储**: Flutter 端使用 Keychain/Keystore 加密存储 Token

---

## 9. 后续扩展建议

1. **批量同步**: 已预留 `SyncService.syncBatch()` 方法，可在设置页添加"同步全部历史记录"功能
2. **同步状态标记**: 本地 SQLite 可添加 `synced_to_semec` 字段，避免重复同步
3. **图片压缩**: 上传前对 Flutter 端图片进行压缩，减少流量和服务器存储
4. **离线队列**: 网络异常时将同步任务加入队列，恢复后自动重试
5. **双向同步**: 从 semecTeaching 拉取系统错题到本地（需额外 API）

---

## 10. 文件变更清单

### semecTeaching (后端)
| 文件 | 操作 | 说明 |
|------|------|------|
| `database/migrations/014-wrong-question-man-support.sql` | 新增 | 数据库迁移 |
| `utils/knowledgeValidator.js` | 新增 | 知识点名称验证 |
| `routes/uploadRoutes.js` | 新增 | 图片上传路由 |
| `services/incorrectService.js` | 修改 | 新增 `createFromWrongQuestionMan` + 修改查询 |
| `controller/incorrectController.js` | 修改 | 新增 `saveFromWrongQuestionMan` |
| `routes/incorrectRoutes.js` | 修改 | 新增 `/from-wrong-question-man` 路由 |
| `routes/index.js` | 修改 | 注册 `uploadRoutes` |

### wrong_answer_client (Flutter)
| 文件 | 操作 | 说明 |
|------|------|------|
| `pubspec.yaml` | 修改 | 添加 `flutter_secure_storage` |
| `lib/api/semec_teaching_api.dart` | 新增 | semecTeaching API 客户端 |
| `lib/services/sync_service.dart` | 新增 | 同步服务层 |
| `lib/screens/settings_screen.dart` | 修改 | 添加云端同步配置和登录 |
| `lib/screens/preview_screen.dart` | 修改 | 保存时自动同步 |
| `lib/screens/detail_screen.dart` | 修改 | 添加手动同步按钮 |
