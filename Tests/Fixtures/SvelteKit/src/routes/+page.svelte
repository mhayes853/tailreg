<script lang="ts">
  let result = "idle";

  async function request(path: string) {
    const response = await fetch(path);
    const body = await response.json();
    result = `${body.framework}:${body.result}`;
  }
</script>

<svelte:head>
  <title>Tailreg SvelteKit fixture</title>
</svelte:head>

<h1>SvelteKit fixture</h1>
<button data-testid="absolute-fetch" onclick={() => request("/route/endpoint")}>Absolute fetch</button>
<button data-testid="relative-fetch" onclick={() => request("route/endpoint")}>Relative fetch</button>
<output data-testid="result">{result}</output>
