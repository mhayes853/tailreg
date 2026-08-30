"use client";

import { useState } from "react";

export default function Page() {
  const [result, setResult] = useState("idle");

  async function request(path) {
    const response = await fetch(path);
    const body = await response.json();
    setResult(`${body.framework}:${body.result}`);
  }

  return (
    <main>
      <h1>Next.js fixture</h1>
      <button data-testid="absolute-fetch" onClick={() => request("/route/endpoint")}>
        Absolute fetch
      </button>
      <button data-testid="relative-fetch" onClick={() => request("route/endpoint")}>
        Relative fetch
      </button>
      <output data-testid="result">{result}</output>
    </main>
  );
}
