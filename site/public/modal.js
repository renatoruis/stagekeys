(() => {
  for (const link of document.querySelectorAll("[data-modal]")) {
    link.addEventListener("click", (e) => {
      const dialog = document.getElementById(link.dataset.modal);
      if (!dialog?.showModal) return;
      e.preventDefault();
      dialog.showModal();
    });
  }

  for (const dialog of document.querySelectorAll("dialog")) {
    dialog.addEventListener("click", (e) => {
      const r = dialog.getBoundingClientRect();
      const inside = e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom;
      if (!inside) dialog.close();
    });
  }

  for (const button of document.querySelectorAll("[data-copy]")) {
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(button.dataset.copy);
        button.textContent = "Copiado!";
      } catch {
        button.textContent = "Copie acima";
      }
      setTimeout(() => (button.textContent = "Copiar"), 1800);
    });
  }
})();
