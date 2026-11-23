var mimeBridge = window.OfficePreview;
var frame = document.querySelector('#document');
var message = document.querySelector('#message');
var select = document.querySelector('#views');
if (location.search === '?dark=1') document.body.classList.add('dark');

var ready = false;
var latestView;
var mime = '';
var fitWordPages;

window.addEventListener('resize', function () {
  if (fitWordPages) fitWordPages();
});

function failed() {
  // 现代幻灯片的本地兼容预览还能显示引擎漏掉的图片。
  if (!ready || mime === 'application/vnd.openxmlformats-officedocument.presentationml.presentation') {
    mimeBridge.postMessage('failed');
    return;
  }
  message.textContent = '这部分内容无法预览';
  message.hidden = false;
}

function request(path, complete, onFailure) {
  var xhr = new XMLHttpRequest();
  xhr.open('GET', path);
  xhr.onload = function () {
    if (xhr.status === 200) complete(xhr.responseText);
    else onFailure();
  };
  xhr.onerror = onFailure;
  xhr.send();
}

function loadView(index) {
  latestView = index;
  message.hidden = true;
  request('view/' + index, function (html) {
    if (index === latestView) showDocument(html);
  }, function () {
    if (index === latestView) failed();
  });
}

select.onchange = function () {
  loadView(Number(select.value));
};

function prepareWordPages(parsed) {
  var children = Array.from(parsed.body.children);
  if (!children.some(function (child) { return child.hasAttribute('data-nuist-word-width'); })) {
    return false;
  }
  parsed.documentElement.classList.add('nuist-word-preview');
  if (document.body.classList.contains('dark')) parsed.documentElement.classList.add('dark');
  var style = parsed.createElement('style');
  style.textContent = `
    html.nuist-word-preview { background: #eef0f3; color-scheme: light; }
    html.nuist-word-preview.dark { background: #15161a; }
    html.nuist-word-preview body { margin: 0 !important; padding: 10px 0 8px; -webkit-text-size-adjust: 100%; }
    .nuist-word-page {
      box-sizing: content-box; display: flow-root; padding: 22px 18px 24px;
      margin: 0 auto 12px; background: #fff; color: #17191c;
      border-radius: 3px; box-shadow: 0 1px 5px rgba(20, 25, 33, .16);
    }
    .nuist-word-page > [data-nuist-word-width] { margin: 0 !important; }
  `;
  parsed.head.appendChild(style);

  var page;
  children.forEach(function (child) {
    var width = child.getAttribute('data-nuist-word-width');
    if (width !== null) {
      page = parsed.createElement('div');
      page.className = 'nuist-word-page';
      child.style.width = width + 'px';
      page.style.width = child.style.width;
      child.before(page);
    }
    // 转换器在末节后生成的注释等内容也保留在纸面上。
    if (page) page.appendChild(child);
  });
  return true;
}

function layoutWordPages(doc) {
  var pages = Array.from(doc.querySelectorAll('.nuist-word-page'));
  var widths = pages.map(function (page) {
    // 先按原版心排版，再把超出版心的表格或图片纳入纸面。
    return Math.max.apply(null, Array.from(page.children, function (child) {
      return Math.max(child.offsetWidth, child.scrollWidth);
    }));
  });
  pages.forEach(function (page, index) {
    page.style.width = widths[index] + 'px';
  });
  var paperWidths = pages.map(function (page) { return page.offsetWidth; });
  var lastWidth;
  return function () {
    var width = doc.documentElement.clientWidth;
    if (width <= 16 || width === lastWidth) return;
    lastWidth = width;
    pages.forEach(function (page, index) {
      // CSS 缩放会同时缩放布局尺寸，保持竖向滚动与页内查找正常。
      page.style.zoom = String(Math.min(1, (width - 16) / paperWidths[index]));
    });
  };
}

function showDocument(html) {
  // 解析到独立的文档中，只显示静态 DOM。正文仍是文本，便于选择和后续搜索。
  var parsed = new DOMParser().parseFromString(html, 'text/html');
  var active = parsed.querySelectorAll('script, iframe, frame, object, embed, form, link, meta[http-equiv]');
  Array.prototype.forEach.call(active, function (node) { node.remove(); });
  Array.prototype.forEach.call(parsed.querySelectorAll('a, area'), function (node) {
    node.removeAttribute('href');
    node.removeAttribute('xlink:href');
  });
  var content = parsed.body.cloneNode(true);
  Array.prototype.forEach.call(content.querySelectorAll('style'), function (node) { node.remove(); });
  if (!content.textContent.trim() &&
      !content.querySelector('img, svg, canvas, [style*="data:image"]')) {
    failed();
    return;
  }
  var policy = parsed.createElement('meta');
  policy.httpEquiv = 'Content-Security-Policy';
  policy.content = "default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:";
  parsed.head.insertBefore(policy, parsed.head.firstChild);
  var word = mime === 'application/msword' && prepareWordPages(parsed);
  fitWordPages = null;
  if (word) frame.style.visibility = 'hidden';
  frame.onload = function () {
    if (word) {
      var wordDocument = frame.contentDocument;
      if (!wordDocument.querySelector('.nuist-word-page')) return;
      fitWordPages = layoutWordPages(wordDocument);
      fitWordPages();
      frame.style.visibility = '';
    }
    message.hidden = true;
    if (!ready) {
      ready = true;
      mimeBridge.postMessage('ready:' + mime);
    }
  };
  frame.srcdoc = '<!doctype html>' + parsed.documentElement.outerHTML;
}

request('views?width=' + window.innerWidth, function (metadata) {
  try {
    var data = JSON.parse(metadata);
    mime = data.mime;
    data.views.forEach(function (name, index) {
      var label = name || (data.sheets ? '工作表 ' : '幻灯片 ') + (index + 1);
      select.add(new Option(label, String(index)));
    });
    select.hidden = select.options.length < 2;
    loadView(0);
  } catch (_) {
    failed();
  }
}, failed);
