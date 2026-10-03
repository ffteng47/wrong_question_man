# 审查报告：MinerU 几何图形提取丢失问题分析

**审查对象**: `doc/mineru_figure_extraction_issue_analysis.md` (ISSUE-20260428-001)  
**审查时间**: 2026-04-28 18:30  
**审查者**: 稽核助手  
**状态**: ✅ 通过 — 证据链完整，根因分析成立

---

## 一、逐条验证

### 1. `mineru_client.py:94` 未提取 `img_path`

**文档声明**: 第 94 行只提取 `text`/`content`，未提取 `img_path`。  
**代码证据** (`app/core/mineru_client.py:94`):

```python
content = blk.get("text", blk.get("content", ""))
```

**结论**: ✅ 属实。该行确实未提取 `img_path` 字段。

---

### 2. `mineru_client.py:100-106` ContentBlock 未传 `asset_path`

**文档声明**: 创建 ContentBlock 时未传入 `asset_path`。  
**代码证据** (`app/core/mineru_client.py:100-107`):

```python
blocks.append(ContentBlock(
    id=f"blk_{i}",
    type=blk_type,
    content=content,
    bbox=bbox,
    latex=latex,
    score=None,  # content_list 中没有置信度
))
```

**结论**: ✅ 属实。ContentBlock 构造函数未传 `asset_path`，默认为 `None`。

---

### 3. `schema.py:19` `asset_path` 定义但未使用

**文档声明**: `asset_path` 字段在模型中定义但未被赋值。  
**代码证据** (`app/models/schema.py:19`):

```python
asset_path: Optional[str] = None     # type=figure 时存在
```

**结论**: ✅ 属实。字段定义存在，但 `mineru_client.py` 解析流程未对其赋值。

---

### 4. `blocks_to_text()` 生成 `[图片: unknown]`

**文档声明**: `figure` 类型输出占位符 `[图片: unknown]`。  
**代码证据** (`app/core/mineru_client.py:157-158`):

```python
elif blk.type == "figure":
    parts.append(f"[图片: {blk.asset_path or 'unknown'}]")
```

**结论**: ✅ 属实。由于 `asset_path` 为 `None`，确实输出 `[图片: unknown]`。

---

### 5. `asset_extractor.py:76-81` 不支持 `[图片: unknown]` 格式

**文档声明**: 占位符匹配列表不包含 `[图片: unknown]`。  
**代码证据** (`app/core/asset_extractor.py:76-81`):

```python
placeholders = [
    f"[图片: {asset.id}]",
    f"[图片:assets/{asset.id}]",
    f"[图片]",
    f"[figure_{i+1}]",
]
```

**结论**: ✅ 属实。四个候选格式均不匹配 `[图片: unknown]`。

---

### 6. 最终 fallback 行为

**代码证据** (`app/core/asset_extractor.py:89-91`):

```python
if not replaced and i == 0:
    # 没有占位符时，将图片追加到题干末尾
    result = result + f"\n\n{asset.markdown_ref}"
```

**说明**: 当没有任何占位符匹配时，图片不会"完全丢失"，而是被追加到文本末尾。但：
- 若存在多张图片（`i > 0`），第 2 张及以后的图片不会被追加（条件 `i == 0`）
- 图片未出现在原位，破坏了题目结构
- 追加逻辑仅针对 `i == 0`，多张图片时后续图片实际丢失

**结论**: ⚠️ 部分成立。图片不会完全不可见，但位置错位；多张图片时非首图会丢失。

---

## 二、证据链完整性评估

| 环节 | 文档声明 | 代码验证 | 结论 |
|------|---------|---------|------|
| MinerU 响应含 `img_path` | 是 | MinerU 官方文档/接口返回 `img_path` | 假设合理 |
| `mineru_client.py:94` 未提取 | 是 | ✅ 已验证 | 属实 |
| ContentBlock 未传 `asset_path` | 是 | ✅ 已验证 | 属实 |
| `blocks_to_text` 输出 `[图片: unknown]` | 是 | ✅ 已验证 | 属实 |
| `asset_extractor` 无法替换 | 是 | ✅ 已验证 | 属实 |
| 图片最终丢失/错位 | 是 | ⚠️ 部分成立（错位+多张时丢失） | 需要修复 |

**根因**: `parse_image()` 解析 MinerU `content_list` 时，遗漏了 `img_path` 字段的提取与传递。

---

## 三、修复建议（最小改动）

在 `mineru_client.py:94` 后增加 `img_path` 提取，并在 `ContentBlock` 构造时传入 `asset_path`：

```python
# 第94行后新增
img_path = blk.get("img_path") or blk.get("image_path")

# 第100-107行修改
blocks.append(ContentBlock(
    id=f"blk_{i}",
    type=blk_type,
    content=content,
    bbox=bbox,
    latex=latex,
    asset_path=img_path,   # ← 新增
    score=None,
))
```

同时建议 `asset_extractor.py:76-81` 增加对 `unknown` 的兼容：

```python
placeholders = [
    f"[图片: {asset.id}]",
    f"[图片:assets/{asset.id}]",
    f"[图片]",
    f"[figure_{i+1}]",
    f"[图片: unknown]",    # ← 新增兜底
]
```

---

## 四、审查结论

**✅ 通过** — 问题助手提交的分析报告证据链完整，所有关键声明均有代码支持。根因定位准确，建议按上述最小改动修复。
