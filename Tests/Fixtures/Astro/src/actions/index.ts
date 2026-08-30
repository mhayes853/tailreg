import { defineAction } from "astro:actions";
import { z } from "astro/zod";

export const server = {
  classify: defineAction({
    input: z.object({ value: z.string() }),
    handler: ({ value }) => ({ framework: "astro", result: value }),
  }),
};
