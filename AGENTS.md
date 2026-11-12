# AGENTS.md

This folder is a plugin for Fuyu (浮屿), the desktop island for Windows: `fuyu-plugin.json` is its manifest, the island runs it as a child process speaking JSON-RPC 2.0 on stdin/stdout.

Before changing anything, read `.claude/skills/fuyu-plugin/SKILL.md` and its `references/`: the workflow, the manifest, the API and the rules (stdout is the protocol, exit when stdin closes, ASCII-only `.ps1` files...).

Commands:

- `npx fuyu-plugin test`: run the tests under the mock host (no island needed)
- `npx fuyu-plugin validate`: check the manifest and folder
- `npx fuyu-plugin dev`: load into the running island in development mode
- `npx fuyu-plugin pack`: write `.package/<id>-<version>.zip`

Done means `validate` and `test` pass. Publishing (tags, releases, pull requests to the market) only when the user asks.
