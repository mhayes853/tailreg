import { expect, test } from "@playwright/test";

for (const binding of ["web-0", "web-1"]) {
  test(`generated URL reaches ${binding} and sets routing context`, async ({ page, context }) => {
    const response = await page.goto(`/${binding}/`);

    expect(response?.status()).toBe(200);
    await expect(page.locator("#app")).toHaveText(binding);

    const cookie = (await context.cookies()).find(({ name }) => name === "tailreg-route");
    expect(cookie).toMatchObject({
      httpOnly: true,
      path: "/",
      sameSite: "Lax",
    });
    expect(cookie?.value).toBeTruthy();
  });
}

for (const binding of ["web-0", "web-1"]) {
  for (const requestPath of ["/route/endpoint", "route/endpoint"]) {
    test(`${binding} fetch(${JSON.stringify(requestPath)}) stays isolated`, async ({ page }) => {
      await page.goto(`/${binding}/`);

      const result = await page.evaluate(async (path) => {
        const response = await fetch(path);
        return { status: response.status, body: await response.json() };
      }, requestPath);

      expect(result).toEqual({
        status: 200,
        body: { binding, result: "correct-upstream" },
      });
    });
  }
}
