// Rendu des diagrammes Mermaid pour les pages Documenter.
//
// mermaid est chargé depuis assets/mermaid.bundle.js : un bundle IIFE (esbuild,
// `--define:define=undefined`) qui n'émet aucun appel `define()`. Il expose
// `window.__mermaidLib` et n'entre donc PAS en conflit avec le chargeur AMD
// (RequireJS) embarqué par Documenter — contrairement au build ESM de mermaid
// servi par CDN, dont les dépendances UMD (dayjs…) se font capturer par
// RequireJS (« Mismatched anonymous define() » / « Se.default.extend is not a
// function »).

(function () {
  "use strict";

  // Thème courant de Documenter (documenter-light/dark + variantes catppuccin).
  var DARK = /dark$|mocha$|macchiato$|frappe$/i;
  var LIGHT = /light$|latte$/i;

  function isDark() {
    var m = (document.documentElement.className || "").match(/theme--([\w-]+)/);
    if (m) {
      if (LIGHT.test(m[1])) return false;
      if (DARK.test(m[1])) return true;
    }
    var links = document.querySelectorAll("link[data-theme-name]");
    for (var i = 0; i < links.length; i++) {
      if (links[i].disabled) continue;
      var name = links[i].getAttribute("data-theme-name") || "";
      if (LIGHT.test(name)) return false;
      if (DARK.test(name)) return true;
    }
    try {
      var stored = localStorage.getItem("documenter-theme");
      if (stored) return DARK.test(stored);
    } catch (e) { /* localStorage indisponible */ }
    return false;
  }

  // <pre><code class="language-mermaid"> (rendu Documenter) -> <div class="mermaid">,
  // en mémorisant la source pour un re-rendu propre au changement de thème.
  function collectDivs() {
    var codes = document.querySelectorAll(
      'pre > code.language-mermaid, pre > code.mermaid, pre.mermaid > code'
    );
    Array.prototype.forEach.call(codes, function (code) {
      var pre = code.closest("pre");
      if (!pre) return;
      var div = document.createElement("div");
      div.className = "mermaid";
      div.setAttribute("data-mermaid-src", code.textContent);
      div.textContent = code.textContent;
      pre.replaceWith(div);
    });
    return Array.prototype.slice.call(document.querySelectorAll("div.mermaid"));
  }

  function whenLib(cb) {
    if (window.__mermaidLib) return cb(window.__mermaidLib);
    var tries = 0;
    var t = setInterval(function () {
      if (window.__mermaidLib) { clearInterval(t); cb(window.__mermaidLib); }
      else if (++tries > 100) { clearInterval(t); console.error("[mermaid] bundle non chargé"); }
    }, 50);
  }

  var busy = false, again = false;
  function render() {
    if (busy) { again = true; return; }
    var divs = collectDivs();
    if (!divs.length) return;
    busy = true;
    whenLib(function (mermaid) {
      try {
        mermaid.initialize({
          startOnLoad: false,
          securityLevel: "loose",
          theme: isDark() ? "dark" : "neutral",
          flowchart: { htmlLabels: true, useMaxWidth: true }
        });
        divs.forEach(function (d) {
          d.removeAttribute("data-processed");
          d.innerHTML = d.getAttribute("data-mermaid-src") || d.textContent;
        });
        mermaid.run({ nodes: divs })
          .catch(function (e) { console.error("[mermaid]", e); })
          .finally(function () { busy = false; if (again) { again = false; render(); } });
      } catch (e) {
        console.error("[mermaid]", e);
        busy = false;
      }
    });
  }

  function start() {
    render();
    var pending = null;
    function schedule() { clearTimeout(pending); pending = setTimeout(render, 100); }
    var obs = new MutationObserver(schedule);
    obs.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
    document.querySelectorAll("link[data-theme-name]").forEach(function (l) {
      obs.observe(l, { attributes: true, attributeFilter: ["disabled"] });
    });
  }

  if (document.readyState !== "loading") start();
  else document.addEventListener("DOMContentLoaded", start);
})();
