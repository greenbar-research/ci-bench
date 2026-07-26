const fs = require("node:fs");
const { test, expect } = require("@playwright/test");

test("creates and opens a project", async ({ page }) => {
  const name = "Browser smoke project";

  await page.goto("/");
  await page.getByLabel("Name").fill(name);
  await page.getByRole("button", { name: "Create project" }).click();
  await expect(page.getByRole("heading", { name })).toBeVisible();

  const outputPath = process.env.BENCH_OUTPUT;
  if (!outputPath) throw new Error("BENCH_OUTPUT is required");

  fs.writeFileSync(
    outputPath,
    JSON.stringify({
      verification: { project_name: name, visible: true },
      telemetry: {}
    }) + "\n"
  );
});
