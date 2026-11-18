(() => {
  "use strict";

  document.querySelectorAll("button.copy[data-copy]").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const src = document.querySelector(btn.dataset.copy);
      if (!src) return;
      try {
        await navigator.clipboard.writeText(src.textContent.trim());
        btn.textContent = "Copied";
        btn.classList.add("done");
      } catch (_) {
        btn.textContent = "Select and copy";
      }
      setTimeout(() => {
        btn.textContent = "Copy";
        btn.classList.remove("done");
      }, 1800);
    });
  });
})();
