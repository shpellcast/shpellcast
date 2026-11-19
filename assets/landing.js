(() => {
  "use strict";

  const feedback = document.getElementById("copy-feedback");
  document.querySelectorAll("button.copy[data-copy]").forEach((button) => {
    const source = document.querySelector(button.dataset.copy);
    if (!source) return;

    const label = button.textContent;
    let reset;
    button.hidden = false;
    button.addEventListener("click", async () => {
      clearTimeout(reset);
      try {
        // The pipe suffix starts with a space so it can follow an existing command.
        await navigator.clipboard.writeText(source.textContent);
        button.textContent = "Copied";
        button.classList.add("done");
        feedback.textContent = "Command copied.";
      } catch (_) {
        const selection = window.getSelection();
        if (selection) {
          const range = document.createRange();
          range.selectNodeContents(source);
          selection.removeAllRanges();
          selection.addRange(range);
        }
        button.textContent = selection ? "Selected" : "Copy manually";
        button.classList.remove("done");
        feedback.textContent = selection ? "Clipboard unavailable. Copy the selected command." : "Clipboard unavailable. Select the command to copy it.";
      }
      reset = setTimeout(() => {
        button.textContent = label;
        button.classList.remove("done");
      }, 2000);
    });
  });

  const demo = document.getElementById("demo");
  const play = document.getElementById("play-demo");
  const status = document.getElementById("demo-state");
  const steps = Array.from(demo.querySelectorAll("[data-reveal]"));
  const link = demo.querySelector(".demo-link");
  const firstLine = demo.querySelector(".log li");
  const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const timers = [];
  let hasPlayed = false;

  function setStatus(state, label) {
    status.dataset.state = state;
    status.textContent = label;
  }

  function finish() {
    timers.splice(0).forEach((timer) => clearTimeout(timer));
    steps.forEach((step) => step.removeAttribute("data-pending"));
    link.classList.remove("revealed");
    demo.removeAttribute("data-playing");
    setStatus("sealed", "Sealed");
    play.textContent = hasPlayed ? "Replay demo" : "Play demo";
    play.hidden = reducedMotion.matches;
  }

  function start() {
    if (reducedMotion.matches || demo.hasAttribute("data-playing")) return;

    hasPlayed = true;
    demo.setAttribute("data-playing", "");
    play.textContent = "Skip to end";
    setStatus("waiting", "Waiting");
    steps.forEach((step) => step.setAttribute("data-pending", ""));

    steps.forEach((step, index) => {
      timers.push(setTimeout(() => {
        step.removeAttribute("data-pending");
        if (step === link) link.classList.add("revealed");
        if (step === firstLine) setStatus("streaming", "Streaming");
        if (index === steps.length - 1) finish();
      }, Number(step.dataset.reveal)));
    });
  }

  finish();
  reducedMotion.addEventListener("change", finish);
  play.addEventListener("click", () => {
    if (demo.hasAttribute("data-playing")) finish();
    else start();
  });
  document.getElementById("see-demo").addEventListener("click", start);

  if ("IntersectionObserver" in window && !reducedMotion.matches) {
    const observer = new IntersectionObserver(([entry]) => {
      if (entry.intersectionRatio < 0.3) return;
      observer.disconnect();
      if (!hasPlayed) start();
    }, { threshold: 0.3 });
    observer.observe(demo);
  }
})();
