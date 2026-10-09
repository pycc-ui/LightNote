# -*- coding: utf-8 -*-
"""
LightNote 图标生成器：把羽毛笔矢量图形渲染成各平台所需位图。

为什么不直接下载一个 png：
  1. 16x16 的 Windows 任务栏图标、Android 各密度 mipmap 需要**不同尺寸重新
     渲染**，直接缩放一张大图会在小尺寸糊成一团；
  2. 以后调颜色/粗细只要改本文件顶部的常量重跑，不用满网找图。

图形来源：Feather Icons v4.29.2 的 `feather` 图标（MIT 许可），
路径数据在 tool/icon/feather.svg。本脚本内置了一个极小的 SVG path 解析器，
因为本机没有 cairosvg，而 Feather 只用到了 M/L/C/Z 四种子命令。

用法：
    python tool/icon/make_icon.py
输出：
    tool/icon/out/icon-<size>.png    各尺寸 PNG
    tool/icon/out/lightnote.ico      Windows 多尺寸图标
    tool/icon/out/android/mipmap-*/ic_launcher.png
    tool/icon/out/lightnote_logo.png App 内使用的 512 透明背景 logo
"""

import math
import os
import re

from PIL import Image, ImageDraw

# ============================================================================
# 可调参数：颜色与粗细都在这里改
# ============================================================================

# 羽毛笔主体色：棕色。比纯棕(#8B5A2B)略深一点，缩到 16px 仍能看清轮廓。
BROWN = (124, 82, 44, 255)
# 羽轴（那条斜线）用更深一档，小尺寸下能多一层细节
BROWN_DARK = (96, 61, 30, 255)

# 背景：暖米色圆角方块。透明背景的图标在深色任务栏上会看不清棕色。
USE_BACKGROUND = True
BG_TOP = (250, 246, 240, 255)     # 米白
BG_BOTTOM = (238, 226, 210, 255)  # 略深，做一点点纵向渐变
BG_RADIUS_RATIO = 0.22            # 圆角半径 / 边长

# 图形在画布里的占比（留白）。0.78 表示内容宽高最多占 78%。
CONTENT_RATIO = 0.80
STROKE_UNITS = 1.9                # Feather 原始描边宽度（viewBox 单位）

SUPERSAMPLE = 4                   # 先画 4 倍大再缩小，得到抗锯齿边缘

VIEWBOX = 24.0

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")


# ============================================================================
# 极简 SVG path 解析：M / L / H / V / C / S / Q / T / A / Z（含相对形式）
#
# 为什么必须支持 A（圆弧）：Feather 的羽毛轮廓里那条 `a 6 6 0 0 0 -8.49 -8.49`
# 是圆弧。第一版解析器直接跳过未知命令，结果把圆弧后面那一串数字
# 当成下一个命令的参数，图形被解成一条折线（图标看着像滑梯，不像羽毛）。
# 这类"静默降级"最危险，所以现在遇到真正不认识的命令会直接抛异常。
# ============================================================================

_NUM = re.compile(r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?")

# 各命令的参数个数；A 是 7 个（rx ry rot large-arc sweep x y）
_ARITY = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4,
          "Q": 4, "T": 2, "A": 7, "Z": 0}


def _cubic(p0, p1, p2, p3, steps=24):
    """三次贝塞尔采样成折线点。"""
    pts = []
    for i in range(1, steps + 1):
        t = i / steps
        mt = 1 - t
        x = (mt ** 3) * p0[0] + 3 * (mt ** 2) * t * p1[0] \
            + 3 * mt * (t ** 2) * p2[0] + (t ** 3) * p3[0]
        y = (mt ** 3) * p0[1] + 3 * (mt ** 2) * t * p1[1] \
            + 3 * mt * (t ** 2) * p2[1] + (t ** 3) * p3[1]
        pts.append((x, y))
    return pts


def _quad(p0, p1, p2, steps=20):
    """二次贝塞尔采样成折线点。"""
    pts = []
    for i in range(1, steps + 1):
        t = i / steps
        mt = 1 - t
        x = (mt ** 2) * p0[0] + 2 * mt * t * p1[0] + (t ** 2) * p2[0]
        y = (mt ** 2) * p0[1] + 2 * mt * t * p1[1] + (t ** 2) * p2[1]
        pts.append((x, y))
    return pts


def _arc(p0, rx, ry, rot_deg, large_arc, sweep, p1, steps_per_90=16):
    """按 SVG 规范 F.6 把椭圆弧转成折线点。

    实现的是「端点参数化 -> 中心参数化 -> 分段用三次贝塞尔逼近」这条路，
    与浏览器渲染结果一致。
    """
    if p0 == p1:
        return []
    rx, ry = abs(rx), abs(ry)
    if rx == 0 or ry == 0:
        return [p1]                      # 半径为 0 时退化为直线

    phi = math.radians(rot_deg)
    cos_p, sin_p = math.cos(phi), math.sin(phi)

    # 步骤 1：把端点变换到未旋转的椭圆坐标系
    dx2 = (p0[0] - p1[0]) / 2.0
    dy2 = (p0[1] - p1[1]) / 2.0
    x1p = cos_p * dx2 + sin_p * dy2
    y1p = -sin_p * dx2 + cos_p * dy2

    # 半径过小时按规范等比放大
    lam = (x1p ** 2) / (rx ** 2) + (y1p ** 2) / (ry ** 2)
    if lam > 1:
        s = math.sqrt(lam)
        rx *= s
        ry *= s

    # 步骤 2：求椭圆中心
    num = rx ** 2 * ry ** 2 - rx ** 2 * y1p ** 2 - ry ** 2 * x1p ** 2
    den = rx ** 2 * y1p ** 2 + ry ** 2 * x1p ** 2
    factor = math.sqrt(max(0.0, num / den)) if den else 0.0
    if large_arc == sweep:
        factor = -factor
    cxp = factor * rx * y1p / ry
    cyp = -factor * ry * x1p / rx

    cx = cos_p * cxp - sin_p * cyp + (p0[0] + p1[0]) / 2.0
    cy = sin_p * cxp + cos_p * cyp + (p0[1] + p1[1]) / 2.0

    # 步骤 3：起始角与扫过角
    def angle(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        n = math.hypot(ux, uy) * math.hypot(vx, vy)
        if n == 0:
            return 0.0
        a = math.acos(max(-1.0, min(1.0, dot / n)))
        return -a if (ux * vy - uy * vx) < 0 else a

    theta1 = angle(1.0, 0.0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
                   (-x1p - cxp) / rx, (-y1p - cyp) / ry)

    if not sweep and dtheta > 0:
        dtheta -= 2 * math.pi
    elif sweep and dtheta < 0:
        dtheta += 2 * math.pi

    # 步骤 4：分片，每片不超过 90 度
    segs = max(1, int(math.ceil(abs(dtheta) / (math.pi / 2))))
    delta = dtheta / segs
    # 三次贝塞尔逼近单位圆弧的经典系数
    k = 4.0 / 3.0 * math.tan(delta / 4.0)

    pts = []
    t = theta1
    for _ in range(segs):
        cos1, sin1 = math.cos(t), math.sin(t)
        t2 = t + delta
        cos2, sin2 = math.cos(t2), math.sin(t2)

        def to_user(ex, ey):
            return (cx + rx * cos_p * ex - ry * sin_p * ey,
                    cy + rx * sin_p * ex + ry * cos_p * ey)

        start = to_user(cos1, sin1)
        end = to_user(cos2, sin2)
        c1 = to_user(cos1 - k * sin1, sin1 + k * cos1)
        c2 = to_user(cos2 + k * sin2, sin2 - k * cos2)
        pts.extend(_cubic(start, c1, c2, end, steps=steps_per_90))
        t = t2
    return pts


def parse_path(d):
    """解析 path 的 d 属性，返回若干条子路径（每条是点列表）。"""
    tokens = re.findall(r"[MmLlHhVvCcSsQqTtAaZz]|" + _NUM.pattern, d)

    subs = []
    cur = []
    pos = (0.0, 0.0)
    start = (0.0, 0.0)
    i = 0
    cmd = None
    # 上一段三次/二次曲线的控制点，供 S / T 的平滑反射使用
    last_cubic_ctrl = None
    last_quad_ctrl = None

    def have_args(n):
        """后面还有 n 个**数字**参数（遇到命令字母即结束）。

        必须同时检查字符与个数：只看"不是字母"会让 M 的第二组参数
        被误当成新命令的参数，进而把 'L' 丢进 float() 崩掉。
        """
        return (i + n <= len(tokens)
                and all(not tokens[j].isalpha() for j in range(i, i + n)))

    while i < len(tokens):
        if tokens[i].isalpha():
            cmd = tokens[i]
            i += 1
        if cmd is None:
            break

        rel = cmd.islower()
        c = cmd.upper()
        need = _ARITY.get(c)
        if need is None:
            raise ValueError("不支持的 SVG path 命令: %r" % cmd)

        if c == "Z":
            if cur:
                cur.append(start)
                subs.append(cur)
                cur = []
            pos = start
            cmd = None                       # 相对基准回到 M 之前的状态
            last_cubic_ctrl = last_quad_ctrl = None
            continue

        # 参数不足则结束（容错截断，不静默画错）
        if not have_args(need):
            break
        nums = [float(tokens[i + k]) for k in range(need)]
        i += need

        if c == "M":
            x, y = nums
            if rel:
                x += pos[0]; y += pos[1]
            if cur:
                subs.append(cur)
            pos = (x, y)
            start = pos
            cur = [pos]
            # M 之后多余坐标组按隐式 L 处理（相对形式的 M 对应相对 l）
            cmd = "l" if rel else "L"
            last_cubic_ctrl = last_quad_ctrl = None
        elif c == "L":
            x, y = nums
            if rel:
                x += pos[0]; y += pos[1]
            pos = (x, y)
            cur.append(pos)
            last_cubic_ctrl = last_quad_ctrl = None
        elif c == "H":
            pos = (nums[0] + (pos[0] if rel else 0.0), pos[1])
            cur.append(pos)
            last_cubic_ctrl = last_quad_ctrl = None
        elif c == "V":
            pos = (pos[0], nums[0] + (pos[1] if rel else 0.0))
            cur.append(pos)
            last_cubic_ctrl = last_quad_ctrl = None
        elif c == "C":
            x1, y1, x2, y2, x, y = nums
            if rel:
                x1 += pos[0]; y1 += pos[1]
                x2 += pos[0]; y2 += pos[1]
                x += pos[0]; y += pos[1]
            ctrl2 = (x2, y2)
            cur.extend(_cubic(pos, (x1, y1), ctrl2, (x, y)))
            pos = (x, y)
            last_cubic_ctrl = ctrl2
            last_quad_ctrl = None
        elif c == "S":
            x2, y2, x, y = nums
            if rel:
                x2 += pos[0]; y2 += pos[1]
                x += pos[0]; y += pos[1]
            # 第一控制点是上一控制点关于当前点的反射
            c1 = (2 * pos[0] - last_cubic_ctrl[0],
                  2 * pos[1] - last_cubic_ctrl[1]) if last_cubic_ctrl else pos
            ctrl2 = (x2, y2)
            cur.extend(_cubic(pos, c1, ctrl2, (x, y)))
            pos = (x, y)
            last_cubic_ctrl = ctrl2
            last_quad_ctrl = None
        elif c == "Q":
            x1, y1, x, y = nums
            if rel:
                x1 += pos[0]; y1 += pos[1]
                x += pos[0]; y += pos[1]
            cur.extend(_quad(pos, (x1, y1), (x, y)))
            pos = (x, y)
            last_quad_ctrl = (x1, y1)
            last_cubic_ctrl = None
        elif c == "T":
            x, y = nums
            if rel:
                x += pos[0]; y += pos[1]
            c1 = (2 * pos[0] - last_quad_ctrl[0],
                  2 * pos[1] - last_quad_ctrl[1]) if last_quad_ctrl else pos
            cur.extend(_quad(pos, c1, (x, y)))
            pos = (x, y)
            last_quad_ctrl = c1
            last_cubic_ctrl = None
        elif c == "A":
            rx, ry, rot, laf, sf, x, y = nums
            if rel:
                x += pos[0]; y += pos[1]
            cur.extend(_arc(pos, rx, ry, rot, bool(laf), bool(sf), (x, y)))
            pos = (x, y)
            last_cubic_ctrl = last_quad_ctrl = None

    if cur:
        subs.append(cur)
    return subs


def parse_svg(path):
    """从 SVG 文件里取出所有 path/line 元素，返回子路径列表与 viewBox 尺寸。"""
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()

    vb = re.search(r'viewBox="([\d.\s-]+)"', src)
    if vb:
        nums = [float(n) for n in vb.group(1).split()]
        size = (nums[2], nums[3])
    else:
        size = (VIEWBOX, VIEWBOX)

    subs = []
    for m in re.finditer(r"<path\b[^>]*\bd=\"([^\"]+)\"", src):
        subs.extend(parse_path(m.group(1)))
    # 注意：`<line ...>` 可能带单独的结束标签，不一定是自闭合的 `<line ... />`。
    # 最初只匹配自闭合形式，导致两条羽枝被整段漏掉（静默少画，不报错）。
    for m in re.finditer(r"<line\b[^>]*>", src):
        tag = m.group(0)
        def attr(name):
            hit = re.search(r'\b%s="([\d.eE+-]+)"' % name, tag)
            return float(hit.group(1)) if hit else 0.0
        subs.append([(attr("x1"), attr("y1")), (attr("x2"), attr("y2"))])
    return subs, size


# ============================================================================
# 渲染
# ============================================================================

def _origin_geometry(src_svg):
    """读取按来源区分的几何与配色。

    为了让两条羽枝（Feather 的 line 元素）比轮廓细一点，这里把
    「只有两个点」的子路径视作羽枝，用更深的颜色和略细的线宽。
    """
    subs, vsize = parse_svg(src_svg)
    return subs, vsize


def _bounds(subs):
    xs = [p[0] for s in subs for p in s]
    ys = [p[1] for s in subs for p in s]
    return min(xs), min(ys), max(xs), max(ys)


def _bg_layer(canvas_px, radius_ratio):
    """画背景：圆角矩形 + 纵向渐变。"""
    bg = Image.new("RGBA", (canvas_px, canvas_px), (0, 0, 0, 0))
    grad = Image.new("RGBA", (1, canvas_px))
    for y in range(canvas_px):
        t = y / max(1, canvas_px - 1)
        grad.putpixel((0, y), tuple(
            round(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(4)
        ))
    grad = grad.resize((canvas_px, canvas_px))

    mask = Image.new("L", (canvas_px, canvas_px), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, canvas_px - 1, canvas_px - 1],
        radius=int(canvas_px * radius_ratio),
        fill=255,
    )
    bg.paste(grad, (0, 0), mask)
    return bg


def render(size, src_svg, bg=True):
    """渲染一张 size x size 的图标，返回 RGBA Image。"""
    ss = SUPERSAMPLE
    n = size * ss
    subs, vsize = _origin_geometry(src_svg)

    # ---- 把图形等比缩放居中到画布 ----
    x0, y0, x1, y1 = _bounds(subs)
    gw, gh = (x1 - x0), (y1 - y0)
    target = n * CONTENT_RATIO
    scale = min(target / gw, target / gh)
    off_x = (n - gw * scale) / 2 - x0 * scale
    off_y = (n - gh * scale) / 2 - y0 * scale

    def tx(pt):
        return (pt[0] * scale + off_x, pt[1] * scale + off_y)

    # 描边宽度按同一比例缩放；最小 1 像素，避免小尺寸下消失
    stroke_main = max(1.0, STROKE_UNITS * scale)
    stroke_barb = max(1.0, STROKE_UNITS * 0.8 * scale)
    r_main = stroke_main / 2
    r_barb = stroke_barb / 2

    if bg:
        img = _bg_layer(n, BG_RADIUS_RATIO)
    else:
        img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    layer = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)

    def stroke_polyline(pts, radius, color):
        if len(pts) < 2:
            if pts:
                x, y = pts[0]
                draw.ellipse([x - radius, y - radius, x + radius, y + radius],
                             fill=color)
            return
        draw.line(pts, fill=color, width=max(1, int(round(radius * 2))),
                  joint="curve")
        # 手动画圆头端点：Pillow 的 line 端点是方的
        for (x, y) in (pts[0], pts[-1]):
            draw.ellipse([x - radius, y - radius, x + radius, y + radius],
                         fill=color)

    # 先画羽毛外轮廓（点多的子路径），再画羽枝（两点的直线）。
    #
    # 注意：**不要填充轮廓**。Feather 的羽毛轮廓是一个开口的凹多边形，
    # 直接 fill 会把它变成一块实心三角形（看起来像帆，不像羽毛）。
    # 只描边才保留「羽毛」的形状。
    main_subs = [s for s in subs if len(s) > 2]
    barb_subs = [s for s in subs if len(s) <= 2]

    for s in main_subs:
        stroke_polyline([tx(p) for p in s], r_main, BROWN)

    # 羽枝压在外轮廓之上，否则会被轮廓的颜色盖住看不出来
    for s in barb_subs:
        stroke_polyline([tx(p) for p in s], r_barb, BROWN_DARK)

    img = Image.alpha_composite(img, layer)

    if ss > 1:
        img = img.resize((size, size), Image.LANCZOS)
    return img


# ============================================================================
# 输出各平台资源
# ============================================================================

ANDROID_DENSITIES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

ICO_SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    src_svg = os.path.join(here, "feather.svg")
    if not os.path.exists(src_svg):
        raise SystemExit("找不到 %s" % src_svg)

    os.makedirs(OUT_DIR, exist_ok=True)

    # 1) 各尺寸 PNG（带背景）—— Windows 资源与预览用
    for s in ICO_SIZES:
        render(s, src_svg, bg=USE_BACKGROUND).save(
            os.path.join(OUT_DIR, "icon-%d.png" % s))

    # 2) Windows .ico：Pillow 支持一次写入多尺寸，必须显式指定 sizes
    base = render(256, src_svg, bg=USE_BACKGROUND)
    base.save(os.path.join(OUT_DIR, "lightnote.ico"),
              format="ICO", sizes=[(s, s) for s in ICO_SIZES])

    # 3) Android mipmap
    for name, px in ANDROID_DENSITIES.items():
        d = os.path.join(OUT_DIR, "android", "mipmap-%s" % name)
        os.makedirs(d, exist_ok=True)
        render(px, src_svg, bg=USE_BACKGROUND).save(
            os.path.join(d, "ic_launcher.png"))

    # 4) App 内使用：透明背景 logo（AppBar / 关于页 / 空状态）
    render(512, src_svg, bg=False).save(
        os.path.join(OUT_DIR, "lightnote_logo.png"))

    # 5) 预览图：白底 + 深底并排，方便人眼确认小尺寸可读性
    sheet = Image.new("RGBA", (16 + 5 * 72, 2 * 72 + 24), (255, 255, 255, 255))
    for i, s in enumerate([16, 24, 32, 48, 64]):
        ic = render(s, src_svg, bg=USE_BACKGROUND)
        sheet.paste(ic, (16 + i * 72, 12), ic)
    dark = Image.new("RGBA", (16 + 5 * 72, 72), (28, 28, 30, 255))
    sheet.paste(dark, (0, 84))
    for i, s in enumerate([16, 24, 32, 48, 64]):
        ic = render(s, src_svg, bg=USE_BACKGROUND)
        sheet.paste(ic, (16 + i * 72, 84 + 4), ic)
    sheet.save(os.path.join(OUT_DIR, "preview.png"))

    print("OK -> %s" % OUT_DIR)


if __name__ == "__main__":
    main()
