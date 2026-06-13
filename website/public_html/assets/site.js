(() => {
  const navToggle = document.querySelector(".nav-toggle");
  const siteNav = document.querySelector(".site-nav");

  if (navToggle && siteNav) {
    navToggle.addEventListener("click", () => {
      const isOpen = siteNav.classList.toggle("is-open");
      navToggle.setAttribute("aria-expanded", String(isOpen));
    });

    document.addEventListener("click", (event) => {
      if (!siteNav.classList.contains("is-open")) {
        return;
      }
      const target = event.target;
      if (target instanceof Node && !siteNav.contains(target) && !navToggle.contains(target)) {
        siteNav.classList.remove("is-open");
        navToggle.setAttribute("aria-expanded", "false");
      }
    });
  }

  document.querySelectorAll("[data-copy-code]").forEach((button) => {
    button.addEventListener("click", async () => {
      const box = button.closest(".command-box");
      const code = box?.querySelector("code")?.textContent || "";
      if (!code.trim()) {
        return;
      }
      try {
        await navigator.clipboard.writeText(code);
        button.textContent = "Copied";
        window.setTimeout(() => {
          button.textContent = "Copy";
        }, 1200);
      } catch {
        button.textContent = "Select";
        const range = document.createRange();
        const selection = window.getSelection();
        const codeElement = box?.querySelector("code");
        if (codeElement && selection) {
          range.selectNodeContents(codeElement);
          selection.removeAllRanges();
          selection.addRange(range);
        }
      }
    });
  });
})();
