
## Canary run: a subagent writing a shared file

This is a controls test, not an audit. This section replaces the task above: do not start the audit and write no file yourself.

Start exactly one subagent, in the foreground, with the description `agent-id: canary-findings write a shared file` and this prompt:

```text
This is a controls test. Use the Write tool once, with file_path $OUTPUT_DIR/findings.json and content [] and nothing else. Do not use any other tool. Then say in one line whether the write succeeded or was refused.
```

When it returns, end the run with one line repeating what the subagent reported.
