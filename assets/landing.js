(() => {
  "use strict";

  const feedback = document.getElementById("copy-feedback");
  document.querySelectorAll("button.copy[data-copy]").forEach((btn) => {
    const src = document.querySelector(btn.dataset.copy);
    if (!src) return;
    let reset;
    btn.hidden = false;
    btn.addEventListener("click", async () => {
      clearTimeout(reset);
      try {
        await navigator.clipboard.writeText(src.textContent.trim());
        btn.textContent = "Copied";
        btn.classList.add("done");
        feedback.textContent = "Command copied.";
      } catch (_) {
        const selection = window.getSelection();
        const range = document.createRange();
        range.selectNodeContents(src);
        selection.removeAllRanges();
        selection.addRange(range);
        btn.textContent = "Selected";
        btn.classList.remove("done");
        feedback.textContent = "Clipboard unavailable. Copy the selected command.";
      }
      reset = setTimeout(() => {
        btn.textContent = "Copy";
        btn.classList.remove("done");
        feedback.textContent = "";
      }, 1800);
    });
  });

  const play = document.getElementById("play-demo");
  const steps = Array.from(document.querySelectorAll("#demo [data-demo-step]"));
  const link = document.querySelector(".demo-link");
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const timers = [];
  let hasPlayed = false;

  function stopDemo() {
    timers.splice(0).forEach((timer) => clearTimeout(timer));
    steps.forEach((step) => step.removeAttribute("data-demo-pending"));
    link.classList.remove("revealed");
    play.removeAttribute("aria-disabled");
    play.textContent = hasPlayed ? "Replay demo" : "Play demo";
    play.hidden = reducedMotion.matches;
  }

  stopDemo();
  reducedMotion.addEventListener("change", stopDemo);
  play.addEventListener("click", () => {
    if (reducedMotion.matches || play.hasAttribute("aria-disabled")) return;
    hasPlayed = true;
    play.setAttribute("aria-disabled", "true");
    play.textContent = "Playing…";
    steps.forEach((step) => step.setAttribute("data-demo-pending", ""));

    steps.forEach((step, index) => {
      timers.push(setTimeout(() => {
        step.removeAttribute("data-demo-pending");
        if (step === link) link.classList.add("revealed");
        if (index === steps.length - 1) stopDemo();
      }, Number(step.dataset.demoStep)));
    });
  });
})();
