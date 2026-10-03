# 框选题目几何图形丢失问题分析报告
分析日期：2026-04-28  
分析助手：问题助手  
问题编号：ISSUE-20260428-001  
MinerU版本：3.1.1  

---

## 一、问题现象
1. **输入**：横置图片（原始尺寸3000x4000），框选题目区域
2. **MinerU解析**：成功识别11个blocks，包含1个`figure`类型block（几何图形），但该block的`content`为空
3. **ROI筛选后**：`figure` block的`content=''`，`ocr_text`中图片占位符为`[图片: unknown]`
4. **最终输出**：Qwen语义分析后，`problem`字段中几何图形完全丢失，仅保留文本

---

## 二、根因分析
### 核心根因
`mineru_client.py`解析MinerU响应时，未提取`figure/image`类型block的`img_path`字段到`ContentBlock`的`asset_path`字段，导致后续流程中图片占位符无法匹配，最终几何图形丢失。

### 代码证据链
| 文件路径 | 行号 | 代码片段 | 说明 |
|---------|------|----------|------|
| `wrong_answer_server/app/core/mineru_client.py` | 94 | `content = blk.get("text", blk.get("content", ""))` | 仅提取`text`/`content`字段，未提取`img_path` |
| `wrong_answer_server/app/core/mineru_client.py` | 100-106 | `ContentBlock(...)`创建时未传入`asset_path` | `asset_path`始终为`None` |
| `wrong_answer_server/app/models/schema.py` | 19 | `asset_path: Optional[str] = None` | 字段定义但未实际使用 |
| `wrong_answer_server/app/core/mineru_client.py` | 157-158 | `parts.append(f"[图片: {blk.asset_path or 'unknown'}]")` | 因`asset_path`为None，输出`[图片: unknown]` |
| `wrong_answer_server/app/core/asset_extractor.py` | 76-81 | 占位符格式检查 | 仅支持`[图片: fig_1]`等格式，无法匹配`[图片: unknown]` |

---

## 三、四层深度分析
### 子问题1：MinerU `img_path`字段解析失败
1.1 `mineru_client.py:94` - 仅提取`text`/`content`，忽略`img_path`  
1.2 `mineru_client.py:100-106` - `ContentBlock`创建时未赋值`asset_path`  
1.3 `schema.py:19` - `asset_path`字段定义但未使用  
1.4 **结论**：MinerU返回的`img_path`被完全丢弃  

### 子问题2：`blocks_to_text`输出`[图片: unknown]`
2.1 `mineru_client.py:157-158` - `figure`类型输出`[图片: {blk.asset_path or 'unknown'}]`  
2.2 因`asset_path`为None，输出`[图片: unknown]`  
2.3 `pipeline.py:124` - `ocr_text`包含无效占位符  
2.4 **结论**：无效占位符导致后续无法替换  

### 子问题3：`inject_assets_into_markdown`占位符不匹配
3.1 `asset_extractor.py:76-81` - 支持的占位符格式为`[图片: fig_1]`、`[图片: assets/fig_1]`等  
3.2 实际文本中是`[图片: unknown]`，无法匹配  
3.3 `asset_extractor.py:89-91` - 仅当`i==0`时无占位符才追加到末尾  
3.4 **结论**：图片引用未能注入到正确位置  

### 子问题4：Qwen OCR对图片的处理
4.1 `qwen_client.py:118` - SYSTEM_PROMPT要求保留`[图片: xxx]`占位符  
4.2 输入中的`[图片: unknown]`无有效信息，Qwen可能忽略或改写  
4.3 日志显示Qwen输出`problem`字段无图片引用  
4.4 **结论**：图片在语义分析阶段彻底丢失  

---

## 四、解决方案选项
### 用户确认选择：选项A（2026-04-28确认）
### 选项A：修复`asset_path`解析（推荐，已选定）
- **类型**：简单逻辑修复  
- **修改点**：`mineru_client.py`第100-106行，添加`asset_path=blk.get("img_path")`  
  ```python
  blocks.append(ContentBlock(
      id=f"blk_{i}",
      type=blk_type,
      content=content,
      bbox=bbox,
      latex=latex,
      asset_path=blk.get("img_path"),  # 新增：提取MinerU返回的img_path
      score=None,
  ))
  ```
- **影响范围**：`mineru_client.py`、`pipeline.py`、`asset_extractor.py`  
- **验证方法**：重新框选含几何图形的题目，检查图片是否正确显示  

### 选项B：直接用bbox裁切原图（未选定）
- **类型**：简单逻辑修复  
- **修改点**：`asset_extractor.py`确保占位符与裁切后的图片路径匹配  
- **影响范围**：`mineru_client.py`、`asset_extractor.py`  
- **验证方法**：同上  

## 五、最终修复方案（用户确认后）
━━━━━━━━━━━━━━━━━━━━━━━━━━━
问题根因：mineru_client.py解析MinerU响应时未提取figure/image类型block的img_path字段到ContentBlock的asset_path，导致后续图片占位符为[图片: unknown]，无法被inject_assets_into_markdown正确替换
选定方案：选项A（修复asset_path解析）
修改文件：wrong_answer_server/app/core/mineru_client.py:100-106
修改内容：在ContentBlock创建时添加asset_path=blk.get("img_path")，提取MinerU返回的图片路径
验证方法：重新框选含几何图形的题目，检查最终problem字段是否正确包含![图](assets/xxx/fig_1.png)引用，Flutter前端能显示几何图形
━━━━━━━━━━━━━━━━━━━━━━━━━━━
> 本修复方案已提交【稽核助手】执行审查。问题助手工作结束。

---

## 五、社区讨论参考
1. [MinerU Output File Format](https://opendatalab.github.io/MinerU/reference/output_files/) - 确认`image`类型block包含`img_path`字段  
2. [MinerU issue #4311](https://github.com/opendatalab/MinerU/issues/4311) - 类似图片路径丢失问题  
3. [MinerU issue #3456](https://github.com/opendatalab/MinerU/issues/3456) - 内容丢失问题讨论  

---

## 六、分析结论
问题根因为`mineru_client.py`未提取MinerU返回的`img_path`字段，导致后续图片处理流程中断。推荐采用**选项A**修复，仅需修改单一文件的1行代码即可解决。

> 本报告用于后续审计，所有结论均有代码证据支撑，未经过用户确认不修改任何代码文件。
