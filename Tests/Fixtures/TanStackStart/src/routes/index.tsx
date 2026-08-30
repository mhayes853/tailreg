import { createFileRoute } from "@tanstack/react-router";
import { createServerFn } from "@tanstack/react-start";
import { useState } from "react";

const classify = createServerFn({ method: "POST" })
  .validator((data: { value: string }) => data)
  .handler(({ data }) => ({ framework: "tanstack-start", result: data.value }));

export const Route = createFileRoute("/")({ component: Home });

function Home() {
  const [result, setResult] = useState("idle");
  return (
    <main>
      <h1>TanStack Start fixture</h1>
      <button
        data-testid="framework-rpc"
        onClick={async () =>
          setResult(
            format(await classify({ data: { value: "correct-upstream" } })),
          )
        }
      >
        Run server function
      </button>
      <output data-testid="result">{result}</output>
    </main>
  );
}

function format(result: Awaited<ReturnType<typeof classify>>) {
  return `${result.framework}:${result.result}`;
}
