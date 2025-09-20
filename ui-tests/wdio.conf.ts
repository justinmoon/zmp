import type { Options } from "@wdio/types";

const host = process.env.ZMP_APPIUM_HOST ?? "127.0.0.1";
const port = Number(process.env.ZMP_APPIUM_PORT ?? "4723");
const appPackage = process.env.ZMP_APP_PACKAGE ?? "com.example.demo";
const appActivity = process.env.ZMP_APP_ACTIVITY ?? ".MainActivity";
const deviceName = process.env.ZMP_DEVICE_NAME ?? "Android Emulator";

export const config: Options.Testrunner = {
  runner: "local",
  specs: ["./test/**/*.spec.ts"],
  maxInstances: 1,
  capabilities: [
    {
      platformName: "Android",
      "appium:automationName": "UiAutomator2",
      "appium:deviceName": deviceName,
      "appium:appPackage": appPackage,
      "appium:appActivity": appActivity,
      "appium:noReset": true,
    },
  ],
  services: [
    [
      "appium",
      {
        args: {
          address: host,
          port,
          basePath: "/",
        },
        command: "appium",
      },
    ],
  ],
  hostname: host,
  port,
  logLevel: "info",
  framework: "mocha",
  mochaOpts: {
    ui: "bdd",
    timeout: 60000,
  },
  reporters: ["spec"],
  before: async () => {
    // ensure app is foregrounded before each test run
    await driver.activateApp(appPackage);
  },
};
