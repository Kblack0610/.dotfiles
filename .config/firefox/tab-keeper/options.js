const { withDefaults, configErrors } = globalThis.TabKeeperRules;
const $ = (id) => document.getElementById(id);

async function render() {
  const { config, log = [] } = await browser.storage.local.get(["config", "log"]);
  $("config").value = JSON.stringify(withDefaults(config), null, 2);
  $("log").textContent = log.slice().reverse().map((entry) => JSON.stringify(entry)).join("\n");
}

$("save").addEventListener("click", async () => {
  let config;
  try {
    config = JSON.parse($("config").value);
  } catch (error) {
    $("status").textContent = `Not valid JSON: ${error.message}`;
    return;
  }
  const errors = configErrors(config);
  if (errors.length) {
    $("status").textContent = errors.join("; ");
    return;
  }
  // permissions.request needs the click, so it runs before anything else is awaited.
  if (config.karakeepUrl) {
    // Firefox match patterns carry no port, so this is built from the hostname, not the origin.
    const { protocol, hostname } = new URL(config.karakeepUrl);
    const granted = await browser.permissions.request({ origins: [`${protocol}//${hostname}/*`] });
    if (!granted) {
      $("status").textContent = "Karakeep access was refused, nothing saved";
      return;
    }
  }
  const key = $("key").value.trim();
  await browser.storage.local.set(key ? { config, karakeepKey: key } : { config });
  $("key").value = "";
  $("status").textContent = "Saved";
  await render();
});

$("tick").addEventListener("click", async () => {
  await browser.runtime.sendMessage("tick");
  await render();
});

render();
