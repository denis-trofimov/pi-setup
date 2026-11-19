// @file: call-guard.test.mjs
// @description: Тесты правил call-guard: вызов без цели, `git branch -a`/`git remote show` без фильтра,
//               отсутствие ложных срабатываний на командах, где `cd` — часть рабочего вызова.
// @dependencies: node:test, node:assert, ../extensions/call-guard-core.mjs
// @created: 2026-11-19
//
// Запуск: `node --test tests/call-guard.test.mjs` из корня pi-setup.
//
// Первые кейсы — живые замеры: #15738 п.5 (`cd … 2>/dev/null; true` пять раз за сессию) и
// #15749 п.5 (`git branch -a` → 2168 строк, 50 КБ).

import assert from "node:assert/strict";
import { test } from "node:test";

import { classifyCall, splitSegments } from "../extensions/call-guard-core.mjs";

test("пустой вызов после cd блокируется — замер #15738 п.5", () => {
	const verdict = classifyCall("cd /home/denis/p/msl/msb-lk 2>/dev/null; true");
	assert.equal(verdict.allowed, false);
	assert.match(verdict.reason, /без цели/);
	assert.match(verdict.hint, /git -C|make -C/);
});

test("голый `:` и `exit 0` — тоже вызов без цели", () => {
	assert.equal(classifyCall("cd /tmp; :").allowed, false);
	assert.equal(classifyCall("cd /tmp && exit 0").allowed, false);
	assert.equal(classifyCall("true").allowed, false);
});

test("cd с полезной частью проходит", () => {
	assert.equal(classifyCall("cd /repo && make test").allowed, true);
	assert.equal(classifyCall("cd /repo 2>/dev/null; rg -n 'foo' src/").allowed, true);
	assert.equal(classifyCall("git -C /repo status --short").allowed, true);
});

test("git branch -a без фильтра блокируется — замер #15749 п.5", () => {
	for (const command of ["git branch -a", "git branch --all", "git branch -r", "git branch --remotes"]) {
		const verdict = classifyCall(command);
		assert.equal(verdict.allowed, false, command);
		assert.match(verdict.reason, /git branch/, command);
		assert.match(verdict.hint, /wc -l/, command);
	}
});

test("git branch с фильтром проходит", () => {
	assert.equal(classifyCall("git branch -a | wc -l").allowed, true);
	assert.equal(classifyCall("git branch -a | rg 15822").allowed, true);
	assert.equal(classifyCall("git branch -a | head -20").allowed, true);
});

test("git branch -d (удаление) правилом не трогается: это другой сторож", () => {
	assert.equal(classifyCall("git branch -d fix/15822-tooling-guards").allowed, true);
});

test("git remote show без фильтра блокируется, get-url проходит", () => {
	assert.equal(classifyCall("git remote show origin").allowed, false);
	assert.equal(classifyCall("git remote show origin | rg Fetch").allowed, true);
	assert.equal(classifyCall("git remote get-url origin").allowed, true);
});

test("осознанный обход снимает блокировку", () => {
	assert.equal(classifyCall("git branch -a", { allow: true }).allowed, true);
	assert.equal(classifyCall("cd /tmp; true", { allow: true }).allowed, true);
});

test("сегменты режутся по ; && || вне кавычек", () => {
	assert.deepEqual(splitSegments("cd /a; true"), ["cd /a", "true"]);
	assert.deepEqual(splitSegments("cd /a && a || b"), ["cd /a", "a", "b"]);
	assert.deepEqual(splitSegments('echo "a;b"'), ['echo "a;b"']);
	assert.deepEqual(splitSegments("git branch -a | wc -l"), ["git branch -a", "wc -l"]);
});
