// lib/screens/assign_student_screen.dart
//
// 教师选择学生分配错题
// 复用 POST /classes/class-tree，前端内存扁平化 + 搜索

import 'package:flutter/material.dart';
import '../api/semec_teaching_api.dart';
import '../utils/theme.dart';

/// 分配结果
class AssignResult {
  final int studentId;
  final String studentName;
  final bool keepLocal;

  AssignResult({
    required this.studentId,
    required this.studentName,
    required this.keepLocal,
  });
}

/// 学生信息（扁平化后）
class _StudentInfo {
  final int id;
  final String name;
  final String className;
  final int classId;

  _StudentInfo({
    required this.id,
    required this.name,
    required this.className,
    required this.classId,
  });
}

class AssignStudentScreen extends StatefulWidget {
  const AssignStudentScreen({super.key});

  @override
  State<AssignStudentScreen> createState() => _AssignStudentScreenState();
}

class _AssignStudentScreenState extends State<AssignStudentScreen> {
  List<_StudentInfo> _allStudents = [];
  List<_StudentInfo> _filteredStudents = [];
  final Set<int> _selectedStudentIds = {};
  final TextEditingController _searchCtrl = TextEditingController();
  bool _keepLocal = true;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadStudents();
    _searchCtrl.addListener(_onSearch);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadStudents() async {
    setState(() => _loading = true);
    try {
      final tree = await SemecTeachingApi.instance.getClassTree();
      final students = _flattenClassTree(tree);
      setState(() {
        _allStudents = students;
        _filteredStudents = students;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '加载学生列表失败: $e';
      });
    }
  }

  /// 将 class-tree 返回的树形结构扁平化为学生列表
  List<_StudentInfo> _flattenClassTree(List<dynamic> tree) {
    final students = <_StudentInfo>[];
    for (final cls in tree) {
      if (cls['type'] != 'class') continue;
      final className = cls['name'] as String? ?? '';
      final classId = (cls['id'] as num?)?.toInt() ?? 0;
      final children = cls['children'] as List<dynamic>?;
      if (children != null) {
        for (final child in children) {
          students.add(_StudentInfo(
            id: (child['id'] as num?)?.toInt() ?? 0,
            name: child['name'] as String? ?? '',
            className: className,
            classId: classId,
          ));
        }
      }
    }
    return students;
  }

  /// 内存搜索（按姓名/班级名过滤）
  void _onSearch() {
    final query = _searchCtrl.text.trim().toLowerCase();
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
    final selectedCount = _selectedStudentIds.length;

    return Scaffold(
      backgroundColor: AppColors.bg0,
      appBar: AppBar(
        title: const Text('选择学生'),
        actions: [
          if (selectedCount > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text(
                  '已选 $selectedCount 人',
                  style: const TextStyle(
                    color: AppColors.amber,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          // 搜索框
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: '搜索学生姓名或班级',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          _onSearch();
                        },
                      )
                    : null,
              ),
            ),
          ),

          // 学生列表
          Expanded(
            child: _buildStudentList(),
          ),

          // 底部操作栏
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            decoration: BoxDecoration(
              color: AppColors.bg1,
              border: Border(top: BorderSide(color: AppColors.bg3)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 保留到错题本开关
                SwitchListTile(
                  title: const Text('保留到我的错题本'),
                  subtitle: const Text('关闭则仅分配给学生，本地不保留'),
                  value: _keepLocal,
                  activeColor: AppColors.amber,
                  onChanged: (v) => setState(() => _keepLocal = v),
                ),
                const SizedBox(height: 8),
                // 确认按钮
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: selectedCount == 0 ? null : _confirm,
                    child: Text('确认分配 ($selectedCount 人)'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStudentList() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.amber, strokeWidth: 2),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_error!, style: const TextStyle(color: AppColors.red)),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _loadStudents,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    if (_filteredStudents.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.person_off_outlined,
                size: 48, color: AppColors.textMuted),
            const SizedBox(height: 12),
            Text(
              _allStudents.isEmpty ? '暂无可分配的学生' : '未找到匹配的学生',
              style: TextStyle(color: AppColors.textMuted),
            ),
          ],
        ),
      );
    }

    // 按班级分组显示
    final grouped = <String, List<_StudentInfo>>{};
    for (final s in _filteredStudents) {
      grouped.putIfAbsent(s.className, () => []).add(s);
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: grouped.length,
      itemBuilder: (ctx, groupIndex) {
        final className = grouped.keys.elementAt(groupIndex);
        final students = grouped[className]!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 班级标题
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 4),
              child: Text(
                className,
                style: AppText.label.copyWith(color: AppColors.amber),
              ),
            ),
            // 学生列表
            ...students.map((s) => CheckboxListTile(
              value: _selectedStudentIds.contains(s.id),
              onChanged: (checked) {
                setState(() {
                  if (checked == true) {
                    _selectedStudentIds.add(s.id);
                  } else {
                    _selectedStudentIds.remove(s.id);
                  }
                });
              },
              title: Text(s.name),
              dense: true,
              activeColor: AppColors.amber,
              controlAffinity: ListTileControlAffinity.leading,
            )),
            const Divider(height: 1),
          ],
        );
      },
    );
  }

  void _confirm() {
    if (_selectedStudentIds.isEmpty) return;

    // 当前仅支持单选（需求文档确认），取第一个选中的学生
    final selected = _allStudents.firstWhere(
      (s) => _selectedStudentIds.contains(s.id),
    );

    Navigator.pop(context, AssignResult(
      studentId: selected.id,
      studentName: selected.name,
      keepLocal: _keepLocal,
    ));
  }
}
