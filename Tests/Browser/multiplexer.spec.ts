import { expect, test, type APIRequestContext } from "@playwright/test";

type CaptureClassification = {
  policyVersion: number;
  category: string;
  ruleID: string;
  tags: string[];
  requestBodyDisposition: string;
  responseBodyDisposition: string;
};

type CapturedExchange = {
  classification?: CaptureClassification;
  method: string;
  outcome: string;
  path: string;
  requestBody?: string;
  requestBodyOmitted?: boolean;
  responseBody?: string;
  responseBodyOmitted?: boolean;
  statusCode?: number;
};

async function captures(
  request: APIRequestContext,
  route: string,
): Promise<CapturedExchange[]> {
  const response = await request.get(
    `http://127.0.0.1:19106/captures/${route}`,
  );
  return (await response.json()).exchanges;
}

for (const binding of ["web-0", "web-1"]) {
  test(`generated URL reaches ${binding} and sets routing context`, async ({
    page,
    context,
  }) => {
    const response = await page.goto(`/${binding}/`);

    expect(response?.status()).toBe(200);
    await expect(page.locator("#app")).toHaveText(binding);

    const cookie = (await context.cookies()).find(
      ({ name }) => name === "tailreg-route",
    );
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
    test(`${binding} fetch(${JSON.stringify(requestPath)}) stays isolated`, async ({
      page,
    }) => {
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
  test(`${binding} stores streamed request and response bodies`, async ({
    page,
  }) => {
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
        return (await captures(page.request, binding)).some(
          (exchange) =>
            exchange.method === "POST" &&
            exchange.path === "/echo" &&
            exchange.statusCode === 200 &&
            exchange.outcome === "complete" &&
            exchange.requestBody === payload &&
            exchange.requestBodyOmitted === false &&
            exchange.responseBody === payload &&
            exchange.responseBodyOmitted === false &&
            exchange.classification?.policyVersion === 1 &&
            exchange.classification.ruleID ===
              "request.structured-or-mutation" &&
            exchange.classification.tags.includes("mutation") &&
            exchange.classification.requestBodyDisposition === "retain" &&
            exchange.classification.responseBodyDisposition === "retain",
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
    assetPrefix: "/_app/immutable/",
    frameworkTag: "sveltekit",
  },
  {
    name: "Next.js",
    route: "nextjs-0",
    result: "nextjs:correct-upstream",
    assetPrefix: "/_next/static/",
    frameworkTag: "nextjs",
  },
  {
    name: "Nuxt",
    route: "nuxt-0",
    result: "nuxt:correct-upstream",
    assetPrefix: "/_nuxt/",
    frameworkTag: "nuxt",
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
      await expect(
        page.getByRole("heading", { name: `${framework.name} fixture` }),
      ).toBeVisible();
      await page.getByTestId(`${fetchKind}-fetch`).click();
      await expect(page.getByTestId("result")).toHaveText(framework.result);

      await expect
        .poll(async () => {
          return (await captures(page.request, framework.route)).some(
            (exchange) =>
              exchange.path.endsWith("/route/endpoint") &&
              exchange.statusCode === 200 &&
              exchange.outcome === "complete" &&
              exchange.responseBodyOmitted === false &&
              exchange.responseBody?.includes(framework.result.split(":")[0]) &&
              exchange.responseBody?.includes("correct-upstream") &&
              exchange.classification?.category === "api" &&
              exchange.classification.ruleID === "browser.fetch" &&
              exchange.classification.tags.includes("fetch-like") &&
              exchange.classification.responseBodyDisposition === "retain",
          );
        })
        .toBe(true);
    });
  }
}

for (const framework of frameworkFixtures) {
  test(`${framework.name} asset traffic is classified as non-interesting`, async ({
    page,
  }) => {
    const response = await page.goto(`/${framework.route}/`);

    expect(response?.status()).toBe(200);
    await expect(
      page.getByRole("heading", { name: `${framework.name} fixture` }),
    ).toBeVisible();
    await expect
      .poll(async () => {
        return (await captures(page.request, framework.route)).some(
          (exchange) =>
            exchange.path.includes(framework.assetPrefix) &&
            exchange.classification?.category === "asset" &&
            exchange.classification.ruleID === "browser.asset-or-probe" &&
            exchange.classification.tags.includes(framework.frameworkTag) &&
            exchange.classification.tags.includes("browser-asset") &&
            exchange.classification.requestBodyDisposition === "discard" &&
            exchange.classification.responseBodyDisposition === "discard",
        );
      })
      .toBe(true);
  });
}

const frameworkDataNavigations = [
  {
    name: "SvelteKit",
    route: "sveltekit-0",
    heading: "SvelteKit classification target",
    ruleID: "sveltekit.data",
    frameworkTag: "sveltekit",
  },
  {
    name: "Next.js",
    route: "nextjs-0",
    heading: "Next.js classification target",
    ruleID: "nextjs.data",
    frameworkTag: "nextjs",
  },
];

for (const framework of frameworkDataNavigations) {
  test(`${framework.name} native data navigation is retained`, async ({
    page,
  }) => {
    await page.goto(`/${framework.route}/`);
    await page.getByTestId("framework-navigation").click();
    await expect(
      page.getByRole("heading", { name: framework.heading }),
    ).toBeVisible();
    await expect
      .poll(async () => {
        return (await captures(page.request, framework.route)).some(
          (exchange) =>
            exchange.classification?.ruleID === framework.ruleID &&
            exchange.classification.tags.includes(framework.frameworkTag) &&
            exchange.classification.tags.includes("framework-data") &&
            exchange.classification.responseBodyDisposition === "retain",
        );
      })
      .toBe(true);
  });
}

test("Astro actions and server islands use their native classifications", async ({
  page,
}) => {
  const response = await page.goto("/astro-0/");

  expect(response?.status()).toBe(200);
  await expect(
    page.getByRole("heading", { name: "Astro fixture" }),
  ).toBeVisible();
  await expect(page.getByTestId("server-island")).toHaveText(
    "Astro server island loaded",
  );
  await page.getByTestId("framework-action").click();
  await expect(page.getByTestId("result")).toHaveText("astro:correct-upstream");

  await expect
    .poll(async () => {
      const exchanges = await captures(page.request, "astro-0");
      return [
        ["astro.action", "framework-action", "retain", "retain"],
        ["astro.data", "framework-data", "discard", "retain"],
        ["browser.asset-or-probe", "browser-asset", "discard", "discard"],
      ].every(
        ([ruleID, tag, requestBodyDisposition, responseBodyDisposition]) =>
          exchanges.some(
            ({ classification }) =>
              classification?.ruleID === ruleID &&
              classification.tags.includes("astro") &&
              classification.tags.includes(tag) &&
              classification.requestBodyDisposition ===
                requestBodyDisposition &&
              classification.responseBodyDisposition ===
                responseBodyDisposition,
          ),
      );
    })
    .toBe(true);
});

test("TanStack Start server functions use the native RPC classification", async ({
  page,
}) => {
  await page.goto("/tanstack-start-0/");
  const response = await page.goto("/");

  expect(response?.status()).toBe(200);
  await expect(
    page.getByRole("heading", { name: "TanStack Start fixture" }),
  ).toBeVisible();
  await page.getByTestId("framework-rpc").click();
  await expect(page.getByTestId("result")).toHaveText(
    "tanstack-start:correct-upstream",
  );

  await expect
    .poll(async () =>
      (await captures(page.request, "tanstack-start-0")).some(
        ({ method, classification }) =>
          method === "POST" &&
          classification?.ruleID === "tanstack-start.rpc" &&
          classification.tags.includes("tanstack-start") &&
          classification.tags.includes("framework-rpc") &&
          classification.requestBodyDisposition === "retain" &&
          classification.responseBodyDisposition === "retain",
      ),
    )
    .toBe(true);
});
