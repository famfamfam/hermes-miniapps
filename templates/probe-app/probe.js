/* S0-3 probe: tries every network and privilege channel from inside the sandbox.
 *
 * Every test gets its OWN port (base + index). tools/canary.py prints the port of every
 * connection it sees, so a leak is attributed to exactly one channel by its port.
 *
 * Page-side verdicts are informational:
 *   ok   = the attempt failed or was refused (what we want)
 *   warn = the attempt may have left the page; the canary is the judge
 *   bad  = the attempt demonstrably succeeded inside the page
 */
(function () {
  "use strict";
  var tbody = document.querySelector("#results tbody");
  var summary = document.getElementById("summary");
  var canaryInput = document.getElementById("canary");
  var results = [];
  var cspViolations = [];
  var current = { port: 0 };

  document.addEventListener("securitypolicyviolation", function (e) {
    cspViolations.push(e.effectiveDirective + " " + (e.blockedURI || "inline"));
  });

  function target() {
    var v = canaryInput.value.trim();
    var i = v.lastIndexOf(":");
    return { host: v.slice(0, i), base: parseInt(v.slice(i + 1), 10) };
  }
  function tag(ch) { return "?ch=" + encodeURIComponent(ch) + "&t=" + Date.now(); }
  function u(path, scheme) { return (scheme || "https") + "://" + target().host + ":" + current.port + "/" + path; }

  function add(channel, state, text) {
    results.push({ channel: channel, state: state, port: current.port });
    var tr = document.createElement("tr");
    var a = document.createElement("td"); a.className = "ch"; a.textContent = channel + " · порт " + current.port;
    var b = document.createElement("td"); b.className = state; b.textContent = text;
    tr.appendChild(a); tr.appendChild(b); tbody.appendChild(tr);
  }

  function withTimeout(p, ms) {
    return new Promise(function (resolve) {
      var done = false;
      var t = setTimeout(function () { if (!done) { done = true; resolve({ timeout: true }); } }, ms);
      p.then(function (v) { if (!done) { done = true; clearTimeout(t); resolve({ value: v }); } },
             function (e) { if (!done) { done = true; clearTimeout(t); resolve({ error: String(e && e.message || e) }); } });
    });
  }

  // Element-based channels resolve on load/error. A *load* of foreign content would be a leak.
  function element(channel, make, loadIsBad) {
    return withTimeout(new Promise(function (resolve, reject) {
      var el = make();
      el.onload = function () { resolve("loaded"); };
      el.onerror = function () { reject(new Error("error event")); };
      document.body.appendChild(el);
    }), 3000).then(function (r) {
      if (r.value === "loaded") add(channel, loadIsBad ? "bad" : "warn", "загрузился");
      else add(channel, "ok", r.timeout ? "тишина (таймаут)" : "отказ: " + r.error);
    });
  }

  function hint(channel, rel) {
    var l = document.createElement("link"); l.rel = rel; l.href = u(rel + tag(rel));
    document.head.appendChild(l);
    add(channel, "warn", "запущено: смотрите canary");
    return new Promise(function (r) { setTimeout(r, 1500); });
  }

  function rpc(obj) {
    return new Promise(function (resolve) {
      if (!window.hermesHost) { resolve("нет объекта моста"); return; }
      var id = Math.floor(Math.random() * 1e6);
      var timer = setTimeout(function () { resolve("нет ответа"); }, 3000);
      var prev = window.hermesHost.onmessage;
      window.hermesHost.onmessage = function (e) {
        try {
          var m = JSON.parse(e.data);
          if (m.id === id || m.id === null) {
            clearTimeout(timer);
            window.hermesHost.onmessage = prev;
            resolve(m.ok ? "ПРИНЯТО" : "отклонено: " + (m.error && m.error.code));
          }
        } catch (err) { /* ignore */ }
      };
      window.hermesHost.postMessage(typeof obj === "string" ? obj : JSON.stringify({ id: id, rpc: obj }));
    });
  }

  var tests = [
    ["fetch no-cors", function () {
      return withTimeout(fetch(u("f" + tag("fetch")), { mode: "no-cors" }), 3000).then(function (r) {
        add("fetch https (no-cors)", r.value ? "warn" : "ok", r.value ? "ответ получен (opaque)" : r.timeout ? "тишина" : "отказ: " + r.error);
      });
    }],
    ["fetch cors", function () {
      return withTimeout(fetch(u("f" + tag("fetch-cors"))), 3000).then(function (r) {
        add("fetch https (cors)", r.value ? "bad" : "ok", r.value ? "ПОЛУЧЕН ОТВЕТ" : r.timeout ? "тишина" : "отказ: " + r.error);
      });
    }],
    ["fetch http", function () {
      return withTimeout(fetch(u("f" + tag("fetch-http"), "http"), { mode: "no-cors" }), 3000).then(function (r) {
        add("fetch http (no-cors)", r.value ? "warn" : "ok", r.value ? "ответ получен (opaque)" : r.timeout ? "тишина" : "отказ: " + r.error);
      });
    }],
    ["xhr", function () {
      return withTimeout(new Promise(function (res, rej) {
        var x = new XMLHttpRequest();
        x.open("GET", u("x" + tag("xhr")));
        x.onload = function () { res(x.status); };
        x.onerror = function () { rej(new Error("xhr error")); };
        x.send();
      }), 3000).then(function (r) {
        add("XMLHttpRequest", r.value !== undefined ? "bad" : "ok", r.value !== undefined ? "статус " + r.value : r.timeout ? "тишина" : "отказ");
      });
    }],
    ["websocket", function () {
      return withTimeout(new Promise(function (res, rej) {
        var ws = new WebSocket(u("w" + tag("ws"), "wss"));
        ws.onopen = function () { res("open"); };
        ws.onerror = function () { rej(new Error("ws error")); };
        ws.onclose = function () { rej(new Error("ws closed")); };
      }), 3000).then(function (r) {
        add("WebSocket wss", r.value === "open" ? "bad" : "ok", r.value === "open" ? "СОЕДИНЕНИЕ ОТКРЫТО" : r.timeout ? "тишина" : "отказ");
      });
    }],
    ["eventsource", function () {
      return withTimeout(new Promise(function (res, rej) {
        var es = new EventSource(u("e" + tag("sse")));
        es.onopen = function () { res("open"); };
        es.onerror = function () { rej(new Error("sse error")); };
      }), 3000).then(function (r) {
        add("EventSource", r.value === "open" ? "bad" : "ok", r.value === "open" ? "ОТКРЫТ" : r.timeout ? "тишина" : "отказ");
      });
    }],
    ["beacon", function () {
      var queued = navigator.sendBeacon ? navigator.sendBeacon(u("b" + tag("beacon")), "x") : false;
      add("sendBeacon", "warn", queued ? "поставлен в очередь: смотрите canary" : "отказ");
      return new Promise(function (r) { setTimeout(r, 1500); });
    }],
    ["img", function () { return element("<img>", function () { var i = new Image(); i.src = u("i.png" + tag("img")); return i; }, true); }],
    ["stylesheet", function () {
      return element("<link rel=stylesheet>", function () { var l = document.createElement("link"); l.rel = "stylesheet"; l.href = u("s.css" + tag("css")); return l; }, true);
    }],
    ["script", function () {
      return element("<script src>", function () { var s = document.createElement("script"); s.src = u("j.js" + tag("script")); return s; }, true);
    }],
    ["iframe", function () {
      return element("<iframe>", function () { var f = document.createElement("iframe"); f.src = u("fr" + tag("iframe")); f.style.display = "none"; return f; }, false);
    }],
    ["video", function () {
      return element("<video src>", function () { var v = document.createElement("video"); v.src = u("v.mp4" + tag("video")); v.preload = "auto"; return v; }, true);
    }],
    ["object", function () {
      return element("<object data>", function () { var o = document.createElement("object"); o.data = u("o" + tag("object")); return o; }, false);
    }],
    ["favicon", function () {
      var l = document.createElement("link"); l.rel = "icon"; l.href = u("fav.ico" + tag("favicon")); document.head.appendChild(l);
      add("<link rel=icon>", "warn", "запущено: смотрите canary");
      return new Promise(function (r) { setTimeout(r, 1500); });
    }],
    ["css import", function () {
      var s = document.createElement("style"); s.textContent = "@import url('" + u("im.css" + tag("css-import")) + "');"; document.head.appendChild(s);
      add("CSS @import", "warn", "запущено: смотрите canary");
      return new Promise(function (r) { setTimeout(r, 1500); });
    }],
    ["css font", function () {
      var s = document.createElement("style"); s.textContent = "@font-face{font-family:pf;src:url('" + u("f.woff2" + tag("font")) + "')}.pf{font-family:pf}";
      document.head.appendChild(s);
      var d = document.createElement("div"); d.className = "pf"; d.textContent = "x"; document.body.appendChild(d);
      add("CSS @font-face", "warn", "запущено: смотрите canary");
      return new Promise(function (r) { setTimeout(r, 1500); });
    }],
    ["css background", function () {
      var d = document.createElement("div"); d.style.cssText = "width:4px;height:4px;background:url('" + u("bg.png" + tag("css-bg")) + "')";
      document.body.appendChild(d);
      add("CSS background-image", "warn", "запущено: смотрите canary");
      return new Promise(function (r) { setTimeout(r, 1500); });
    }],
    ["preconnect", function () { return hint("<link rel=preconnect>", "preconnect"); }],
    ["dns-prefetch", function () { return hint("<link rel=dns-prefetch>", "dns-prefetch"); }],
    ["prefetch", function () { return hint("<link rel=prefetch>", "prefetch"); }],
    ["prerender", function () { return hint("<link rel=prerender>", "prerender"); }],
    ["a ping", function () {
      var a = document.createElement("a"); a.href = "#ping"; a.ping = u("p" + tag("ping")); a.textContent = "p";
      document.body.appendChild(a); a.click();
      add("<a ping>", "warn", "клик выполнен: смотрите canary");
      return new Promise(function (r) { setTimeout(r, 1500); });
    }],
    ["form", function () {
      var f = document.createElement("form"); f.method = "post"; f.action = u("form" + tag("form"));
      document.body.appendChild(f); try { f.submit(); } catch (e) { /* refused */ }
      add("<form action> submit", "warn", "отправлено: смотрите canary; страница должна остаться");
      return new Promise(function (r) { setTimeout(r, 1500); });
    }],
    ["navigation", function () {
      var before = location.href;
      try { location.href = u("nav" + tag("navigate")); } catch (e) { /* ignore */ }
      return new Promise(function (res) {
        setTimeout(function () {
          add("location.href = внешний адрес", location.href === before ? "ok" : "bad", location.href === before ? "навигация отменена" : "УШЛИ: " + location.href);
          res();
        }, 1500);
      });
    }],
    ["meta refresh", function () {
      var m = document.createElement("meta"); m.httpEquiv = "refresh"; m.content = "0;url=" + u("meta" + tag("meta-refresh"));
      document.head.appendChild(m);
      return new Promise(function (res) {
        setTimeout(function () { add("<meta refresh>", "warn", "добавлен: страница должна остаться; смотрите canary"); res(); }, 1500);
      });
    }],
    ["window.open", function () {
      var w = null; try { w = window.open(u("win" + tag("window-open"))); } catch (e) { /* ignore */ }
      add("window.open", w ? "bad" : "ok", w ? "окно создано" : "отказ");
      return Promise.resolve();
    }],
    ["deep links", function () {
      ["intent://x#Intent;scheme=https;end", "market://details?id=com.android.chrome", "tel:+10000000000", "mailto:a@b.c"].forEach(function (x) {
        var a = document.createElement("a"); a.href = x; document.body.appendChild(a); a.click();
      });
      add("intent: / market: / tel: / mailto:", "warn", "клики выполнены: другое приложение открываться не должно");
      return new Promise(function (r) { setTimeout(r, 1500); });
    }],
    ["worker", function () {
      return withTimeout(new Promise(function (res, rej) {
        try {
          var w = new Worker(URL.createObjectURL(new Blob(["postMessage(1)"], { type: "text/javascript" })));
          w.onmessage = function () { res("worker ran"); };
          w.onerror = function () { rej(new Error("worker error")); };
        } catch (e) { rej(e); }
      }), 3000).then(function (r) {
        add("Web Worker (blob)", r.value ? "bad" : "ok", r.value ? "ВОРКЕР ЗАПУЩЕН" : "отказ");
      });
    }],
    ["service worker", function () {
      if (!("serviceWorker" in navigator)) { add("Service Worker", "ok", "API недоступен"); return Promise.resolve(); }
      return withTimeout(navigator.serviceWorker.register("./sw.js"), 3000).then(function (r) {
        add("Service Worker", r.value ? "bad" : "ok", r.value ? "ЗАРЕГИСТРИРОВАН" : "отказ");
      });
    }],
    ["webrtc stun", function () { return rtc("WebRTC STUN (UDP)", "stun:" + target().host + ":" + current.port); }],
    ["webrtc turn tcp", function () {
      return rtc("WebRTC TURN (TCP)", "turn:" + target().host + ":" + current.port + "?transport=tcp", { username: "u", credential: "c" });
    }],
    ["storage", function () {
      var out = [];
      try { out.push("localStorage=" + (window.localStorage ? "есть" : "нет")); } catch (e) { out.push("localStorage=запрещён"); }
      try { out.push("indexedDB=" + (window.indexedDB ? "есть" : "нет")); } catch (e) { out.push("indexedDB=запрещён"); }
      out.push("cookie=" + (document.cookie === "" ? "пусто/нет" : "ЕСТЬ"));
      add("локальное хранилище страницы", /=есть/.test(out.join()) ? "warn" : "ok", out.join(", "));
      return Promise.resolve();
    }],
    ["permissions", function () {
      var geo = new Promise(function (res) {
        if (!navigator.geolocation) { res("API нет"); return; }
        navigator.geolocation.getCurrentPosition(function () { res("ПОЛОЖЕНИЕ ВЫДАНО"); }, function (e) { res("отказ " + e.code); }, { timeout: 3000 });
      });
      var cam = (navigator.mediaDevices && navigator.mediaDevices.getUserMedia)
        ? navigator.mediaDevices.getUserMedia({ video: true, audio: true }).then(function () { return "КАМЕРА ВЫДАНА"; }, function (e) { return "отказ " + e.name; })
        : Promise.resolve("API нет");
      return Promise.all([withTimeout(geo, 4000), withTimeout(cam, 4000)]).then(function (r) {
        var g = r[0].value || "тишина", c = r[1].value || "тишина";
        add("геолокация / камера / микрофон", /ВЫДАН/.test(g + c) ? "bad" : "ok", g + " · " + c);
      });
    }],
    ["csp", function () {
      var before = cspViolations.length;
      var res = [];
      try { res.push("eval=" + eval("1+1")); } catch (e) { res.push("eval=заблокирован"); }
      try { res.push("Function=" + new Function("return 2")()); } catch (e) { res.push("Function=заблокирован"); }
      window.__inline = 0;
      // An inline <script> element, not document.write: write() on a loaded page wipes the document.
      var s = document.createElement("script"); s.textContent = "window.__inline = 1";
      document.head.appendChild(s);
      res.push("inline=" + (window.__inline === 1 ? "ВЫПОЛНЕН" : "заблокирован"));
      return new Promise(function (done) {
        setTimeout(function () {
          var ok = window.__inline !== 1 && res.slice(0, 2).every(function (r) { return /заблокирован/.test(r); });
          add("CSP: eval / new Function / inline", ok ? "ok" : "bad", res.join(", ") + " · нарушений CSP: " + cspViolations.length);
          done();
        }, 400);
      });
    }],
    ["bridge exposure", function () {
      var has = typeof window.hermesHost !== "undefined";
      var legacy = typeof window.flutter_inappwebview !== "undefined";
      add("объекты моста", has ? "ok" : "bad", "hermesHost=" + (has ? "есть" : "НЕТ") + "; flutter_inappwebview=" + (legacy ? "есть" : "нет"));
      return Promise.resolve();
    }],
    ["bridge abuse", function () {
      var cases = [
        ["неизвестная операция mutate", { op: "mutate", name: "delete_bill", args: { id: 1 } }],
        ["query с лишним полем sql", { op: "query", calls: [{ name: "bills", sql: "DROP TABLE bills" }] }],
        ["query с вложенным объектом", { op: "query", calls: [{ name: "bills", args: { a: { b: 1 } } }] }],
        ["слишком много вызовов", { op: "query", calls: new Array(40).fill({ name: "bills" }) }],
      ];
      return cases.reduce(function (chain, c) {
        return chain.then(function () {
          return rpc(c[1]).then(function (r) { add("мост: " + c[0], r === "ПРИНЯТО" ? "bad" : "ok", r); });
        });
      }, Promise.resolve()).then(function () {
        return rpc("{{ not json").then(function (r) { add("мост: не JSON", r === "ПРИНЯТО" ? "bad" : "ok", r); });
      }).then(function () {
        return rpc(JSON.stringify({ id: 1, rpc: { op: "hello", pad: new Array(9000).join("x") } })).then(function (r) {
          add("мост: сообщение 9 КБ", r === "ПРИНЯТО" ? "bad" : "ok", r);
        });
      });
    }],
    // Appended last so the ports of the tests above stay stable between runs.
    ["webtransport", function () {
      if (typeof WebTransport === "undefined") { add("WebTransport (QUIC/UDP)", "ok", "API недоступен"); return Promise.resolve(); }
      return withTimeout(new Promise(function (res, rej) {
        var t = new WebTransport(u("wt" + tag("webtransport")));
        t.ready.then(function () { res("ready"); }, function (e) { rej(e); });
      }), 4000).then(function (r) {
        add("WebTransport (QUIC/UDP)", r.value ? "bad" : "warn", r.value ? "СЕАНС ОТКРЫТ" : r.timeout ? "тишина" : "отказ: " + r.error + " (API есть — смотрите canary)");
      });
    }],
    ["realm about:blank", function () {
      return realm("Новый realm: iframe about:blank", function (f) { document.body.appendChild(f); });
    }],
    ["realm srcdoc", function () {
      return realm("Новый realm: iframe srcdoc", function (f) { f.srcdoc = "<p>x</p>"; document.body.appendChild(f); });
    }],
    ["main-frame exposure", function () {
      var present = ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel", "WebTransport"].filter(function (n) {
        return typeof window[n] !== "undefined";
      });
      add("WebRTC/WebTransport в основном окне", present.length ? "bad" : "ok", present.length ? "ДОСТУПНО: " + present.join(", ") : "удалены до скриптов страницы");
      return Promise.resolve();
    }],
  ];

  // Tries to get a pristine global object (a second realm) and finds out whether the removed
  // APIs are back in it. A frame is the only way a page script could reach an untouched window.
  function realm(channel, attach) {
    return new Promise(function (resolve) {
      var f = document.createElement("iframe");
      f.style.display = "none";
      try { attach(f); } catch (e) { add(channel, "ok", "создание iframe отказано: " + e.message); resolve(); return; }
      setTimeout(function () {
        var w = null;
        try { w = f.contentWindow; } catch (e) { /* cross-origin */ }
        if (!w) { add(channel, "ok", "contentWindow недоступен"); resolve(); return; }
        var back = [];
        try {
          ["RTCPeerConnection", "webkitRTCPeerConnection", "WebTransport"].forEach(function (n) {
            if (typeof w[n] !== "undefined") back.push(n);
          });
        } catch (e) { add(channel, "ok", "realm закрыт: " + e.message); resolve(); return; }
        add(channel, back.length ? "bad" : "ok", back.length ? "ОБХОД: в новом realm доступно " + back.join(", ") : "API удалены и в новом realm");
        resolve();
      }, 500);
    });
  }

  function rtc(channel, url, cred) {
    return withTimeout(new Promise(function (res, rej) {
      if (typeof RTCPeerConnection === "undefined") { res("api absent"); return; }
      var server = { urls: url };
      if (cred) { server.username = cred.username; server.credential = cred.credential; }
      var pc = new RTCPeerConnection({ iceServers: [server] });
      var cands = [];
      pc.createDataChannel("x");
      pc.onicecandidate = function (e) {
        if (e.candidate) cands.push(e.candidate.candidate);
        else res("gathered " + cands.length);
      };
      pc.createOffer().then(function (o) { return pc.setLocalDescription(o); }).catch(rej);
    }), 5000).then(function (r) {
      var v = r.value || "";
      if (v === "api absent") add(channel, "ok", "API недоступен");
      else add(channel, "warn", r.timeout ? "тишина" : (v || "отказ") + ": смотрите canary; кандидаты раскрывают локальные адреса");
    });
  }

  function run() {
    tbody.textContent = ""; results = []; cspViolations = []; summary.className = ""; summary.textContent = "Выполняется…";
    var base = target().base;
    var chain = Promise.resolve();
    tests.forEach(function (t, i) {
      chain = chain.then(function () {
        current.port = base + i;
        return Promise.resolve().then(t[1]).catch(function (e) { add(t[0], "warn", "исключение: " + (e && e.message || e)); });
      });
    });
    return chain.then(function () {
      var bad = results.filter(function (r) { return r.state === "bad"; }).length;
      var warn = results.filter(function (r) { return r.state === "warn"; }).length;
      summary.className = bad ? "bad" : warn ? "warn" : "ok";
      summary.textContent = "Готово: ошибок " + bad + ", к проверке по canary " + warn + ", всего " + results.length +
        ". Порты " + base + "–" + (base + tests.length - 1) + ". Итог по сети — только по окну canary.py.";
    });
  }

  document.getElementById("run").onclick = run;
  document.getElementById("flood").onclick = function () {
    var n = 0, t0 = performance.now();
    for (var i = 0; i < 2000; i++) { if (window.hermesHost) { window.hermesHost.postMessage(JSON.stringify({ id: i, rpc: { op: "hostState" } })); n++; } }
    summary.className = "warn";
    summary.textContent = "Отправлено " + n + " сообщений за " + Math.round(performance.now() - t0) + " мс. Хост должен остаться отзывчивым.";
  };
  document.getElementById("freeze").onclick = function () {
    summary.textContent = "Зависаю…";
    setTimeout(function () { for (;;) { /* busy loop on purpose */ } }, 50);
  };
  // Start only when asked: automatic runs made earlier results disappear under later tests.
  summary.textContent = "Нажмите «Запустить все проверки».";
})();
