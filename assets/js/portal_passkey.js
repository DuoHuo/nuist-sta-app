(() => {
  "use strict";

  /*
   * NUIST 统一门户软件通行密钥注册脚本（APP 内嵌 WebView 注入版）。
   * 改造自 authserver_login/browser_passkey.js，去掉了控制台交互，改为通过
   * JavaScriptChannel `NuistPasskey` 向 Dart 汇报进度 / 结果 / 错误。
   *
   * 流程：
   *   0. Android WebView 没有 window.PublicKeyCredential / navigator.credentials，
   *      页面会判定“浏览器不支持”而不渲染通行密钥列表。先补一份「存在但永远拒绝」
   *      的实现，再把 SPA 路由到 #/accountsecurity（若已在该页则先离开再进入，
   *      让组件重新检测）。
   *   1. 切到「生物识别」子 tab（不体现在 hash 上），等待「绑定当前设备」按钮渲染出来。
   *   2. GET /personalInfo/common/isUserRecheckNecessary
   *        code === "0"          -> 无需二次验证，直接进入注册。
   *        其它（如 2106010002）  -> 模拟点击「绑定当前设备」，触发页面自带的
   *        身份验证（登录密码 + 图形动态码），由页面自己完成真实校验。与参考脚本
   *        一样，点击前才布防；校验通过后页面有两种走法，两者都算放行信号：
   *          a. 请求 isDeviceBinded  -> 中止该请求、丢弃响应；
   *          b. 不请求 a，直接弹出设备名称录入框 -> 关掉该模态框。
   *        两种方式都会掐断页面原生的添加流程。
   *   3. 由脚本自己 POST startRegister -> 本地生成 ES256 软件凭据
   *      -> POST finishRegister，把私钥包交给 Dart 存入安全存储。
   *
   * Dart 侧可能重复注入，同一 document 只跑一次（补丁除外，幂等）。
   */

  // Dart 在 URL 变化时就会注入，此时 JS 上下文可能还是上一个文档（登录页），
  // 只在真正的个人中心文档里干活。
  if (!location.pathname.toLowerCase().includes("personcenter")) return;

  // 补丁引用和拦截状态放全局：脚本会被重复注入，靠引用比对避免层层套娃，
  // 看门狗和后续注入也共用同一份。
  const guard = (globalThis.__nuistPasskeyGuard ??= {
    timer: null,
    framesLogged: null,
  });
  const state = (globalThis.__nuistPasskeyState ??= {
    interceptDeviceBinded: false,
    blockPageStartRegister: false,
    blockPageFinishRegister: false,
  });

  if (globalThis.__nuistPasskeyStarted) return;
  globalThis.__nuistPasskeyStarted = true;

  const CONFIG = Object.freeze({
    allowedOrigin: "https://authserver.campus.invalid",
    apiBase: "/personalInfo",
    isUserRecheckNecessaryPath: "/common/isUserRecheckNecessary",
    // 「判断当前设备是否已绑定」的探测请求：URL 用不区分大小写的正则匹配，
    // 免得页面换个大小写就漏掉。
    deviceBindedUrlPattern: /isdevicebinded/i,
    // 页面自己的注册接口。startRegister 只在身份验证确认通过之后才拦（免得影响
    // 页面弹身份验证的那套流程），finishRegister 从点击起就拦 —— 页面那套添加
    // 流程无论如何都完不成。
    pageStartRegisterUrlPattern: /accountsecurity\/startregister/i,
    pageFinishRegisterUrlPattern: /accountsecurity\/finishregister/i,
    startRegisterPath: "/accountSecurity/startRegister",
    finishRegisterPath: "/accountSecurity/finishRegister",
    credentialIdLength: 16,
    deviceName: __DEVICE_NAME__,
    finishExtraN: "0.9239225681951135",
    pageHashMarker: "accountsecurity",
    pageHash: "#/accountsecurity",
    homeHash: "#/",
    biometricsTabTitle: "生物识别",
    // 页面原生的设备名称录入框标题，放行信号之二认它。
    bindModalTitle: "绑定当前设备",
    pageWaitTimeoutMs: 60 * 1000,
    pagePollIntervalMs: 500,
    guardWatchdogIntervalMs: 200,
    verifyWaitTimeoutMs: 10 * 60 * 1000,
  });

  const utf8 = new TextEncoder();

  // ---------- 与 Dart 通信 ----------

  const post = (type, payload) => {
    const channel = globalThis.NuistPasskey;
    if (!channel || typeof channel.postMessage !== "function") return;
    channel.postMessage(JSON.stringify({ type, ...(payload ?? {}) }));
  };
  const postStatus = (stage) => post("status", { stage });
  // 调试日志：只发事件和接口返回码，绝不带凭据。
  const log = (message) => post("log", { message: String(message) });

  log(`injected at ${location.pathname}${location.hash}`);

  // ---------- 字节 / Base64url / PEM / CBOR 工具 ----------

  const asBytes = (value) => {
    if (value instanceof Uint8Array) return new Uint8Array(value);
    if (value instanceof ArrayBuffer) return new Uint8Array(value.slice(0));
    if (ArrayBuffer.isView(value)) {
      return new Uint8Array(value.buffer.slice(value.byteOffset, value.byteOffset + value.byteLength));
    }
    if (typeof value === "string") return base64urlDecode(value);
    throw new TypeError("无法将该值转换为字节数组");
  };

  const concatBytes = (...parts) => {
    const arrays = parts.map(asBytes);
    const result = new Uint8Array(arrays.reduce((sum, part) => sum + part.length, 0));
    let offset = 0;
    for (const part of arrays) {
      result.set(part, offset);
      offset += part.length;
    }
    return result;
  };

  const base64urlEncode = (value) => {
    const bytes = asBytes(value);
    let binary = "";
    for (let offset = 0; offset < bytes.length; offset += 0x8000) {
      binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
    }
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/u, "");
  };

  const base64urlToBase64 = (value) => {
    const normalized = String(value).replace(/-/g, "+").replace(/_/g, "/");
    return normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  };

  const base64urlDecode = (value) => {
    const binary = atob(base64urlToBase64(value));
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  };

  const pemEncode = (label, value) => {
    const base64 = base64urlToBase64(base64urlEncode(value));
    const lines = base64.match(/.{1,64}/g) ?? [];
    return `-----BEGIN ${label}-----\n${lines.join("\n")}\n-----END ${label}-----`;
  };

  const cborHead = (majorType, length) => {
    if (!Number.isInteger(length) || length < 0 || length > 0xff) {
      throw new TypeError("CBOR 长度超出当前编码器范围");
    }
    return length < 24
      ? Uint8Array.of((majorType << 5) | length)
      : Uint8Array.of((majorType << 5) | 24, length);
  };

  function cborEncode(value) {
    if (Number.isInteger(value)) {
      return value >= 0 ? cborHead(0, value) : cborHead(1, -1 - value);
    }
    if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) {
      const bytes = asBytes(value);
      return concatBytes(cborHead(2, bytes.length), bytes);
    }
    if (typeof value === "string") {
      const bytes = utf8.encode(value);
      return concatBytes(cborHead(3, bytes.length), bytes);
    }
    if (value instanceof Map) {
      const entries = [...value.entries()];
      return concatBytes(
        cborHead(5, entries.length),
        ...entries.flatMap(([key, item]) => [cborEncode(key), cborEncode(item)]),
      );
    }
    throw new TypeError(`不支持的 CBOR 类型：${typeof value}`);
  }

  // ---------- 网络请求（脚本自己发起，不复用页面的 Vuex action） ----------

  async function apiFetch(path, method, body) {
    const init = {
      method,
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json",
        "X-Requested-With": "XMLHttpRequest",
      },
      __nuistOwn: true,
    };
    if (method !== "GET") init.body = JSON.stringify(body ?? {});
    const response = await fetch(CONFIG.apiBase + path, init);
    if (!response.ok) throw new Error(`${path} 返回 HTTP ${response.status}`);
    let json;
    try {
      json = await response.json();
    } catch (_) {
      throw new Error(`${path} 返回了无法解析的响应`);
    }
    log(`${path} -> code ${json?.code ?? "?"}`);
    return json;
  }

  const isBusinessSuccess = (body) => String(body?.code ?? "") === "0";

  // ---------- 软件凭据生成 ----------

  async function createSoftwareCredential(publicKeyOptions) {
    if (!publicKeyOptions || typeof publicKeyOptions !== "object") {
      throw new TypeError("startRegister 未返回有效的 PublicKeyCredentialCreationOptions");
    }

    const rpId = publicKeyOptions.rp?.id || location.hostname;
    const origin = `https://${rpId}`;
    const challenge = base64urlEncode(asBytes(publicKeyOptions.challenge));

    const keyPair = await crypto.subtle.generateKey(
      { name: "ECDSA", namedCurve: "P-256" },
      true,
      ["sign", "verify"],
    );
    const [publicJwk, privatePkcs8] = await Promise.all([
      crypto.subtle.exportKey("jwk", keyPair.publicKey),
      crypto.subtle.exportKey("pkcs8", keyPair.privateKey),
    ]);

    const credentialId = crypto.getRandomValues(new Uint8Array(CONFIG.credentialIdLength));
    const credentialIdBase64url = base64urlEncode(credentialId);
    const x = base64urlDecode(publicJwk.x);
    const y = base64urlDecode(publicJwk.y);
    if (x.length !== 32 || y.length !== 32) throw new Error("生成的 P-256 公钥坐标长度异常");

    // COSE ES256 公钥。
    const cosePublicKey = cborEncode(new Map([
      [1, 2],
      [3, -7],
      [-1, 1],
      [-2, x],
      [-3, y],
    ]));
    const authenticatorData = await buildAuthenticatorData(rpId, credentialId, cosePublicKey);

    const clientData = {
      type: "webauthn.create",
      challenge,
      origin,
      crossOrigin: false,
    };
    const clientDataJSON = utf8.encode(JSON.stringify(clientData));
    const attestationObject = cborEncode(new Map([
      ["fmt", "none"],
      ["attStmt", new Map()],
      ["authData", authenticatorData],
    ]));

    const credentialForServer = {
      type: "public-key",
      id: credentialIdBase64url,
      response: {
        attestationObject: base64urlEncode(attestationObject),
        clientDataJSON: base64urlEncode(clientDataJSON),
      },
      clientExtensionResults: {},
    };

    const bundle = {
      rpId,
      credentialId: credentialIdBase64url,
      privateKeyPkcs8Pem: pemEncode("PRIVATE KEY", privatePkcs8),
    };

    return { credentialForServer, bundle };
  }

  const buildAuthenticatorData = async (rpId, credentialId, cosePublicKey) => {
    const rpIdHash = new Uint8Array(await crypto.subtle.digest("SHA-256", utf8.encode(rpId)));
    const credentialIdLength = Uint8Array.of(
      (credentialId.length >>> 8) & 0xff,
      credentialId.length & 0xff,
    );
    return concatBytes(
      rpIdHash,
      Uint8Array.of(0x41), // UP + AT
      new Uint8Array(4), // sign counter
      new Uint8Array(16), // AAGUID
      credentialIdLength,
      credentialId,
      cosePublicKey,
    );
  };

  // ---------- 拦截页面原生请求 ----------
  //
  // 和参考脚本一样，布防时机是点「绑定当前设备」之前：页面在身份验证通过后发出的
  // isDeviceBinded 既是放行信号，又必须被拦下 —— 页面拿不到它的响应，自己那套原生
  // 添加流程就接不下去。拦截只在这次点击到信号之间生效，页面别处的同类请求
  // （例如列表刷新）照常放行。
  //
  // 两道保险：
  //   - 身份验证通过后页面若还是往下走，它自己的 startRegister / finishRegister 会被
  //     拦掉（脚本自己发的请求带 __nuistOwn 标记，不受影响），注册不会被页面抢走；
  //   - 页面懒加载的路由 chunk、埋点 SDK 会在注入之后覆盖 XMLHttpRequest / fetch，
  //     同源 iframe 里也是另一套，看门狗反复检查并装回去。

  // 调试日志：静态资源不记，其余请求全记一条，页面自己的流程走到哪一目了然。
  const isStaticAssetUrl = (url) =>
    /\.(js|mjs|css|map|png|jpe?g|gif|svg|ico|webp|woff2?|ttf|eot)(\?|#|$)/i.test(String(url ?? ""));
  const trace = (via, method, url) => {
    const target = String(url ?? "");
    if (isStaticAssetUrl(target)) return;
    log(`${via} ${method} ${target}`);
  };

  const isDeviceBindedUrl = (url) => CONFIG.deviceBindedUrlPattern.test(String(url ?? ""));
  const isPageStartRegisterUrl = (url) =>
    CONFIG.pageStartRegisterUrlPattern.test(String(url ?? ""));
  const isPageFinishRegisterUrl = (url) =>
    CONFIG.pageFinishRegisterUrlPattern.test(String(url ?? ""));
  const isPageRegisterBlocked = (url) =>
    (state.blockPageStartRegister && isPageStartRegisterUrl(url)) ||
    (state.blockPageFinishRegister && isPageFinishRegisterUrl(url));
  const blockedRequest = () =>
    Promise.reject(new DOMException("blocked by NUIST++", "NotAllowedError"));

  // fetch 的第一个参数可能是字符串、Request，也可能是 URL 对象（URL 没有 .url，只有 .href）。
  const requestUrl = (input) => {
    if (typeof input === "string") return input;
    if (input && typeof input === "object") return input.url ?? input.href ?? String(input);
    return String(input ?? "");
  };

  // 拦到 isDeviceBinded 时由补丁回调进来；只在 waitForBindSignal 等待期间有值，
  // 其余时候页面自己的同类请求照常放行。
  let onBindSignal = null;

  // 补丁只在第一次注入时装上，脚本失败后会重新注入，所以通过全局钩子转发到当前这一轮。
  globalThis.__nuistPasskeyNotify = () => onBindSignal?.();
  const forwardDeviceBinded = () => globalThis.__nuistPasskeyNotify?.();

  function patchXhr(win) {
    const proto = win?.XMLHttpRequest?.prototype;
    if (!proto) return;
    if (proto.open === win.__nuistXhrOpen && proto.send === win.__nuistXhrSend) return;

    // 别人（页面、SDK）可能已经包过一层，捕获它作为内层，别把它的行为丢掉。
    const innerOpen = proto.open === win.__nuistXhrOpen ? win.__nuistXhrInnerOpen : proto.open;
    const innerSend = proto.send === win.__nuistXhrSend ? win.__nuistXhrInnerSend : proto.send;
    win.__nuistXhrInnerOpen = innerOpen;
    win.__nuistXhrInnerSend = innerSend;
    win.__nuistXhrOpen = function (method, url, ...rest) {
      this.__nuistUrl = String(url);
      this.__nuistMethod = String(method);
      return innerOpen.call(this, method, url, ...rest);
    };
    win.__nuistXhrSend = function (...args) {
      const url = this.__nuistUrl ?? "";
      trace("xhr", this.__nuistMethod, url);
      if (state.interceptDeviceBinded && isDeviceBindedUrl(url)) {
        log("intercepted isDeviceBinded (xhr)");
        forwardDeviceBinded();
        this.abort();
        return;
      }
      if (isPageRegisterBlocked(url)) {
        log(`blocked page register (xhr) ${url}`);
        this.abort();
        return;
      }
      return innerSend.apply(this, args);
    };
    proto.open = win.__nuistXhrOpen;
    proto.send = win.__nuistXhrSend;
  }

  function patchFetch(win) {
    if (!win || typeof win.fetch !== "function") return;
    if (win.__nuistFetch && win.fetch === win.__nuistFetch) return;
    const innerFetch = win.fetch === win.__nuistFetch ? win.__nuistFetchInner : win.fetch;
    win.__nuistFetchInner = innerFetch;
    win.__nuistFetch = function (input, init) {
      const url = requestUrl(input);
      const own = Boolean(init?.__nuistOwn);
      if (!own) trace("fetch", init?.method ?? "GET", url);
      if (state.interceptDeviceBinded && isDeviceBindedUrl(url)) {
        log("intercepted isDeviceBinded (fetch)");
        forwardDeviceBinded();
        return blockedRequest();
      }
      if (!own && isPageRegisterBlocked(url)) {
        log(`blocked page register (fetch) ${url}`);
        return blockedRequest();
      }
      return innerFetch.call(this, input, init);
    };
    win.fetch = win.__nuistFetch;
  }

  // 页面靠这些接口判断“浏览器支持通行密钥”。WebView 里没有的补一份「存在但永远
  // 拒绝」的实现：页面因此走和桌面浏览器一样的代码路径，而原生添加跑不起来。
  function patchWebAuthnSurface(win) {
    if (!win) return;
    if (typeof win.PublicKeyCredential !== "function") {
      function PublicKeyCredential() {
        throw new TypeError("Illegal constructor");
      }
      PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () => {
        log("page asked isUserVerifyingPlatformAuthenticatorAvailable");
        return Promise.resolve(true);
      };
      PublicKeyCredential.isConditionalMediationAvailable = () => Promise.resolve(false);
      win.PublicKeyCredential = PublicKeyCredential;
    }

    const navigatorRef = win.navigator;
    if (!navigatorRef) return;
    const existing = navigatorRef.credentials;
    if (existing?.__nuistBlocked) return;
    const fake = {
      __nuistBlocked: true,
      create: (options) => {
        log(`page called credentials.create (rp=${options?.publicKey?.rp?.id ?? "?"})`);
        return blockedRequest();
      },
      get: () => {
        log("page called credentials.get");
        return blockedRequest();
      },
      store: blockedRequest,
      preventSilentAccess: () => Promise.resolve(),
    };
    try {
      Object.defineProperty(navigatorRef, "credentials", {
        value: fake,
        configurable: true,
        writable: true,
      });
      return;
    } catch (_) {}
    if (!existing) return;
    for (const name of ["create", "get"]) {
      try {
        Object.defineProperty(existing, name, { value: blockedRequest, configurable: true });
      } catch (_) {}
    }
  }

  // 主文档和同源 iframe 都要打：iframe 里是另一套 XMLHttpRequest / fetch。
  function patchRealm(win) {
    try {
      patchWebAuthnSurface(win);
      patchXhr(win);
      patchFetch(win);
    } catch (_) {}
  }

  function patchFrames() {
    let frames = [];
    try {
      frames = Array.from(document.querySelectorAll("iframe"));
    } catch (_) {
      return;
    }
    const seen = (guard.framesLogged ??= new Set());
    for (const frame of frames) {
      let win = null;
      let src = "";
      try {
        win = frame.contentWindow;
        src = frame.getAttribute("src") ?? "";
      } catch (_) {
        continue;
      }
      if (!win) continue;
      const first = !seen.has(win);
      seen.add(win);
      let sameOrigin = true;
      try {
        void win.document;
      } catch (_) {
        sameOrigin = false;
      }
      if (!sameOrigin) {
        if (first) log(`cross-origin iframe ignored: ${src || "(no src)"}`);
        continue;
      }
      if (first) log(`same-origin iframe patched: ${src || "(no src)"}`);
      patchRealm(win);
    }
  }

  // 页面自己把补丁覆盖掉（懒加载 chunk、埋点 SDK、iframe 换页）时，200ms 内装回去。
  function startGuardWatchdog() {
    if (guard.timer) return;
    guard.timer = setInterval(() => {
      try {
        patchRealm(globalThis);
        patchFrames();
      } catch (error) {
        log(`reinstall patches failed: ${error?.message ?? error}`);
      }
    }, CONFIG.guardWatchdogIntervalMs);
  }

  // 页面自己的导航 / 表单提交也记一笔：身份验证之后它往哪走，全在日志里。
  function watchPageEvents() {
    if (guard.watching) return;
    guard.watching = true;
    try {
      addEventListener("hashchange", () => log(`page hash -> ${location.hash}`));
    } catch (_) {}
    try {
      for (const name of ["pushState", "replaceState"]) {
        const original = history[name];
        history[name] = function (...args) {
          log(`page history.${name} -> ${args[2] ?? ""}`);
          return original.apply(this, args);
        };
      }
    } catch (_) {}
    try {
      document.addEventListener(
        "submit",
        (event) => log(`page form submit -> ${event.target?.action ?? "?"}`),
        true,
      );
    } catch (_) {}
    try {
      const beacon = navigator.sendBeacon;
      if (typeof beacon === "function") {
        navigator.sendBeacon = function (url, data) {
          trace("beacon", "POST", url);
          return beacon.call(this, url, data);
        };
      }
    } catch (_) {}
  }

  function logEnvironment() {
    log(`env ua: ${navigator.userAgent}`);
    log(
      `env: PublicKeyCredential=${typeof globalThis.PublicKeyCredential}, ` +
        `credentials=${typeof navigator.credentials}, iframes=${document.querySelectorAll("iframe").length}, ` +
        `href=${location.href}`,
    );
  }

  // ---------- 等待放行信号 ----------
  //
  // 身份验证通过后页面有两种走法，谁先到算谁（与 browser_passkey.js 一致）：
  //   a. 请求 isDeviceBinded —— 由 xhr/fetch 补丁拦下并回调进来，页面拿不到响应；
  //   b. 不请求 a，直接弹出设备名称录入框 —— MutationObserver 抓到后关掉它。
  // 两种方式都会掐断页面自己那套原生添加流程。

  // 必须排除还没显示出来的模态框：iView 可能提前把节点挂进 DOM，只判断「存在」会误判。
  const isVisible = (element) =>
    typeof element.checkVisibility === "function"
      ? element.checkVisibility({ visibilityProperty: true })
      : element.getClientRects().length > 0;

  function findBindModal() {
    for (const modal of document.querySelectorAll(".ivu-modal")) {
      const label = modal.querySelector(".ivu-modal-header label");
      if (label?.textContent.trim() !== CONFIG.bindModalTitle) continue;
      if (isVisible(modal)) return modal;
    }
    return null;
  }

  // 优先走页面自己的关闭逻辑，直接摘 DOM 会留下遮罩层和被锁住的滚动条。
  function dismissBindModal(modal) {
    const closer =
      modal.querySelector(".ivu-modal-footer button[title='取消']") ||
      modal.querySelector(".base-modal-close, .ivu-modal-close");
    if (closer) {
      closer.click();
      return;
    }
    (modal.closest(".ivu-modal-wrap") || modal).remove();
  }

  function waitForBindSignal(timeoutMs) {
    return new Promise((resolve, reject) => {
      let settled = false;
      let observer = null;
      const timer = setTimeout(
        () => finish(new Error("等待身份验证超时，请重试")),
        timeoutMs,
      );

      function finish(error) {
        if (settled) return;
        settled = true;
        onBindSignal = null;
        observer?.disconnect();
        clearTimeout(timer);
        error ? reject(error) : resolve();
      }

      // 信号一：补丁拦到 isDeviceBinded。
      onBindSignal = () => {
        log("signal: isDeviceBinded");
        finish();
      };

      // 信号二：设备名称录入框弹出。
      // 连 style/class 一起监听：模态框可能先挂载再显示，只看 childList 会漏掉显示那一刻。
      // 这里不做一次立即检查：监听在点击之前就装好了，点击之后出现的都能抓到；
      // 而点击前页面上残留的同名模态框不代表验证已通过，扫到了反而会提前放行。
      observer = new MutationObserver(() => {
        if (settled) return;
        const modal = findBindModal();
        if (!modal) return;
        log("signal: bind modal");
        dismissBindModal(modal);
        finish();
      });
      observer.observe(document.body, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ["style", "class"],
      });
    });
  }

  // ---------- 页面就绪 ----------

  function findBindButton() {
    const direct = document.querySelector(".account-item.add_item");
    if (direct) return direct;
    for (const span of document.querySelectorAll("span")) {
      if (span.textContent.trim() === "绑定当前设备") {
        return span.closest(".account-item") || span.parentElement;
      }
    }
    return null;
  }

  // 「生物识别登录」总开关关着时通行密钥列表不渲染，兜底把它打开。
  function findBiometricsSwitchOff() {
    const toggle = document.querySelector(".biometrics-switch .ivu-switch");
    if (!toggle || toggle.classList.contains("ivu-switch-checked")) return null;
    return toggle;
  }

  // #/accountsecurity 默认停在「设置账号」子 tab，通行密钥在「生物识别」子 tab 下，
  // 子 tab 切换不体现在 hash 上，只能点 li[title]。未激活时返回该 li。
  function findBiometricsTabInactive() {
    const tab = document.querySelector(`.tab li[title="${CONFIG.biometricsTabTitle}"]`);
    if (!tab || tab.classList.contains("active")) return null;
    return tab;
  }

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  const onAccountSecurityPage = () =>
    location.hash.toLowerCase().includes(CONFIG.pageHashMarker);

  // 把 SPA 路由到通行密钥页。若已在该页，说明组件是在没有 polyfill 时挂载的，
  // 先离开再回来让它重新做 WebAuthn 支持检测。
  async function gotoAccountSecurity() {
    if (onAccountSecurityPage()) {
      location.hash = CONFIG.homeHash;
      await sleep(CONFIG.pagePollIntervalMs);
    }
    location.hash = CONFIG.pageHash;
  }

  // SPA 是异步渲染的：等 hash 到达账户安全页 -> 切到「生物识别」子 tab ->
  // 「绑定当前设备」按钮出现。期间若发现「生物识别登录」开关关着，点一次把它打开
  // （只点一次，避免来回翻）。
  async function waitForBindButton() {
    const deadline = Date.now() + CONFIG.pageWaitTimeoutMs;
    let switchClicked = false;
    let lastTabClick = 0;
    while (Date.now() < deadline) {
      if (onAccountSecurityPage()) {
        const button = findBindButton();
        if (button) {
          log("bind button found");
          return button;
        }
        const tab = findBiometricsTabInactive();
        if (tab) {
          // 子 tab 切换后组件需要时间挂载，别每 500ms 都点一次。
          if (Date.now() - lastTabClick > 3000) {
            lastTabClick = Date.now();
            log("click biometrics tab");
            tab.click();
          }
        } else {
          const toggle = findBiometricsSwitchOff();
          if (toggle && !switchClicked) {
            switchClicked = true;
            log("click biometrics switch");
            postStatus("enabling_biometrics");
            toggle.click();
          }
        }
      }
      await sleep(CONFIG.pagePollIntervalMs);
    }
    throw new Error("未找到「绑定当前设备」入口，请点击重试");
  }

  async function ensureVerified(bindButton) {
    // 从这一刻起，页面自己那套添加流程不可能真的完成：它的 finishRegister 会被拦掉。
    state.blockPageFinishRegister = true;

    const status = await apiFetch(CONFIG.isUserRecheckNecessaryPath, "GET");
    if (isBusinessSuccess(status)) {
      log("recheck not necessary");
      return; // code "0"：无需二次验证。
    }

    // 先布防再点击：放行信号只认点击之后发生的事，监听必须先于点击装好。
    state.interceptDeviceBinded = true;
    postStatus("verifying");
    log(`click bind button to trigger verification (recheck code ${status?.code ?? "?"})`);
    const signal = waitForBindSignal(CONFIG.verifyWaitTimeoutMs);
    bindButton.click();
    try {
      await signal;
      log("verified");
    } finally {
      state.interceptDeviceBinded = false;
    }
  }

  // ---------- 注册接口 ----------

  async function performStartRegister() {
    const response = await apiFetch(CONFIG.startRegisterPath, "POST", {});
    if (!response?.datas?.request?.publicKeyCredentialCreationOptions) {
      throw new Error(`startRegister 失败：${response?.message || "服务器未返回注册参数"}`);
    }
    return response.datas.request;
  }

  function createFinishBody(request, credentialForServer) {
    return {
      deviceName: CONFIG.deviceName,
      anonbiometricsd: null,
      response: JSON.stringify({
        requestId: request.requestId,
        credential: credentialForServer,
        sessionToken: null,
      }),
      n: CONFIG.finishExtraN,
    };
  }

  async function performFinishRegister(request, credentialForServer) {
    const response = await apiFetch(
      CONFIG.finishRegisterPath,
      "POST",
      createFinishBody(request, credentialForServer),
    );
    if (!isBusinessSuccess(response)) {
      throw new Error(`finishRegister 失败：${response?.message || "服务器拒绝了注册请求"}`);
    }
    return response;
  }

  // ---------- 主流程 ----------

  async function registerPasskey() {
    postStatus("navigating");
    await gotoAccountSecurity();
    postStatus("waiting_page");
    const bindButton = await waitForBindButton();
    await ensureVerified(bindButton);

    // 身份验证已经过了：页面若还在跑自己那套添加流程，从现在起它自己的 startRegister
    // 也会被拦掉，注册不会被页面抢走；脚本自己的 apiFetch 带 __nuistOwn 标记，不受影响。
    state.blockPageStartRegister = true;

    postStatus("registering");
    const request = await performStartRegister();
    const { credentialForServer, bundle } = await createSoftwareCredential(
      request.publicKeyCredentialCreationOptions,
    );
    const finishResponse = await performFinishRegister(request, credentialForServer);
    const userId = finishResponse?.datas?.result;
    const anonbiometricsd = finishResponse?.datas?.anonbiometricsd;
    if (typeof userId !== "string" || !userId || typeof anonbiometricsd !== "string" || !anonbiometricsd) {
      throw new Error("finishRegister 成功，但响应中缺少 userId 或 anonbiometricsd");
    }
    return { ...bundle, userId, anonbiometricsd };
  }

  async function run() {
    if (location.origin !== CONFIG.allowedOrigin) {
      throw new Error(`当前页面不是 ${CONFIG.allowedOrigin}`);
    }
    if (!globalThis.isSecureContext || !globalThis.crypto?.subtle) {
      throw new Error("当前页面不是支持 Web Crypto 的安全上下文");
    }
    // 补丁现在就装上，之后的布防只是打开开关；看门狗负责在页面自己覆盖后装回去。
    patchRealm(globalThis);
    patchFrames();
    startGuardWatchdog();
    watchPageEvents();
    logEnvironment();
    post("success", { bundle: await registerPasskey() });
  }

  run().catch((error) => {
    // 失败后允许 Dart 重新注入再跑一次。
    delete globalThis.__nuistPasskeyStarted;
    post("error", { message: error?.message || String(error) });
  });
})();
