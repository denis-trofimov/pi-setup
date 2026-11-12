/**
 * No Output Cap on Routed Requests
 *
 * Pi sends the model's `maxTokens` as `max_completion_tokens` on every request.
 * OpenRouter treats that field as an endpoint *filter* as well as a cap: an
 * endpoint whose own `max_completion_tokens` is lower is dropped from the
 * candidate list before `provider.order` is consulted. The catalog's value for
 * deepseek/deepseek-v4.1-flash-1017 is 943718, while every DeepInfra and
 * InferenceNet endpoint caps at 393216 — so the `deepinfra → inference-net →
 * morph` pin silently collapsed to morph (the only endpoint that accepts
 * 943718).
 *
 * Routed requests (payload carries a `provider` routing object — OpenRouter, and
 * any gateway that honours the same contract, such as RouterAI) therefore go out
 * without an output cap; the endpoint's own limit applies. Requests without
 * routing keep whatever Pi computed.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const CAP_FIELDS = ["max_completion_tokens", "max_tokens", "max_output_tokens"];

function isRouted(payload: unknown): payload is Record<string, unknown> {
	if (typeof payload !== "object" || payload === null) return false;
	const routing = (payload as Record<string, unknown>).provider;
	return typeof routing === "object" && routing !== null;
}

export default function noOutputCap(pi: ExtensionAPI) {
	pi.on("before_provider_request", (event) => {
		if (!isRouted(event.payload)) return undefined;

		const payload = { ...event.payload };
		const removed = CAP_FIELDS.filter((field) => field in payload);
		if (removed.length === 0) return undefined;
		for (const field of removed) delete payload[field];
		return payload;
	});
}
