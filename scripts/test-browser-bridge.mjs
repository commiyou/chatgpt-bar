import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const playwrightPackage = process.env.PLAYWRIGHT_PACKAGE || "/Users/youbin/node_modules/playwright";
const { chromium } = require(playwrightPackage);

const bridge = execFileSync("swift", ["run", "BridgeDump"], {
  encoding: "utf8",
  cwd: new URL("..", import.meta.url).pathname
});
const fixture = readFileSync(new URL("../tests/fixtures/bridge.html", import.meta.url), "utf8");
const browser = await chromium.launch({
  headless: true,
  executablePath: process.env.CHROME_BIN || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
});

try {
  const context = await browser.newContext();
  await context.tracing.start({ screenshots: true, snapshots: true, sources: true });
  const page = await context.newPage();
  await page.setContent(fixture);
  await page.addScriptTag({ content: bridge });

  const response = await page.evaluate(() => window.__chatgptBar.getLastResponse());
  if (!response.ok) throw new Error(`getLastResponse failed: ${JSON.stringify(response)}`);
  if (!response.value.markdown.includes("| Feature | Value |")) throw new Error("table was not converted to Markdown");
  if (!response.value.markdown.includes("$$\nx^2 + y^2\n$$")) throw new Error("math source was not preserved");
  if (!response.value.markdown.includes("```swift")) throw new Error("code fence was not preserved");

  const copy = await page.evaluate(() => {
    window.clickedCopy = null;
    return window.__chatgptBar.clickCopyButton();
  });
  const clicked = await page.evaluate(() => window.clickedCopy);
  if (!copy.ok || clicked !== "response") {
    throw new Error(`response-level copy selection failed: ${JSON.stringify({ copy, clicked })}`);
  }

  const custom = await page.evaluate(() => {
    const custom = document.createElement("div");
    custom.id = "custom-assistant";
    custom.textContent = "Custom selector response";
    document.body.appendChild(custom);
    return window.__chatgptBar.configure({ assistant: ["#custom-assistant"] });
  });
  if (!custom.ok) throw new Error(`runtime selector configuration failed: ${JSON.stringify(custom)}`);
  const configured = await page.evaluate(() => window.__chatgptBar.getLastResponse());
  if (!configured.ok || configured.value.markdown !== "Custom selector response") {
    throw new Error(`runtime selector configuration did not take effect: ${JSON.stringify(configured)}`);
  }

  console.log("Browser bridge fixture test passed");
  await context.tracing.stop();
  await context.close();
} catch (error) {
  try {
    await browser.contexts()[0]?.tracing.stop({
      path: `${process.env.TMPDIR || "/tmp"}/chatgpt-bar-browser-bridge-trace.zip`
    });
  } catch {}
  throw error;
} finally {
  await browser.close();
}
