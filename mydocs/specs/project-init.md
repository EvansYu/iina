# Project initialization

- Date: 2026-10-13. Scope: initialize the AI development context for iina on the new `oona` branch.
- Authorization: the user explicitly requested branch creation, checkout and project initialization.
- Done contract: `oona` is checked out; CodeGraph status is healthy and its file inventory exists; a source-linked project CodeMap and four project entry documents exist; original README content is preserved with a backup; document links and fences pass checks.
- Boundary: documentation and local indexing only. No business source, dependency installation, ignore rules, commits or pushes.
- Plan: inspect repository evidence, index code, create navigation and collaboration documents, validate the diff and write back results.
- Risks: indexing does not establish runtime correctness; local Xcode availability and absent automated tests limit build verification.
- Checkpoint: branch created; README, contribution rules, CI, Xcode configuration and source entry points inspected. Proceed with documentation, then check links, placeholders, fences and source preservation.

## Result and validation

- Completed: `oona` created from the initial develop checkout and selected; no commit or push performed.
- CodeGraph: indexed 283 files, 11,376 nodes and 25,798 edges; final status reports up to date. Nonempty inventory: `.codegraph/iina_files_structure.md`.
- Created: GLOBAL_AGENTS.md, AGENTS.md, CLAUDE.md, project CodeMap and knowledge references. README gained a developer navigation section and a source-grounded Mermaid diagram; its complete prior content remains unchanged as a prefix, with byte-identical backup at `.codegraph/project-init-backups/2026-10-13/README.md`.
- Checks passed: local Markdown link targets, no unresolved template placeholders, balanced fences, equivalent agent entry content, current branch, unchanged business source, README backup/preservation, `git diff --check`, and Mermaid conservative-syntax self-check. No Mermaid rendering engine was run.
- Build skipped: `xcodebuild -version` reports Command Line Tools selected instead of full Xcode. No automatic test command identified from project targets, shared scheme or CI; runtime validation remains unperformed.
- Template adaptation: skill references use outdated filenames. Equivalent existing templates and the English Karpathy reference were located and used; no skill files were modified.
- Project sync: stable playback boundaries, generated-file restrictions and build facts are recorded in shared rules and the CodeMap. No further long-term knowledge candidate remains.
- Resume: initialization is complete; future application work needs full Xcode selection, native dependencies and relevant manual playback checks. Ignore policy remains unchanged for user review.
