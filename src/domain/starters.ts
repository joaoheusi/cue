import { blankAction } from "./types";
const templates = [
  [
    "Resolve CI",
    "Inspect failing checks and make the smallest fix",
    "Coding",
    "ci,fix,git",
    "fix build,fix checks",
    "Work in this conversation and the current checkout. Inspect the CI failures for the current branch or pull request using the tools available to you. Identify the cause, make the smallest appropriate fix, and run the relevant checks. Do not commit, push, or start another conversation unless I ask. If you cannot access the failure logs, ask me to provide them. Report what changed and what you verified.",
  ],
  [
    "Resolve merge conflicts",
    "Preserve the intent of both changes",
    "Coding",
    "git,conflicts",
    "merge conflicts",
    "Inspect the current Git state and explain which operation caused the conflicts. Resolve them while preserving the intent of both changes. Ask when the intended behavior is ambiguous. Do not discard unrelated work, commit, push, or continue a rebase or merge without my approval. Summarize the resolutions and the checks you ran.",
  ],
  [
    "Explain this PR",
    "Understand the change as a linear flow",
    "Coding",
    "review,explain",
    "pull request",
    "Explain this pull request as a linear flow. First describe the behavior before the change: what called what, in what order, and what happened. Then explain the new flow and its user-visible effects. Identify changed conditions, removed calls, side effects, and failure paths. Use simple technical English. Ask for the PR or diff if it is not available in this conversation.",
  ],
  [
    "Review current changes",
    "Find concrete bugs and unsafe assumptions",
    "Coding",
    "review,bugs",
    "",
    "Review the current changes for correctness, regressions, missing cases, and unsafe assumptions. Focus on concrete issues rather than style preferences. Explain each finding with the relevant file, behavior, and consequence. Do not modify files unless I ask. State what you could not verify.",
  ],
  [
    "Rewrite clearly",
    "Clear, natural English from your clipboard",
    "Writing",
    "english,rewrite",
    "rewrite text",
    "Rewrite the text below in clear, natural English. Keep the meaning and tone. Remove filler and unnecessary jargon. Return only the rewritten text.\n\nText:\n{{clipboard}}",
  ],
  [
    "Create a handoff",
    "Carry decisions and context into the next session",
    "Coding",
    "docs,handoff",
    "",
    "Create an implementation handoff from this conversation. Include the goal, decisions, interfaces, affected areas, edge cases, completed work, pending work, and verification steps. Clearly separate confirmed details from assumptions. Do not invent missing implementation details.",
  ],
];
export const starterActions = () =>
  templates.map(
    ([name, description, category, tags, aliases, template], i) => ({
      ...blankAction(category),
      name,
      description,
      template,
      tags: tags.split(","),
      aliases: aliases ? aliases.split(",") : [],
      favorite: i === 0 || i === 2 || i === 4,
    }),
  );
