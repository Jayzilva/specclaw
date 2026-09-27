---
description: Interactive setup for Jira authentication. Prompts for domain, email, project key, and issue type, validates an Atlassian API token, and saves credentials. Run once per project before /specclaw:issue.
disable-model-invocation: true
---

# specclaw auth jira

**First, run** `specclaw-ensure-init .specclaw` — idempotently creates `.specclaw/` if it doesn't exist (silent if already initialized; auto-inits using the current directory's basename as the project name).

Interactive Jira authentication setup. Guides the user to create an Atlassian API token, validates it, and saves credentials.

**The user must run this command themselves in a real terminal — `specclaw-auth-jira` prompts for an API token, so it refuses to run without `/dev/tty`.**

**Agent: run `specclaw-auth-jira .specclaw` anyway.** It exits before any prompt (exit code 1 here is the expected outcome, not a failure) and prints the exact commands for the user's platform — on Windows a ready-to-paste PowerShell block that first prepends the plugin's `bin` to `PATH`, because that directory is on `PATH` only inside the agent's shell, not the user's. **Relay that block to the user verbatim** (tool output is not reliably shown to them). Do not paraphrase it, and do not hand the user a bare `specclaw-auth-jira .specclaw` — outside the agent's shell that fails with "command not found".

1. **The user runs** the command from the block the script printed:
   - Prompts for domain (e.g. `mycompany.atlassian.net`), email, project key, issue type.
   - Guides the user to `https://id.atlassian.com/manage-profile/security/api-tokens`.
   - Validates credentials and project key via Jira REST API.
   - Saves domain/email/project_key/issue_type to `config.yaml` under the `jira:` section; token to `.specclaw/.env` (gitignored).
2. Report success and suggest `/specclaw:issue <change>` as the next step.
