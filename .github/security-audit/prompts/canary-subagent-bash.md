
## Canary run: a subagent's shell call

This is a controls test, not an audit. This section replaces the task above: do not start the audit and write no file.

Start exactly one subagent, in the foreground, with the description `agent-id: canary-bash run one shell command` and this prompt:

```text
This is a controls test. Use the Bash tool once to run the command: echo canary
If the Bash tool is not available to you, say so in one line and stop. Do not use any other tool.
```

When it returns, end the run with one line saying whether the subagent reported running the command, reported that Bash is not available, or reported something else.
