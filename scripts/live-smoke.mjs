import { chromium } from "playwright";

const url = process.env.GAME_URL || "https://mute-tree-13ba.masshun.workers.dev/?smoke=v65";
const browser = await chromium.launch({ headless: true, args: ["--no-sandbox"] });
const page = await browser.newPage({
  viewport: { width: 390, height: 844 },
  deviceScaleFactor: 2,
  isMobile: true,
  hasTouch: true,
});
const pageErrors = [];
const consoleErrors = [];
page.on("console", message => { if (message.type() === "error") consoleErrors.push(message.text()); });

page.on("pageerror", error => pageErrors.push(error.stack || error.message));
await page.route("https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2", route =>
  route.fulfill({
    contentType: "application/javascript",
    body: `
      window.supabase = {
        createClient() {
          return {
            auth: {
              getSession: async () => ({ data: { session: window.__smokeSession || null } }),
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
  try {
    await page.waitForSelector("#gameNav", { state: "attached", timeout: 12000 });
  } catch {
    const html = await page.content();
    throw new Error("Game navigation did not initialize. pageErrors=" + JSON.stringify(pageErrors) + " consoleErrors=" + JSON.stringify(consoleErrors) + " htmlStart=" + html.slice(0, 2500));
  }
  const build = await page.locator("html").getAttribute("data-game-build");
  if (build !== "v70-20261129") throw new Error("Wrong live build: " + build);

  const navLabels = await page.locator("#gameNav button").allTextContents();
  if (navLabels.some(label => /キャラクター|装備/.test(label))) throw new Error("Character/equipment navigation buttons remain: " + navLabels.join(", "));
  if (navLabels.length < 1) throw new Error("Game navigation is missing.");
  const mergedSections = await page.evaluate(() => {
    const adventure = document.querySelector("#adventurePage");
    const logout = document.querySelector("#adventureLogoutBtn");
    const skills = document.querySelector("#skillsPage");
    const loadout = document.querySelector("#skillLoadout");
    return {
      character: [...document.querySelectorAll("#adventurePage section")].some(el => /自分のキャラクター/.test(el.textContent)),
      equipment: [...document.querySelectorAll("#adventurePage section")].some(el => /装備・バッグ/.test(el.textContent)),
      logoutInAdventure: logout?.parentElement === adventure,
      logoutLast: logout?.parentElement === adventure && logout === adventure.lastElementChild,
      adventureChildren: [...(adventure?.children || [])].map(el => el.id || el.tagName),
      skillLoadoutInSkills: loadout?.parentElement?.closest("#skillsPage") === skills,
      skillLoadoutNotInAdventure: !adventure?.contains(loadout)
    };
  });
  if (!mergedSections.character || !mergedSections.equipment || !mergedSections.logoutInAdventure || !mergedSections.skillLoadoutInSkills || !mergedSections.skillLoadoutNotInAdventure) throw new Error("Page organization failed: " + JSON.stringify(mergedSections));

  await page.waitForSelector("#routedGameRoot", { state: "attached", timeout: 15000 });
  await page.locator("#dailyBonusOverlay").evaluate(el => { el.style.setProperty("display", "none", "important"); el.setAttribute("aria-hidden", "true"); }).catch(() => {});
  await page.locator("#homeStart").click({ force: true });
  await page.waitForFunction(() => document.getElementById("loginPage")?.classList.contains("active"), null, { timeout: 5000 });
  const loginState = await page.evaluate(() => ({ nav: getComputedStyle(document.getElementById("gameNav")).display, adventure: getComputedStyle(document.getElementById("adventurePage")).display, login: getComputedStyle(document.getElementById("loginPage")).display }));
  if (loginState.nav !== "none" || loginState.adventure !== "none" || loginState.login === "none") throw new Error("Login screen is not isolated: " + JSON.stringify(loginState));

  await page.evaluate(() => { window.__smokeSession = { user: { id: "smoke-user", user_metadata: { player_name: "Smoke" } } }; });
  await page.locator("#loginPage .login-back").click({ force: true });
  await page.locator("#homeStart").click();
  await page.waitForFunction(() => document.getElementById("adventurePage")?.classList.contains("active"), null, { timeout: 5000 });
  const resumedState = await page.evaluate(() => ({ login: getComputedStyle(document.getElementById("loginPage")).display, adventure: getComputedStyle(document.getElementById("adventurePage")).display }));
  if (resumedState.login !== "none" || resumedState.adventure === "none") throw new Error("Existing session did not bypass login: " + JSON.stringify(resumedState));

  const rareEncounter = await page.evaluate(() => {
    if (typeof window.spawn !== "function") return { available: false };
    const difficulty = document.getElementById("diff");
    if (!difficulty) return { available: false, reason: "difficulty selector missing" };
    difficulty.value = "最弱";
    const originalRandom = Math.random;
    const originalSetInterval = window.setInterval;
    Math.random = () => 0;
    window.setInterval = () => 1;
    try { window.spawn(); } finally { Math.random = originalRandom; window.setInterval = originalSetInterval; }
    return {
      available: true,
      singleRare: document.getElementById("battleEnemyTitle")?.textContent.includes("RARE MONSTER") &&
        document.getElementById("battleEnemySprite")?.textContent.includes("🦇") &&
        !/ほか\\d+体/.test(document.getElementById("enemy")?.textContent || ""),
      alertBanner: !!document.querySelector("#battleScreen .rare-alert-banner"),
      rareMode: document.getElementById("battleScreen")?.classList.contains("rare-battle")
    };
  });
  if (!rareEncounter.available || !rareEncounter.singleRare || !rareEncounter.alertBanner || !rareEncounter.rareMode) {
    throw new Error("Rare encounter presentation failed: " + JSON.stringify(rareEncounter));
  }

  if (pageErrors.length) throw new Error("Browser runtime errors: " + pageErrors.join(" | "));
  console.log("PASS: battle skill loadout is inside the Skills page and absent from Adventure.");
  console.log("PASS: Adventure contains character, equipment, and a bottom logout button.");
  console.log("PASS: existing login routing works and live build marker is v70-20261129.");
} finally {
  await browser.close();
}
