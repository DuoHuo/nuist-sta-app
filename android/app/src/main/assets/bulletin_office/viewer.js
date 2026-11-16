var mimeBridge = window.OfficePreview;
var frame = document.querySelector('#document');
var message = document.querySelector('#message');
var select = document.querySelector('#views');
if (location.search === '?dark=1') document.body.classList.add('dark');

var ready = false;
var latestView;
var mime = '';

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
  frame.onload = function () {
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
