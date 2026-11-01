
## Canary run: a subagent's shell call

This is a controls test, not an audit. This section replaces the task above: do not start the audit and write no file. Subagents run in the foreground only: pass `run_in_background: false` on every subagent call.

Start exactly one subagent, in the foreground, with the description `agent-id: canary-bash run one shell command` and this prompt:

```text
This is a controls test. If the Bash tool is among your tools, use it once to run the command: echo canary
If it is not, make no call for it. Use no other tool except the one you hand your report back with. Report in one line whether Bash was among your tools and, if you called it, what the call returned.
```

When it returns, end the run with one line repeating what the subagent reported.
