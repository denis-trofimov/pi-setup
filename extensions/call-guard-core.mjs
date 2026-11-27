// @file: call-guard-core.mjs
// @description: Решение «пропустить / заблокировать» для bash-вызова — без Pi API.
// @dependencies: node:fs (размер файла в правиле чтения)
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
// 3. **`sed -i` по файлу** (#15849 п.3). Правило «точечная правка — `edit`, а не `python3 - <<EOF`»
//    жило в AGENTS.md и не меняло поведения: в сессии #15822 после записи правила было 31 правка
//    через heredoc и девять `sed -i`. У `sed -i` нет случая, когда он лучше `edit`: он меняет текст
//    без проверки уникальности вхождения, и диффа до правки не видно. Набор замен через heredoc
//    остаётся разрешённым (это записано в AGENTS.md); блокируется именно in-place правка файла,
//    а `sed` без `-i` (фильтр текста в конвейере) проходит.
// 4. **Чтение файла и поиск по всему домашнему каталогу через bash** (#15906 п.4, #15909 п.4). Правило
//    «файл читает `read`, поиск делает `ffgrep`/`fffind`» жило в AGENTS.md и не держалось: 26 вызовов
//    `sed -n 'N,Mp'` против 6 `read` в одной сессии, около 20 `sed -n` и 30 `grep -n`/`ls` в другой,
//    а два `grep -r … /home/денis` умерли по таймауту (60 с и 10 с). Файл до 50 КБ читается только
//    `read` с `offset`/`limit`; файл больше 50 КБ и конвейер не трогаются.
//
//    С #16110 отказ у этого правила приходит вместе с содержимым: у `cat`, `sed -n 'A,Bp'` и `grep -n`
//    по файлу до 50 КБ в тексте отказа стоят запрошенные строки с номерами. Причина — замер: 6–7
//    отказов за сессию (#16074 — 3, #16048 — 7, #16110 — 6–7), и каждый стоил хода на повтор той же
//    цели законным инструментом. Функция сторожа может только заблокировать вызов и подменить
//    аргументы (`tool_call` в Pi не умеет вернуть результат другого инструмента), поэтому содержимое
//    едет в тексте отказа. Отдаётся только первая область (как `read` с `limit`) и только один файл;
//    для остального в отказе назван `offset`, с которого читать.
// 5. **Конвейер в `head`/`tail` и голый `$?` после него** (#16096 п.1). Правило «код возврата теряется
//    в конвейере» стояло в AGENTS.md дважды и нарушалось 22 раза за одну сессию (#16087): 84 из 153
//    вызовов `bash` кончались `| tail` или `| head`, и в 22 из них рядом читался голый `$?` — код
//    `tail`, а не команды. Две ошибки дали неверный вывод, одна ушла в трекер: «абсолютный путь к
//    `.pi/` работает» было итогом команды `rg -l … /abs/.pi/ | head -3; echo "exit=$?"`. Поэтому гейт
//    стоит на форме вызова: конвейер с `head`/`tail` (в любой ступени — он и режет вывод) и чтение
//    `$?`/`${?}` в более позднем сегменте. С `set -o pipefail` в той же команде `$?` верен — такое не
//    блокируется.
//
//    С #102 отказ по этому правилу заменён исправлением: сторож подставляет `set -o pipefail` в начало
//    команды и одной строкой в stderr говорит об этом. Отказ стоил хода шесть раз за одну сессию
//    (#16219), а исправление ему не нужно: правило защищает от кода `tail`, и `pipefail` снимает саму
//    причину. Отказ остаётся только у формы, где подстановка в начало меняет смысл, — `$?` читается
//    внутри `$( … )`: там код принадлежит подстановке, а не конвейеру в командной строке.
//
// 6. **Листинг каталога без предела и глушение опечатки в пути** (#102). `ls docs` в каталоге с 2958
//    записями отдал 50 КБ — 13 % всего вывода сессии; у `read` обрезка есть, у листинга не было.
//    Каталог с числом записей выше порога теперь режется до 20 строк с названным числом. И
//    `2>/dev/null` на `cd`/`ls`/`test -d` снимается: он глушит единственный сигнал о промахе в пути,
//    после которого следующие сегменты выполняются в каталоге от предыдущего `cd`.
//
//    Перенаправление heredoc-тела (#101 п.2) из разбора вырезается: текст примера внутри `<<'EOF'`
//    — это данные для команды, а не команда, и правило чтения файла не должно срабатывать на
//    `gh issue create --body-file …` из-за примера `cat <файл>` в самом теле.
//
// 7. **Относительный путь резолвится от `cd`, а не от cwd сессии** (#101 п.1). `cd /воркдерево && sed -n
//    '1,10p' файл` отдавал в отказе содержимое файла из основного дерева: `readFileSync` резолвил
//    операнд от cwd процесса pi, а `cd` парсер отбрасывал. Содержимое чужого дерева читается как
//    текущее состояние файла — два хода на перепроверку и `edit` по этому тексту. Теперь каталог
//    ведётся по сегментам, и неразвёрнутый `cd` (`$VAR`) содержимого не отдаёт вовсе.
//
// 5. **Имя инструмента pi, набранное как команда bash** (#16126). В сессии #16110 дважды вернулось
//    `bash: ffgrep: command not found`: тул набран в командной строке вместо вызова. Отказ называет
//    вызов тула. В список входят только имена, которых в системе нет (`ffgrep`, `fffind`); `read` —
//    встроенная команда bash, и `while read -r` — обычный код, поэтому его здесь нет.
//
// Осознанный обход — PI_CALL_GUARD_ALLOW=1 (как у остальных сторожей pi-setup).
//
// Границы названы честно: разбор команд строковый и не знает экранирования вложенного шелла
// (`bash -c '…'`). Ложное срабатывание лечится обходом, а не правкой правила на ходу.

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

/** Порог «файл больше 50 КБ»: такой файл через `sed -n`/`cat` читать разрешено (51200 байт). */
const READ_LIMIT_BYTES = 51200;

/** Диапазон печати `sed -n`: `1,20p`, `5p`, `120,400p`. */
const SED_PRINT_RANGE = /^\d+(?:,\d+)?p$/;

/**
 * Корень репозитория и весь домашний каталог: поиск по ним дороже выгоды. Подкаталог (`~/p`,
 * `/home/denis/p`) в список не входит — там поиск законный, и правило не должно его запрещать.
 */
const BROAD_PATHS = [".", "./", "~", "~/", "$HOME", "${HOME}", "/home/denis", "/home/denis/"];

/** Команда, у которой нет полезной части: только переход в каталог, `true`, `:` или `exit 0`. */
const NOOP_SEGMENT = /^(?:true|:)\s*$|^exit(?:\s+0)?\s*$/;

/** `cd <путь>` вместе с типичными перенаправлениями, которыми глушат ошибку перехода. */
const CD_SEGMENT = /^cd\s+[^;&|]+?(?:\s+[012]?>>?\s*\S+|\s+2>&1)*\s*$/;

/**
 * Список веток/remote целиком: `-a`, `--all`, `-r`, `--remotes`, `git remote show <name>` без фильтра.
 *
 * Якорь `^` и проверка по сегменту, а не по строке целиком: `rg -n "git branch -a"` — это поиск
 * текста по репозиторию, а не вызов git, и блокировать его нельзя (такая строка живёт в самом
 * call-guard-core.mjs).
 */
const GIT_BRANCH_LISTING = /^git\s+(?:-C\s+(?:"[^"]*"|'[^']*'|\S+)\s+)?branch\b[^|;]*\s(?:-a|--all|-r|--remotes|--list)\b/;
const GIT_REMOTE_SHOW = /^git\s+(?:-C\s+(?:"[^"]*"|'[^']*'|\S+)\s+)?remote\s+show\b/;

/**
 * `sed -i`, `sed -E -i`, `sed -i.bak`, `sed --in-place`: правка файла на месте.
 *
 * Якорь `^` и `[^|;]*` до флага: `rg -n "sed -i" docs` — поиск текста, а не правка, и блокировать
 * его нельзя. `perl -pi` и heredoc-наборы замен намеренно не трогаются: решение #15849 п.3 выбрало
 * гейт именно на `sed -i`, а многошаговые замены остаются разрешёнными с `assert count==1`.
 */
const SED_IN_PLACE = /^sed\b[^|;]*\s(?:-i\S*|--in-place(?:=\S*)?)(?=\s|$)/;

/**
 * Ступень конвейера, которая режет вывод: `| head`, `| tail -20`, `| head -n 3`.
 *
 * Проверяется любая ступень, а не только последняя: `cmd | rg x | head` — тот же обрезанный вывод, и
 * именно в такой форме ловушка чаще всего и встречается.
 */
const PIPELINE_TRIM = /\|\s*(?:head|tail)\b/;

/** Чтение кода возврата: `$?` и `${?}`. `$$` (pid) и `$#` под правило не попадают. */
const EXIT_STATUS_READ = /\$(?:\?|\{\?\})/;

/**
 * `$?` внутри подстановки: `x=$(cmd | tail …)`. `pipefail` в начало строки там не исправит ничего —
 * код читает подстановка, и $? принадлежит ей, а не конвейеру командной строки (#102).
 */
const EXIT_STATUS_IN_SUBSTITUTION = /\$\([^()]*\$(?:\?|\{\?\})[^()]*\)/;

/**
 * Сегмент включает `pipefail`: `set -o pipefail`, `set -euo pipefail`, `set -eu -o pipefail`.
 *
 * Только `set` в начале сегмента: упоминание флага в тексте (`rg 'set -o pipefail' docs`) не делает
 * соседний `$?` верным и правилом не считается.
 */
const PIPEFAIL_SEGMENT = /^set\s[^|;]*\bpipefail\b/;

/**
 * Ожидание прогона паузой: `sleep 400`, `sleep 5m`, `sleep 0.5`, `sleep 1h`.
 *
 * Порог — 30 секунд (#16149 п.1): короткая пауза законна (порт поднимается, файл появляется), а
 * `sleep 400` — это ожидание долгого прогона, у которого есть `run-detached.sh wait`. Разбор идёт по
 * сегменту, а не по строке: `rg -n 'sleep 400' docs` — поиск текста, а не вызов, и якорь `^` его
 * отсекает.
 */
const SLEEP_SEGMENT = /^sleep\s+(\d+(?:[.,]\d+)?)\s*([smhd]?)(?=\s|$)/;

/** Секунды во единицах суффикса `sleep`: `5`, `5s`, `5m`, `5h`, `5d`. */
const SLEEP_UNIT_SECONDS = { "": 1, s: 1, m: 60, h: 3600, d: 86400 };

/** `sleep` длиннее этого — ожидание прогона, а не пауза (#16149). */
const SLEEP_MAX_SECONDS = 30;

/** Указатель на каталог git: `gitdir: /path/.git/worktrees/<имя>` — так `.git` выглядит в воркдереве. */
const GITDIR_POINTER = /^gitdir:\s*(.+)$/m;

/**
 * Начало heredoc: `<<EOF`, `<<'EOF'`, `<<-"EOF"`. Имя — слово без кавычек в захвате 2.
 *
 * Тело heredoc — данные для команды, а не команда (#101 п.2): правило чтения файла срабатывало на
 * пример `cat <файл>` внутри тела и блокировало `gh issue create --body-file …`, публикацию issue по
 * тому самому дефекту.
 */
const HEREDOC_START = /<<(-?)\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\2/;

/** Каталог с числом записей больше этого сторож режет до `LISTING_MAX_LINES` строк (#102). */
const LISTING_MAX_ENTRIES = 200;
const LISTING_MAX_LINES = 20;

/** Простой листинг каталога без конвейера и флагов: единственный вид, который переписывается безопасно. */
const PLAIN_LS = /^ls\s+([^|;&<>\s]+)\s*$/;

/** Перенаправление stderr в никуда: на `cd`/`ls`/`test -d` оно глушит опечатку в пути (#102). */
const STDERR_SILENCED = /\s*2>\s*\/dev\/null/;

/** `cd <цель>` вместе с перенаправлениями — цель нужна, чтобы резолвить относительные операнды. */
const CD_ONLY = /^cd\s+(?:"[^"]*"|'[^']*'|\S+)/;

/**
 * Вырезать тела heredoc из команды перед разбором (#101 п.2).
 *
 * Строки тела заменяются пустыми: границы heredoc остаются на месте (неразрывность строк важна
 * для номера строки, но не для разбора), а содержимое больше не считается командами.
 * Незакрытый heredoc оставляет текст как есть — обрезать по догадке значило бы потерять команду.
 *
 * @param {string} command
 * @returns {string}
 */
export function stripHeredocBodies(command) {
	const lines = command.split("\n");
	const kept = [];

	for (let index = 0; index < lines.length; index += 1) {
		const line = lines[index];
		kept.push(line);
		const start = HEREDOC_START.exec(line);
		if (start === null || line.indexOf("<<<") !== -1) continue;
		const marker = start[3];
		const allowTabs = start[1] === "-";
		let end = index + 1;
		for (; end < lines.length; end += 1) {
			const candidate = allowTabs ? lines[end].replace(/^\t+/, "") : lines[end];
			if (candidate.trimEnd() === marker) break;
		}
		if (end >= lines.length) return command;
		// Тело — данные: место под него остаётся пустым, терминатор остаётся как маркер.
		for (let body = index + 1; body < end; body += 1) kept.push("");
		kept.push(lines[end]);
		index = end;
	}

	return kept.join("\n");
}

/**
 * Абсолютный путь операнда: от каталога вызова, а не от cwd процесса (#101 п.1).
 *
 * `null` — путь не раскрыт (`$VAR`, `$(…)`): гадать о нём значило бы снова отдать чужое содержимое.
 *
 * @param {string} cwd каталог, в котором идёт сегмент
 * @param {string} operand операнд команды
 * @returns {string | null}
 */
function resolveOperand(cwd, operand) {
	if (cwd === null || /[$`]/.test(operand)) return null;
	const expanded = operand.replace(/^~(?=\/|$)/, homedir());
	return resolve(cwd, expanded);
}

/**
 * Цель `cd` из одного сегмента, либо `null`.
 *
 * @param {string} segment
 * @returns {string | null}
 */
function cdSegmentTarget(segment) {
	if (!CD_SEGMENT.test(segment)) return null;
	const parts = words(segment);
	return parts[0] === "cd" && parts[1] !== undefined ? parts[1] : null;
}

/**
 * BRE-шаблон `grep` → регулярное выражение JS (#95).
 *
 * В shell-grep по умолчанию BRE: альтернация — `\|`, группа — `\(`, повтор — `\+`. В JS-regex эти
 * последовательности — литералы (`\|` ищет символ `|`). Сторож повторял шаблон через `new RegExp`
 * и отвечал «совпадений нет» на `grep -n 'putenv\|tearDown' файл`, где совпадения были (#16200):
 * вывод «такого кода нет» делался по ложному ответу инструмента, заведённого ровно ради точности.
 *
 * @param {string} pattern
 * @returns {string}
 */
export function breToJs(pattern) {
	const escaped = { "|": "|", "(": "(", ")": ")", "+": "+", "?": "?", "{": "{", "}": "}" };
	let out = "";
	for (let index = 0; index < pattern.length; index += 1) {
		const char = pattern[index];
		if (char !== "\\" || index + 1 >= pattern.length) {
			out += char;

			continue;
		}
		const next = pattern[index + 1];
		out += escaped[next] ?? `\\${next}`;
		index += 1;
	}
	return out;
}

/**
 * Число записей каталога, если это каталог и их читаемо много; иначе `null`.
 *
 * @param {string | null} path
 * @returns {number | null}
 */
function directoryEntryCount(path) {
	if (path === null) return null;
	try {
		const stat = statSync(path);
		if (!stat.isDirectory()) return null;
		return readdirSync(path).length;
	} catch {
		return null;
	}
}

/**
 * Строка для stderr: одна короткая фраза о том, что сторож поменял в команде.
 *
 * @param {string} note
 * @returns {string}
 */
function noteCommand(note) {
	return `printf '%s\\n' ${shellQuote(note)} >&2`;
}

/**
 * Слово в одинарных кавычках для shell, а не для JS-шаблона: апостроф внутри ломает кавычки.
 *
 * @param {string} text
 * @returns {string}
 */
function shellQuote(text) {
	return "'" + text.replaceAll("'", "'\\''") + "'";
}

/**
 * Слова сегмента: кавычки снимаются, перенаправления остаются отдельными словами.
 *
 * @param {string} segment
 * @returns {string[]}
 */
function words(segment) {
	const out = [];
	const re = /'([^']*)'|"([^"]*)"|(\S+)/g;
	let match;
	while ((match = re.exec(segment)) !== null) {
		out.push(match[1] ?? match[2] ?? match[3]);
	}
	return out;
}

/** Флаг, а не операнд: `-n`, `-rn`, `--quiet`; одинокий `-` — stdin, а не флаг. */
function isFlag(token) {
	return token.startsWith("-") && token !== "-";
}

/**
 * Что лежит по пути: `{ isFile, size }`, либо `null` — путь не проверен (относительный, нет такого).
 *
 * @param {string} path
 * @returns {{ isFile: boolean, size: number } | null}
 */
function probeFile(path) {
	try {
		const stat = statSync(path);
		return { isFile: stat.isFile(), size: stat.size };
	} catch {
		return null;
	}
}

/**
 * Файл читается только через `read`: размер не доказан большим (или не проверен вовсе).
 *
 * @param {string | null} path абсолютный путь (резолвится от `cd`, см. `resolveOperand`)
 * @returns {boolean}
 */
function readsSmallFile(path) {
	if (path === null) return true;
	const probe = probeFile(path);
	return probe === null || probe.size <= READ_LIMIT_BYTES;
}

/**
 * Факты о каталоге для вызова, который состоял только из `cd` (#87 п.1).
 *
 * Переход писали ради ответа «где я, какая ветка, есть ли правки», а сторож отдавал пустой отказ
 * одиннадцать раз за сессию. `git` здесь не запускается: ветку даёт `.git/HEAD`, наличие репозитория —
 * сам `.git`, а состояние правок агент получает готовой строкой. Запуск `git` из сторожа стоил бы
 * секунды на каждом вызове в большом репозитории и дал бы новую причину зависания (ADR 0001).
 *
 * @param {string | null} target каталог из `cd`, либо null — текущий каталог процесса
 * @returns {string[]}
 */
function directoryFacts(target) {
	if (target !== null && /[$`]/.test(target)) {
		return [`каталог \`${target}\` не раскрыт — подставьте путь в строку ниже сами`];
	}
	const dir = resolve(process.cwd(), (target ?? ".").replace(/^~(?=\/|$)/, homedir()));
	if (!existsSync(dir)) return [`каталога \`${dir}\` нет`];

	let head = "";
	const dotGit = join(dir, ".git");
	try {
		head = readFileSync(join(dotGit, "HEAD"), "utf8").trim();
	} catch {
		// `.git` файлом — это воркдерево: HEAD лежит по указателю из этого файла.
		try {
			const pointer = readFileSync(dotGit, "utf8").match(GITDIR_POINTER);
			if (pointer === null) return [`\`.git\` в \`${dir}\` — файл без указателя gitdir`];
			head = readFileSync(join(resolve(dir, pointer[1].trim()), "HEAD"), "utf8").trim();
		} catch {
			return [`\`.git\` в \`${dir}\` нет — это не репозиторий`];
		}
	}

	const branch = head.match(/^ref:\s*refs\/heads\/(.+)$/);
	return [
		branch === null ? `HEAD отделён от ветки: \`${head.slice(0, 12)}\`` : `ветка: \`${branch[1]}\``,
		`состояние правок — \`git -C ${dir} status --short --branch\``,
	];
}

/**
 * Каталог, в который переходят `cd`-сегменты: последний переход выигрывает, как в shell.
 *
 * @param {string[]} segments
 * @returns {string | null}
 */
function cdTarget(segments) {
	let target = null;
	for (const segment of segments) {
		const text = unwrapped(segment);
		if (!CD_SEGMENT.test(text)) continue;
		const parts = words(text);
		if (parts[0] === "cd" && parts[1] !== undefined) target = parts[1];
	}
	return target;
}

/**
 * Отфильтрованный список веток: `--list '<шаблон>'` или `--list=<шаблон>` (#86).
 *
 * `--list` без шаблона печатает весь список — правило прежнее. Шаблон отдельным словом или в самом
 * флаге — это фильтр, и отказ на нём стоил двух ходов в сессии #16129.
 *
 * @param {string} segment
 * @returns {boolean}
 */
function branchListFiltered(segment) {
	const tokens = words(segment);
	const index = tokens.findIndex((token) => token === "--list" || token.startsWith("--list="));
	if (index === -1) return false;
	const token = tokens[index];
	if (token.startsWith("--list=")) return token.length > "--list=".length;
	const next = tokens[index + 1];
	return next !== undefined && !isFlag(next);
}

/** Операнды сегмента: без флагов, без heredoc-меток и перенаправлений. */
function operands(args) {
	return args.filter((token) => !isFlag(token) && !token.startsWith("<") && !token.includes(">"));
}

/**
 * Сколько строк файла сторож отдаёт вместо запрошенного чтения (#16110).
 *
 * Отказ без содержимого стоил хода на каждой сессии (#16074 — 3, #16048 — 7, #16110 — 6–7): агент
 * повторял ту же цель законным инструментом. Возврат самого содержимого в тексте отказа делает отказ
 * бесплатным, а граница держит разговор коротким — столько же вернул бы `read` с `limit`.
 */
const EXCERPT_MAX_LINES = 200;
const EXCERPT_MAX_MATCHES = 50;

/**
 * Строки файла с номерами: `cat` — с начала, `sed -n 'A,Bp'` — запрошенный диапазон.
 *
 * @param {string} path
 * @param {number} from с 1
 * @param {number} to 0 с 1, включительно
 * @returns {string} пустая строка — файл не прочитан
 */
function linesExcerpt(path, from, to) {
	try {
		const all = readFileSync(path, "utf8").split("\n");
		const start = Math.max(1, from);
		const end = Math.min(to, all.length, start + EXCERPT_MAX_LINES - 1);
		if (end < start) return "";
		const lines = [];
		for (let n = start; n <= end; n += 1) {
			lines.push(`${String(n).padStart(6, " ")}\t${all[n - 1] ?? ""}`);
		}
		if (end < all.length) lines.push(`… строки ${end + 1}–${all.length} не показаны: их отдаст read с offset=${end + 1}`);
		return lines.join("\n");
	} catch {
		return "";
	}
}

/**
 * Совпадения `grep -n <шаблон> <файл>` с номерами строк.
 *
 * Шаблон берётся так, как его понял бы сам grep: BRE-эскейпы (`\|`, `\(`, `\+`) переводятся в
 * регулярное выражение JS (#95). Шаблон, который после перевода всё равно не разбирается,
 * ищется подстрокой — и ответ это называет: «шаблон не разобран», а не «совпадений нет»:
 * разница между «нет совпадений» и «не смог прочитать запрос» — это разница между фактом и
 * догадкой, а именно на ней ломался вывод ретро #16200.
 *
 * @param {string} path абсолютный путь
 * @param {string} pattern
 * @returns {string}
 */
function grepExcerpt(path, pattern) {
	let test;
	let unparsed = false;
	try {
		const re = new RegExp(breToJs(pattern));
		test = (line) => re.test(line);
	} catch {
		test = (line) => line.includes(pattern);
		unparsed = true;
	}
	try {
		const all = readFileSync(path, "utf8").split("\n");
		const hits = [];
		for (let i = 0; i < all.length; i += 1) {
			if (test(all[i])) hits.push(`${String(i + 1).padStart(6, " ")}\t${all[i]}`);
			if (hits.length > EXCERPT_MAX_MATCHES) break;
		}
		if (hits.length === 0) {
			return unparsed
				? `шаблон «${pattern}» не разобран как регулярное выражение; подстрокой совпадений в файле нет`
				: `совпадений «${pattern}» в файле нет`;
		}
		const shown = hits.slice(0, EXCERPT_MAX_MATCHES);
		if (hits.length > EXCERPT_MAX_MATCHES) shown.push(`… совпадений больше ${EXCERPT_MAX_MATCHES}: сузьте шаблон или берите ffgrep с limit`);
		return shown.join("\n");
	} catch {
		return "";
	}
}

/**
 * Имена инструментов pi, которые иногда уходят в `bash` как бинарник (#16126).
 *
 * В сессии #16110 дважды пришло `bash: ffgrep: command not found`: имя тула набрано в командной
 * строке вместо вызова тула. Ошибка дешёвая, но немая — в отказе видно только «command not found»,
 * и следующий ход агент тратит на ту же цель другим путём. Правило ловит только имена, которых в
 * системе нет: `read` не входит (это встроенная команда bash, `while read -r` — обычный код).
 */
const PI_TOOL_NAMES = new Set(["ffgrep", "fffind"]);

/**
 * Инструмент pi, набранный как команда bash: `ffgrep --pattern …` вместо вызова тула.
 *
 * @param {string} segment уже развёрнутый сегмент (`unwrapped`)
 * @returns {{ allowed: boolean, reason: string, hint: string } | null}
 */
function toolNameVerdict(segment) {
	const command = words(segment)[0];
	if (command === undefined || !PI_TOOL_NAMES.has(command)) return null;
	return {
		allowed: false,
		reason: "`" + command + "` — инструмент pi, а не бинарник: в bash такого файла нет (`command not found`).",
		hint: "Вызовите сам тул: `ffgrep pattern='…' path='…' limit=20` для поиска по содержимому, `fffind` — для поиска по пути. Осознанно — PI_CALL_GUARD_ALLOW=1.",
	};
}

/**
 * Правило чтения: `sed -n`, `cat <файл>`, `grep -n <файл>` по файлу до 50 КБ и `grep -r` по дому.
 *
 * Пути резолвятся от `cwd` — каталога, в котором идёт сегмент после `cd` того же вызова (#101 п.1):
 * `cd /воркдерево && cat файл` отдавал в отказе файл из основного дерева, и отказ читался как
 * «вот текущее состояние файла».
 *
 * @param {string} segment
 * @param {string} cwd каталог сегмента (уже раскрытый от `cd`)
 * @returns {{ allowed: boolean, reason: string, hint: string, excerpt?: string } | null}
 */
function readingVerdict(segment, cwd) {
	const parts = words(segment);
	const command = parts[0];
	if (command !== "sed" && command !== "cat" && command !== "grep") return null;

	const args = parts.slice(1);
	const hintRead = "Чтение файла — `read` с `offset` и `limit` (нумерация строк, обрезка вывода, дифф), поиск по содержимому — `ffgrep`, поиск по пути — `fffind`. Осознанно — PI_CALL_GUARD_ALLOW=1.";

	if (command === "sed") {
		const quiet = args.some((token) => token === "-n" || token === "--quiet" || token === "--silent"
			|| /^-[a-zA-Z]*n[a-zA-Z]*$/.test(token));
		if (!quiet) return null;
		const script = args.find((token) => SED_PRINT_RANGE.test(token));
		if (script === undefined) return null;
		const operand = operands(args.slice(args.indexOf(script) + 1))[0];
		if (operand === undefined || operand === "-") return null;
		const file = resolveOperand(cwd, operand);
		if (!readsSmallFile(file)) return null;
		const [from, to] = script.slice(0, -1).split(",").map((value) => Number.parseInt(value, 10));
		return {
			allowed: false,
			reason: "`sed -n 'N,Mp' <файл>` — чтение файла через bash; преимуществ перед `read` у него нет.",
			hint: hintRead,
			excerpt: file === null ? "" : linesExcerpt(file, from, Number.isFinite(to) ? to : from),
		};
	}

	if (command === "cat") {
		// `cat > файл`, `cat >> журнал`, `cat <<EOF` — это запись и heredoc, а не чтение: их правило
		// не трогает (иначе блокировался бы самый обычный способ создать временный файл).
		if (args.some((token) => token.includes(">") || token.startsWith("<"))) return null;
		const names = operands(args);
		if (names.length === 0 || names.includes("-")) return null;
		const files = names.map((name) => resolveOperand(cwd, name));
		if (!files.some((file) => readsSmallFile(file))) return null;
		// Несколько файлов сторож не отдаёт: `cat a b` — это склейка, и порядок в ней важен для
		// читающего; без содержимого остаётся обычный отказ.
		const excerpt = files.length !== 1 || files[0] === null ? "" : linesExcerpt(files[0], 1, EXCERPT_MAX_LINES);
		return {
			allowed: false,
			reason: "`cat <файл>` — то же чтение, что и `read`, но без номеров строк и без номера области.",
			hint: hintRead,
			excerpt,
		};
	}

	const recursive = args.some((token) => token === "--recursive" || token === "--dereference-recursive"
		|| /^-[a-zA-Z]*[rR][a-zA-Z]*$/.test(token));
	const positional = operands(args);
	if (recursive) {
		const paths = positional.slice(1);
		const broad = paths.some((path) => BROAD_PATHS.includes(path) || path === "/home/denis/.");
		if (!broad) return null;
		return {
			allowed: false,
			reason: "`grep -r` по домашнему каталогу или корню репозитория: два таких вызова в одной сессии умерли по таймауту (60 с и 10 с).",
			hint: "Сужьте путь или берите `ffgrep pattern='…' path='…' exclude='…' limit=20` (он сразу без зеркал); для особого случая — `rg` с `--glob '!…'`. Осознанно — PI_CALL_GUARD_ALLOW=1.",
		};
	}

	const numbered = args.some((token) => token === "--line-number" || /^-[a-zA-Z]*n[a-zA-Z]*$/.test(token));
	const names = positional.slice(1);
	// `grep -n шаблон -` читает stdin: файла нет, и правило чтения файла к нему не относится.
	if (!numbered || names.length === 0 || names.includes("-")) return null;
	const files = names.map((name) => resolveOperand(cwd, name));
	const suspicious = files.some((file) => {
		if (file === null) return true;
		const probe = probeFile(file);
		return probe !== null && !probe.isFile ? false : readsSmallFile(file);
	});
	if (!suspicious) return null;
	// Шаблон — первый операнд, файлы — остальные; для нескольких файлов содержимое не отдаётся, как и
	// у `cat`: смешать их вывод значило бы соврать о том, откуда строка.
	const excerpt = files.length !== 1 || files[0] === null ? "" : grepExcerpt(files[0], positional[0] ?? "");
	return {
		allowed: false,
		reason: "`grep -n <файл>` — поиск по файлу через bash; `ffgrep` учитывает `.gitignore` и держит вывод в `limit`.",
		hint: hintRead,
		excerpt,
	};
}

/**
 * Вердикт по `sleep`: длинная пауза вместо ожидания прогона (#16149 п.1).
 *
 * Правило живёт в стороже, а не только в прозе `AGENTS.md`, потому что проза меняет поведение не всегда:
 * правило про `wait` появилось в 11:03, а сессия #16105 стартовала в 10:41 — в снимке контекста его не
 * было, и ожидание снова ушло двумя `sleep` на 9 минут. Сторож работает независимо от того, какую
 * версию `AGENTS.md` загрузила сессия.
 *
 * @param {string} segment сегмент без обёрток, первая ступень конвейера
 * @returns {{ allowed: boolean, reason?: string, hint?: string } | null}
 */
function sleepVerdict(segment) {
	const match = SLEEP_SEGMENT.exec(segment);
	if (match === null) return null;
	const value = Number(match[1].replace(",", "."));
	if (!Number.isFinite(value)) return null;
	const seconds = value * (SLEEP_UNIT_SECONDS[match[2]] ?? 1);
	if (seconds <= SLEEP_MAX_SECONDS) return null;

	return {
		allowed: false,
		reason: `Ожидание \`sleep\` на ${match[0].slice("sleep ".length)} — дольше 30 секунд: так ждут долгий прогон, а у него есть \`wait\`.`,
		hint: "Цель дольше ~5 минут запускается обёрткой (`bash scripts/ci/run-detached.sh start -- <команда>`), а ждётся одним вызовом `wait <id> [--timeout N]`: он выходит, как только прогон закончился, и печатает итог. `sleep` промахивается в обе стороны: прогон готов на 400-й секунде, а спят 540 (#16009, 3 ч 48 мин из 7 ч 47 мин в #15815). Пауза до 30 с проходит; осознанно — PI_CALL_GUARD_ALLOW=1.",
	};
}

/**
 * Обёртки перед командой: `sudo`, `command`, `env -u X`, `GIT_PAGER=cat`, `time`, их флаги и
 * присваивания переменных. Снимаются, чтобы правило видело сам вызов: `sudo git branch -a`
 * блокировался и до сужения правил к сегменту. Якорь `^` нужен ровно для того, что НЕ является
 * вызовом git (`rg -n "git branch -a"`).
 */
const WRAPPER = /^(sudo|command|exec|time|env)\b\s*/;
const ASSIGNMENT = /^[A-Za-z_][A-Za-z0-9_]*=\S*\s+/;
const FLAG = /^-{1,2}[^\s]+/;

/**
 * Флаги обёрток, у которых аргумент отдельным словом — свои у каждой обёртки: `-p` у `sudo` — prompt
 * с аргументом, а у `time` — «portable output» без аргумента. Один общий список съедал `git`.
 */
const WRAPPER_ARGUMENT_FLAGS = {
	sudo: new Set(["-u", "--user", "-g", "--group", "-p", "--prompt", "-h", "--host", "-U", "--other-user", "-C", "--close-from"]),
	env: new Set(["-u", "--unset", "-C", "--chdir", "-S", "--split-string"]),
	time: new Set(["-f", "--format", "-o", "--output"]),
	command: new Set(),
	exec: new Set(["-a"]),
};

function unwrapped(segment) {
	let text = segment.trim();
	let wrapperName = null;

	for (;;) {
		let next = null;
		const wrapper = text.match(WRAPPER);
		if (wrapper) {
			wrapperName = wrapper[1];
			next = text.slice(wrapper[0].length).trim();
		} else if (ASSIGNMENT.test(text)) {
			next = text.replace(ASSIGNMENT, "").trim();
		} else if (FLAG.test(text)) {
			const flag = (text.match(FLAG) || [""])[0];
			const rest = text.slice(flag.length).trim();
			const takesArgument = wrapperName !== null
				&& (WRAPPER_ARGUMENT_FLAGS[wrapperName] || new Set()).has(flag);
			next = takesArgument ? rest.replace(/^\S+\s*/, "").trim() : rest;
		}

		if (next === null || next === text || next === "") return next ?? text;
		text = next;
	}
}

/**
 * Первая ступень конвейера: текст до первого `|` вне кавычек. `grep -n 'a|b' файл` — один сегмент,
 * а не две ступени; без этого разбор кавычек съел бы шаблон и заблокировал чтение зря.
 *
 * @param {string} segment
 * @returns {string}
 */
export function firstPipelineStage(segment) {
	let quote = null;
	for (let i = 0; i < segment.length; i += 1) {
		const char = segment[i];
		if (quote !== null) {
			if (char === quote) quote = null;
			continue;
		}
		if (char === "'" || char === '"') {
			quote = char;
			continue;
		}
		if (char === "|") return segment.slice(0, i);
	}
	return segment;
}

/**
 * Разбить команду на сегменты по `;`, `&&`, `||` вне кавычек.
 *
 * Одиночный `|` сегментом НЕ считается: конвейер — это один вызов, и «есть ли фильтр» решается
 * внутри сегмента (`git branch -a | wc -l` — это один сегмент с фильтром).
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
		const pair = command[i + 1];
		// `2>&1`, `&>file`: `&` здесь часть перенаправления, а не фон — иначе конвейер после него
		// разрезался бы, и `git branch -a 2>&1 | head` падал бы под правило «без фильтра».
		const redirect = char === "&" && (command[i - 1] === ">" || pair === ">");
		if (redirect) {
			current += char;

			continue;
		}
		if (char === ";" || char === "&" || (char === "|" && pair === "|")) {
			segments.push(current);
			current = "";
			// `&&` и `||` — один разделитель из двух символов; одиночный `&` — фон, тоже конец команды.
			if (pair === "&" || (char === "|" && pair === "|")) i += 1;
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
 * @returns {{ allowed: boolean, reason?: string, hint?: string, excerpt?: string, patchedCommand?: string, note?: string }}
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

	// Тело heredoc — данные для команды, а не команда (#101 п.2): пример `cat <файл>` внутри
	// `gh issue create --body-file … <<'EOF'` блокировал публикацию самого issue про этот дефект.
	const parsed = stripHeredocBodies(trimmed);
	const segments = splitSegments(parsed);
	const useful = segments.filter((segment) => !NOOP_SEGMENT.test(segment) && !CD_SEGMENT.test(segment));
	if (useful.length === 0) {
		return {
			allowed: false,
			reason: "Вызов без цели: после `cd` и `;` не остаётся команды, которая что-то делает.",
			hint: [
				...directoryFacts(cdTarget(segments)),
				"Переход сам по себе ничего не проверяет. Дальше — либо абсолютный путь в самой команде (`git -C <abs>`, `make -C <abs>`), либо строка из подсказки выше.",
			].join("\n"),
		};
	}

	// Исправления, а не отказы (#102): сторож вставляет в команду то, что агент забыл, и говорит
	// об этом строкой в stderr. Отказ стоил хода там, где правка однозначна.
	const patches = [];
	let patched = trimmed;
	const patch = (from, to) => {
		if (from === "" || !patched.includes(from)) return false;
		patched = patched.replace(from, to);
		return true;
	};

	// Конвейер в `head`/`tail` и голый `$?` в более позднем сегменте: код возврата приходит от `tail`.
	// Проверка идёт по порядку сегментов, а не по всей строке: `echo $? | tail` — обратный случай
	// (код читается до обрезки), и трогать его незачем.
	let pipefail = false;
	let needsPipefail = false;
	const trimIndex = segments.findIndex((segment) => PIPELINE_TRIM.test(segment));
	if (trimIndex !== -1 && segments.slice(trimIndex + 1).some((segment) => EXIT_STATUS_READ.test(segment))) {
		// `set -o pipefail` в этой же команде делает `$?` верным — тогда правки нет.
		pipefail = segments.some((segment) => PIPEFAIL_SEGMENT.test(unwrapped(segment).trim()));
		// Отказ остаётся только там, где подстановка `$?` принадлежит подстановке, а не конвейеру
		// командной строки: `x=$(cmd | tail …; echo $?)` — код печатает сама подстановка.
		if (!pipefail && EXIT_STATUS_IN_SUBSTITUTION.test(trimmed)) {
			return {
				allowed: false,
				reason: "Конвейер в `head`/`tail` и `$?` после него — внутри `$( … )`: код возврата принадлежит подстановке, а `pipefail` в начало строки его не исправит.",
				hint: [
					`Заблокирован сегмент \`${segments[trimIndex].trim()}\` — команда не выполнена целиком, остальные её сегменты тоже.`,
					"Код первой ступени в обход правила — `${PIPESTATUS[0]}` вместо голого `$?`, либо снимите конвейер.",
				].join("\n"),
			};
		}
		needsPipefail = !pipefail;
	}

	let cwd = process.cwd();
	for (const raw of segments) {
		// Чтение проверяется и в конвейере, по первой ступени: `cat файл | head` — тот же `cat`, и
		// именно `| head` был самым естественным обходом правила (замер ревью: 26 вызовов `sed -n`,
		// ради которых правило написано, проходили ровно так). Правило 2 наоборот требует конвейер
		// как признак фильтра, поэтому ниже сегменты с `|` по-прежнему пропускаются.
		const stage = unwrapped(firstPipelineStage(raw));

		// Каталог сегмента: относительный операнд резолвится от последнего `cd` (#101 п.1).
		const cdTo = cdSegmentTarget(stage.trim());
		if (cdTo !== null) cwd = resolveOperand(cwd, cdTo);

		// Имя тула вместо бинарника проверяется раньше чтения: `ffgrep` — не команда, и отказ должен
		// называть вызов тула, а не правило чтения файла.
		const toolName = toolNameVerdict(stage);
		if (toolName !== null) return toolName;

		const reading = readingVerdict(stage, cwd);
		if (reading !== null) return reading;

		// `sleep` проверяется до пропуска конвейера: `sleep 400 | tee log` — то же ожидание паузой.
		const sleeping = sleepVerdict(stage.trim());
		if (sleeping !== null) return sleeping;

		// Правки ниже переписывают сегмент целиком, поэтому конвейерные ступени сюда не идут.
		if (/\|/.test(raw)) continue;

		// `2>/dev/null` на `cd`/`ls`/`test -d` глушит единственный сигнал о промахе в пути (#102 п.3):
		// после такой команды следующие сегменты работают в каталоге от предыдущего `cd`.
		if (/^(?:cd|ls|test)\b/.test(stage.trim()) && STDERR_SILENCED.test(raw)) {
			const cleaned = raw.replace(STDERR_SILENCED, "").trim();
			if (patch(raw.trim(), cleaned)) {
				patches.push(`\`2>/dev/null\` с \`${stage.trim().split(/\s+/)[0]}\` снят: он глушит ошибку пути`);
			}
		}

		// Листинг каталога с тысячами записей режется до нескольких строк (#102 п.2): `ls docs`
		// отдал 50 КБ в ретро #16219, и такой хвост — потеря вывода, а не самого вызова.
		const listing = PLAIN_LS.exec(stage.trim());
		if (listing !== null) {
			const target = listing[1];
			const dir = resolveOperand(cwd, target);
			const count = directoryEntryCount(dir);
			if (count !== null && count > LISTING_MAX_ENTRIES) {
				const quoted = shellQuote(target);
				const replacement = `{ n=$(ls -1 ${quoted} | wc -l); ls -1 ${quoted} | head -${LISTING_MAX_LINES}; printf '\\ncall-guard: каталог %s: %s записей, показаны первые ${LISTING_MAX_LINES}\\n' ${quoted} "$n"; }`;
				if (patch(raw.trim(), replacement)) {
					patches.push(`\`ls ${target}\`: ${count} записей — показаны первые ${LISTING_MAX_LINES}`);
				}
			}
		}

		const segment = unwrapped(raw);

		if (SED_IN_PLACE.test(segment)) {
			return {
				allowed: false,
				reason: "`sed -i` — правка файла на месте, без проверки уникальности вхождения и без диффа.",
				hint: "Точечная правка — `edit` (он требует уникального `oldText` и принимает несколько замен за вызов). Набор замен через heredoc разрешён с `assert count==1`; осознанно — PI_CALL_GUARD_ALLOW=1.",
			};
		}

		if (GIT_BRANCH_LISTING.test(segment) && !branchListFiltered(segment)) {
			return {
				allowed: false,
				reason: "Вывод `git branch` без фильтра: список веток всего репозитория (2168 строк, 50 КБ).",
				hint: "Добавьте фильтр: `| wc -l`, `| rg <шаблон>` или `| head`. Нужен весь список осознанно — PI_CALL_GUARD_ALLOW=1.",
			};
		}

		if (GIT_REMOTE_SHOW.test(segment)) {
			return {
				allowed: false,
				reason: "Вывод `git remote show` без фильтра: десятки строк про каждый remote.",
				hint: "Уточните вопрос: `git remote get-url origin`, `git remote show origin | rg <поле>`. Осознанно — PI_CALL_GUARD_ALLOW=1.",
			};
		}
	}

	if (needsPipefail) {
		patched = `set -o pipefail; ${patched}`;
		patches.push("добавлен `set -o pipefail`: `$?` теперь от первой ступени конвейера, а не от `tail`");
	}

	if (patches.length === 0) return { allowed: true };

	const note = `call-guard: ${patches.join("; ")}`;
	return { allowed: true, patchedCommand: `${noteCommand(note)}; ${patched}`, note };
}

/**
 * Ответ хука Pi: `{ block: true, reason }` либо `undefined`, если вызов проходит.
 *
 * @param {{ allowed: boolean, reason?: string, hint?: string }} verdict
 */
export function toToolCallResult(verdict) {
	if (verdict.allowed) return undefined;

	const lines = [`Call Guard blocked: ${verdict.reason ?? "вызов без цели"}`];
	if (verdict.excerpt) {
		// Содержимое отдаётся до подсказки о законном инструменте: агенту нужен ответ, а не нотация.
		// Повторный вызов не нужен — это и есть цель правки #16110.
		lines.push(
			"Запрошенное содержимое — здесь, повторный вызов не нужен:",
			verdict.excerpt,
			"Дальше этот файл читайте `read` (offset/limit, нумерация и дифф) или `ffgrep`: сторож отдаёт только первую область, остальное — нет."
		);
	}
	if (verdict.hint) lines.push(verdict.hint);
	return { block: true, reason: lines.join("\n") };
}
