import { json } from "@sveltejs/kit";

export function GET() {
  return json({ framework: "sveltekit", result: "correct-upstream" });
}
