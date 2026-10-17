// Copy buttons: <button data-copy="#target"> copies #target's text.
document.addEventListener("click", async (event) => {
  const button = event.target.closest("[data-copy]");
  const target = button && document.querySelector(button.dataset.copy);
  if (!target) return;
  await navigator.clipboard.writeText(target.innerText.trim());
  const label = button.textContent;
  button.textContent = "Copied";
  setTimeout(() => { button.textContent = label; }, 1500);
});
