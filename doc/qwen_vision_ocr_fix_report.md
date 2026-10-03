# Qwen Vision OCR 修复方案文档

## 基本信息

| 项目 | 内容 |
|------|------|
| 问题编号 | ISSUE-2026-0428-001 |
| 问题描述 | Qwen Vision fallback 无论框选什么内容都返回相同题目 |
| 根因定位 | `qwen_client.py:251-254` 调用 processor 时未正确传递图片数据 |
| 影响范围 | `wrong_answer_server/app/core/qwen_client.py:ocr_image()` |
| 修复方案 | 方案A：使用 `apply_chat_template(tokenize=True, return_dict=True)` 一步生成 inputs |

---

## 一、问题现象

服务端日志显示：

- 两次不同的框选区域：
  - 第一次：裁切区域 `(240,1822)-(2851,2209)`，图片 285KB
  - 第二次：裁切区域 `(116,2736)-(2501,3641)`，图片 574KB
- 但 Qwen Vision **输出完全相同的文本**：

```
1. 下列各组数中互为相反数的是 ( )
A. -2 和 2
B. -2 和 -2
C. 0 和 0
D. 2 和 2
```

---

## 二、根因分析

### 2.1 精确根因链（源码级别）

**第一层：`tokenize=False` 导致图片信息未被提取**

当前代码（`qwen_client.py:251-253`）：
```python
text = processor.apply_chat_template(
    messages, tokenize=False, add_generation_prompt=True
)
```

证据：`transformers/processing_utils.py:1644`
```python
tokenize = processed_kwargs["template_kwargs"].pop("tokenize", False)
```

由于 `tokenize=False`，**不会进入 `if tokenize:` 分支**（`processing_utils.py:1646` 开始），messages 中的图片信息（含 base64）**完全不会被提取和处理**。

**第二层：`processor(text=[text])` 未传入 `images` 参数**

当前代码（`qwen_client.py:254`）：
```python
inputs = processor(text=[text], return_tensors="pt").to(model.device)
```

证据：`transformers/models/qwen2_5_vl/processing_qwen2_5_vl.py:83`
```python
def __call__(
    self,
    images: Optional[ImageInput] = None,
    text: Union[TextInput, ...] = None,
    ...
) -> BatchFeature:
```

由于 `images` 参数未传入，`__call__` 中 `images is None`，导致：
- `image_inputs = {}`（空字典，不生成 `pixel_values` 和 `image_grid_thw`）
- text 中的 `<|image_pad|>` 占位符不会被替换为实际 image token（`processing_qwen2_5_vl.py:134-140`）

**第三层：模型只收到纯文本 token，没有视觉特征数据**

最终传给 `model.generate()` 的只有 `input_ids` 和 `attention_mask`，没有任何 `pixel_values`。Qwen2.5-VL 视觉模型"看不到"图片，只能根据文本 prompt 进行幻觉（hallucinate）输出，因此每次都会输出训练记忆中的固定题目。

### 2.2 为什么 base64 格式本身没有问题

当前 messages 格式：
```python
{"type": "image", "image": f"data:{media_type};base64,{image_data}"}
```

证据：`transformers/image_utils.py:478-480`
```python
if image.startswith("data:image/"):
    image = image.split(",")[1]

# Try to load as base64
try:
    b64 = base64.decodebytes(image.encode())
    image = PIL.Image.open(BytesIO(b64))
```

transformers 的 `load_image` 函数**明确支持** `data:image/xxx;base64,xxxx` 格式的 data URI。

**问题不在于 base64 格式，而在于 `tokenize=False` 导致图片信息根本没有被提取，加上后续 `processor()` 没有传 `images` 参数，图片永远不会被处理。**

---

## 三、修复方案

### 3.1 方案A（已选定）：使用 `apply_chat_template(tokenize=True, return_dict=True)`

**修改文件**：`wrong_answer_server/app/core/qwen_client.py`

**修改内容**：

```python
# 1. 新增导入（第20行附近，删除 import base64）
from PIL import Image

# 2. 修改 ocr_image() 函数（第217-275行），完整替换为：
async def ocr_image(image_path: Path) -> str:
    """
    直接用 Qwen2.5-VL 视觉能力识别图片中的题目文本。

    供 pipeline.py 的 Vision fallback 调用：当 MinerU OCR 返回空文本时，
    将裁切好的 ROI 原图传入此函数，Qwen 直接看图识文字。

    返回识别到的文本（含 LaTeX 格式公式），失败时抛出异常。
    """
    model, processor = _load_model()

    # 加载图片为 PIL Image 对象
    image = Image.open(image_path)

    messages = [
        {"role": "system", "content": _OCR_SYSTEM_PROMPT},
        {
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "image": image,  # ← PIL Image 对象，替代 base64 URL
                },
                {
                    "type": "text",
                    "text": "请识别图片中的题目文本，完整输出所有文字内容。",
                },
            ],
        },
    ]

    # 一步生成 inputs：提取图片 + 图像预处理 + tokenization + 返回可直接传给 model.generate() 的字典
    inputs = processor.apply_chat_template(
        messages,
        add_generation_prompt=True,
        tokenize=True,
        return_dict=True,
        return_tensors="pt",
    ).to(model.device)

    if settings.debug:
        logger.debug(f"[Qwen Vision OCR] 图片: {image_path.name}, 大小: {image_path.stat().st_size} bytes")

    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=1000,
            temperature=0,
            do_sample=False,
        )

    raw_content = processor.batch_decode(outputs, skip_special_tokens=True)[0]
    raw_content = raw_content.split("assistant\n")[-1].strip()

    if settings.debug:
        logger.debug(f"[Qwen Vision OCR 输出]\n{raw_content[:500]}")

    logger.info(f"Qwen Vision OCR 完成，识别文本长度={len(raw_content)}")
    return raw_content
```

### 3.2 关键变更点

| 变更项 | 修改前 | 修改后 |
|--------|--------|--------|
| 图片加载方式 | `base64.b64encode(f.read())` 编码为 data URI 字符串 | `Image.open(image_path)` 加载为 PIL Image 对象 |
| messages 中 image 值 | `f"data:{media_type};base64,{image_data}"` | `image`（PIL Image 对象） |
| processor 调用 | 两步：`apply_chat_template(tokenize=False)` → `processor(text=[text])` | 一步：`apply_chat_template(tokenize=True, return_dict=True, return_tensors="pt")` |
| 是否传 images | 否 | 是（由 `apply_chat_template` 内部自动提取并传递） |
| 返回类型 | `BatchFeature`（仅含 input_ids, attention_mask） | `BatchFeature`（含 input_ids, attention_mask, **pixel_values**, **image_grid_thw**） |

### 3.3 删除 base64 编码逻辑的安全性说明

- `base64` 模块在 `qwen_client.py` 中的**唯一使用点**是 `ocr_image()` 函数的第228-229行
- `analyze_semantic()` 是纯文本接口，不涉及图片处理
- 删除 `import base64` 和 base64 编码逻辑**不会影响任何其他功能**
- `PIL.Image.open()` 是更直接的图片加载方式，与 base64 编码功能等价

---

## 四、官方文档与源码引用

### 4.1 Hugging Face 官方文档

Qwen2.5-VL 官方文档明确示例（来源：`https://github.com/huggingface/transformers/blob/main/docs/source/en/model_doc/qwen2_5_vl.md`）：

```python
inputs = processor.apply_chat_template(
    messages,
    add_generation_prompt=True,
    tokenize=True,
    return_dict=True,
    return_tensors="pt"
).to(model.device)
```

### 4.2 源码级别验证

**验证1：`apply_chat_template` 在 `tokenize=True` 时提取图片**

`transformers/processing_utils.py:1646-1700`：

```python
if tokenize:
    batch_images, batch_videos = [], []
    for conversation in conversations:
        images, videos = [], []
        for message in conversation:
            visuals = [content for content in message["content"] if content["type"] in ["image", "video"]]
            image_fnames = [
                vision_info[key]
                for vision_info in visuals
                for key in ["image", "url", "path", "base64"]
                if key in vision_info and vision_info["type"] == "image"
            ]
            images.extend(image_fnames)
        batch_images.append(images)

    # ... 渲染 template ...

    out = self(
        text=prompt,
        images=batch_images if images_exist else None,
        videos=batch_videos if videos_exist else None,
        **kwargs,
    )
```

- `image_fnames` 提取逻辑支持 `key="image"`（当前代码使用的 key）
- 提取后通过 `self(...)` 调用 `Qwen2_5_VLProcessor.__call__()`，传入 `images` 参数

**验证2：`Qwen2_5_VLProcessor.__call__` 接收 images 生成 pixel_values**

`transformers/models/qwen2_5_vl/processing_qwen2_5_vl.py:123-124`：

```python
if images is not None:
    image_inputs = self.image_processor(images=images, **output_kwargs["images_kwargs"])
    image_grid_thw = image_inputs["image_grid_thw"]
```

**验证3：`load_image` 支持 base64 和 PIL Image**

`transformers/image_utils.py:453-488` 的 `load_image` 函数：

```python
def load_image(image: Union[str, "PIL.Image.Image"], timeout: Optional[float] = None) -> "PIL.Image.Image":
    if isinstance(image, str):
        if image.startswith("http://") or image.startswith("https://"):
            image = PIL.Image.open(BytesIO(requests.get(image, timeout=timeout).content))
        elif os.path.isfile(image):
            image = PIL.Image.open(image)
        else:
            if image.startswith("data:image/"):
                image = image.split(",")[1]

            # Try to load as base64
            try:
                b64 = base64.decodebytes(image.encode())
                image = PIL.Image.open(BytesIO(b64))
            except Exception as e:
                raise ValueError(
                    f"Incorrect image source. Must be a valid URL starting with `http://` or `https://`, "
                    f"a valid path to an image file, or a base64 encoded string. Got {image}. Failed with {e}"
                )
    elif not isinstance(image, PIL.Image.Image):
        raise TypeError(
            "Incorrect format used for image. Should be an url linking to an image, a base64 string, "
            "a local path, or a PIL image."
        )
    image = PIL.ImageOps.exif_transpose(image)
    image = image.convert("RGB")
    return image
```

- 支持 URL、本地路径、base64 字符串、PIL Image 对象
- 支持 `data:image/xxx;base64,xxx` 格式（第478-479行）

---

## 五、修复后执行流程验证

修复后 `ocr_image()` 的完整执行流程：

```
Image.open(image_path)
    → PIL.Image.Image 对象
    → messages = [{"type": "image", "image": image}, ...]
    → processor.apply_chat_template(messages, tokenize=True, return_dict=True, return_tensors="pt")
        → 提取 image 值（PIL Image 对象）
        → batch_images = [[PIL.Image]]
        → render_jinja_template() 生成 prompt（含 <|image_pad|> 占位符）
        → self(text=prompt, images=batch_images, ...)
            → Qwen2_5_VLProcessor.__call__()
            → self.image_processor(images=images)
                → load_image(PIL.Image) → 直接返回 PIL Image
                → 生成 pixel_values, image_grid_thw
            → 替换 text 中的 <|image_pad|> 为正确数量的 image token
            → tokenizer(text) → 生成 input_ids, attention_mask
            → return BatchFeature({input_ids, attention_mask, pixel_values, image_grid_thw})
    → inputs.to(model.device)
    → model.generate(**inputs)
        → 模型同时接收文本 token 和视觉特征
        → 正确识别图片内容
```

---

## 六、验证方法

### 6.1 部署前验证

1. 在本地或服务器运行以下测试脚本，确认 `inputs` 包含 `pixel_values`：

```python
from PIL import Image
from transformers import Qwen2_5_VLForConditionalGeneration, AutoProcessor

model = Qwen2_5_VLForConditionalGeneration.from_pretrained(
    "/path/to/Qwen2.5-VL-7B-Instruct-AWQ",
    dtype=torch.float16,
    device_map="auto",
    trust_remote_code=True,
)
processor = AutoProcessor.from_pretrained("/path/to/Qwen2.5-VL-7B-Instruct-AWQ", trust_remote_code=True)

image = Image.open("/path/to/test_image.jpg")
messages = [
    {"role": "system", "content": "你是专业的试卷 OCR 助手。"},
    {
        "role": "user",
        "content": [
            {"type": "image", "image": image},
            {"type": "text", "text": "请识别图片中的题目文本。"},
        ],
    },
]

inputs = processor.apply_chat_template(
    messages,
    add_generation_prompt=True,
    tokenize=True,
    return_dict=True,
    return_tensors="pt",
).to(model.device)

print("Keys:", inputs.keys())  # 应包含 pixel_values 和 image_grid_thw
assert "pixel_values" in inputs, "缺少 pixel_values！"
assert "image_grid_thw" in inputs, "缺少 image_grid_thw！"
print("验证通过：视觉特征已正确加载")
```

### 6.2 部署后验证

1. 框选图片中**不同的题目区域**（至少3个不同区域）
2. 查看服务端日志，确认：
   - `Vision fallback：裁切区域 (x1,y1)-(x2,y2)` 显示不同坐标
   - `Qwen Vision OCR 输出` 显示**不同的识别文本**
   - 不再出现固定的 "1. 下列各组数中互为相反数的是..."
3. 检查返回的 JSON 中 `problem` 字段内容与框选区域匹配

---

## 七、影响范围分析

| 模块 | 影响 | 说明 |
|------|------|------|
| `app/core/qwen_client.py` | 修改 | 仅修改 `ocr_image()` 函数 |
| `app/core/qwen_client.py` | 删除 | 删除 `import base64`，新增 `from PIL import Image` |
| `app/services/pipeline.py` | 无影响 | 调用接口不变（仍为 `qwen_client.ocr_image(path)`） |
| `app/api/extract.py` | 无影响 | 调用链路不变 |
| 前端 Flutter | 无影响 | 接口契约不变 |
| `analyze_semantic()` | 无影响 | 纯文本接口，不涉及图片处理 |

---

## 八、回退方案

如果修复后出现问题，可立即回退到修改前的版本：

```bash
cd wrong_answer_server
git checkout app/core/qwen_client.py
```

回退后 Vision fallback 将恢复为原有行为（模型看不到图片，但系统仍能运行，只是识别结果不准确）。

---

*文档生成时间：2026-04-28*  
*问题助手审核状态：待稽核助手重新审查后执行*
