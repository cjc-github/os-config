"use strict";

// app.js 是可无 DOM 加载的纯函数集合，便于用 Node 内置 test runner 验证。
const test = require("node:test");
const assert = require("node:assert");

const app = require("../ui/static/app.js");

test("statusLabel distinguishes install and verify phases", () => {
  assert.equal(app.statusLabel("ok"), "成功");
  assert.equal(app.statusLabel("failed"), "失败");
  assert.equal(app.statusLabel("ok", "verify"), "通过");
  assert.equal(app.statusLabel("failed", "verify"), "未通过");
  assert.equal(app.statusLabel("not_run", "verify"), "未执行");
  assert.equal(app.statusLabel("skipped", "verify"), "跳过");
});

test("joinLogLines separates log rows with newlines", () => {
  assert.equal(app.joinLogLines(["a", "b", ""]), "a\nb\n");
  assert.equal(app.joinLogLines([]), "");
});

test("validAdhocToken accepts only apt/npm/snap tokens", () => {
  assert.equal(app.validAdhocToken("apt:jq"), true);
  assert.equal(app.validAdhocToken("npm:@scope/pkg"), true);
  assert.equal(app.validAdhocToken("snap:code"), true);
  assert.equal(app.validAdhocToken("apt:jq;rm -rf /"), false);
  assert.equal(app.validAdhocToken("brew:jq"), false);
  assert.equal(app.validAdhocToken("apt:-x"), false);
  assert.equal(app.validAdhocToken(""), false);
});

test("logFileName uses the viewed run id", () => {
  assert.equal(app.logFileName("20261020-120000-abc123"), "os-config-20261020-120000-abc123.log");
  assert.equal(app.logFileName(null), "os-config-log.log");
  assert.equal(app.logFileName(""), "os-config-log.log");
});

test("normalizeAdhocId mirrors the server id normalization", () => {
  assert.equal(app.normalizeAdhocId("apt:jq"), "jq");
  assert.equal(app.normalizeAdhocId("npm:@scope/pkg"), "scope-pkg");
  assert.equal(app.normalizeAdhocId("snap:code"), "code");
  assert.equal(app.normalizeAdhocId("apt:jq;rm -rf /"), null);
  assert.equal(app.normalizeAdhocId(""), null);
});

test("normalizeAdhocId strips every leading and trailing dash", () => {
  // 与 engine/lib/profile.sh、ui/schema.py 的规则一致
  assert.equal(app.normalizeAdhocId("apt:x--"), "x");
  assert.equal(app.normalizeAdhocId("apt:x-"), "x");
  assert.equal(app.normalizeAdhocId("apt:-x"), null);
});

test("selectionResultIds includes adhoc items before item events arrive", () => {
  assert.deepEqual(app.selectionResultIds(["git", "apt:jq"], []), ["git", "jq"]);
  assert.deepEqual(app.selectionResultIds(["apt:foo", "snap:foo"], []), ["foo"]);
  assert.deepEqual(app.selectionResultIds(["git"], ["git", "curl"]), ["git", "curl"]);
  assert.deepEqual(app.selectionResultIds(["apt:jq"], ["jq"]), ["jq"]);
});

test("canLoadHistory blocks playback while a run is active", () => {
  assert.equal(app.canLoadHistory(false), true);
  assert.equal(app.canLoadHistory(true), false);
});

test("appendLogLine keeps raw stream order and drops the oldest line", () => {
  const lines = [];
  app.appendLogLine(lines, "git a", 4);
  app.appendLogLine(lines, "jq a", 4);
  app.appendLogLine(lines, "git b", 4);
  app.appendLogLine(lines, "jq b", 4);
  assert.deepEqual(lines, ["git a", "jq a", "git b", "jq b"]);
  app.appendLogLine(lines, "git c", 4);
  assert.deepEqual(lines, ["jq a", "git b", "jq b", "git c"]);
});
