<script setup lang="ts">
const result = ref("idle");

async function request(path: string) {
  const response = await fetch(path);
  const body: { framework: string; result: string } = await response.json();
  result.value = `${body.framework}:${body.result}`;
}
</script>

<template>
  <main>
    <h1>Nuxt fixture</h1>
    <button data-testid="absolute-fetch" @click="request('/route/endpoint')">
      Absolute fetch
    </button>
    <button data-testid="relative-fetch" @click="request('route/endpoint')">
      Relative fetch
    </button>
    <NuxtLink data-testid="framework-navigation" to="/classification-target">
      Framework navigation
    </NuxtLink>
    <output data-testid="result">{{ result }}</output>
  </main>
  <NuxtPage />
</template>
