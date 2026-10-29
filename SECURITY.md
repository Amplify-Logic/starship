# Security

## Reporting a problem

Report a security problem privately, not in a public issue.
A security problem is anything that could let Starship leak a secret, act outward without your word, change a project outside its isolated copy, or run something it should not.

1. Open the repository's **Security** tab and choose **Report a vulnerability**.
2. If that button is not there, open an issue that says only that you have a security report and asks for a private way to send it, and leave every detail out of the issue.

Say what you ran, what happened, and what you expected, and include the Starship commit you run (`git -C ~/starship rev-parse --short HEAD`).
Only the latest `main` is supported, so check that the problem is still there after "update starship".
Ordinary bugs go to [Issues](https://github.com/Amplify-Logic/starship/issues/new?template=bug.md).
A problem that comes from [Firstmate](https://github.com/kunchenguid/firstmate), the engine Starship is built on, is passed on to it.

## Know this before you run it

Starship runs without permission prompts.
The first mate launches Claude Code with its permission prompts turned off, and by default every Claude worker runs the same way, so they can run commands on your machine without asking each time; [Claude permission mode](docs/configuration.md#claude-permission-mode-configclaude-permission-mode) switches workers to Claude Code's reviewed mode instead.

What keeps it in line are its house rules, written in [AGENTS.md](AGENTS.md) and summed up in [what Starship must never become](docs/never-become.md), plus guard scripts that refuse unsafe steps:

- Workers change your projects only in isolated copies, and nothing merges without your word unless you turn that on for a project.
- Sending, posting and other outward actions need your permission ([worker outward actions](docs/configuration.md#worker-outward-actions-configoutward-permissions)).
- Destructive, irreversible and security-sensitive steps come back to you.

These are rules an AI follows and checks scripts run, not a sandbox.
Run Starship on a machine and with accounts where that is acceptable, and keep secrets it does not need off that machine.
