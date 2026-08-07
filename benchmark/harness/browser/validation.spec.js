const crypto = require("node:crypto");
const fs = require("node:fs");
const { test, expect } = require("@playwright/test");

test("exercises complete CI reporting flows", async ({ page }) => {
  const parameters = JSON.parse(process.env.BENCH_PARAMS || "{}");
  const seed = Number.parseInt(process.env.BENCH_SEED || "", 10);
  const outerTimeoutSeconds = Number.parseInt(process.env.BENCH_TIMEOUT_SECONDS || "", 10);
  const iterations = parameters.flow_iterations;
  const artifactBytes = parameters.artifact_bytes;
  if (!Number.isInteger(seed) || !Number.isInteger(iterations) || iterations <= 0 ||
      !Number.isInteger(artifactBytes) || artifactBytes <= 0 ||
      !Number.isInteger(outerTimeoutSeconds) || outerTimeoutSeconds <= 0) {
    throw new Error("validation browser parameters must be positive integers");
  }
  test.setTimeout(outerTimeoutSeconds * 900);

  const phaseDurationMs = {};
  const measure = async (name, action) => {
    const started = Date.now();
    await action();
    phaseDurationMs[name] = Date.now() - started;
  };

  await measure("authentication", async () => {
    await page.goto("/session/new");
    await page.getByLabel("Email").fill("browser@example.com");
    await page.getByLabel("Password").fill("benchmark-password");
    await page.getByRole("button", { name: "Sign in" }).click();
    await expect(page.getByText("Signed in as browser@example.com")).toBeVisible();
  });

  const projectNames = [];
  const artifactDigest = crypto.createHash("sha256");
  await measure("reporting_flows", async () => {
    for (let iteration = 0; iteration < iterations; iteration += 1) {
      const projectName = `Browser validation ${seed}-${iteration}`;
      projectNames.push(projectName);
      await page.goto("/");
      await page.getByLabel("Name").fill(projectName);
      await page.getByRole("button", { name: "Create project" }).click();
      await expect(page.getByRole("heading", { name: projectName })).toBeVisible();

      for (const build of [
        { number: 1, state: "passed", sha: "a".repeat(40), duration: 1000 + iteration },
        { number: 2, state: "failed", sha: "b".repeat(40), duration: 2000 + iteration }
      ]) {
        await page.getByLabel("Number").fill(String(build.number));
        await page.getByLabel("Commit sha").fill(build.sha);
        await page.getByLabel("State", { exact: true }).selectOption(build.state);
        await page.getByLabel("Duration ms", { exact: true }).fill(String(build.duration));
        await page.getByRole("button", { name: "Create build" }).click();
      }

      const buildOne = page.getByRole("region", { name: "Build 1 details" });
      await buildOne.getByLabel("Test name").fill(`passing test ${iteration}`);
      await buildOne.getByLabel("Test state").selectOption("passed");
      await buildOne.getByLabel("Test duration ms").fill("11");
      await buildOne.getByRole("button", { name: "Add test result" }).click();

      const buildTwo = page.getByRole("region", { name: "Build 2 details" });
      for (const result of [
        { name: `failing test ${iteration}`, state: "failed", duration: "22" },
        { name: `skipped test ${iteration}`, state: "skipped", duration: "0" }
      ]) {
        await buildTwo.getByLabel("Test name").fill(result.name);
        await buildTwo.getByLabel("Test state").selectOption(result.state);
        await buildTwo.getByLabel("Test duration ms").fill(result.duration);
        await buildTwo.getByRole("button", { name: "Add test result" }).click();
      }

      const artifact = Buffer.allocUnsafe(artifactBytes);
      for (let index = 0; index < artifact.length; index += 1) {
        artifact[index] = (seed + iteration + index) % 256;
      }
      artifactDigest.update(artifact);
      const artifactName = `report-${iteration}.bin`;
      await buildOne.getByLabel("Artifact file").setInputFiles({
        name: artifactName,
        mimeType: "application/octet-stream",
        buffer: artifact
      });
      await buildOne.getByRole("button", { name: "Upload artifact" }).click();
      await expect(page.getByRole("link", { name: artifactName })).toBeVisible();

      const buildCounts = await page.getByRole("region", { name: "Build report" })
        .locator("dd").allTextContents();
      expect(buildCounts).toEqual(["2", "1", "1"]);
      const testCounts = await page.getByRole("region", { name: "Test report" })
        .locator("dd").allTextContents();
      expect(testCounts).toEqual(["3", "1", "1", "1"]);

      await page.getByRole("navigation", { name: "Test result filters" })
        .getByRole("link", { name: "Failed" }).click();
      const resultRows = page.getByRole("table", { name: "Test results" }).locator("tbody tr");
      await expect(resultRows).toHaveCount(1);
      await expect(resultRows).toContainText(`failing test ${iteration}`);
    }
  });

  await measure("sign_out", async () => {
    await page.goto("/");
    await page.getByRole("button", { name: "Sign out" }).click();
    await expect(page.getByRole("link", { name: "Sign in" })).toBeVisible();
  });

  const outputPath = process.env.BENCH_OUTPUT;
  if (!outputPath) throw new Error("BENCH_OUTPUT is required");
  fs.writeFileSync(
    outputPath,
    JSON.stringify({
      verification: {
        artifact_bytes: artifactBytes * iterations,
        artifact_count: iterations,
        artifact_digest: artifactDigest.digest("hex"),
        build_count: iterations * 2,
        project_count: iterations,
        project_names_digest: crypto.createHash("sha256")
          .update(JSON.stringify(projectNames)).digest("hex"),
        reports_verified: true,
        signed_out: true,
        test_result_count: iterations * 3
      },
      telemetry: { phase_duration_ms: phaseDurationMs }
    }) + "\n"
  );
});
