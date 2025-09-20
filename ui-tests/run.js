import { spawn } from "node:child_process";
import { once } from "node:events";
import { setTimeout as delay } from "node:timers/promises";
import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { remote } from "webdriverio";

const host = process.env.ZMP_APPIUM_HOST ?? "127.0.0.1";
const port = Number(process.env.ZMP_APPIUM_PORT ?? "4723");
const appPackage = process.env.ZMP_APP_PACKAGE ?? "com.example.demo";
const appActivity = process.env.ZMP_APP_ACTIVITY ?? ".MainActivity";
const deviceName = process.env.ZMP_DEVICE_NAME ?? "Android Emulator";
const expectContext = (process.env.ZMP_EXPECT_CONTEXT ?? "web").toLowerCase();
const nativeSelector = process.env.ZMP_EXPECT_SELECTOR ?? process.env.ZMP_NATIVE_SELECTOR ?? 'android=new UiSelector().textContains("Zig says")';
const nativeExpect = process.env.ZMP_EXPECT_TEXT ?? process.env.ZMP_NATIVE_EXPECT ?? "Zig says: 42";
const webSelector = process.env.ZMP_WEB_SELECTOR ?? "#count";
const webExpect = process.env.ZMP_WEB_EXPECT ?? "Count: 0";
const webContextMatch = (process.env.ZMP_WEB_CONTEXT_MATCH ?? "webview").toLowerCase();
const driverSpec = process.env.ZMP_APPIUM_DRIVER ?? "uiautomator2@2.27.0";
const appiumHome = path.resolve(process.env.APPIUM_HOME ?? path.join(process.cwd(), ".appium"));
const appiumBin = process.env.ZMP_APPIUM_BIN ?? "appium";

function spawnAppium(args, options = {}) {
  const env = { ...process.env, APPIUM_HOME: appiumHome, ...(options.env ?? {}) };
  return spawn(appiumBin, args, { ...options, env });
}

async function ensureUiAutomator2() {
  await fs.mkdir(appiumHome, { recursive: true });
  const list = spawnAppium(["driver", "list", "--installed", "--json"], {
    stdio: ["ignore", "pipe", "inherit"],
  });
  let data = "";
  list.stdout.setEncoding("utf8");
  list.stdout.on("data", (chunk) => (data += chunk));
  const [code] = await once(list, "exit");
  if (code !== 0) {
    throw new Error("Failed to query installed Appium drivers");
  }
  try {
    const parsed = JSON.parse(data || "{}");
    const drivers = parsed.driver ?? parsed;
    if (drivers?.uiautomator2) {
      return;
    }
  } catch (err) {
    console.warn("Unable to parse Appium driver list output", err);
  }
  console.log(`Installing Appium driver ${driverSpec} (APPIUM_HOME=${appiumHome})...`);
  const install = spawnAppium(["driver", "install", driverSpec], { stdio: "inherit" });
  const [installCode] = await once(install, "exit");
  if (installCode !== 0) {
    throw new Error("Failed to install Appium UiAutomator2 driver");
  }
  console.log("Appium UiAutomator2 driver ready.");
}

async function startAppium() {
  const args = ["--base-path", "/", "--address", host, "--port", String(port)];
  args.push("--allow-insecure", "chromedriver_autodownload");
  const child = spawnAppium(args, { stdio: ["ignore", "pipe", "pipe"] });
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");

  const ready = new Promise((resolve, reject) => {
    let resolved = false;
    const onStdout = (chunk) => {
      if (!resolved && chunk.includes("AppiumREST http interface listener started")) {
        resolved = true;
        child.stdout.off("data", onStdout);
        resolve(undefined);
      }
    };
    child.stdout.on("data", onStdout);
    child.stderr.on("data", (chunk) => {
      if (!resolved && chunk.toLowerCase().includes("error")) {
        resolved = true;
        reject(new Error(chunk));
      }
    });
    child.on("exit", (code) => {
      if (!resolved) {
        resolved = true;
        reject(new Error(`Appium exited with code ${code}`));
      }
    });
  });

  await Promise.race([ready, delay(15000)]);
  await delay(500);
  return child;
}

async function stopAppium(child) {
  if (!child.killed) {
    child.kill();
    await once(child, "exit");
  }
}

async function waitForWebContext(client, match) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    const contexts = await client.getContexts();
    console.log("Available contexts:", contexts);
    const target = contexts.find((ctx) => ctx.toLowerCase().includes(match));
    if (target) {
      return target;
    }
    await delay(500);
  }
  throw new Error(`WebView context containing '${match}' not found`);
}

async function run() {
  await ensureUiAutomator2();
  const appium = await startAppium();
  let client;
  try {
    client = await remote({
      hostname: host,
      port,
      path: "/",
      logLevel: "error",
      capabilities: {
        platformName: "Android",
        "appium:automationName": "UiAutomator2",
        "appium:deviceName": deviceName,
        "appium:appPackage": appPackage,
        "appium:appActivity": appActivity,
        "appium:noReset": true,
        "appium:chromedriverAutodownload": true,
      },
    });

    await client.activateApp(appPackage);
    if (expectContext === "web") {
      const context = await waitForWebContext(client, webContextMatch);
      await client.switchContext(context);
      const source = await client.getPageSource();
      console.log("WebView source:", source);
      const element = await client.$(webSelector);
      await element.waitForExist({ timeout: 15000 });
      const text = (await element.getText()).trim();
      if (text !== webExpect) {
        throw new Error(`Expected "${webExpect}", got "${text}"`);
      }
      console.log(`✔ WebView assertion passed (found: ${text})`);
      await client.switchContext("NATIVE_APP");
    } else {
      const element = await client.$(nativeSelector);
      await element.waitForExist({ timeout: 15000 });
      const text = await element.getText();
      if (text !== nativeExpect) {
        throw new Error(`Expected "${nativeExpect}", got "${text}"`);
      }
      console.log(`✔ Native assertion passed (found: ${text})`);
    }
  } finally {
    if (client) {
      await client.deleteSession().catch(() => {});
    }
    await stopAppium(appium);
  }
}

run().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
