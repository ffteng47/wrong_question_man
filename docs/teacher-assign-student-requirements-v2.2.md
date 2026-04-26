# 需求确认与修复方案文档 v2.2（最小修改版）

> 生成时间：2026-04-26
> 需求确认助手：已完成
> 问题助手分析：已完成
> 状态：✅ 已确认，待开发助手执行

---

## 一、功能描述

为错题本系统增加**教师角色分配错题给学生**的功能：教师登录后，可以将扫描/录入的错题（单选或多选）分配给自己班级的指定学生；admin 可分配给所有学生。保存时直接写入 `incorrect_question` 表（`question_id=0`，不经过题库），与 semecTeaching 现有"试卷管理→整理错题→分配错题"流程互不干扰。

**核心决策**：复用现有 `POST /classes/class-tree` 接口获取教师班级学生列表，前端内存扁平化 + 搜索，后端无需新增任何接口。

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
| **学生选择** | 复用 `POST /classes/class-tree` 获取学生列表，前端内存扁平化 + 搜索过滤 |
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
| **`POST /classes/class-tree`** | 班级树，已支持教师角色过滤 | ✅ **本功能复用此接口**，前端扁平化获取学生列表 |

**结论**：新功能与 semecTeaching 现有的"试卷管理→整理错题→分配错题"流程**完全独立、互不干扰**。后端仅需修改 **1 个文件**。

---

## 四、接口复用分析

### 复用 `POST /classes/class-tree` 的理由

```javascript
// classRoutes.js:23
router.post('/class-tree', requireRole(['admin', 'teacher']), csrfMiddleware, classController.getClassTree);

// classService.js:20-84
async getClassTree(data) {
    const {isAdmin, id, role} = data;
    if(isAdmin) { /* 返回所有班级 + 未分组学生 */ }
    else if(role == "teacher") {
        // 只返回教师任教的班级（relation_type='teach'）
        [classes] = await mysql_pool.query(`
            SELECT c.id, c.name 
            FROM user_class_relations ucr, classes c 
            WHERE ucr.user_id = ? 
              AND ucr.relation_type = 'teach'
              AND ucr.class_id = c.id
        `, [id]);
    }
    // 每个班级下查询学生（relation_type='study'）
    for (const cls of classes) {
        const [students] = await mysql_pool.query(`
            SELECT u.id, u.real_name AS name
            FROM users u
            JOIN user_class_relations ucr ON u.id = ucr.user_id
            WHERE ucr.class_id = ? AND ucr.relation_type = 'study'
        `, [cls.id]);
    }
}
```

- ✅ 已限制 `requireRole(['admin', 'teacher'])`
- ✅ 教师只返回自己 `relation_type='teach'` 的班级
- ✅ 每个班级下包含 `relation_type='study'` 的学生
- ✅ 已有 CSRF 保护
- ✅ 返回格式：`[{id, name, type:'class', children:[{id, name, type:'student'}]}]`

### 前端扁平化方案

```dart
// 将树形结构扁平化为学生列表
List<StudentInfo> flattenClassTree(List<dynamic> tree) {
    final students = <StudentInfo>[];
    for (final cls in tree) {
        if (cls['type'] != 'class') continue;
        final className = cls['name'] as String;
        final classId = cls['id'] as int;
        final children = cls['children'] as List<dynamic>?;
        if (children != null) {
            for (final child in children) {
                students.add(StudentInfo(
                    id: child['id'] as int,
                    name: child['name'] as String,
                    className: className,
                    classId: classId,
                ));
            }
        }
    }
    return students;
}

// 内存搜索（教师通常 <200 个学生，性能可忽略）
List<StudentInfo> filterStudents(List<StudentInfo> students, String query) {
    if (query.isEmpty) return students;
    final lower = query.toLowerCase();
    return students.where((s) => 
        s.name.toLowerCase().contains(lower) ||
        s.className.toLowerCase().contains(lower)
    ).toList();
}
```

**性能评估**：教师通常任教 1-3 个班级，每班 30-50 个学生，总数据量 < 200 条，内存搜索时间 < 1ms，完全不需要后端搜索接口。

---

## 五、后端最小修改方案：仅需修改 1 个文件

### 文件：`exam-server/controller/incorrectController.js`

**修改位置**：第72-84行（权限校验）

**修改内容**：
```javascript
// 替换原有的硬身份拦截（第72-84行）
const targetUserId = parseInt(user_id);
const isSelf = req.user.id === targetUserId;
const isAdmin = req.user.role === 'admin';
const isTeacher = req.user.role === 'teacher';

if (!isSelf && !isAdmin && !isTeacher) {
    return res.status(403).json({
        code: 1, success: false,
        message: '无权操作：只能为自己或学生保存错题'
    });
}

// 教师代学生保存：内联 SQL 校验班级关系
if (isTeacher && !isSelf) {
    const [relationRows] = await mysql_pool.execute(`
        SELECT 1 
        FROM user_class_relations ucr_teacher
        JOIN user_class_relations ucr_student 
            ON ucr_teacher.class_id = ucr_student.class_id
        WHERE ucr_teacher.user_id = ? 
          AND ucr_teacher.relation_type = 'teach'
          AND ucr_student.user_id = ? 
          AND ucr_student.relation_type = 'study'
        LIMIT 1
    `, [req.user.id, targetUserId]);
    
    if (relationRows.length === 0) {
        return res.status(403).json({
            code: 1, success: false,
            message: '该学生不在您的班级中'
        });
    }
}

// 审计日志
if (!isSelf) {
    logger.info('教师代学生保存纸质错题', {
        operatorId: req.user.id,
        operatorRole: req.user.role,
        targetStudentId: targetUserId,
        subject,
        ip: req.ip
    });
}
```

**为什么不需要新增 Service 方法？**
- `checkTeacherStudentRelation` 只有这 1 处调用
- SQL 只有 6 行，内联在 Controller 中足够清晰
- 减少文件修改数量，降低回归风险

---

## 六、前端修改清单（9 个文件）

### 文件1：`lib/models/wrong_answer_record.dart`

**修改位置**：`WrongAnswerRecord` 类

**修改内容**：
```dart
// 在现有字段后新增：
String? assignedToStudentId;    // 目标学生 ID（semecTeaching user id）
String? assignedToStudentName;  // 目标学生姓名（显示用）
bool keepInTeacherCollection;   // 是否保留到教师错题本
String? assignStatus;           // null / 'pending' / 'assigned' / 'failed'
```

### 文件2：`lib/utils/db_helper.dart`

**修改位置**：数据库版本、表结构、`onUpgrade`、`upsert`、`query`

**修改内容**：
```dart
// 1. 数据库版本升级
version: 3,  // 从 2 升级到 3

// 2. onUpgrade 添加 ALTER TABLE
onUpgrade: (db, oldVersion, newVersion) async {
  if (oldVersion < 2) {
    await _createDraftTable(db);
  }
  if (oldVersion < 3) {
    await db.execute('ALTER TABLE records ADD COLUMN assigned_to_student_id TEXT');
    await db.execute('ALTER TABLE records ADD COLUMN assigned_to_student_name TEXT');
    await db.execute('ALTER TABLE records ADD COLUMN keep_in_teacher_collection INTEGER DEFAULT 1');
    await db.execute('ALTER TABLE records ADD COLUMN assign_status TEXT');
  }
},

// 3. _createRecordsTable 新增列
Future<void> _createRecordsTable(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS records (
      id          TEXT PRIMARY KEY,
      subject     TEXT NOT NULL DEFAULT '',
      grade       TEXT NOT NULL DEFAULT '',
      type        TEXT NOT NULL DEFAULT '',
      difficulty  INTEGER NOT NULL DEFAULT 3,
      review_status TEXT NOT NULL DEFAULT 'pending',
      created_at  TEXT NOT NULL,
      updated_at  TEXT NOT NULL,
      tags_json   TEXT NOT NULL DEFAULT '[]',
      assigned_to_student_id TEXT,
      assigned_to_student_name TEXT,
      keep_in_teacher_collection INTEGER DEFAULT 1,
      assign_status TEXT,
      data_json   TEXT NOT NULL
    )
  ''');
  // ... 原有索引
  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_assign_status ON records(assign_status)');
}

// 4. upsert 写入新列
Future<void> upsert(WrongAnswerRecord r) async {
  final d = await db;
  await d.insert(
    'records',
    {
      'id':            r.id,
      'subject':       r.subject,
      'grade':         r.grade,
      'type':          r.type,
      'difficulty':    r.difficulty,
      'review_status': r.reviewStatus,
      'created_at':    r.createdAt,
      'updated_at':    r.updatedAt,
      'tags_json':     jsonEncode(r.tags),
      'assigned_to_student_id': r.assignedToStudentId,
      'assigned_to_student_name': r.assignedToStudentName,
      'keep_in_teacher_collection': r.keepInTeacherCollection ? 1 : 0,
      'assign_status': r.assignStatus,
      'data_json':     r.toJsonString(),
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

// 5. query 增加过滤参数
Future<List<WrongAnswerRecord>> query({
  String? subject,
  String? grade,
  String? reviewStatus,
  String? assignStatus,
  bool? keepInTeacherCollection,
  int limit = 50,
  int offset = 0,
}) async {
  final d = await db;
  final conditions = <String>[];
  final args = <Object?>[];

  if (subject != null) { conditions.add('subject = ?'); args.add(subject); }
  if (grade != null)   { conditions.add('grade = ?');   args.add(grade); }
  if (reviewStatus != null) {
    conditions.add('review_status = ?'); args.add(reviewStatus);
  }
  if (assignStatus != null) {
    conditions.add('(assign_status = ? OR assign_status IS NULL)');
    args.add(assignStatus);
  }
  if (keepInTeacherCollection != null) {
    conditions.add('(keep_in_teacher_collection = ? OR keep_in_teacher_collection IS NULL)');
    args.add(keepInTeacherCollection ? 1 : 0);
  }

  final where = conditions.isEmpty ? null : conditions.join(' AND ');
  final rows = await d.query(
    'records',
    where: where,
    whereArgs: args.isEmpty ? null : args,
    orderBy: 'created_at DESC',
    limit: limit,
    offset: offset,
  );
  return rows.map((r) =>
      WrongAnswerRecord.fromJson(
        jsonDecode(r['data_json'] as String) as Map<String, dynamic>))
      .toList();
}
```

### 文件3：`lib/api/semec_teaching_api.dart`

**修改位置**：新增 `getClassTree()` 方法

**修改内容**：
```dart
/// 获取班级树（含学生列表）
/// 教师角色只返回自己班级的学生，admin 返回所有
Future<List<Map<String, dynamic>>> getClassTree() async {
  try {
    final resp = await _dio.post('/classes/class-tree');
    if (resp.statusCode == 200 && resp.data?['code'] == 0) {
      return List<Map<String, dynamic>>.from(resp.data!['data'] ?? []);
    }
    return [];
  } catch (e) {
    print('[SEMEC] 获取班级树失败: $e');
    return [];
  }
}
```

### 文件4：`lib/services/sync_service.dart`

**修改位置**：新增 `assignToStudent()` 方法

**修改内容**：
```dart
/// 教师分配错题给学生
Future<SyncResult> assignToStudent({
  required WrongAnswerRecord record,
  required int targetUserId,
  required bool keepLocal,
}) async {
  if (!isLoggedIn) {
    return SyncResult(success: false, error: '未登录 semecTeaching');
  }

  // 1. 上传图片（同现有逻辑）
  List<String>? imageUrls;
  bool uploadedAny = false;
  if (record.assets.isNotEmpty) {
    imageUrls = [];
    for (final asset in record.assets) {
      final file = File(asset.srcPath);
      if (await file.exists()) {
        final uploadResult = await _api.uploadImage(file);
        if (uploadResult.success && uploadResult.url != null) {
          imageUrls.add(uploadResult.url!);
          uploadedAny = true;
        }
      }
    }
    if (imageUrls.isEmpty) imageUrls = null;
  }

  // 2. 调用 semecTeaching API，user_id = targetUserId（教师代保存）
  final saveResult = await _api.saveIncorrectQuestion(
    userId: targetUserId,
    subject: record.subject,
    problem: record.problem,
    grade: record.grade,
    knowledgePoints: record.knowledgePoints.isNotEmpty ? record.knowledgePoints : null,
    answer: record.answer.isNotEmpty ? record.answer : null,
    solution: record.solution.isNotEmpty ? record.solution : null,
    studentAnswer: record.errorAnalysis.studentAnswer.isNotEmpty
        ? record.errorAnalysis.studentAnswer : null,
    errorCategory: record.errorAnalysis.errorCategory != '未知'
        ? record.errorAnalysis.errorCategory : null,
    errorDesc: record.errorAnalysis.errorDesc.isNotEmpty
        ? record.errorAnalysis.errorDesc : null,
    images: imageUrls,
    difficulty: record.difficulty,
    realScore: record.realScore,
  );

  // 3. 如保留到本地，使用 upsert（修正：不使用不存在的 update 方法）
  if (keepLocal && saveResult.success) {
    record.assignedToStudentId = targetUserId.toString();
    record.assignStatus = 'assigned';
    await DbHelper.instance.upsert(record);
  }

  return SyncResult(
    success: saveResult.success,
    incorrectId: saveResult.incorrectId,
    error: saveResult.error,
    uploadedImages: uploadedAny,
  );
}
```

### 文件5：`lib/screens/preview_screen.dart`

**修改位置**：`_save()` 方法

**修改内容**：
```dart
Future<void> _save() async {
  final user = SyncService.instance.currentUser;
  final isTeacher = user?.role == 'teacher';
  int? targetUserId;
  bool keepLocal = true;
  SyncResult? teacherSyncResult;

  // 教师：先选择目标学生
  if (isTeacher) {
    final result = await Navigator.push<AssignResult>(context,
      MaterialPageRoute(builder: (_) => const AssignStudentScreen()));
    if (result == null) return; // 用户取消
    targetUserId = result.studentId;
    keepLocal = result.keepLocal;
    _record.assignedToStudentId = targetUserId.toString();
    _record.assignedToStudentName = result.studentName;
    _record.keepInTeacherCollection = keepLocal;
  }

  setState(() => _saving = true);
  String? localError;

  // 1. 保存到本地 SQLite（学生 always 保存；教师根据 keepLocal）
  try {
    if (!isTeacher || keepLocal) {
      await DbHelper.instance.upsert(_record);
    }
  } catch (e) {
    localError = e.toString();
  }

  // 2. 同步到 semecTeaching
  if (localError == null && SyncService.instance.isLoggedIn) {
    try {
      if (isTeacher && targetUserId != null) {
        teacherSyncResult = await SyncService.instance.assignToStudent(
          record: _record,
          targetUserId: targetUserId,
          keepLocal: keepLocal,
        );
      } else {
        teacherSyncResult = await SyncService.instance.syncRecord(_record);
      }
    } catch (e) {
      // 异常处理
    }
  }

  if (mounted) {
    setState(() => _saving = false);

    if (localError != null) {
      // 本地保存失败
    } else {
      // 修正：使用 teacherSyncResult?.success 替代 syncSuccess
      if (isTeacher && !keepLocal && teacherSyncResult != null && teacherSyncResult.success) {
        // 教师不保留本地且同步成功：不保存到 SQLite
      }
      Navigator.pop(context, true);
    }
  }
}
```

### 文件6：`lib/screens/detail_screen.dart`

**修改位置**：AppBar actions 新增"分配"按钮

**修改内容**：在现有"同步到 semecTeaching"按钮旁增加：
```dart
// 仅教师角色显示分配按钮
if (SyncService.instance.currentUser?.role == 'teacher')
  IconButton(
    icon: const Icon(Icons.person_add_outlined, color: AppColors.textSecondary),
    tooltip: '分配给学生',
    onPressed: _assignToStudent,
  ),

// 新增方法
Future<void> _assignToStudent() async {
  final result = await Navigator.push<AssignResult>(context,
    MaterialPageRoute(builder: (_) => AssignStudentScreen(record: _record)));
  if (result == null) return;
  
  final syncResult = await SyncService.instance.assignToStudent(
    record: _record,
    targetUserId: result.studentId,
    keepLocal: result.keepLocal,
  );
  
  if (syncResult.success) {
    _record.assignedToStudentId = result.studentId.toString();
    _record.assignStatus = 'assigned';
    if (!result.keepLocal) {
      await DbHelper.instance.delete(_record.id);
      Navigator.pop(context); // 返回首页
    } else {
      await DbHelper.instance.upsert(_record);
    }
  }
}
```

### 文件7：`lib/screens/assign_student_screen.dart`（新增）

**功能**：学生选择页面

**核心逻辑**：
```dart
class AssignStudentScreen extends StatefulWidget {
  final WrongAnswerRecord? record; // null 表示从 PreviewScreen 调用
  const AssignStudentScreen({super.key, this.record});
  // ...
}

class _AssignStudentScreenState extends State<AssignStudentScreen> {
  List<StudentInfo> _allStudents = [];
  List<StudentInfo> _filteredStudents = [];
  final Set<int> _selectedStudentIds = {};
  final TextEditingController _searchCtrl = TextEditingController();
  bool _keepLocal = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadStudents();
    _searchCtrl.addListener(_onSearch);
  }

  Future<void> _loadStudents() async {
    final tree = await SemecTeachingApi.instance.getClassTree();
    final students = _flattenClassTree(tree);
    setState(() {
      _allStudents = students;
      _filteredStudents = students;
      _loading = false;
    });
  }

  List<StudentInfo> _flattenClassTree(List<dynamic> tree) {
    final students = <StudentInfo>[];
    for (final cls in tree) {
      if (cls['type'] != 'class') continue;
      final className = cls['name'] as String;
      final classId = cls['id'] as int;
      final children = cls['children'] as List<dynamic>?;
      if (children != null) {
        for (final child in children) {
          students.add(StudentInfo(
            id: child['id'] as int,
            name: child['name'] as String,
            className: className,
            classId: classId,
          ));
        }
      }
    }
    return students;
  }

  void _onSearch() {
    final query = _searchCtrl.text.toLowerCase();
    setState(() {
      _filteredStudents = query.isEmpty
          ? _allStudents
          : _allStudents.where((s) =>
              s.name.toLowerCase().contains(query) ||
              s.className.toLowerCase().contains(query)
            ).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('选择学生')),
      body: Column(
        children: [
          // 搜索框
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchCtrl,
              decoration: const InputDecoration(
                hintText: '搜索学生姓名或班级',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          // 学生列表（按班级分组）
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _filteredStudents.length,
                    itemBuilder: (ctx, i) => CheckboxListTile(
                      title: Text(_filteredStudents[i].name),
                      subtitle: Text(_filteredStudents[i].className),
                      value: _selectedStudentIds.contains(_filteredStudents[i].id),
                      onChanged: (checked) {
                        setState(() {
                          if (checked == true) {
                            _selectedStudentIds.add(_filteredStudents[i].id);
                          } else {
                            _selectedStudentIds.remove(_filteredStudents[i].id);
                          }
                        });
                      },
                    ),
                  ),
          ),
          // 保留到错题本开关
          SwitchListTile(
            title: const Text('保留到我的错题本'),
            subtitle: const Text('关闭则仅分配给学生'),
            value: _keepLocal,
            onChanged: (v) => setState(() => _keepLocal = v),
          ),
          // 确认按钮
          Padding(
            padding: const EdgeInsets.all(16),
            child: ElevatedButton(
              onPressed: _selectedStudentIds.isEmpty ? null : _confirm,
              child: Text('确认分配给 ${_selectedStudentIds.length} 人'),
            ),
          ),
        ],
      ),
    );
  }

  void _confirm() {
    // 单选/多选：返回选中的学生
    final selected = _allStudents.where(
      (s) => _selectedStudentIds.contains(s.id)
    ).toList();
    Navigator.pop(context, AssignResult(
      studentId: selected.first.id,
      studentName: selected.first.name,
      keepLocal: _keepLocal,
    ));
  }
}
```

### 文件8：`lib/screens/home_screen.dart`

**修改位置**：`_load()` 查询 + 列表渲染 + 底部分配按钮

**修改内容**：
```dart
// _load() 增加教师过滤
Future<void> _load() async {
  setState(() => _loading = true);
  final isTeacher = SyncService.instance.currentUser?.role == 'teacher';
  final records = await DbHelper.instance.query(
    subject: _filterSubject,
    grade: _filterGrade,
    reviewStatus: _filterStatus,
    // 教师视图：过滤掉已分配且不保留的
    keepInTeacherCollection: isTeacher ? true : null,
  );
  // ...
}

// 列表渲染增加复选框（教师角色）
SliverList(
  delegate: SliverChildBuilderDelegate(
    (ctx, i) => RecordCard(
      record: _records[i],
      isSelectable: isTeacher,
      isSelected: _selectedRecordIds.contains(_records[i].id),
      onSelectChanged: (selected) {
        setState(() {
          if (selected) {
            _selectedRecordIds.add(_records[i].id);
          } else {
            _selectedRecordIds.remove(_records[i].id);
          }
        });
      },
      onTap: () async { /* ... */ },
      onDelete: () => _confirmDelete(_records[i]),
    ),
    childCount: _records.length,
  ),
),

// 底部出现分配按钮（选中时）
if (isTeacher && _selectedRecordIds.isNotEmpty)
  Positioned(
    bottom: 80,
    left: 16,
    right: 16,
    child: ElevatedButton.icon(
      onPressed: _assignSelected,
      icon: const Icon(Icons.person_add),
      label: Text('分配所选 ${_selectedRecordIds.length} 题'),
    ),
  ),
```

### 文件9：`lib/widgets/record_card.dart`

**修改位置**：构造函数和 build 方法

**修改内容**：
```dart
class RecordCard extends StatelessWidget {
  final WrongAnswerRecord record;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final bool isSelectable;      // 新增
  final bool isSelected;        // 新增
  final ValueChanged<bool>? onSelectChanged; // 新增

  const RecordCard({
    super.key,
    required this.record,
    this.onTap,
    this.onDelete,
    this.isSelectable = false,
    this.isSelected = false,
    this.onSelectChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: isSelectable && onSelectChanged != null
          ? () => onSelectChanged!(!isSelected)
          : onTap,
      child: Container(
        // ...
        child: Row(
          children: [
            // 复选框（仅教师角色）
            if (isSelectable)
              Checkbox(
                value: isSelected,
                onChanged: (v) => onSelectChanged?.call(v ?? false),
              ),
            Expanded(
              child: Column(
                // ... 原有内容
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

---

## 七、范围边界

- **本次包含**：
  - 后端：仅 `incorrectController.js` 权限校验修改 + 审计日志
  - 前端：教师/admin 角色识别、复选框 + 分配按钮、学生选择页面、教师分配流程、SQLite 表结构升级

- **本次不包含**：
  - 后端：不新增任何接口（复用 `POST /classes/class-tree`）
  - 学生收到错题后的通知推送
  - 教师查看学生答题结果/反馈
  - 按班级批量一键分配全班（需选择具体学生）
  - 分配历史记录/撤回功能

---

## 八、验证方法

1. **后端权限验证**：
   ```bash
   # 教师代本班学生保存 → 200
   # 教师代其他班学生保存 → 403 "该学生不在您的班级中"
   # admin 代任意学生保存 → 200
   ```

2. **前端数据流验证**：
   ```bash
   POST /classes/class-tree → 
   [{id:1, name:"七一班", type:"class", children:[{id:101, name:"张三", type:"student"}]}]
   # 前端扁平化 → [StudentInfo(id:101, name:"张三", className:"七一班", classId:1)]
   ```

3. **数据库升级验证**：
   ```sql
   PRAGMA table_info(records);
   -- 应包含 assigned_to_student_id, assigned_to_student_name, 
   -- keep_in_teacher_collection, assign_status
   ```

4. **端到端流程验证**：
   - 教师扫描错题 → PreviewScreen → 选择学生 → 保存成功 → 首页不显示（如果不保留）
   - 保存失败 → 首页显示 → DetailScreen 可重新分配

---

> ✅ **需求确认与修复方案完成（v2.2 最小修改版）**
>
> 后端修改：**1 个文件**（`incorrectController.js`）
> 前端修改：**9 个文件**（8 个修改 + 1 个新增）
>
> 请将本文档交给 **开发助手** 执行代码修改。
