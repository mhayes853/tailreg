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

const frameworkFixtures = [
  {
    name: "SvelteKit",
    route: "sveltekit-0",
    result: "sveltekit:correct-upstream",
  },
  {
    name: "Next.js",
    route: "nextjs-0",
    result: "nextjs:correct-upstream",
  },
  {
    name: "Nuxt",
    route: "nuxt-0",
    result: "nuxt:correct-upstream",
  },
];

for (const framework of frameworkFixtures) {
  for (const fetchKind of ["absolute", "relative"] as const) {
    const article = fetchKind === "absolute" ? "an" : "a";
    test(`${framework.name} hydrates and performs ${article} ${fetchKind} fetch through the MUX`, async ({
      page,
    }) => {
      const response = await page.goto(`/${framework.route}/`);

      expect(response?.status()).toBe(200);
      await expect(page.getByRole("heading", { name: `${framework.name} fixture` })).toBeVisible();
      await page.getByTestId(`${fetchKind}-fetch`).click();
      await expect(page.getByTestId("result")).toHaveText(framework.result);
    });
  }
}
