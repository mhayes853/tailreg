import react from "@vitejs/plugin-react";
import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import { defineConfig } from "vite";
import { nitro } from "nitro/vite";

export default defineConfig({ plugins: [tanstackStart(), react(), nitro()] });
