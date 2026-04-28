#!/usr/bin/env node
// Runs a Claude Agent SDK session inside a pre-existing worktree.
// Reads JSON from stdin (shape depends on --mode).
// Writes one JSON event per line to stdout.
// Exits 0 on success, nonzero on error.

import { query } from "@anthropic-ai/claude-agent-sdk";
import { readFileSync } from "node:fs";
import process from "node:process";

function emit(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function parseArgs(argv) {
  const args = { worktree: null, mode: "implement" };
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--worktree") args.worktree = argv[++i];
    else if (argv[i] === "--mode") args.mode = argv[++i];
  }
  if (!args.worktree) {
    console.error("usage: run_agent.mjs --worktree <path> [--mode implement|reviewer|address]");
    process.exit(2);
  }
  if (!["implement", "reviewer", "address"].includes(args.mode)) {
    console.error(`unknown mode: ${args.mode}`);
    process.exit(2);
  }
  return args;
}

const SYSTEM_PROMPTS = {
  implement: [
    "You are a software engineer working in a Rails 8 app.",
    "Implement the feature described below in the current directory.",
    "When finished, commit your changes with a clear message using git.",
    "Do NOT push the branch and do NOT open a pull request — the caller handles that.",
  ].join(" "),

  reviewer: [
    "You are reviewing a pull request.",
    "Read the diff in the current directory using `git diff main...HEAD`.",
    "Compare the diff against the feature request title and body provided below.",
    "If there are real correctness, scope, or quality issues, run:",
    "`gh pr review <pr_url> --request-changes --body \"<your concerns, in plain English>\"`.",
    "If there are no real issues, run: `gh pr review <pr_url> --comment --body \"<short positive note>\"`.",
    "Do NOT use --approve — GitHub blocks self-approval and we run as the PR author.",
    "Do NOT make any code changes. Do NOT commit. Do NOT push.",
    "Run exactly one `gh pr review` command and stop.",
  ].join(" "),

  address: [
    "You are addressing review feedback on a pull request.",
    "The original feature request, the current diff, and the reviewer's comments are below.",
    "Make the code changes that the reviewer requested.",
    "Commit your changes with a clear message using git.",
    "Do NOT push and do NOT open a PR — the caller handles that.",
  ].join(" "),
};

const { worktree, mode } = parseArgs(process.argv);
const stdin = readFileSync(0, "utf-8");
const payload = JSON.parse(stdin);

function buildUserPrompt(mode, payload) {
  const { title, body, pr_url, diff, feedback } = payload;
  switch (mode) {
    case "implement":
      return `Feature request:\n\nTitle: ${title}\n\nBody:\n${body}`;
    case "reviewer":
      return [
        `PR URL: ${pr_url}`,
        `Original feature request:\nTitle: ${title}\nBody:\n${body}`,
        `Use \`git diff main...HEAD\` to read the diff.`,
        `Decide: --request-changes or --approve.`,
      ].join("\n\n");
    case "address":
      return [
        `Original feature request:\nTitle: ${title}\nBody:\n${body}`,
        `Current diff:\n${diff}`,
        `Reviewer feedback:\n${feedback}`,
        `Address the feedback and commit.`,
      ].join("\n\n");
  }
}

const userPrompt = buildUserPrompt(mode, payload);

process.chdir(worktree);

try {
  const iterator = query({
    prompt: userPrompt,
    options: {
      systemPrompt: SYSTEM_PROMPTS[mode],
      permissionMode: "bypassPermissions",
      allowDangerouslySkipPermissions: true,
      cwd: worktree,
      // Hermetic — no user/project plugins or hooks.
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
