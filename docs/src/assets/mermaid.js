// Rendu des diagrammes Mermaid pour les pages Documenter.
//
// Pourquoi un asset maison plutôt que DocumenterMermaid : Documenter charge
// RequireJS, dont le `define()` global capture les modules UMD empaquetés dans
// mermaid@11 (dayjs, etc.) -> « Mismatched anonymous define() » puis
// « Se.default.extend is not a function ». On neutralise donc `define`/`require`
// le temps de l'import dynamique de mermaid, puis on les restaure.

(function () {
  "use strict";

  var MERMAID_URL = "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
  var mermaidPromise = null;

  function loadMermaid() {
    if (mermaidPromise) return mermaidPromise;
    var savedDefine = window.define;
    var savedRequire = window.require;
    try {
      window.define = undefined;
      window.require = undefined;
    } catch (e) { /* propriétés non configurables sur certains navigateurs */ }
    mermaidPromise = import(MERMAID_URL)
      .then(function (m) { return m.default; })
      .finally(function () {
        window.define = savedDefine;
        window.require = savedRequire;
      });
    return mermaidPromise;
  }

  // Thème courant de Documenter (clair / sombre), tel qu'il est réellement appliqué.
  // Documenter 1.x embarque documenter-light/dark + les 4 variantes catppuccin.
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

  var busy = false, again = false;
  function render() {
    if (busy) { again = true; return; }
    var divs = collectDivs();
    if (!divs.length) return;
    busy = true;
    loadMermaid()
      .then(function (mermaid) {
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
        return mermaid.run({ nodes: divs });
      })
      .catch(function (e) { console.error("[mermaid]", e); })
      .finally(function () {
        busy = false;
        if (again) { again = false; render(); }
      });
  }

  function ready(fn) {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", fn);
    } else {
      fn();
    }
  }

  ready(function () {
    render();
    // Re-rendu quand Documenter bascule le thème clair / sombre.
    var pending = null;
    function schedule() {
      clearTimeout(pending);
      pending = setTimeout(render, 100);
    }
    var obs = new MutationObserver(schedule);
    obs.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
    document.querySelectorAll("link[data-theme-name]").forEach(function (l) {
      obs.observe(l, { attributes: true, attributeFilter: ["disabled"] });
    });
  });
})();
