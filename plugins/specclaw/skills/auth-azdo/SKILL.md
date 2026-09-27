---
description: Interactive setup for Azure DevOps authentication. Prompts for organization, project, and repo, validates a Personal Access Token, and saves credentials to gitignored .specclaw/.env. Run once per project before /specclaw:pr-azdo.
disable-model-invocation: true
---

# specclaw auth azdo

**First, run** `specclaw-ensure-init .specclaw` — idempotently creates `.specclaw/` if it doesn't exist (silent if already initialized; auto-inits using the current directory's basename as the project name).

Interactive Azure DevOps authentication setup. Guides the user to create a PAT, validates it, and saves credentials.

**The user must run this command themselves in a real terminal — `specclaw-auth-azdo` prompts for a Personal Access Token, so it refuses to run without `/dev/tty`.**

**Agent: run `specclaw-auth-azdo .specclaw` anyway.** It exits before any prompt (exit code 1 here is the expected outcome, not a failure) and prints the exact commands for the user's platform — on Windows a ready-to-paste PowerShell block that first prepends the plugin's `bin` to `PATH`, because that directory is on `PATH` only inside the agent's shell, not the user's. **Relay that block to the user verbatim** (tool output is not reliably shown to them). Do not paraphrase it, and do not hand the user a bare `specclaw-auth-azdo .specclaw` — outside the agent's shell that fails with "command not found".

1. **The user runs** the command from the block the script printed:
   - Prompts for org name, project name, repo name.
   - Guides the user to `https://dev.azure.com/<org>/_usersSettings/tokens` to create a PAT.
   - Required scopes: Code (Read & Write), Work Items (Read & Write).
   - Validates the token via ADO REST API.
   - Saves org/project/repo to `config.yaml` under the `azdo:` section; token to `.specclaw/.env` (gitignored).
2. Report success and suggest `/specclaw:pr-azdo <change>` as the next step.
