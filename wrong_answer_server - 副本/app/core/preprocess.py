"""
图像预处理 — OpenCV
- 手机拍照：透视变换矫正 + 去噪 + 二值化
- 扫描仪：仅去噪（版面已规整）
"""
from __future__ import annotations
import cv2
import numpy as np
from pathlib import Path
import logging

logger = logging.getLogger(__name__)


def preprocess_image(
    src_path: Path,
    dst_path: Path,
    source_type: str = "camera",   # "camera" | "scanner"
) -> tuple[Path, int, int]:
    """
    对原图做预处理，输出标准化 PNG。
    返回 (输出路径, 宽px, 高px)
    """
    img = cv2.imread(str(src_path))
    if img is None:
        raise ValueError(f"无法读取图片: {src_path}")

    h, w = img.shape[:2]
    logger.debug(f"原图尺寸: {w}x{h}, source_type={source_type}")

    if source_type == "camera":
        img = _correct_perspective(img)
        img = _denoise(img)
        # 二值化仅用于调试预览，OCR 输入用原彩图
    elif source_type == "scanner":
        img = _denoise(img)

    dst_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(dst_path), img, [cv2.IMWRITE_PNG_COMPRESSION, 3])
    out_h, out_w = img.shape[:2]
    logger.info(f"预处理完成: {dst_path}, 输出尺寸: {out_w}x{out_h}")
    return dst_path, out_w, out_h


def _denoise(img: np.ndarray) -> np.ndarray:
    """快速去噪：高斯模糊 + 锐化"""
    blurred = cv2.GaussianBlur(img, (3, 3), 0)
    # 反锐化掩模
    sharpened = cv2.addWeighted(img, 1.5, blurred, -0.5, 0)
    return sharpened


def _correct_perspective(img: np.ndarray) -> np.ndarray:
    """
    透视矫正：自动检测最大四边形轮廓并做仿射变换。
    若检测失败则原图返回（不影响后续 OCR）。
    """
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (5, 5), 0)
    edged = cv2.Canny(blurred, 50, 150)

    # 膨胀使边缘连续
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (5, 5))
    dilated = cv2.dilate(edged, kernel, iterations=2)

    contours, _ = cv2.findContours(dilated, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        logger.warning("透视矫正：未找到轮廓，跳过")
        return img

    # 取面积最大的轮廓
    largest = max(contours, key=cv2.contourArea)
    peri = cv2.arcLength(largest, True)
    approx = cv2.approxPolyDP(largest, 0.02 * peri, True)

    if len(approx) != 4:
        logger.warning(f"透视矫正：轮廓顶点数={len(approx)}，非四边形，跳过")
        return img

    pts = approx.reshape(4, 2).astype(np.float32)
    pts = _order_points(pts)

    (tl, tr, br, bl) = pts
    widthA = np.linalg.norm(br - bl)
    widthB = np.linalg.norm(tr - tl)
    heightA = np.linalg.norm(tr - br)
    heightB = np.linalg.norm(tl - bl)
    maxW = int(max(widthA, widthB))
    maxH = int(max(heightA, heightB))

    dst_pts = np.array([
        [0, 0], [maxW - 1, 0], [maxW - 1, maxH - 1], [0, maxH - 1]
    ], dtype=np.float32)

    M = cv2.getPerspectiveTransform(pts, dst_pts)
    warped = cv2.warpPerspective(img, M, (maxW, maxH))
    logger.info(f"透视矫正完成，输出: {maxW}x{maxH}")
    return warped


def _order_points(pts: np.ndarray) -> np.ndarray:
    """按 tl, tr, br, bl 排序四个角点"""
    rect = np.zeros((4, 2), dtype=np.float32)
    s = pts.sum(axis=1)
    rect[0] = pts[np.argmin(s)]   # tl
    rect[2] = pts[np.argmax(s)]   # br
    diff = np.diff(pts, axis=1)
    rect[1] = pts[np.argmin(diff)]  # tr
    rect[3] = pts[np.argmax(diff)]  # bl
    return rect


def crop_bbox(src_path: Path, bbox: list[float], dst_path: Path) -> Path:
    """
    按 bbox=[x1,y1,x2,y2] 从原图裁切，保存到 dst_path。
    用于 asset_extractor 裁切 figure block。
    """
    img = cv2.imread(str(src_path))
    if img is None:
        raise ValueError(f"无法读取: {src_path}")
    x1, y1, x2, y2 = (int(v) for v in bbox)
    cropped = img[y1:y2, x1:x2]
    dst_path.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(dst_path), cropped)
    logger.debug(f"裁切完成: {dst_path}, bbox={bbox}")
    return dst_path
