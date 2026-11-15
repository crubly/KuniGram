document.addEventListener("DOMContentLoaded", () => {
  // Copy buttons
  document.querySelectorAll(".code-wrap").forEach((wrap) => {
    const btn = wrap.querySelector(".copy-btn");
    const code = wrap.querySelector("code");
    if (!btn || !code) return;
    btn.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(code.innerText);
        const prev = btn.textContent;
        btn.textContent = "Copied!";
        setTimeout(() => { btn.textContent = prev; }, 1400);
      } catch (_) {}
    });
  });

  // Language switcher
  let currentLang = "ru";
  const toggleBtn = document.getElementById("lang-toggle");
  const applyLang = (lang) => {
    currentLang = lang;
    document.querySelectorAll("[data-ru][data-en]").forEach((el) => {
      el.textContent = el.getAttribute(`data-${lang}`);
    });
    if (toggleBtn) {
      toggleBtn.textContent = lang === "ru" ? "EN" : "RU";
    }
  };
  if (toggleBtn) {
    toggleBtn.addEventListener("click", () => {
      applyLang(currentLang === "ru" ? "en" : "ru");
    });
  }
  applyLang("ru");
});
