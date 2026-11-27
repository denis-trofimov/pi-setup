// @file: call-guard.ts
// @description: Блокирует bash-вызов без цели (`cd …; true`) и дамп списка веток/remote без фильтра.
// @dependencies: @earendil-works/pi-coding-agent, ./call-guard-core.mjs
// @created: 2026-11-19
//
// Зачем: #15738 п.5 (пять пустых вызовов и один дамп домашнего каталога) и #15749 п.5
// (`git branch -a` вернул 2168 строк, 50 КБ). Правило было записано в AGENTS.md, но гейта у него не было.
//
// С #102 сторож не только блокирует: там, где правка однозначна (`$?` после конвейера в `head`/`tail`,
// листинг каталога с тысячами записей, `2>/dev/null` на `cd`/`ls`), он правит команду и говорит об этом
// строкой в stderr. Отказ стоил хода шесть раз за одну сессию (#16219), а исправление — ни разу.
//
// Блокировка без диалога: пустой вызов и нефильтрованный список веток — это ошибка в аргументе,
// а не решение пользователя, и спрашивать «разрешить?» значит предлагать её подтвердить.
// Осознанный обход — PI_CALL_GUARD_ALLOW=1.
//
// Отключить на сессию: `pi --no-extensions` или убрать файл из `~/.pi/agent/extensions`.

import { isToolCallEventType, type ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { classifyCall, toToolCallResult } from "./call-guard-core.mjs";

export default function callGuard(pi: ExtensionAPI) {
	pi.on("tool_call", async (event) => {
		if (!isToolCallEventType("bash", event)) return undefined;

		const command = event.input.command;
		if (typeof command !== "string") return undefined;

		// Обход читается на момент вызова: его включают в окружении сессии, а не при загрузке pi.
		const verdict = classifyCall(command, { allow: process.env.PI_CALL_GUARD_ALLOW === "1" });
		if (verdict.allowed) {
			// `event.input` мутируется до исполнения вызова — это и есть место, где сторож правит
			// команду (#102): подставляет `set -o pipefail`, режет листинг, снимает `2>/dev/null`.
			if (typeof verdict.patchedCommand === "string" && verdict.patchedCommand !== command) {
				event.input.command = verdict.patchedCommand;
			}
			return undefined;
		}

		return toToolCallResult(verdict);
	});
}
