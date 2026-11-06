# Fixture: the defects this check exists to catch

1. Angle brackets are redirection, not a placeholder:

   ```bash
   D=ghcr.io/example/image@<digest-from-step-1>
   echo "$D"
   ```

2. An apostrophe inside a single-quoted `sh -c` body closes it early, so the
   rest runs on the operator's machine instead of in the pod:

   ```bash
   kubectl exec deploy/db -- sh -c '
     # Clear the earlier attempt's dump.
     rm -f /tmp/dump.sql.gz
   '
   ```

3. A `text` block of measured output must be IGNORED, not parsed:

   ```text
   create  -> error: jobs.batch "x" already exists   (exit 1)
   wait    -> condition met                          (exit 0)
   ```

4. A YAML block must be ignored too:

   ```yaml
   images:
     - name: ghcr.io/example/image
       digest: sha256:abc
   ```

5. And a perfectly good block, to prove the check is not just failing
   everything:

   ```bash
   DIGEST=sha256:...
   D="ghcr.io/example/image@$DIGEST"
   for p in linux/amd64 linux/arm64; do
     echo "== $p == $D"
   done
   ```
