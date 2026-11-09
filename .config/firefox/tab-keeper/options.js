const { karakeepOrigin } = globalThis.TabKeeperRules;
const $ = (id) => document.getElementById(id);
let config = null;

async function render() {
  const [current, { log = [] }] = await Promise.all([browser.runtime.sendMessage("state"), browser.storage.local.get("log")]);
  config = current.config;
  $("problem").textContent = current.problem ?? "";
  $("config").value = JSON.stringify(config, null, 2);
  $("grant").disabled = !config.karakeepUrl;
  $("log").textContent = log.slice().reverse().map((entry) => JSON.stringify(entry)).join("\n");
}

$("grant").addEventListener("click", async () => {
  // permissions.request needs the click, so nothing is awaited before it.
  const granted = await browser.permissions.request({ origins: [karakeepOrigin(config.karakeepUrl)] });
  $("status").textContent = granted ? "Karakeep access granted" : "Karakeep access was refused";
  await render();
});

$("tick").addEventListener("click", async () => {
  await browser.runtime.sendMessage("tick");
  await render();
});

render();
