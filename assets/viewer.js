(() => {
  "use strict";

  const base = location.pathname.replace(/\/+$/, "");
  const $ = (id) => document.getElementById(id);
  const out = $("out");
  const empty = $("empty");
  const faded = $("faded");
  const seal = $("seal");
  const stateEl = $("state");
  const watchers = $("watchers");
  const jump = $("jump");
  const raw = $("raw");

  const MAX_LINES = 5000;
  const QUIET_MS = 10000;
  const TOKEN = /(\x1b\[[0-9;?]*[A-Za-z]|\r\n|\n|\r)/;

  let line = null;
  let lastData = 0;
  let lineCount = 0;
  let following = true;
  let scrollQueued = false;
  let style = { fg: null, bold: false, ul: false };

  raw.href = base + "/raw";

  function setState(name, mode) {
    if (stateEl.textContent !== name) stateEl.textContent = name;
    if (document.body.dataset.state !== mode) document.body.dataset.state = mode;
  }

  function fmtDuration(sec) {
    if (sec < 60) return Math.max(1, Math.round(sec)) + "s";
    if (sec < 3600) return Math.floor(sec / 60) + "m " + Math.round(sec % 60) + "s";
    return Math.floor(sec / 3600) + "h " + Math.floor((sec % 3600) / 60) + "m";
  }

  function fmtBytes(n) {
    if (n < 1024) return n + " B";
    if (n < 1048576) return (n / 1024).toFixed(1) + " KB";
    return (n / 1048576).toFixed(1) + " MB";
  }

  function plural(n, word) {
    return n + " " + word + (n === 1 ? "" : "s");
  }

  function atBottom() {
    return window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 120;
  }

  function scheduleScroll() {
    if (!following || scrollQueued) return;
    scrollQueued = true;
    requestAnimationFrame(() => {
      scrollQueued = false;
      window.scrollTo(0, document.documentElement.scrollHeight);
    });
  }

  function setFollowing(on) {
    following = on;
    jump.hidden = on || !out.childElementCount;
    if (on) scheduleScroll();
  }

  window.addEventListener("scroll", () => {
    if (atBottom()) {
      if (!following) setFollowing(true);
    } else if (following) {
      setFollowing(false);
    }
  }, { passive: true });

  jump.addEventListener("click", () => setFollowing(true));

  function reset() {
    out.replaceChildren();
    line = null;
    lineCount = 0;
    lastData = 0;
    style = { fg: null, bold: false, ul: false };
    seal.hidden = true;
    seal.textContent = "";
    faded.hidden = true;
    jump.hidden = true;
    raw.hidden = false;
    empty.hidden = true;
  }

  function ensureLine() {
    if (line) return line;
    line = document.createElement("div");
    line.className = "ln";
    out.appendChild(line);
    lineCount++;
    empty.hidden = true;
    if (out.childElementCount > MAX_LINES) out.firstElementChild.remove();
    return line;
  }

  function endLine() {
    line = null;
  }

  function applySGR(params) {
    if (params.indexOf("?") !== -1) return;
    const codes = params === "" ? [0] : params.split(";").map(Number);
    for (const c of codes) {
      if (c === 0) style = { fg: null, bold: false, ul: false };
      else if (c === 1) style.bold = true;
      else if (c === 22) style.bold = false;
      else if (c === 4) style.ul = true;
      else if (c === 24) style.ul = false;
      else if ((c >= 30 && c <= 37) || (c >= 90 && c <= 97)) style.fg = c;
      else if (c === 39) style.fg = null;
    }
  }

  function appendText(text) {
    const target = ensureLine();
    const span = document.createElement("span");
    const classes = [];
    if (style.fg !== null) classes.push("c" + style.fg);
    if (style.bold) classes.push("b");
    if (style.ul) classes.push("u");
    if (classes.length) span.className = classes.join(" ");
    span.textContent = text;
    target.appendChild(span);
  }

  function writeChunk(text) {
    const now = Date.now();
    if (lastData && now - lastData > QUIET_MS && lineCount > 0) {
      endLine();
      const gap = document.createElement("div");
      gap.className = "gap";
      gap.textContent = "quiet for " + fmtDuration((now - lastData) / 1000);
      out.appendChild(gap);
    }
    lastData = now;

    for (const tok of text.split(TOKEN)) {
      if (tok === "") continue;
      if (tok === "\n" || tok === "\r\n") {
        endLine();
      } else if (tok === "\r") {
        if (line) line.replaceChildren();
      } else if (tok.charAt(0) === "\x1b") {
        const final = tok.charAt(tok.length - 1);
        if (final === "m") applySGR(tok.slice(2, -1));
        else if (final === "K" && line) line.replaceChildren();
      } else {
        appendText(tok);
      }
    }
    scheduleScroll();
  }

  function finish(stats) {
    endLine();
    setState("Sealed", "sealed");
    empty.hidden = true;
    const glyph = document.createElement("span");
    glyph.className = "glyph";
    glyph.setAttribute("aria-hidden", "true");
    glyph.textContent = "✦";
    const details = stats.bytes === 0 ? "no output" :
      fmtDuration(stats.duration) + " · " + fmtBytes(stats.bytes) + " · " + plural(stats.lines, "line");
    seal.replaceChildren(glyph, " Cast sealed · " + details);
    seal.hidden = false;
    scheduleScroll();
  }

  function showFaded() {
    setState("Unavailable", "faded");
    empty.hidden = true;
    out.replaceChildren();
    faded.hidden = false;
    watchers.textContent = "";
    jump.hidden = true;
    raw.hidden = true;
  }

  function parse(e) {
    try {
      return JSON.parse(e.data);
    } catch (_) {
      return {};
    }
  }

  reset();
  raw.hidden = true;
  setState("Connecting", "connecting");

  const es = new EventSource(base + "/events");

  es.addEventListener("snapshot", (e) => {
    reset();
    const t = parse(e).t || "";
    setState(t ? "Streaming" : "Waiting", t ? "streaming" : "waiting");
    if (t) writeChunk(t);
    else empty.hidden = false;
  });

  es.addEventListener("data", (e) => {
    setState("Streaming", "streaming");
    writeChunk(parse(e).t || "");
  });

  es.addEventListener("viewers", (e) => {
    const n = parse(e).n || 0;
    watchers.textContent = n > 0 ? n + " watching" : "";
  });

  es.addEventListener("end", (e) => {
    finish(parse(e));
    es.close();
  });

  es.onerror = () => {
    if (es.readyState === EventSource.CLOSED) {
      showFaded();
    } else {
      setState("Reconnecting", "connecting");
    }
  };
})();
