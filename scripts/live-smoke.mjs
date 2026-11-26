import { chromium } from "playwright";

const url = process.env.GAME_URL || "https://mute-tree-13ba.masshun.workers.dev/?smoke=v61";
const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage({
  viewport: { width: 390, height: 844 },
  deviceScaleFactor: 2,
  isMobile: true,
  hasTouch: true,
});
const pageErrors = [];

page.on("pageerror", error => pageErrors.push(error.message));
await page.route("https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2", route =>
  route.fulfill({
    contentType: "application/javascript",
    body: `
      window.supabase = {
        createClient() {
          return {
            auth: {
              getSession: async () => ({ data: { session: null } }),
              onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
              signInWithPassword: async () => ({ data: { user: { id: "smoke-user" } }, error: null }),
              signUp: async () => ({ data: { user: { id: "smoke-user" }, session: null }, error: null }),
              signOut: async () => ({ error: null })
            },
            from() {
              const q = {
                select() { return this; }, insert() { return Promise.resolve({ data: [], error: null }); },
                update() { return this; }, upsert() { return Promise.resolve({ data: [], error: null }); },
                eq() { return this; }, order() { return this; }, limit() { return Promise.resolve({ data: [], error: null }); },
                maybeSingle() { return Promise.resolve({ data: null, error: null }); },
                single() { return Promise.resolve({ data: null, error: null }); }
              };
              return q;
            },
            rpc: async () => ({ data: null, error: null })
          };
        }
      };
    `
  })
);

try {
  const response = await page.goto(url, { waitUntil: "domcontentloaded", timeout: 45000 });
  if (!response || response.status() !== 200) throw new Error("Game page did not return HTTP 200.");
  const build = await page.locator("html").getAttribute("data-game-build");
  if (build !== "v61-20261126") throw new Error("Wrong live build: " + build);

  await page.waitForSelector("#routedGameRoot", { state: "attached", timeout: 15000 });
  await page.locator("#homeStart").click();
  await page.waitForFunction(() => document.getElementById("loginPage")?.classList.contains("active"), null, { timeout: 5000 });
  const loginState = await page.evaluate(() => ({ nav: getComputedStyle(document.getElementById("gameNav")).display, adventure: getComputedStyle(document.getElementById("adventurePage")).display, login: getComputedStyle(document.getElementById("loginPage")).display }));
  if (loginState.nav !== "none" || loginState.adventure !== "none" || loginState.login === "none") throw new Error("Login screen is not isolated: " + JSON.stringify(loginState));

  await page.evaluate(() => {
    document.body.classList.remove("prelaunch");
    document.body.classList.add("routed-active");
    document.querySelectorAll(".game-page").forEach(el => el.classList.remove("active"));
    document.getElementById("adventurePage")?.classList.add("active");
    document.getElementById("adventurePage")?.style.setProperty("display", "block", "important");
    document.getElementById("loginPage")?.style.setProperty("display", "none", "important");
    document.getElementById("gameNav")?.style.setProperty("display", "flex", "important");
    const root = document.getElementById("routedGameRoot");
    if (root) root.style.setProperty("display", "block", "important");
  });

  await page.waitForSelector("#battleModeSelect", { timeout: 10000 });
  await page.locator("#battleModeSelect").selectOption("command");
  const hiddenBeforeBattle = await page.locator("#commandActionRow").evaluate(el => getComputedStyle(el).display);
  if (hiddenBeforeBattle === "none") {
    // Expected: command controls must stay out of the adventure page until the battle screen opens.
  } else {
    throw new Error("Battle commands leaked onto the adventure page: " + hiddenBeforeBattle);
  }

  await page.locator("#spawn").click();
  await page.waitForFunction(() => {
    const screen = document.getElementById("battleScreen");
    const row = document.getElementById("commandActionRow");
    return screen?.classList.contains("open") &&
      row?.parentElement?.classList.contains("battle-actions") &&
      getComputedStyle(row).display !== "none";
  }, null, { timeout: 12000 });

  if (pageErrors.length) throw new Error("Browser runtime errors: " + pageErrors.join(" | "));
  console.log("PASS: mobile title button opens an isolated login screen; navigation and adventure page are hidden.");
  console.log("PASS: command row stays hidden outside battle.");
  console.log("PASS: command row moves into battle actions and becomes visible during command battle.");
  console.log("PASS: live build marker is v61-20261126.");
} finally {
  await browser.close();
}
