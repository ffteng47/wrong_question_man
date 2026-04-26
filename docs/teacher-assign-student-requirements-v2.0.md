# 需求确认文档 v2.0 — 教师分配错题给学生

> 生成时间：2026-04-25
> 需求确认助手：已完成
> 状态：✅ 已确认，待移交问题助手进行技术方案分析

---

## 一、功能描述

为错题本系统增加**教师角色分配错题给学生**的功能：教师登录后，可以将扫描/录入的错题（单选或多选）分配给自己班级的指定学生；admin 可分配给所有学生。保存时直接写入 `incorrect_question` 表（`question_id=0`，不经过题库），与 semecTeaching 现有"试卷管理→整理错题→分配错题"流程互不干扰。

---

## 二、已确认需求

| 维度 | 确认内容 |
|------|----------|
| **角色体系** | `SemecUser.role` 取值为 `student` / `teacher` / `admin` |
| **学生功能** | 学生登录 → 正常扫描/录入错题 → 同步到 semecTeaching（已有功能，保持不变） |
| **教师功能** | 教师登录 → 扫描/录入错题 → **保存时可指定目标学生** → 推送到 semecTeaching 该学生名下 |
| **Admin 功能** | admin 登录 → 可分配给**所有班级**的任意学生 |
| **教师权限限制** | 教师**只能**分配**自己任教班级**的学生，不可跨班分配 |
| **题目来源** | 本地 `WrongAnswerRecord`（每次截图扫描的题目），非 semecTeaching 云端题库 |
| **分配方式** | 支持 **单选** 和 **多选** 题目，批量分配给指定学生 |
| **学生选择** | 从 semecTeaching 获取学生列表，支持搜索/按班级过滤 |
| **分配后行为** | 分配后题目与学生自己录入的逻辑一致；教师端**不保留反馈机制** |
| **教师保留选项** | 保存/分配时提供开关：**"同时保留到我的错题本"**<br>• 开启 → 教师本地也保存一份<br>• 关闭 → 仅分配给学生，教师本地不保留 |
| **UI 交互** | 错题列表中每个题目左侧显示复选框，选中后底部出现 **"分配"** 按钮；分配后题目从教师列表中**消失** |
| **保存目标** | **直接写入 `incorrect_question` 表**，`question_id = 0` 标识纸质错题，**不经过 `question_bank` 题库表** |

---

## 三、与现有 semecTeaching 功能的兼容性分析

| semecTeaching 现有功能 | 数据特征 | 与新功能的关系 |
|------------------------|----------|---------------|
| **试卷管理 → 整理错题 → 分配错题** | `question_id > 0`，来自题库 | ❌ 无关。该流程分配的是题库已有题目，本功能创建的是 `question_id=0` 的纸质错题 |
| **`POST /api/incorrect/assign`** | 需要 `question_id` + `paper_id` | ❌ 不调用。本功能直接调用 `from-wrong-question-man` 创建新记录 |
| **`POST /api/incorrect/assignBatch`** | 需要已有 `incorrect_id`，批量复制 | ❌ 不调用。本功能是新创建错题，不是复制已有错题 |
| **`POST /api/incorrect/from-wrong-question-man`** | `question_id=0`，直接插入 | ✅ **本功能复用此接口**，仅需放开教师代学生保存的权限校验 |

**结论**：新功能与 semecTeaching 现有的"试卷管理→整理错题→分配错题"流程**完全独立、互不干扰**。

---

## 四、待定项

| 待定内容 | 备注 |
|----------|------|
| **后端权限放开** | `from-wrong-question-man` 当前有 `req.user.id !== parseInt(user_id)` 校验，教师代学生保存会返回 403。**需要后端修改**：教师/admin 角色允许指定其他 user_id |
| **教师班级学生列表接口** | 当前 `GET /api/users?role=student&classId=xxx` 可按班级过滤，但没有"获取我教的班级的所有学生"的接口。需要后端新增或扩展：如 `GET /api/users/my-students?search=`，自动根据当前教师的 `user_class_relations.relation_type='teach'` 过滤 |
| **admin 班级列表** | admin 获取学生时是否需要按班级分组显示？还是平铺所有学生？ |

---

## 五、技术规格与实现方案

### 5.1 数据模型变更

**`WrongAnswerRecord` 模型（Dart）—— 新增字段：**
```dart
// 分配相关（仅教师端使用）
String? assignedToStudentId;    // 目标学生 ID（semecTeaching user id）
String? assignedToStudentName;  // 目标学生姓名（显示用）
bool keepInTeacherCollection;   // 是否保留到教师错题本
String? assignStatus;           // "pending" / "assigned" / "failed"
```

**SQLite 表结构：**
```sql
-- 在现有 records 表中新增列：
ALTER TABLE records ADD COLUMN assigned_to_student_id TEXT;
ALTER TABLE records ADD COLUMN assigned_to_student_name TEXT;
ALTER TABLE records ADD COLUMN keep_in_teacher_collection INTEGER DEFAULT 0;
ALTER TABLE records ADD COLUMN assign_status TEXT DEFAULT 'pending';
```

### 5.2 权限与数据过滤

**后端（semecTeaching）需新增/修改：**

```javascript
// 1. from-wrong-question-man 权限放开
// exam-server/controller/incorrectController.js:72-84
async saveFromWrongQuestionMan(req, res) {
    // ...
    // 原逻辑：if (req.user.id !== parseInt(user_id)) → 403
    // 新逻辑：
    const isSelf = req.user.id === parseInt(user_id);
    const isTeacherOrAdmin = ['teacher', 'admin'].includes(req.user.role);
    
    if (!isSelf && !isTeacherOrAdmin) {
        return res.status(403).json({ message: '无权操作：只能为自己或学生保存错题' });
    }
    
    // 如果是教师代学生保存，校验目标学生是否属于教师班级
    if (!isSelf && req.user.role === 'teacher') {
        const isMyStudent = await userService.checkTeacherStudentRelation(
            req.user.id, parseInt(user_id)
        );
        if (!isMyStudent) {
            return res.status(403).json({ message: '该学生不在您的班级中' });
        }
    }
    // ...
}

// 2. 新增获取教师班级学生列表接口
// exam-server/controller/userController.js
async getMyStudents(req, res) {
    const teacherId = req.user.id;
    const { search, classId } = req.query;
    
    // 查询教师任教的所有班级
    const [teacherClasses] = await mysql_pool.execute(`
        SELECT class_id FROM user_class_relations 
        WHERE user_id = ? AND relation_type = 'teach'
    `, [teacherId]);
    
    const classIds = teacherClasses.map(r => r.class_id);
    if (classIds.length === 0) {
        return res.json({ data: { items: [], total: 0 } });
    }
    
    // 查询这些班级的学生
    let sql = `
        SELECT DISTINCT u.id, u.username, u.real_name, c.name as class_name, c.id as class_id
        FROM users u
        JOIN user_class_relations ucr ON u.id = ucr.user_id AND ucr.relation_type = 'study'
        JOIN classes c ON ucr.class_id = c.id
        WHERE u.role = 'student' AND ucr.class_id IN (${classIds.map(() => '?').join(',')})
    `;
    const params = [...classIds];
    
    if (classId && classIds.includes(parseInt(classId))) {
        sql += ' AND c.id = ?';
        params.push(parseInt(classId));
    }
    
    if (search) {
        sql += ' AND (u.username LIKE ? OR u.real_name LIKE ?)';
        params.push(`%${search}%`, `%${search}%`);
    }
    
    const [rows] = await mysql_pool.execute(sql, params);
    res.json({ code: 0, data: { items: rows, total: rows.length } });
}
```

### 5.3 前端界面结构

```
┌─────────────────────────────────────────┐
│  📷 错题本                              │
├─────────────────────────────────────────┤
│  [☑] 题1  $x^2 + 1 = 0$               │
│  [ ]  题2  函数定义域...                │
│  [☑] 题3  三角函数...                  │
├─────────────────────────────────────────┤
│  已选择 2 题          [分配给学生]      │
└─────────────────────────────────────────┘
```

**新页面/组件：**

| 文件 | 说明 |
|------|------|
| `lib/screens/assign_student_screen.dart` | 学生选择页面：搜索框 + 班级Tab/筛选 + 学生列表 + 确认分配<br>教师：只显示自己班级的学生（按班级分组）<br>admin：显示所有学生（可选按班级分组） |
| `lib/widgets/record_card.dart` | 修改：左侧增加复选框（仅教师/admin 角色显示） |
| `lib/screens/home_screen.dart` | 修改：底部出现"分配"浮动按钮（选中时显示） |
| `lib/screens/detail_screen.dart` | 修改：保存页面增加"分配给"学生选择器 + "保留到错题本"开关 |

**教师保存/分配流程：**

```dart
// 教师录入错题后的保存流程
Future<void> saveAsTeacher(WrongAnswerRecord record) async {
  // 1. 弹出学生选择 + 保留选项
  final assignConfig = await showAssignDialog(context);
  if (assignConfig == null) return; // 用户取消
  
  final targetStudent = assignConfig.student;
  final keepLocal = assignConfig.keepInTeacherCollection;
  
  // 2. 上传图片到 semecTeaching（同现有逻辑）
  final imageUrls = await uploadImages(record.assets);
  
  // 3. 调用 semecTeaching API，user_id = 目标学生ID
  final result = await semecApi.saveIncorrectQuestion(
    userId: targetStudent.id,  // ← 关键：教师代学生保存
    // ... 其他字段同学生自己保存
  );
  
  // 4. 本地处理
  if (keepLocal) {
    // 保留到教师错题本
    record.assignedToStudentId = targetStudent.id.toString();
    record.assignedToStudentName = targetStudent.realName;
    record.assignStatus = 'assigned';
    await dbHelper.insert(record);
  } else {
    // 不保留本地，标记为已分配
    record.assignStatus = 'assigned';
    // 可选择删除本地草稿或不保存到 SQLite
  }
}
```

### 5.4 API 客户端变更

**`SemecTeachingApi` 新增方法：**

```dart
// 获取教师班级的学生列表
Future<List<SemecStudent>> getMyStudents({
  String? search,
  int? classId,
});

// Admin 获取所有学生（带班级信息）
Future<List<SemecStudent>> getAllStudents({
  String? search,
  int? classId,
  int page = 1,
  int limit = 50,
});

// 保存错题（已支持传入 userId，本次只需放开权限）
Future<SemecSaveResult> saveIncorrectQuestion({
  required int userId,    // 目标学生ID（教师代保存时用）
  required String subject,
  required String problem,
  // ... 其他字段
});
```

### 5.5 同步服务变更

**`SyncService` 新增方法：**

```dart
/// 教师分配错题给学生
Future<SyncResult> syncRecordAsTeacher({
  required WrongAnswerRecord record,
  required int targetUserId,
  required bool keepLocal,
}) async {
  // 1. 上传图片（同现有逻辑）
  // 2. 调用 semecTeaching API，user_id = targetUserId
  final saveResult = await _api.saveIncorrectQuestion(
    userId: targetUserId,    // ← 教师代学生保存
    subject: record.subject,
    problem: record.problem,
    // ... 其他字段
  );
  
  if (saveResult.success) {
    if (keepLocal) {
      // 保留到教师本地错题本
      record.assignedToStudentId = targetUserId.toString();
      record.assignStatus = 'assigned';
      await dbHelper.update(record);
    }
    return SyncResult(success: true, incorrectId: saveResult.incorrectId);
  } else {
    return SyncResult(success: false, error: saveResult.error);
  }
}
```

---

## 六、范围边界

- **本次包含**：
  - 教师/admin 角色识别与界面差异化（复选框 + 分配按钮）
  - 学生选择页面（搜索/按班级过滤/多选学生）
  - 教师只能分配自己班级的学生，admin 可分配所有学生
  - 教师代学生保存错题到 semecTeaching（`from-wrong-question-man`）
  - "保留到教师错题本"开关
  - 分配后题目从教师列表消失
  - 后端权限放开（教师/admin 允许指定 user_id）
  - 后端新增获取教师班级学生列表接口

- **本次不包含**：
  - 学生收到错题后的通知推送
  - 教师查看学生答题结果/反馈
  - 从 semecTeaching 云端题库直接选题分配
  - 按班级批量一键分配全班（需选择具体学生）
  - 分配历史记录/撤回功能
  - 修改 semecTeaching 现有的"试卷管理→整理错题→分配错题"流程

---

## 七、后端必须修改清单

| # | 文件 | 修改内容 | 影响范围 |
|---|------|----------|----------|
| 1 | `exam-server/controller/incorrectController.js` | `saveFromWrongQuestionMan`：放开教师/admin 代学生保存的权限校验；增加教师-学生班级关系校验 | semecTeaching 后端 |
| 2 | `exam-server/controller/userController.js` | 新增 `getMyStudents` 方法，根据 `user_class_relations.relation_type='teach'` 过滤 | semecTeaching 后端 |
| 3 | `exam-server/routes/userRoutes.js` | 新增 `GET /api/users/my-students` 路由 | semecTeaching 后端 |
| 4 | `exam-server/services/userService.js` | 新增 `checkTeacherStudentRelation` 方法 | semecTeaching 后端 |

---

> ✅ **需求确认完成（v2.0）**
>
> 请将本文档交给 **问题助手** 进行详细技术方案拆解和四层 TODO 规划。
