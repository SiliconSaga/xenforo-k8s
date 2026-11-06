# Fixture: a shell fence that is literal content inside a text block

The second fence below is transcript, not an opener, and the `if` under it is
not a script. A parser that does not track the `text` block reports a syntax
error in a perfectly good document.

```text
```bash
if
```

And a real block after it, to prove the parser recovers and keeps checking:

```bash
echo "this one is genuinely shell"
```
