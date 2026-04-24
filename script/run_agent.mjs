#!/usr/bin/env node
// Runs a Claude Agent SDK session inside a pre-existing worktree.
// Reads {title, body} as JSON from stdin.
// Writes one JSON event per line to stdout.
// Exits 0 on success, nonzero on error. Does not push or open a PR.

import { query } from "@anthropic-ai/claude-agent-sdk";
import { readFileSync } from "node:fs";
import process from "node:process";

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function parseArgs(argv) {
  const args = { worktree: null };
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--worktree") args.worktree = argv[++i];
  }
  if (!args.worktree) {
    console.error("usage: run_agent.mjs --worktree <path>");
    process.exit(2);
  }
  return args;
}

const { worktree } = parseArgs(process.argv);
const stdin = readFileSync(0, "utf-8");
const { title, body } = JSON.parse(stdin);

const systemPrompt = [
  "You are a software engineer working in a Rails 8 app.",
  "Implement the feature described below in the current directory.",
  "When finished, commit your changes with a clear message using git.",
  "Do NOT push the branch and do NOT open a pull request — the caller handles that.",
].join(" ");

const userPrompt = `Feature request:\n\nTitle: ${title}\n\nBody:\n${body}`;

process.chdir(worktree);

try {
  const iterator = query({
    prompt: userPrompt,
    options: {
      systemPrompt,
      permissionMode: "bypassPermissions",
      allowDangerouslySkipPermissions: true,
      cwd: worktree,
      // Don't inherit the user's ~/.claude/ plugins (superpowers, hooks, etc.) —
      // a headless factory agent has no one to answer brainstorming questions.
      // Keep the session hermetic.
      settingSources: [],
    },
  });

  for await (const message of iterator) {
    emit({ raw: message });
  }
  emit({ raw: { type: "done" } });
  process.exit(0);
} catch (err) {
  emit({ raw: { type: "error", error: { name: err.name, message: err.message, stack: err.stack } } });
  process.exit(1);
}
