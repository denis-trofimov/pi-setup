// @file: call-guard-core.mjs
// @description: Решение «пропустить / заблокировать» для bash-вызова — без Pi API.
// @dependencies: нет
// @created: 2026-11-19
//
// Вынесено из call-guard.ts, чтобы правила проверялись тестом без запуска сессии Pi:
// `node --test tests/call-guard.test.mjs`.
//
// Правила (поводы — ретро #15598):
//
// 1. **Вызов без цели** (#15738 п.5). `cd /каталог 2>/dev/null; true` возвращает пустой вывод и ничего
//    не делает: пять таких вызовов в одной сессии, и каждый стоил хода. Правило «в каждом вызове —
//    абсолютный путь к цели» записано в AGENTS.md, но гейта у него не было.
// 2. **Дамп веток и remote без фильтра** (#15749 п.5). `git branch -a` в большом репозитории вернул
//    2168 строк (50 КБ) — весь список веток вместо одной строки ответа. Фильтр — это конвейер:
//    `| wc -l`, `| rg <шаблон>`, `| head`; без него такие команды не печатаются.
//
// Осознанный обход — PI_CALL_GUARD_ALLOW=1 (как у остальных сторожей pi-setup).
//
// Границы названы честно: разбор команд строковый и не знает экранирования вложенного шелла
// (`bash -c '…'`). Ложное срабатывание лечится обходом, а не правкой правила на ходу.

/** Команда, у которой нет полезной части: только переход в каталог, `true`, `:` или `exit 0`. */
const NOOP_SEGMENT = /^(?:true|:)\s*$|^exit(?:\s+0)?\s*$/;

/** `cd <путь>` вместе с типичными перенаправлениями, которыми глушат ошибку перехода. */
const CD_SEGMENT = /^cd\s+[^;&|]+?(?:\s+[012]?>>?\s*\S+|\s+2>&1)*\s*$/;

/** Список веток/remote целиком: `-a`, `--all`, `-r`, `--remotes`, `git remote show <name>` без фильтра. */
const GIT_BRANCH_LISTING = /\bgit\s+(?:-C\s+\S+\s+)?branch\b[^|;]*\s(?:-a|--all|-r|--remotes|--list)\b/;
const GIT_REMOTE_SHOW = /\bgit\s+(?:-C\s+\S+\s+)?remote\s+show\b/;

/**
 * Разбить команду на сегменты по `;`, `&&`, `||` вне кавычек. Полноценный шелл-парсер не нужен:
 * правило про пустой вызов смотрит только на простые цепочки, которыми его и ловили.
 *
 * @param {string} command
 * @returns {string[]}
 */
export function splitSegments(command) {
	const segments = [];
	let current = "";
	let quote = null;

	for (let i = 0; i < command.length; i += 1) {
		const char = command[i];
		if (quote) {
			current += char;
			if (char === quote) quote = null;
			continue;
		}
		if (char === '"' || char === "'") {
			quote = char;
			current += char;
			continue;
		}
		if (char === ";" || char === "&" || char === "|") {
			segments.push(current);
			current = "";
			// `&&`, `||`, `>>` — второй символ той же цепочки, третий поглощается как обычный.
			if ((char === "&" || char === "|") && command[i + 1] === char) i += 1;
			continue;
		}
		current += char;
	}
	segments.push(current);

	return segments.map((segment) => segment.trim()).filter((segment) => segment !== "");
}

/**
 * @param {string} command
 * @param {{ allow?: boolean }} [options] allow — осознанный обход (PI_CALL_GUARD_ALLOW=1)
 * @returns {{ allowed: boolean, reason?: string, hint?: string }}
 */
export function classifyCall(command, options = {}) {
	if (options.allow) return { allowed: true };

	const trimmed = command.trim();
	if (trimmed === "") {
		return {
			allowed: false,
			reason: "Пустая команда: вызов без цели.",
			hint: "bash-вызов обязан что-то делать — назовите цель (read/ffgrep для чтения, make/тест для прогона).",
		};
	}

	const segments = splitSegments(trimmed);
	const useful = segments.filter((segment) => !NOOP_SEGMENT.test(segment) && !CD_SEGMENT.test(segment));
	if (useful.length === 0) {
		return {
			allowed: false,
			reason: "Вызов без цели: после `cd` и `;` не остаётся команды, которая что-то делает.",
			hint: "Такой вызов возвращает пустой вывод и ничего не проверяет. Нужен переход ради пути — используйте абсолютный путь в самой команде (`git -C <abs>`, `make -C <abs>`).",
		};
	}

	const hasPipe = /\|/.test(trimmed);
	if (!hasPipe && GIT_BRANCH_LISTING.test(trimmed)) {
		return {
			allowed: false,
			reason: "Вывод `git branch` без фильтра: список веток всего репозитория (2168 строк, 50 КБ).",
			hint: "Добавьте фильтр: `| wc -l`, `| rg <шаблон>` или `| head`. Нужен весь список осознанно — PI_CALL_GUARD_ALLOW=1.",
		};
	}

	if (!hasPipe && GIT_REMOTE_SHOW.test(trimmed)) {
		return {
			allowed: false,
			reason: "Вывод `git remote show` без фильтра: десятки строк про каждый remote.",
			hint: "Уточните вопрос: `git remote get-url origin`, `git remote show origin | rg <поле>`. Осознанно — PI_CALL_GUARD_ALLOW=1.",
		};
	}

	return { allowed: true };
}

/**
 * Ответ хука Pi: `{ block: true, reason }` либо `undefined`, если вызов проходит.
 *
 * @param {{ allowed: boolean, reason?: string, hint?: string }} verdict
 */
export function toToolCallResult(verdict) {
	if (verdict.allowed) return undefined;

	const lines = [`Call Guard blocked: ${verdict.reason ?? "вызов без цели"}`, ...(verdict.hint ? [verdict.hint] : [])];
	return { block: true, reason: lines.join("\n") };
}
