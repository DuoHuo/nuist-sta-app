/* ============================================================================
 *  DeepSeek 鲸鱼 · 粒子交互   纯静态实现（无依赖、无构建、无网络请求）
 *
 *  1) 把 index.html 里的官方鲸鱼轮廓（50×50 的 SVG path）栅格化成母版位图；
 *  2) 用「到轮廓边缘的距离」做加权采样 —— 边缘更密、内部更疏，轮廓最清晰；
 *  3) 粒子绕家庭位置做缓慢呼吸漂移，整只鲸鱼像在游动；
 *  4) 光标划过时把粒子推开（推力 = 距离柔化 × 光标速度），离开后弹簧阻尼回位，
 *     于是形成「划过去 → 粒子被拨开再聚拢」的手感；点击则是冲击波。
 * ==========================================================================*/
(function () {
  'use strict';

  /* ---------------------------------------------------------------- 参数 */
  var CONFIG = {
    /* 粒子规模 */
    basePoints: 7200,          // 1920×1080 上的基准粒子数，按屏幕面积伸缩
    minPoints: 1500,
    maxPoints: 11000,
    fillRatio: 0.42,           // 粒子预算中用于填充内部的占比（其余给轮廓边缘）
    edgeFalloffRef: 4.5,       // 距离场加权衰减尺度（以 masterSize 为基准，用前按位图尺寸等比缩放）
    masterSize: 380,           // 轮廓母版位图边长

    /* 版式 */
    sizeFactor: 0.68,          // 鲸鱼边长 ≈ min(视口宽, 视口高) × 系数
    minSize: 260,
    maxSize: 780,
    centerX: 0.5,
    centerY: 0.5,

    /* 运动 */
    driftAmp: 1.9,             // 呼吸漂移幅度（px）
    driftSpeed: 0.55,
    shimmerAmp: 0.34,          // 逐粒子亮度闪烁
    stiff: 52,                 // 回位弹簧刚度
    damp: 7.5,                 // 阻尼

    /* 光标交互
     * 力的量纲：applyPush 里 v += F * 1/60，即「每帧给粒子的最大速度增量 = F/60 px/s」。
     * 下面数值由离线物理仿真标定（把本文件的物理函数抽到 Node 里跑）：
     * 划速 600px/s → 峰值偏移 23.7px；200~400px/s → 72.8px（触安全上限）；
     * 1500px/s → 10.8px；点击冲击波 → 51.9px；均在 0.4s 内回位。 */
    influence: 104,            // 影响半径（px）
    minInfluence: 58,
    push: 38000,               // 基础推力
    velocityPush: 0.95,        // 光标速度对推力的加成
    maxPush: 6500,             // 单粒子每帧推力上限（F/60 ≈ 108 px/s 速度增量）
    swirl: 0.28,               // 切向涡流，粒子绕光标两侧滑走
    wake: 0.45,                // 尾迹拖拽强度
    wakeReach: 300,            // 尾迹拖拽半径（px）
    gridMargin: 26,            // 空间网格查询外扩
    maxStretch: 0.7,           // 位移硬上限 = influence × 系数
    burstPower: 1350000,       // 点击冲击波强度
    burstRadius: 176,          // 点击冲击波半径

    /* 显示 */
    trailAlpha: 0.5,           // 每帧背景清洗的不透明度（<1 会留下轻微拖尾）
    spriteScale: 2.8           // 光斑贴图相对粒子半径的尺寸（越大越柔、叠加越亮）
  };

  /* 调色板：鲸头深靛蓝 → 青 → 鲸尾亮蓝，单条线性 sRGB 渐变等距取色 */
  var GRADIENT_STOPS = [
    [0.00, 0x1a1466], [0.26, 0x2b3fb4], [0.55, 0x2f8fe0],
    [0.80, 0x3fd0f0], [1.00, 0x9df4ff]
  ];
  var BANDS = 16;                         // 横向色带数
  var LEVELS = 6;                         // 每色带的亮度档数
  var BUCKETS = BANDS * LEVELS;
  var PALETTE = buildPalette();

  var coreSprite = null;                  // 粒子光斑（预渲染一次，之后只做位图拷贝）
  var cursorSprite = null;

  /* ------------------------------------------------------------- DOM 环境 */
  var canvas = document.getElementById('stage');
  var ctx = canvas ? canvas.getContext('2d', { alpha: true }) : null;
  var fallbackEl = document.getElementById('fallback');
  var masterSvg = document.getElementById('whale-master');

  if (!ctx) { fail('浏览器不支持 Canvas 2D。'); return; }

  var dpr = 1, W = 0, H = 0;              // 视口尺寸（CSS 像素）
  var points = null;                      // 采样点：{nx, ny, u, d}
  var count = 0;

  /* 粒子状态（扁平数组，避免上万个临时对象） */
  var hx, hy, px, py, vx, vy, pR, pGC, pW, seedA, seedB;

  /* 空间网格：按家庭位置分桶，只在光标附近的桶里找粒子 */
  var gridHead = null, gridItems = null, gCols = 0, gRows = 0, gCell = 1, gMinX = 0, gMinY = 0;
  var nearIds = null;                     // 查询结果缓冲

  var buckets = [];                       // 绘制分桶
  for (var bi = 0; bi < BUCKETS; bi++) buckets.push([]);

  /* 时间 / 光标 */
  var t = 0, last = 0, raf = 0, running = true, keys = {};
  var ptr = {
    x: -1e5, y: -1e5, px: -1e5, py: -1e5, vx: 0, vy: 0,
    active: false, down: false, ringR: 0, ringAlpha: 0
  };
  var mouse = { influence: CONFIG.influence, energy: 0 };

  /* -------------------------------------------------------------- 小工具 */
  function clamp(v, a, b) { return v < a ? a : (v > b ? b : v); }
  function mix(a, b, k) { return a + (b - a) * k; }

  function hexToRgb(hex) {
    return [(hex >> 16) & 255, (hex >> 8) & 255, hex & 255];
  }

  function sampleStops(u) {
    u = clamp(u, 0, 1);
    var i, span, k;
    for (i = 0; i < GRADIENT_STOPS.length - 1; i++) {
      if (u <= GRADIENT_STOPS[i + 1][0]) {
        span = GRADIENT_STOPS[i + 1][0] - GRADIENT_STOPS[i][0];
        k = span > 0 ? (u - GRADIENT_STOPS[i][0]) / span : 0;
        var a = hexToRgb(GRADIENT_STOPS[i][1]);
        var b = hexToRgb(GRADIENT_STOPS[i + 1][1]);
        return [mix(a[0], b[0], k), mix(a[1], b[1], k), mix(a[2], b[2], k)];
      }
    }
    return hexToRgb(GRADIENT_STOPS[GRADIENT_STOPS.length - 1][1]);
  }

  /* 只有靠近光标的粒子才会用到高亮档，所以亮度分档比逐粒子改样式便宜得多 */
  function buildPalette() {
    var out = [], b, g, rgb, boost, white;
    for (b = 0; b < BANDS; b++) {
      rgb = sampleStops(BANDS > 1 ? b / (BANDS - 1) : 0);
      for (g = 0; g < LEVELS; g++) {
        boost = 1 + g * 0.18;                       // 越亮 = 越靠近光标
        white = Math.max(0, g - 2) * 0.14;          // 最亮的两档偏白
        out.push('rgba(' +
          Math.round(clamp(mix(rgb[0] * boost, 235, white), 0, 255)) + ',' +
          Math.round(clamp(mix(rgb[1] * boost, 245, white), 0, 255)) + ',' +
          Math.round(clamp(mix(rgb[2] * boost, 255, white), 0, 255)) + ',' +
          (0.5 + g * 0.066).toFixed(2) + ')');
      }
    }
    return out;
  }

  function fail(msg) {
    if (fallbackEl) { fallbackEl.textContent = msg; fallbackEl.hidden = false; }
  }

  /* ================================================ 1. 轮廓 → 母版位图 */
  /* 官方路径只用到 M / L / C / Z（绝对坐标），所以给没有 Path2D 的浏览器留一个极简解析 */
  function parsePathD(d) {
    var p = new Path2D();
    var re = /([MLCZmlcz])|(-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)/g, tk = [], mm;
    while ((mm = re.exec(d))) tk.push(mm[1] || parseFloat(mm[2]));
    var i = 0, cx = 0, cy = 0, sx = 0, sy = 0, last = '';
    function num() { return tk[i++]; }
    while (i < tk.length) {
      var cmd = (typeof tk[i] === 'string') ? tk[i++] : last;
      if (cmd === 'M') {
        cx = num(); cy = num(); sx = cx; sy = cy;
        p.moveTo(cx, cy);
      } else if (cmd === 'L') {
        cx = num(); cy = num();
        p.lineTo(cx, cy);
      } else if (cmd === 'C') {
        var x1 = num(), y1 = num(), x2 = num(), y2 = num(), x3 = num(), y3 = num();
        p.bezierCurveTo(x1, y1, x2, y2, x3, y3);
        cx = x3; cy = y3;
      } else if (cmd === 'Z' || cmd === 'z') {
        p.closePath(); cx = sx; cy = sy;
      } else if (cmd === 'c') {
        var rx1 = cx + num(), ry1 = cy + num(), rx2 = cx + num(), ry2 = cy + num();
        var rx3 = cx + num(), ry3 = cy + num();
        p.bezierCurveTo(rx1, ry1, rx2, ry2, rx3, ry3);
        cx = rx3; cy = ry3;
      } else if (cmd === 'm' || cmd === 'l') {
        var ax = cx + num(), ay = cy + num();
        if (cmd === 'm') { p.moveTo(ax, ay); sx = ax; sy = ay; } else { p.lineTo(ax, ay); }
        cx = ax; cy = ay;
      } else {
        break;                                  // 出现不支持的指令就停手，已解析部分照样能用
      }
      last = cmd;
    }
    return p;
  }

  function buildPath(d) {
    if (typeof Path2D === 'function') {
      try { return new Path2D(d); } catch (e) { /* 落到下面的解析器 */ }
    }
    return parsePathD(d);
  }

  function rasterize(pathD, size) {
    var c = document.createElement('canvas');
    c.width = size; c.height = size;
    var g = c.getContext('2d');
    g.fillStyle = '#000';
    g.fill(buildPath(pathD));             // fill 默认 nonzero，与官方图标一致
    return g.getImageData(0, 0, size, size);
  }

  /* 两遍 Chamfer 距离场：每个实体像素到最近背景像素的近似欧氏距离 */
  function distanceField(mask, size) {
    var BIG = 1e4, i, x, y, k, best, dk;
    var d = new Float32Array(size * size);
    for (i = 0; i < d.length; i++) d[i] = mask[i] ? BIG : 0;

    for (y = 0; y < size; y++) {
      for (x = 0; x < size; x++) {
        k = y * size + x;
        if (d[k] === 0) continue;
        best = d[k];
        if (x > 0) best = Math.min(best, d[k - 1] + 1);
        if (y > 0) best = Math.min(best, d[k - size] + 1);
        if (x > 0 && y > 0) best = Math.min(best, d[k - size - 1] + 1.414);
        if (x < size - 1 && y > 0) best = Math.min(best, d[k - size + 1] + 1.414);
        d[k] = best;
      }
    }
    for (y = size - 1; y >= 0; y--) {
      for (x = size - 1; x >= 0; x--) {
        k = y * size + x;
        dk = d[k];
        if (dk === 0) continue;
        if (x < size - 1) dk = Math.min(dk, d[k + 1] + 1);
        if (y < size - 1) dk = Math.min(dk, d[k + size] + 1);
        if (x < size - 1 && y < size - 1) dk = Math.min(dk, d[k + size + 1] + 1.414);
        if (x > 0 && y < size - 1) dk = Math.min(dk, d[k + size - 1] + 1.414);
        d[k] = dk;
      }
    }
    return d;
  }

  /* 采样：内部均匀抽 fillRatio，其余按边缘权重抽（拒绝采样） */
  function samplePoints(mask, dist, size, need) {
    var wantFill = Math.round(need * CONFIG.fillRatio);
    var out = new Float32Array(need * 3);
    // 距离是以母版像素为单位的：等比缩放到标定尺度，换分辨率也不会改变疏密手感
    var falloff = CONFIG.edgeFalloffRef * (size / 260);
    var n = 0, i, tries = 0;

    while (n < wantFill && tries < wantFill * 80) {           /* —— 内部填充 */
      tries++;
      i = (Math.random() * mask.length) | 0;
      if (!mask[i]) continue;
      out[n * 3] = i % size;
      out[n * 3 + 1] = (i / size) | 0;
      out[n * 3 + 2] = dist[i];
      n++;
    }

    var bins = 160, maxD = 0;                                 /* —— 边缘加权 */
    for (i = 0; i < dist.length; i++) if (mask[i] && dist[i] > maxD) maxD = dist[i];
    maxD = Math.max(1, maxD);

    var cdf = new Float32Array(bins), acc = 0, bin;
    for (i = 0; i < dist.length; i++) {
      if (!mask[i]) continue;
      acc += Math.exp(-dist[i] / falloff);
      bin = Math.min(bins - 1, ((dist[i] / maxD) * bins) | 0);
      cdf[bin] += acc;                       // 累积权重按 bin 记录
    }
    var total = cdf[bins - 1] || 1;
    for (i = 0; i < bins; i++) cdf[i] /= total;   // → 归一化累积分布

    tries = 0;
    while (n < need && tries < need * 400) {
      tries++;
      i = (Math.random() * mask.length) | 0;
      if (!mask[i]) continue;
      var w = Math.exp(-dist[i] / falloff);
      // 先按 bin 的累积分布粗筛（便宜），再接受/拒绝（精确）
      bin = Math.min(bins - 1, ((dist[i] / maxD) * bins) | 0);
      if (Math.random() < cdf[bin] && Math.random() < w) {
        out[n * 3] = i % size;
        out[n * 3 + 1] = (i / size) | 0;
        out[n * 3 + 2] = dist[i];
        n++;
      }
    }

    var guard = 0;                                            /* —— 兜底补齐 */
    while (n < need && guard < mask.length) {
      i = guard++;
      if (!mask[i]) continue;
      out[n * 3] = i % size;
      out[n * 3 + 1] = (i / size) | 0;
      out[n * 3 + 2] = dist[i];
      n++;
    }
    return { data: out, used: n };
  }

  /* 等比居中归一化到 [-0.5,0.5]，并记录横向参数 u 用于配色 */
  function normalize(pts) {
    var d = pts.data, n = pts.used, i;
    var minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
    for (i = 0; i < n; i++) {
      if (d[i * 3] < minX) minX = d[i * 3];
      if (d[i * 3] > maxX) maxX = d[i * 3];
      if (d[i * 3 + 1] < minY) minY = d[i * 3 + 1];
      if (d[i * 3 + 1] > maxY) maxY = d[i * 3 + 1];
    }
    var span = Math.max(1e-3, Math.max(maxX - minX, maxY - minY));
    var cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
    var list = [];
    for (i = 0; i < n; i++) {
      list.push({
        nx: (d[i * 3] - cx) / span,          // -0.5 … 0.5
        ny: (d[i * 3 + 1] - cy) / span,
        u: (d[i * 3] - minX) / span,         // 0 = 鲸头 … 1 = 鲸尾尖
        d: d[i * 3 + 2]
      });
    }
    return list;
  }

  /* ================================================== 2. 预渲染光斑贴图 */
  function makeCoreSprite(radius) {
    var s = Math.max(8, Math.ceil(radius * 14));
    var c = document.createElement('canvas');
    c.width = c.height = s;
    var g = c.getContext('2d');
    var r = s / 2;
    var grad = g.createRadialGradient(r, r, 0, r, r, r);
    grad.addColorStop(0.00, 'rgba(255,255,255,1)');
    grad.addColorStop(0.15, 'rgba(255,255,255,0.9)');
    grad.addColorStop(0.38, 'rgba(255,255,255,0.3)');
    grad.addColorStop(0.72, 'rgba(255,255,255,0.075)');
    grad.addColorStop(1.00, 'rgba(255,255,255,0)');
    g.fillStyle = grad;
    g.beginPath();
    g.arc(r, r, r, 0, Math.PI * 2);
    g.fill();
    return c;
  }

  function makeCursorSprite(size) {
    var c = document.createElement('canvas');
    c.width = c.height = size;
    var g = c.getContext('2d');
    var r = size / 2;
    var grad = g.createRadialGradient(r, r, 0, r, r, r);
    grad.addColorStop(0.00, 'rgba(200,235,255,0.34)');
    grad.addColorStop(0.5, 'rgba(120,175,255,0.12)');
    grad.addColorStop(1.00, 'rgba(90,140,255,0)');
    g.fillStyle = grad;
    g.beginPath();
    g.arc(r, r, r, 0, Math.PI * 2);
    g.fill();
    return c;
  }

  /* ====================================================== 3. 布局与网格 */
  function layout() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    W = Math.max(320, window.innerWidth || 320);
    H = Math.max(320, window.innerHeight || 320);
    canvas.width = Math.round(W * dpr);
    canvas.height = Math.round(H * dpr);
    canvas.style.width = W + 'px';
    canvas.style.height = H + 'px';
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    var side = clamp(Math.min(W, H) * CONFIG.sizeFactor, CONFIG.minSize, CONFIG.maxSize);
    var cx = W * CONFIG.centerX, cy = H * CONFIG.centerY;
    var i;

    for (i = 0; i < count; i++) {
      hx[i] = cx + points[i].nx * side;
      hy[i] = cy + points[i].ny * side;
      px[i] = hx[i]; py[i] = hy[i]; vx[i] = 0; vy[i] = 0;
    }

    var base = clamp(Math.round(side / 150), 2, 4);          // 粒子尺寸随屏幕缩放
    var radius = clamp(base * 0.5 + 0.55, 1.1, 3.4);
    coreSprite = makeCoreSprite(radius);
    cursorSprite = makeCursorSprite(220);
    for (i = 0; i < count; i++) pR[i] = radius * (0.78 + Math.random() * 0.44);

    buildGrid();
    mouse.influence = Math.max(CONFIG.minInfluence,
      CONFIG.influence * clamp(Math.min(W, H) / 900, 0.62, 1.3));
  }

  function buildGrid() {
    gCell = Math.max(24, CONFIG.influence * 0.5 + CONFIG.gridMargin);
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity, i, k, c, r;
    for (i = 0; i < count; i++) {
      if (hx[i] < minX) minX = hx[i];
      if (hx[i] > maxX) maxX = hx[i];
      if (hy[i] < minY) minY = hy[i];
      if (hy[i] > maxY) maxY = hy[i];
    }
    gMinX = minX - gCell * 2;
    gMinY = minY - gCell * 2;
    gCols = Math.max(1, Math.ceil((maxX - gMinX) / gCell) + 1);
    gRows = Math.max(1, Math.ceil((maxY - gMinY) / gCell) + 1);

    var cells = gCols * gRows;
    var cellIdx = new Int32Array(count);
    var counts = new Int32Array(cells + 1);
    for (i = 0; i < count; i++) {
      c = clamp(((hx[i] - gMinX) / gCell) | 0, 0, gCols - 1);
      r = clamp(((hy[i] - gMinY) / gCell) | 0, 0, gRows - 1);
      k = r * gCols + c;
      cellIdx[i] = k;
      counts[k + 1]++;
    }
    for (i = 0; i < cells; i++) counts[i + 1] += counts[i];   // → 前缀和（每桶区间）
    gridHead = counts;
    gridItems = new Int32Array(count);
    var cursor = counts.slice(0, cells);
    for (i = 0; i < count; i++) gridItems[cursor[cellIdx[i]]++] = i;
    if (!nearIds || nearIds.length < count) nearIds = new Int32Array(count);
  }

  /* 收集光标附近桶内的粒子；结果复用同一块缓冲，零分配 */
  function collect(x, y, reach) {
    if (!gridHead) return nearIds.subarray(0, 0);
    var c0 = clamp(((x - reach - gMinX) / gCell) | 0, 0, gCols - 1);
    var c1 = clamp(((x + reach - gMinX) / gCell) | 0, 0, gCols - 1);
    var r0 = clamp(((y - reach - gMinY) / gCell) | 0, 0, gRows - 1);
    var r1 = clamp(((y + reach - gMinY) / gCell) | 0, 0, gRows - 1);
    var k = 0, r, c, i;
    for (r = r0; r <= r1; r++) {
      for (c = c0; c <= c1; c++) {
        var base = r * gCols + c;
        for (i = gridHead[base]; i < gridHead[base + 1]; i++) nearIds[k++] = gridItems[i];
      }
    }
    return nearIds.subarray(0, k);
  }

  /* ======================================================== 4. 构建粒子云 */
  function build() {
    // 先把视口/画布尺寸确定下来，后面才按屏幕面积决定粒子数量
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    W = Math.max(320, window.innerWidth || 320);
    H = Math.max(320, window.innerHeight || 320);

    var pathD = null;
    if (masterSvg) {
      var p = masterSvg.querySelector('path');
      if (p) pathD = p.getAttribute('d');
    }
    if (!pathD) { fail('未找到鲸鱼轮廓路径。'); return false; }

    var size = CONFIG.masterSize;
    var img;
    try {
      img = rasterize(pathD, size);
    } catch (e) {
      fail('SVG 轮廓栅格化失败：' + e.message);
      return false;
    }

    var mask = new Uint8Array(size * size), kept = 0, i;
    for (i = 0; i < mask.length; i++) {
      if (img.data[i * 4 + 3] > 124) { mask[i] = 1; kept++; }
    }
    if (kept < 400) { fail('鲸鱼轮廓为空。'); return false; }

    var need = clamp(Math.round(CONFIG.basePoints * (W * H) / (1920 * 1080)),
      CONFIG.minPoints, CONFIG.maxPoints);
    if (Math.min(W, H) < 620) need = Math.min(need, 2400);

    var pts = samplePoints(mask, distanceField(mask, size), size, need);
    points = normalize(pts);
    count = points.length;

    hx = new Float32Array(count); hy = new Float32Array(count);
    px = new Float32Array(count); py = new Float32Array(count);
    vx = new Float32Array(count); vy = new Float32Array(count);
    pR = new Float32Array(count); pGC = new Uint8Array(count); pW = new Float32Array(count);
    seedA = new Float32Array(count); seedB = new Float32Array(count);

    for (i = 0; i < count; i++) {
      seedA[i] = Math.random() * Math.PI * 2;
      seedB[i] = 0.55 + Math.random() * 0.9;
      pW[i] = points[i].d < 1.35 ? 0.45 : 0;   // 轮廓外缘常态就亮一档 → 描边感
    }

    layout();
    ctx.clearRect(0, 0, W, H);

    // 调试/嵌入用的小接口
    window.__whale = {
      config: CONFIG,
      get count() { return count; },
      get points() { return points; }
    };
    return true;
  }

  /* ============================================================ 5. 交互 */
  function setPointer(x, y) {
    ptr.x = x; ptr.y = y;
    if (!ptr.active) {
      ptr.active = true; ptr.px = x; ptr.py = y; ptr.vx = 0; ptr.vy = 0;
      document.body.classList.add('is-drawing');
    }
  }

  /* 点击冲击波：半径内粒子获得径向瞬时速度 */
  function burst(bx, by, power, radius) {
    var ids = collect(bx, by, radius);
    var i, id, dx, dy, d2, d, f, len = ids.length;
    for (i = 0; i < len; i++) {
      id = ids[i];
      dx = px[id] - bx; dy = py[id] - by;
      d2 = dx * dx + dy * dy;
      if (d2 > radius * radius) continue;
      d = Math.sqrt(d2) || 1e-3;
      f = (1 - d / radius) * power / Math.max(30, d);
      vx[id] += (dx / d) * f * 0.016;
      vy[id] += (dy / d) * f * 0.016;
    }
  }

  /* 核心手感：距离柔化 × 光标速度 → 推力，再加切向涡流与尾迹拖拽 */
  function applyPush(ids, len, x, y, pvx, pvy, speed, scale) {
    var R = mouse.influence;
    var R2 = R * R;
    var hard = R * 1.22;
    var sp = clamp(speed / 42, 0.28, 1);                  // 静止悬停也有轻微排开
    var base = CONFIG.push * (0.55 + CONFIG.velocityPush * sp) * (scale || 1);
    var vlen = speed > 1e-3 ? speed : 1;
    var ux = pvx / vlen, uy = pvy / vlen;                 // 光标运动方向（尾迹）
    var i, id, dx, dy, d2, d2s, d, f, nx, ny, tx, ty, side, w;

    for (i = 0; i < len; i++) {
      id = ids[i];
      dx = px[id] - x; dy = py[id] - y;
      d2 = dx * dx + dy * dy;
      if (d2 > R2 * 1.45) continue;
      d = Math.sqrt(d2);
      if (d > hard) continue;
      d2s = d2 + 200;                                     // 软化核，避免近距离除零
      f = base * (R2 / (d2s * d2s)) * (1 - d / hard);
      if (f <= 0) continue;
      if (f > CONFIG.maxPush) f = CONFIG.maxPush;
      if (d < 1e-3) d = 1e-3;
      nx = dx / d; ny = dy / d;

      vx[id] += nx * f * 0.016;                           // 径向推开
      vy[id] += ny * f * 0.016;

      tx = -ny; ty = nx;                                  // 切向涡流
      side = (tx * ux + ty * uy) >= 0 ? 1 : -1;
      vx[id] += tx * f * CONFIG.swirl * side * 0.016;
      vy[id] += ty * f * CONFIG.swirl * side * 0.016;

      if (speed > 30) {                                   // 尾迹拖拽
        w = clamp(1 - d / CONFIG.wakeReach, 0, 1) * CONFIG.wake * (speed / 900);
        vx[id] += ux * f * w * 0.016;
        vy[id] += uy * f * w * 0.016;
      }
    }
  }

  function bindInput() {
    window.addEventListener('pointermove', function (e) {
      setPointer(e.clientX, e.clientY);
    }, { passive: true });

    window.addEventListener('pointerdown', function (e) {
      setPointer(e.clientX, e.clientY);
      ptr.down = true;
      burst(e.clientX, e.clientY, CONFIG.burstPower, CONFIG.burstRadius);
    }, { passive: true });

    window.addEventListener('pointerup', function () { ptr.down = false; }, { passive: true });
    window.addEventListener('pointercancel', function () { ptr.down = false; }, { passive: true });

    function leave() {
      ptr.active = false; ptr.vx = 0; ptr.vy = 0;
      document.body.classList.remove('is-drawing');
    }
    window.addEventListener('pointerleave', leave, { passive: true });
    window.addEventListener('blur', leave);

    // 键盘也能玩：方向键 / WASD 移动光标，空格爆开
    window.addEventListener('keydown', function (e) {
      keys[e.key] = true;
      if (e.key === ' ' || e.key === 'Spacebar' || e.key === 'Enter') {
        if (!ptr.active) setPointer(W / 2, H / 2);
        burst(ptr.x, ptr.y, CONFIG.burstPower * 1.15, CONFIG.burstRadius);
      }
    });
    window.addEventListener('keyup', function (e) { keys[e.key] = false; });
  }

  /* ============================================================ 6. 主循环 */
  function step(dt) {
    var i, k, len;

    /* 光标速度（指数平滑，抗抖动） */
    if (ptr.active) {
      var ivx = (ptr.x - ptr.px) / Math.max(dt, 1 / 240);
      var ivy = (ptr.y - ptr.py) / Math.max(dt, 1 / 240);
      ptr.vx = mix(ptr.vx, clamp(ivx, -4200, 4200), 0.42);
      ptr.vy = mix(ptr.vy, clamp(ivy, -4200, 4200), 0.42);
      ptr.px = ptr.x; ptr.py = ptr.y;
    } else {
      ptr.vx *= 0.86; ptr.vy *= 0.86;
    }

    /* 键盘操控光标 */
    var kx = 0, ky = 0;
    if (keys.ArrowLeft || keys.a || keys.A) kx -= 1;
    if (keys.ArrowRight || keys.d || keys.D) kx += 1;
    if (keys.ArrowUp || keys.w || keys.W) ky -= 1;
    if (keys.ArrowDown || keys.s || keys.S) ky += 1;
    if (kx || ky) {
      if (!ptr.active) setPointer(W / 2, H / 2);
      var kn = 780 * dt;
      ptr.x = clamp(ptr.x + kx * kn, 0, W);
      ptr.y = clamp(ptr.y + ky * kn, 0, H);
    }

    /* 光标推开（作用范围要覆盖被甩到远处的粒子） */
    var speed = Math.sqrt(ptr.vx * ptr.vx + ptr.vy * ptr.vy);
    if (ptr.active) {
      var reach = mouse.influence * (1 + CONFIG.maxStretch) + CONFIG.gridMargin;
      var ids = collect(ptr.x, ptr.y, reach);
      applyPush(ids, ids.length, ptr.x, ptr.y, ptr.vx, ptr.vy, speed, ptr.down ? 1.15 : 1);
    }

    /* 物理积分 + 亮度分档 */
    var stiff = CONFIG.stiff, dampK = CONFIG.damp, amp = CONFIG.driftAmp, sp = CONFIG.driftSpeed;
    var maxOff = mouse.influence * CONFIG.maxStretch, maxOff2 = maxOff * maxOff;
    var cr = mouse.influence * 1.25, cr2 = cr * cr;
    var energy = 0;

    for (i = 0; i < count; i++) {
      var ph = t * sp * seedB[i] + seedA[i];
      var dxs = px[i] - hx[i] + Math.cos(ph) * amp;
      var dys = py[i] - hy[i] + Math.sin(ph * 1.17) * amp;
      vx[i] -= dxs * stiff * dt;
      vy[i] -= dys * stiff * dt;
      var dmp = Math.exp(-dampK * dt);
      vx[i] *= dmp; vy[i] *= dmp;
      px[i] += vx[i] * dt;
      py[i] += vy[i] * dt;

      var ox = px[i] - hx[i], oy = py[i] - hy[i];
      var o2 = ox * ox + oy * oy;
      if (o2 > maxOff2) {                       // 拉扯过度 → 柔性拉回
        var s = maxOff / Math.sqrt(o2);
        px[i] = hx[i] + ox * s;
        py[i] = hy[i] + oy * s;
        vx[i] *= 0.55; vy[i] *= 0.55;
        o2 = maxOff2;
      }

      var g = 0;
      if (ptr.active) {
        var cdx = px[i] - ptr.x, cdy = py[i] - ptr.y;
        var cd2 = cdx * cdx + cdy * cdy;
        if (cd2 < cr2) {
          g = (1 - Math.sqrt(cd2) / cr) * 3.4;
          energy += g;
        }
      }
      g += Math.sqrt(o2) / (maxOff + 1) * 1.9;                    // 被拨开的粒子亮起来
      g += pW[i];                                                  // 轮廓描边
      g += Math.sin(t * 1.9 + seedA[i] * 3.1) * CONFIG.shimmerAmp;  // 闪烁
      pGC[i] = g <= 0 ? 0 : (g >= LEVELS - 1 ? LEVELS - 1 : g | 0);
    }
    mouse.energy = energy;

    ptr.ringR = mix(ptr.ringR, ptr.active ? 24 + Math.min(34, speed / 55) : 0, 0.12);
    ptr.ringAlpha = mix(ptr.ringAlpha, ptr.active ? 1 : 0, 0.08);
  }

  function draw() {
    /* 背景清洗：留一点拖尾，粒子轨迹更顺滑 */
    ctx.globalCompositeOperation = 'source-over';
    ctx.fillStyle = 'rgba(5,7,16,' + CONFIG.trailAlpha + ')';
    ctx.fillRect(0, 0, W, H);

    ctx.globalCompositeOperation = 'lighter';

    /* 光标柔光 */
    if (cursorSprite && ptr.ringAlpha > 0.02) {
      var cs = cursorSprite.width * 0.5 * (0.72 + Math.min(0.5, ptr.ringR / 120));
      ctx.globalAlpha = 0.6 * ptr.ringAlpha;
      ctx.drawImage(cursorSprite, ptr.x - cs, ptr.y - cs, cs * 2, cs * 2);
      ctx.globalAlpha = 1;
    }

    /* 粒子：按 (色带 × 亮度档) 分桶，一批只切一次状态 */
    var i, b, list, k, id, half, col, sImg = coreSprite;
    for (b = 0; b < BUCKETS; b++) buckets[b].length = 0;
    for (i = 0; i < count; i++) {
      var u = points[i].u;
      b = (u >= 0.9999 ? BANDS - 1 : (u * BANDS) | 0) * LEVELS + pGC[i];
      buckets[b].push(i);
    }
    for (b = 0; b < BUCKETS; b++) {
      list = buckets[b];
      k = list.length;
      if (!k) continue;
      col = PALETTE[b];
      if (ctx.fillStyle !== col) ctx.fillStyle = col;
      for (i = 0; i < k; i++) {
        id = list[i];
        half = pR[id] * CONFIG.spriteScale;
        ctx.drawImage(sImg, px[id] - half, py[id] - half, half * 2, half * 2);
      }
    }

    ctx.globalCompositeOperation = 'source-over';
  }

  function frame(now) {
    raf = requestAnimationFrame(frame);
    if (!last) last = now;
    var dt = (now - last) / 1000;
    last = now;
    if (dt > 0.05) dt = 0.05;                 // 切回标签页时不要暴走
    if (dt <= 0) dt = 1 / 60;
    t += dt;
    if (!running) return;
    step(dt);
    draw();
  }

  /* ============================================================== 7. 启动 */
  var resizeTimer = 0;
  window.addEventListener('resize', function () {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () { layout(); }, 140);
  });

  document.addEventListener('visibilitychange', function () {
    running = !document.hidden;
    last = 0;
  });

  if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    CONFIG.driftAmp = 0.5;
    CONFIG.shimmerAmp = 0.06;
    CONFIG.trailAlpha = 0.92;
  }

  bindInput();
  if (build()) raf = requestAnimationFrame(frame);
})();
