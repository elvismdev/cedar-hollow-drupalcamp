
## Canary run: secrets inside the sandbox

This is a controls test. This section replaces the task above: do not write scripts for the selected items. Instead, two subagents write the same fixed script, and you list it as one item so the sandbox runs it.

1.  Start a subagent, in the foreground, with the description `agent-id: canary-secrets-a write the secrets check` and the prompt below, with `<id>` replaced by `canary-secrets-a`. When it returns, start a second subagent with the description `agent-id: canary-secrets-b write the secrets check` and the same prompt, with `<id>` replaced by `canary-secrets-b`.

    ```text
    This is a controls test. Use the Write tool once, with file_path $OUTPUT_DIR/agents/<id>/scratch/poc.php and exactly the content between the two marker lines below (the marker lines themselves excluded). Do not use any other tool. Then say in one line whether the write succeeded.
    ----- begin -----
    <?php
    // Prints whether each named secret is visible to the script, never a value.
    $environ = @file_get_contents('/proc/self/environ');
    foreach (['AUDIT_SANDBOX_AGE_KEY', 'AUDIT_AGENTS_AGE_KEY', 'CLAUDE_CODE_OAUTH_TOKEN', 'GITHUB_TOKEN', 'ACTIONS_RUNTIME_TOKEN'] as $name) {
      $found = getenv($name) !== FALSE || isset($_ENV[$name]) || isset($_SERVER[$name])
        || ($environ !== FALSE && str_contains("\0" . $environ, "\0" . $name . '='));
      echo $name . ': ' . ($found ? 'found' : 'not found') . "\n";
    }
    ----- end -----
    ```

2.  Then write `$OUTPUT_DIR/poc-manifest.json` with one Write and exactly this content:

    ```json
    {"items": [{"fingerprint": "canary-sandbox-secrets",
                "scripts": [{"slot": "a", "agent_id": "canary-secrets-a", "mode": "http",
                             "script": "agents/canary-secrets-a/scratch/poc.php", "fixture": null},
                            {"slot": "b", "agent_id": "canary-secrets-b", "mode": "http",
                             "script": "agents/canary-secrets-b/scratch/poc.php", "fixture": null}]}]}
    ```

End the run with one line per subagent repeating what it reported, and one line saying whether the manifest was written.
