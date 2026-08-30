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

for (const binding of ["web-0", "web-1"]) {
  test(`${binding} stores streamed request and response bodies`, async ({ page }) => {
    await page.goto(`/${binding}/`);
    const payload = `captured-by:${binding}`;
    const result = await page.evaluate(async (body) => {
      const response = await fetch("/echo", {
        method: "POST",
        headers: { "Content-Type": "text/plain" },
        body,
      });
      return { body: await response.text(), status: response.status };
    }, payload);

    expect(result).toEqual({ body: payload, status: 200 });
    await expect
      .poll(async () => {
        const response = await page.request.get(`http://127.0.0.1:19106/captures/${binding}`);
        const capture = await response.json();
        return capture.exchanges.some(
          (exchange: {
            method: string;
            outcome: string;
            path: string;
            requestBody?: string;
            requestBodyOmitted?: boolean;
            responseBody?: string;
            responseBodyOmitted?: boolean;
            statusCode?: number;
          }) =>
            exchange.method === "POST" &&
            exchange.path === "/echo" &&
            exchange.statusCode === 200 &&
            exchange.outcome === "complete" &&
            exchange.requestBody === payload &&
            exchange.requestBodyOmitted === false &&
            exchange.responseBody === payload &&
            exchange.responseBodyOmitted === false,
        );
      })
      .toBe(true);
  });
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

      await expect
        .poll(async () => {
          const response = await page.request.get(
            `http://127.0.0.1:19106/captures/${framework.route}`,
          );
          const capture = await response.json();
          return capture.exchanges.some(
            (exchange: {
              outcome: string;
              path: string;
              responseBody?: string;
              responseBodyOmitted?: boolean;
              statusCode?: number;
            }) =>
              exchange.path.endsWith("/route/endpoint") &&
              exchange.statusCode === 200 &&
              exchange.outcome === "complete" &&
              exchange.responseBodyOmitted === false &&
              exchange.responseBody?.includes(framework.result.split(":")[0]) &&
              exchange.responseBody?.includes("correct-upstream"),
          );
        })
        .toBe(true);
    });
  }
}
