/**
 * Collapse Bash — one line per shell tool call.
 *
 * Overrides the built-in `bash` tool renderers so a finished command takes a
 * single transcript line:
 *
 *   $ npm test ✓ 0.8s
 *   $ git status ✗ 0.1s
 *
 * Ctrl+O (app.tools.expand) still expands the row to the full output.
 * While the command runs the line shows `…` and the elapsed time is omitted.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createBashToolDefinition } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";

type RenderState = { call?: Text };

/** Keep the header on one line: first line of the command, `…` if it continues. */
function oneLineCommand(command: unknown): string {
	if (typeof command !== "string" || command.trim() === "") return "...";
	const [first, ...rest] = command.trim().split("\n");
	const head = first.length > 120 ? `${first.slice(0, 117)}...` : first;
	return rest.length > 0 ? `${head} …` : head;
}

function formatDuration(ms: number | undefined): string {
	if (ms === undefined) return "";
	return ` ${(ms / 1000).toFixed(1)}s`;
}

export default function (pi: ExtensionAPI) {
	const bash = createBashToolDefinition(process.cwd());

	pi.registerTool({
		...bash,

		renderCall(args, theme, context) {
			const text = (context.lastComponent as Text | undefined) ?? new Text("", 0, 0);
			text.setText(theme.fg("toolTitle", theme.bold(`$ ${oneLineCommand(args?.command)}`)));
			// Hand the live component to renderResult so it can append the status
			// in place, without a second line and without an invalidate() loop.
			(context.state as RenderState).call = text;
			return text;
		},

		renderResult(result, { expanded, isPartial }, theme, context) {
			const state = context.state as RenderState;
			const command = oneLineCommand(context.args?.command);

			let status: string;
			if (isPartial) {
				status = theme.fg("muted", " …");
			} else if (context.isError) {
				status = theme.fg("error", ` ✗${formatDuration(context.durationMs)}`);
			} else {
				status = theme.fg("success", ` ✓${formatDuration(context.durationMs)}`);
			}

			state.call?.setText(theme.fg("toolTitle", theme.bold(`$ ${command}`)) + status);

			if (!expanded) return new Text("", 0, 0);

			const output = result.content
				.filter((c): c is { type: "text"; text: string } => c.type === "text")
				.map((c) => c.text)
				.join("\n")
				.trim();

			if (!output) return new Text("", 0, 0);

			const styled = output
				.split("\n")
				.map((line) => theme.fg("toolOutput", line))
				.join("\n");

			return new Text(`\n${styled}`, 0, 0);
		},
	});
}
