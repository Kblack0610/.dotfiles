// <kb-shell>: a site's top bar and its tabs under group headings (README.md has the markup).
// The site renders the bar and the whole tab list as plain HTML; this element only adds the
// phone menu: a button that opens the list as a dropdown, and the open tab's name beside the
// brand. The open tab is the item with aria-current; a page that switches tabs without a load
// (agent-web's hash routes) just moves the attribute and the name follows.
class KbShell extends HTMLElement {
  #menu = null;
  #cur = null;
  #nav = null;
  #watch = null;
  #onDoc = (e) => { if (!this.contains(e.target)) this.toggle(false); };
  #onKey = (e) => { if (e.key === "Escape") this.toggle(false); };

  connectedCallback() {
    document.addEventListener("click", this.#onDoc);
    document.addEventListener("keydown", this.#onKey);
    if (this.#menu) return;
    this.#nav = this.querySelector(".kb-nav");
    if (!this.#nav) return;
    if (!this.#nav.id) this.#nav.id = "kb-nav";
    const menu = document.createElement("button");
    menu.type = "button";
    menu.className = "kb-menu";
    menu.setAttribute("aria-label", "Menu");
    menu.setAttribute("aria-expanded", "false");
    menu.setAttribute("aria-controls", this.#nav.id);
    menu.innerHTML = '<span class="kb-bars"></span>';
    // A count the site keeps on the bar (agent-web's Needs you) rides on the button, so a
    // closed menu still says something waits.
    const badge = this.querySelector(".kb-menu-badge");
    if (badge) menu.append(badge);
    menu.addEventListener("click", (e) => { e.stopPropagation(); this.toggle(); });
    this.prepend(menu);
    this.#menu = menu;
    this.#cur = document.createElement("span");
    this.#cur.className = "kb-cur";
    (this.querySelector(".kb-brand") || menu).after(this.#cur);
    // A pick closes the menu; so does a tap outside the bar or Escape.
    this.#nav.addEventListener("click", (e) => { if (e.target.closest("a, button")) this.toggle(false); });
    this.#watch = new MutationObserver(() => this.#label());
    this.#watch.observe(this.#nav, { subtree: true, attributes: true, attributeFilter: ["aria-current"] });
    this.#label();
  }

  disconnectedCallback() {
    document.removeEventListener("click", this.#onDoc);
    document.removeEventListener("keydown", this.#onKey);
  }

  toggle(on = !this.hasAttribute("open")) {
    if (!this.#menu) return;
    this.toggleAttribute("open", on);
    this.#menu.setAttribute("aria-expanded", on ? "true" : "false");
  }

  // The open tab's name: its data-title, else its first text (a count after it is not the name).
  #label() {
    const item = this.#nav.querySelector(":scope > [aria-current]");
    this.#cur.textContent = item ? (item.dataset.title || item.firstChild?.textContent || "").trim() : "";
  }
}

customElements.define("kb-shell", KbShell);
